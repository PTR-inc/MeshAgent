# Module loader

How `require()` finds a module in the agent, how a server-pushed module replaces a built-in one, and why that no longer goes through `_altrequire`.
Code: `microscript/ILibDuktapeModSearch.c`, `microscript/ILibDuktape_Polyfills.c`, `microscript/ILibDuktape_Debugger.c`, `meshcore/agentcore.c`.

## Why it changed

Goal: a module the server pushes with its core must really replace the agent's built-in copy, everywhere in the heap, with one instance per module, and the agent must be able to say which copy runs.

The old way did not do that:

- **Pushed modules lost.** `addModule()` only replaced a module whose pushed date was newer than the built-in date. Every built-in module has a date, the server pushed none, so the pushed copy never got in.
- **`_altrequire` was a patch on top of a loaded module.** When `addModule()` replaced a module that was already `require()`d, it swapped `global.require` for `_altrequire`. That function compiled the new source under a second name (`<name>_<uuid>`) and handed that out. Problems:
  - Only `global.require` was swapped. Inside a module, Duktape passes its own module-local `require`, so code in modules kept getting the old instance.
  - Every module that had been loaded before the swap got a second instance at its next `require()`, replaced or not. `promise` ended up twice in one heap, with two `Promise` classes.
  - The first alternate instance was cached for good, so a second replacement of the same module was never seen.
  - "Already loaded" was a flag set before the module compiled, so a module that failed to load still counted as loaded.
  - Nothing reported which copy ran: the uuid copy had no origin, version or date.
- **A `<name>.js` file next to the binary replaced any module**, and ran with the agent's rights without a trace.

The new loader removes `_altrequire`, `_legacyrequire` and the alternate table. A replacement goes into the one module table, and the next `require()` compiles it under its own name.

## Design principles

The starting points every decision below was checked against.

- **As simple as possible.** One module table, one decision point (`ILibDuktape_ModSearch_AddModuleChecked()`), one report.
- **Low impact on the agent and on the agent-server traffic.** The report rides in `coreinfo`, which the core already sends, so there is no new command. The core reads its working directory on its existing info run, only in the modes that need it (see the table in the reporting section), and sends only when the list changed. The server compares with the stored report, so a reconnect or a server restart sends and writes nothing new.
- **Prefer no database entry.** No new record type, only the last report as `dm` on the existing device record.
- **Visible to the user and the admin.** A popup when the state changes, a notification at login, a message on the device (the dot in the device list and on the device page), event lines on the device, and the `modules` console commands on the agent and the server.
- **Logged on the agent and on the server.** The agent writes `-allowDiskModules`, every `setModulePath()` call and every disk file that replaces a built-in or pushed module (with the file name) to its `.log`. The server writes event lines 167 to 172 into the device's event log.
- **Secure: not circumventable from remote, traces not removable.** Disk loading and the debugger need a debug build or `-allowDiskModules` on the command line, which only a local admin can set. Neither the server, the `.msh`, the `.db` nor a module can switch them on. The server derives the reason from the reported mode instead of trusting a reason sent by the agent, and the event lines it wrote are out of the agent's reach.
  Limit: this holds for the stock agent binary. A modified binary can report anything, including no files.

## Design overview

```
require(id)
  └─ Duktape.modLoaded[id]      already loaded: the cached instance
  └─ mod_Search(id)             first load:
       1. module object          addModuleObject()
       2. native C binding       never replaceable
       3. disk file <id>.js      only when the disk mode allows it
       4. table copy             built-in ("internal") or pushed ("server")
       5. .db "__MODULE:<id>"    last fallback
```

- **One table per heap** holds every JavaScript module's source, with its origin (`internal` or `server`) and date. The agent's own modules are added at heap creation, `ILibDuktape_ModSearch_BuiltinModulesDone()` marks the end, everything added after that is `server`.
- **One decision point**, `ILibDuktape_ModSearch_AddModuleChecked()`, behind `addModule()` and `addCompressedModule()`:
  1. Identical text: kept, nothing to do.
  2. The `/*! @module-version=N */` first line decides: the higher version wins, a version beats no version.
  3. Same version, different text: the copy added after the built-in set wins (the server's).
  4. No version on either side: the newer date wins, without dates the new copy replaces.
  5. Returns `true` when the given copy is now the one in use.

  `addModule()` throws for a name that is not a string and for a missing source.

  A module that the agent embeds and the server also pushes (today `monitor-border`, `util-agentlog` and `win-console`, which the server marks `@module-version=1`) goes to whichever side carries the higher number. The agent's copies have no version line, so the server's copy is used. For the agent's copy to win again, its `modules/<name>.js` needs a higher number than the server's.
- **Replacing a loaded module** removes its entry from `Duktape.modLoaded` (`ForgetLoaded()`). The next `require()` from anywhere, global or module-local, compiles the new copy. Code that already holds the old instance keeps it. Native bindings are never replaced.
- **Disk files** follow a mode: 0 never (release default), 1 only for names the table does not have (script mode), 2 always (`-allowDiskModules` on the command line, never from `.msh` or `.db`), 3 always (debug build). Every disk load emits `process.on('diskModule')`, and one that replaces a table copy is also logged.
- **Reporting**:
  - `getJSModuleInfo(name)`: `{ source, version, date }` of the copy `require()` would load now. Source is `native`, `disk`, `internal` or `server`. A copy that only the `.db` cache holds is not looked at.
  - `getJSModulesLoaded()`: the same per module for what was really loaded, plus `db` for a copy that came from the `.db` cache.
  - `getJSModuleDiskMode()`: the disk mode.
  - `getModules(true)`: also lists the native names.
  - `showModuleNames` in the `.db` traces every first load as `ModuleLoader: <name>, <source>, <version>` to the console and the log.

## Step by step: a pushed module replaces a built-in one

Example: the built-in `win-com` has version 3, the server's copy has version 4.

1. The server builds the core with `addModule('win-com', source)` (or `addCompressedModule`) lines at the top, and pushes it.
2. The core runs and calls `addModule('win-com', source)`.
3. `AddModuleChecked()` reads the table copy, parses both version lines: 4 > 3, so the copy is added.
4. `ForgetLoaded('win-com')` removes `win-com` from `Duktape.modLoaded`, if it was loaded.
5. `AddModuleEx()` writes the source into the table, origin `server`, with the pushed date or none.
6. `addModule()` returns `true`.
7. The next `require('win-com')` finds no cached instance, `mod_Search()` returns the table copy, Duktape compiles it and caches it under `win-com`.
8. `getJSModulesLoaded()['win-com']` now says `{ source: "server", version: 4, ... }`.

A server copy with a lower version is not added and `addModule()` returns `false`. Identical text is not added either, but returns `true`, because that copy is already in use.

## Step by step: core start with replaced modules

Every core start now runs the core first in a fresh heap, so the modules it brings are added before anything loads them.

1. The agent starts, creates a heap, registers the built-in modules and calls `BuiltinModulesDone()`. Its start-up code loads a few of them (`promise`, `win-registry`, `win-com` and others on Windows).
2. It connects and sends the hash of the core cached in the `.db`.
3. Then one of three things happens:
   - **Core changed**: it pushes the new core. The agent stores it in the `.db` and starts it with `ScriptEngine_Restart()`.
   - **Core unchanged** (CoreOk): the agent calls `MeshAgent_LaunchCachedCore()`, which also starts the cached core with `ScriptEngine_Restart()`. Before this change it ran in the existing heap, next to the already loaded built-in instances.
   - **No server within 60 s**: the timer posts `MeshAgent_LaunchCachedCore_Sink()` to the chain, so the heap is not destroyed under the running timer callback. It runs only while that heap is still the live one, so a core push that arrived in between is not started a second time.
4. `ScriptEngine_Restart()` destroys the old heap and builds a new one. The built-in modules are registered again, and the heap's own setup loads only a few of them (`compressed-stream`, `promise`).
5. The core is compiled and runs. Its `addModule()` lines replace the built-in copies by the rules above.
6. The core's `require()` calls load the server copies. A pushed module whose name was loaded during setup is still dropped from `modLoaded` by `ForgetLoaded()`, as in the previous section.

The `noUpdateCoreModule` and local debug mode starts use the same launch.

Cost: one extra heap build per start.

## Module reporting to the server

Goal: the server must see when an agent can load, or did load, module files from its working directory, and tell the user, without extra traffic at every connect.

Design: the core builds one report at start and sends it as the `dm` field of `coreinfo`, which the core already sends at every connect and again on any change. The server compares it with the copy stored in the device record and only acts on a difference. The server code lives in MeshCentral: `agents/meshcore.js`, `meshagent.js`, `webserver.js`, `meshuser.js`.

### Agent side (the core, `agents/meshcore.js`)

1. At core start, `getJSModuleDiskMode()` gives the mode. On an agent without that global the mode is `null` (an old agent, where disk files always win).
2. Except in mode 1, the core lists the `*.js` files in `process.cwd()`, and lists them again on the info runs the table below gives. A changed list replaces `dm.files` and goes out with `coreinfo`, so a removed or added file is seen without an agent restart.
3. In mode 2 or 3 it takes the names already loaded from disk from `getJSModulesLoaded()` (`source == "disk"`). In mode 2 it also listens to `process.on('diskModule')`: a new name goes into `dm.loaded` and `meshCoreObjChanged()` sends `coreinfo` again.
   The core writes the file list to the agent's log with `console.rawLog()` at start (when files are present or in mode 2 or 3) and when a re-read finds a change. The agent's C code only logs the switch and the disk loads that replace a module.

What runs per mode:

| mode | start report and log | `diskModule` hook | re-read of the directory | why |
|---|---|---|---|---|
| 0 release | yes (log only with files) | no | at connect and on `coreinfoupdate` | Nothing loads, so a file planted later is harmless. The re-read lets a removed file clear the warning without an agent restart. |
| 1 script | no | no | no | The core does not run in script mode. Disk files there are the script's own helpers. |
| 2 `-allowDiskModules` | yes | yes | at connect, every 5 minutes, on `coreinfoupdate` | The only mode where a file planted after start replaces a module, so loads are reported live and the list is kept current. |
| 3 debug | yes | no | no | Loading from disk is the normal way a debug build works, a line per load would be noise. The start report marks the build for good. |
| `null` old agent | yes (log only with files) | not possible | at connect, every 5 minutes, on `coreinfoupdate` | A stock agent loads files without any event, so the re-read is the only way to see a file planted later. |
4. It sets `meshCoreObj.dm = { mode, files, loaded }`, with `files` and `loaded` sorted so the server can compare them as text. Files whose name matches a module go first. The core sends facts only, the server decides what they mean.

`dm` is always present from this core on, so the server can tell "nothing to report" from a core that does not know the field.

### Server side

1. `ChangeAgentCoreInfo()` (`meshagent.js`) passes `command.dm` to `processDiskModulesReport()`.
2. `processDiskModulesReport()` ignores a report whose `mode` is not `null` or 0 to 3. It cleans the names (at most 1000 entries, a fixed character rule: file names without a path, up to 64 characters, and loaded module names with a path allowed, up to 260 characters, because `require('sub/x')` loads `sub/x.js`; a file name outside the rule is counted as `others`, a loaded name outside it is left out) and derives the reason from the mode and the files:

| `reason` | when |
|---|---|
| `allowdisk` | mode 2, the agent runs with `-allowDiskModules` |
| `debug` | mode 3, a debug build |
| `oldagent` | mode `null`, files present: an old agent loads them over every built-in module |
| `notloaded` | mode 0, files present but ignored |
| none | nothing to report, the state is `null` |

   The state is `{ reason, files, others, loaded }`. `setDiskModules()` keeps it on the connection and sets the device message (the dot in the device list, the count and the message on the device page), ids 173 to 176 with the file list as argument.
3. It compares the state with `device.agent.dm`. Equal: nothing more happens. That covers every reconnect and every server restart.
4. Different: it writes `device.agent.dm` and the existing `db.Set(device)` and `changenode` event carry it to the database and the open pages.
5. A new state (the first report, or the reason changed) gets the full report: an event line on the device (ids 167 to 172) and the warning popup. In the same state, a list with new files writes event 177, the new files first and then all files, and popup 45 naming only the new files. A list with fewer files writes nothing, the device message and the login warning show the current list anyway.
6. For every name newly in `loaded` it writes event 169, and with `allowdisk` a popup naming the file.
7. The connection keeps the state in `obj.diskModules`, filled at connect from `device.agent.dm`, so a login that comes before the first `coreinfo` already sees it. At login, users with rights on a flagged agent get one notification per agent, at most 10, linking to the device's Events tab.
8. Console commands: on the device, `modules [e l i s d n r]` lists the modules with source, version and date from `getJSModuleInfo()` and `getJSModulesLoaded()`. On the server, `modules w` lists every connected flagged agent.

Compatibility: an old server ignores `dm`. With an old core, `dm` is missing and the stored state stays as it is, until a newer core reports again.

## Module debugger

Goal: keep the JavaScript debugger for development and testing, and make it unreachable on a production agent unless someone with local admin rights asks for it.

Why: the debugger is a remote shell without a password.
- `attachDebugger()` starts a web UI with `WebServer.listen({ port: webport })` (`modules/duktape-debugger.js`) and no host, so it listens on every interface. Behind it, the engine-side transport (`ILibDuktape_Debugger.c`) accepts the first local connection on its port.
- The debugger's `Eval` runs any code in the agent's heap, as root or SYSTEM.
- Before this change, `attachDebugger` was a global in every heap, and the `.db` key `jsDebugPort` turned it on for the core. The server can write the `.db`, and a pushed core, a plugin or a console `eval` can call the global directly.
- Release builds were only safe by accident: `duktape-debugger.js` is not embedded in the agent. Any code that brings that module along with `addModule()` gets a working debugger.

The gate uses the same condition as disk modules, because it is the same trust decision. Both let local code take over the agent. So both need a debug build, or `-allowDiskModules` on the command line, which only a local admin can set, which is never read from `.msh` or `.db`, and which is reported to the server (see the reporting section above).

- **What**: Duktape debugger, `attachDebugger({ webport, wait })`, with a browser UI on `jsDebugPort`.
- **Gate**: only when `getJSModuleDiskMode() >= 2`, a debug build or `-allowDiskModules`. Otherwise `attachDebugger` is not registered in any heap, the `.db` key `jsDebugPort` is ignored and logged, and the test helpers `_debugHang`, `_debugCrash`, `_debug`, `_rootObject`, `_nextObject`, `_countObjects` are not registered.
- **Core under the debugger**: with `jsDebugPort` set, `MeshAgent_CoreWithDebugger()` puts an `attachDebugger({ webport: <jsDebugPort>, wait: 1 })` line in front of the cached core before `ScriptEngine_Restart()`. The core waits until a browser connects, so breakpoints can be set before any core module loads. `wait: 0` attaches without waiting. A core pushed by the server starts without the debugger; re-attaching after a push comes with the `debugger-fixes` branch.
- **Debugging a script**: `MeshService64.exe script.js -allowDiskModules`, the switch after the script name.
