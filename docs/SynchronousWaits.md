# Synchronous Waits: `waitExit()` / `promise.wait()` and nested continuation frames

## The problem this solves

`child.waitExit()` (and `promise.wait()`) are synchronous blocking APIs on a
single-threaded event loop. They block by **re-entering the event loop**: the
implementation calls `ILibChain_Continue()`, which runs a nested copy of the
chain's select/dispatch loop until someone calls `ILibChain_EndContinue()` —
typically the child's exit handler — or the timeout expires.

Historically the chain tracked this with a single global enum,
`ILibBaseChain.continuationState`:

```
INACTIVE -> CONTINUE (ILibChain_Continue running) -> END_CONTINUE -> INACTIVE
```

That design had two hard limitations:

1. **Only one continuation could exist at a time.** If any JS executed while a
   continuation was pumping (an event handler, timer callback, dispatcher,
   etc.) and called `waitExit()` on another process, the second
   `ILibChain_Continue()` call found `continuationState == CONTINUE` and bailed
   with `ERROR_INVALID_STATE`, surfacing to script as the infamous
   **"waitExit() already in progress"** error.

2. **Exits could not be matched to waiters.** `ILibChain_EndContinue()` set the
   single global flag, so even if nesting had been allowed, *any* waited-on
   child exiting would have terminated the *innermost* loop, regardless of
   which child was actually being waited on. The old `\xFF_WaitExit` marker on
   the JS object was just a boolean — it carried no identity.

## The new design: a LIFO stack of continuation frames

Nested `ILibChain_Continue()` calls naturally form a stack (exactly like
nested Windows message loops), so they are now modeled as one.

### Data structures (`microstack/ILibParsers.c`)

```c
typedef struct ILibChain_ContinuationFrame
{
    struct ILibChain_ContinuationFrame *previous; // next-outer frame
    uint64_t serial;                              // unique token, never reused
    int depth;                                    // 1 = outermost
    int ended;                                    // set to leave the loop
} ILibChain_ContinuationFrame;
```

`ILibBaseChain` holds:

* `continuationTop` — pointer to the innermost live frame (`NULL` = inactive).
* `continuationSerial` — monotonically increasing counter; each new frame gets
  the next value.

Frames live **on the C stack of `ILibChain_Continue()` itself** — no heap
allocation, and the LIFO discipline is enforced by the call stack for free.

### `ILibChain_Continue()` lifecycle

1. Reject only if the nesting depth cap (`ILibChain_MaxContinuationDepth`, 16)
   is reached — this guards against runaway recursive waits overflowing the C
   stack. Otherwise nesting is allowed.
2. Push a frame: `serial = ++continuationSerial`, `ended = 0`,
   `previous = continuationTop`, then `continuationTop = &frame`.
3. Loop `while (TerminateFlag == 0 && frame.ended == 0)`. The timeout and
   empty-wait-set paths set `frame.ended = 1` (they only end *this* frame).
4. On exit, pop: `continuationTop = frame.previous`.

### Ending a continuation

* `ILibChain_EndContinue(chain)` — **legacy**: marks the *innermost* frame
  ended and unblocks the chain. Kept for existing callers.
* `ILibChain_EndContinue_BySerial(chain, serial)` — **new**: walks the frame
  stack looking for a frame with that exact serial and marks only it ended.
  A serial that matches no live frame is silently ignored.
* `ILibChain_PeekNextContinuationSerial(chain)` — returns
  `continuationSerial + 1`. Because the chain is single-threaded, the very
  next `ILibChain_Continue()` call is guaranteed to receive this serial, so a
  caller can record the token *before* entering the nested loop — which is
  required, because the code that ends the wait runs *from inside* that loop.

### Why serials instead of frame pointers or depth numbers?

Tokens can go stale: a `waitExit(timeout)` can return by timeout while the
child is still running, and the child's exit handler fires later. At that
point some *other* wait may be active:

* A recorded **frame pointer** could alias a new frame reusing the same stack
  address → would kill an unrelated wait.
* A recorded **depth** could match a new frame at the same nesting level →
  same problem.
* A recorded **serial** is never reused, so a stale token matches nothing and
  the call is a harmless no-op. (Even at one wait per millisecond, a uint64
  serial lasts ~584 million years. Stored as a Duktape number/double it is
  exact up to 2^53 — still ~285,000 years.)

As a belt-and-braces measure, the token property is also deleted from the JS
object as soon as the wait returns and after the exit handler consumes it.

### `ILibChain_GetContinuationState()` compatibility

Legacy callers (e.g. `ILibProcessPipe_Manager_OnPostSelect`, which stops
dispatching further pipe reads once the current continuation ends) still work;
the state is now derived from the stack:

| Stack state                  | Reported state  |
|------------------------------|-----------------|
| `continuationTop == NULL`    | `INACTIVE`      |
| innermost frame `ended == 0` | `CONTINUE`      |
| innermost frame `ended != 0` | `END_CONTINUE`  |

Note the state only reflects the **innermost** frame: if an outer frame is
marked ended while an inner wait is still pumping, dispatch continues — which
is correct, because the inner wait still needs its events.

The old main-loop reset (`END_CONTINUE -> INACTIVE` at the top of
`ILibStartChain`'s loop) was deleted; with the stack design the state is
`INACTIVE` by construction once all frames unwind.

## Call-site changes

### `child.waitExit()` (`microscript/ILibDuktape_ChildProcess.c`)

* Before calling `ILibChain_Continue()`, the predicted serial is stored on the
  spawnedProcess object as `\xFF_WaitExit` (previously a boolean `1`, and
  previously only when no continuation was active — that conditional existed
  precisely because nesting used to be an error).
* The exit handler (`..._SubProcess_ExitHandler`) reads the serial and calls
  `ILibChain_EndContinue_BySerial()`, ending exactly the frame that waits on
  this child, then deletes the property.
* After `ILibChain_Continue()` returns, `waitExit()` deletes the property so a
  timed-out child's later exit cannot end anyone else's frame.
* `ERROR_INVALID_STATE` now only means the depth cap was hit, so the error
  message changed from "waitExit() already in progress" to
  "waitExit() nesting depth limit reached".

### `waitExit()` timeout semantics

A child that never exits used to park its caller (and, per the LIFO rule, any
outer waits) forever when `waitExit()` was called with no argument. The
timeout contract is now:

| Call                  | Behavior on expiry                                       |
|-----------------------|----------------------------------------------------------|
| `waitExit()`          | Default timeout (`ILibDuktape_ChildProcess_DefaultWaitExitTimeout`, 120000&nbsp;ms); **throws** `"waitExit() timed out after Nms, child (pid=P) still running"` |
| `waitExit(ms)` (>0)   | Same rule with a custom deadline — **throws** after `ms` |
| `waitExit(-1)` / `waitExit(0)` | Waits forever — the explicit escape hatch       |

Rationale: a silently-returning timeout lets the caller proceed as if the
child had exited (no `exit` event, no exit code), and a later GC of the JS
object would then hard-kill a still-running child via the finalizer — silent
corruption instead of a visible error. Throwing makes the timeout loud and
catchable; the caller decides whether to `kill()`, retry, or wait longer. The
throw is guarded on the child actually still running (a photo-finish exit
returns normally), and the child is *not* auto-killed. Explicit timeouts
originally kept a silent-return contract for compatibility, but a survey of
all 264 in-tree `waitExit()` call sites found none passing a timeout at all,
so uniform throwing was chosen over an inconsistency that protected nothing.

Additionally, `waitExit()` on a child that has **already exited** now returns
immediately (previously it would re-enter the loop and wait forever, since
the exit handler that ends the wait had already fired).

The default also bounds the LIFO hold-open problem: a stack of defaulted
waits always unwinds within the default timeout per frame.

### `promise.wait()` (`microscript/ILibDuktape_ScriptContainer.c`)

Same pattern: the predicted serial is stored on the internal wait-state object
as `\xFF_WaitSerial` just before `ILibChain_Continue()`, the resolve/reject
sinks call `ILibChain_EndContinue_BySerial()` with it (previously they called
`ILibChain_EndContinue()` unconditionally — which could end an unrelated
innermost frame if the promise settled after the wait had already returned),
and the token is deleted once the wait returns.

## Semantics and caveats

* **LIFO unwind.** If `waitExit(A)` is outer and `waitExit(B)` is nested
  inside it and A exits first, A's `exit` event fires immediately (dispatched
  from B's loop) and A's frame is marked ended — but the `waitExit(A)` *call*
  physically returns only after B's loop unwinds. This is inherent to
  single-threaded nested blocking loops. Practical consequence: an outer wait
  can be held open past its own deadline by an inner wait; with the default
  `waitExit()` timeout this is bounded unless a caller explicitly opts into
  `waitExit(-1)`.
* **Windows child-exit detection in nested waits.** `waitExit()` passes the
  child's process/pipe handles into `ILibChain_Continue()`, and an inner
  nested loop does not carry the outer child's explicit handles. This is safe
  because `ILibProcessPipe` also registers every child's process handle and
  pipe events in the chain-wide `auxSelectHandles` list
  (`ILibChain_AddWaitHandle`), which every loop iteration — nested or not —
  merges into its wait set (`ILibChain_SetupWindowsWaitObject`).
* **Depth cap.** `ILibChain_MaxContinuationDepth` (16, overridable at build
  time via `#ifndef`) bounds C-stack growth from pathological recursive
  waiting. Hitting it returns
  `ILibChain_Continue_Result_ERROR_INVALID_STATE`, which `waitExit()` /
  `wait()` surface as a thrown "nesting depth limit reached" error.
  Measurements behind the number: each nested level — timer dispatch → JS
  callback → spawn → `waitExit()` → `ILibChain_Continue()` — consumes roughly
  35&nbsp;KB of C stack. Win64 Release with the old default 1&nbsp;MB stack overflowed
  at depth ~28, so the Windows vcxprojs now reserve an 8&nbsp;MB stack
  (`StackReserveSize`; reserve is address space, committed on demand, so
  unused depth costs no RAM). Linux main threads already get 8&nbsp;MB via the
  default ulimit, and a probe build with the cap raised to 64 ran all 64
  nested levels without incident — so 16 carries at least 4× margin, plus
  room for deeper JS stacks per level. Ports with smaller stacks (embedded
  targets, or the agent embedded as a library into a host thread) should
  define a lower `ILibChain_MaxContinuationDepth` at build time. Realistic
  legitimate nesting is 2–4 deep; anything approaching 16 almost certainly
  indicates a recursion bug in script.
* **Threading.** All of this is single-threaded by design;
  `ILibChain_EndContinue_BySerial` must be called on the chain thread (as
  `ILibChain_EndContinue` always had to be).
