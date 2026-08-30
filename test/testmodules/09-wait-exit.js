/*
Copyright 2026

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

//
// child_process.waitExit() and promise.wait(): a wait nested inside another wait, the timeout that
// throws, 0 and -1 as wait forever, a wait on an already exited child, the nesting depth cap, and
// the ProcessPipe races that only show with many children alive at once.
//

exports.name = 'Wait Exit';
exports.run = function (check, deepEqual, done) {
    var S = 'WaitExit';
    var cp = require('child_process');
    var promise = require('promise');   // The engine has no global Promise, this is the polyfill with wait().
    var isWin = process.platform == 'win32';
    var shell = isWin ? (process.env['ComSpec'] || 'C:\\Windows\\System32\\cmd.exe') : '/bin/sh';
    var shellArgv0 = isWin ? 'cmd.exe' : 'sh';

    // Every child gets stdout and stderr readers so both pipes are drained, and an exit counter.
    function sh(cmd) {
        var c = cp.execFile(shell, [shellArgv0, isWin ? '/c' : '-c', cmd]);
        c.exits = 0; c.code = null;
        c.on('exit', function (code) { this.exits++; this.code = code; });
        c.stdout.on('data', function () { });
        c.stderr.on('data', function () { });
        return c;
    }
    // Windows has no sub second sleep. ping -n 2 takes about one second.
    function sleeper(sec) { return sh(isWin ? ('ping -n ' + (Math.ceil(sec) + 1) + ' 127.0.0.1 >nul') : ('sleep ' + sec)); }
    var anchors = [];   // Timer objects stay referenced here, see the stress-test.js header.

    // --- a wait nested inside another wait. The outer child's 'exit' handler runs inside the outer
    //     wait's loop, spawns a second child and waits for it there ---
    var outer = sleeper(0.5), nestOK = false, innerCode = -1, nestErr = null;
    outer.on('exit', function () {
        var inner = sh('exit 5');
        try { inner.waitExit(); nestOK = true; innerCode = inner.code; } catch (e) { nestErr = '' + e; }
    });
    outer.waitExit();
    check(S, nestOK && innerCode == 5, 'nested waitExit() inside another waitExit() failed (ok=' + nestOK + ', code=' + innerCode + ', err=' + nestErr + ')');

    // --- the timeout throws, and a timer armed before the wait fires inside it and waits on a second
    //     child there. waitExit(1) rounds up to one second, and the deadline check has whole second
    //     precision, so the throw comes between 1 and 2 seconds after the call. The base timer runs
    //     inside the wait, so the 100 ms timer is dispatched before that deadline ---
    var hung = sleeper(3), threw = null, t0 = Date.now(), timerNestOK = false, timerCode = -1, timerErr = null;
    anchors.push(setTimeout(function () {
        var viaTimer = sh('exit 5');
        try { viaTimer.waitExit(); timerNestOK = true; timerCode = viaTimer.code; } catch (e) { timerErr = '' + e; }
    }, 100));
    try { hung.waitExit(1); } catch (e) { threw = '' + e; }
    var took = Date.now() - t0;
    check(S, timerNestOK && timerCode == 5, 'timer inside a wait: nested waitExit() failed (ok=' + timerNestOK + ', code=' + timerCode + ', err=' + timerErr + ')');
    check(S, threw != null && threw.indexOf('timed out') >= 0, 'waitExit(1) did not throw a timeout: ' + threw);
    check(S, took >= 900 && took < 6000, 'waitExit(1) returned after ' + took + 'ms, expected 1 to 2 seconds');
    hung.kill();

    // --- a later wait is not ended by the stale token of the timed out child, and a wait on an
    //     already exited child returns at once ---
    var later = sleeper(0.3), t1 = Date.now();
    later.waitExit();
    var d1 = Date.now() - t1;
    check(S, later.code == 0 && d1 >= 200, 'wait after a timed out wait returned early (' + d1 + 'ms, code ' + later.code + ')');
    t1 = Date.now();
    later.waitExit();
    check(S, Date.now() - t1 < 1000, 'waitExit() on an already exited child did not return at once');

    // --- 0 and -1 both mean wait forever. 0 used to give select() a zero timeout and spun at
    //     100% CPU, so the check is simply that the wait returns once the child exits ---
    var z = sleeper(0.3); t1 = Date.now(); z.waitExit(0); d1 = Date.now() - t1;
    check(S, z.code == 0 && d1 >= 200, 'waitExit(0) returned after ' + d1 + 'ms with code ' + z.code);
    var m = sleeper(0.3); t1 = Date.now(); m.waitExit(-1); d1 = Date.now() - t1;
    check(S, m.code == 0 && d1 >= 200, 'waitExit(-1) returned after ' + d1 + 'ms with code ' + m.code);

    // --- promise.wait() nested inside promise.wait(). The outer promise settles from a child's
    //     'exit' handler, which runs inside the outer wait's loop and waits there for a second
    //     promise that another child's exit settles ---
    var host = sleeper(0.5), pv = null, inner = null, perr = null;
    var p1 = new promise(function (res) {
        host.on('exit', function () {
            var second = sleeper(0.3);
            var p2 = new promise(function (r2) { second.on('exit', function () { r2('inner'); }); });
            try { inner = promise.wait(p2); } catch (e) { perr = '' + e; }
            res('outer');
        });
    });
    try { pv = promise.wait(p1); } catch (e) { perr = '' + e; }
    check(S, pv == 'outer' && inner == 'inner' && perr == null, 'nested promise.wait(): outer=' + pv + ' inner=' + inner + ' err=' + perr);

    // --- 'exit' fires once even with stdout and stderr both piped. Each pipe breaking used to run
    //     the exit handler again ---
    var both = sh(isWin ? 'echo out & echo err 1>&2 & exit 3' : 'echo out; echo err >&2; exit 3');
    both.waitExit();
    check(S, both.exits == 1 && both.code == 3, "'exit' fired " + both.exits + ' time(s) with code ' + both.code + ', expected once with 3');

    // --- depth cap: 16 nested waits with 17 children alive at once. The 17th nested wait throws,
    //     and every child's exit still reaches its own wait, so no pipe read was skipped and no fd
    //     or pid was mixed up. A SIGCHLD listener adds the second waitpid() path that raced the
    //     pipe reap. The children sleep 3 seconds because a timer set inside a nested wait can be
    //     held back for up to a second by the base timer's select() floor ---
    var depth = 0, maxDepth = 0, capHits = 0, okWaits = 0, launched = 0, lostExits = 0, sigchld = 0;
    var onSig = function () { sigchld++; };
    if (!isWin) { try { process.on('SIGCHLD', onSig); } catch (e) { } }
    function nest() {
        ++depth; if (depth > maxDepth) { maxDepth = depth; }
        var c = sleeper(3);
        if (++launched < 17) { anchors.push(setTimeout(nest, 30)); }
        try { c.waitExit(); ++okWaits; if (c.exits != 1) { lostExits++; } }
        catch (e) { if (('' + e).indexOf('nesting depth') >= 0) { ++capHits; } c.kill(); }
        --depth;
        if (depth == 0) { finishDepth(); }
    }
    function finishDepth() {
        if (!isWin) { try { process.removeListener('SIGCHLD', onSig); } catch (e) { } }
        check(S, maxDepth == 17 && okWaits == 16 && capHits == 1, 'depth cap: max depth ' + maxDepth + ', ' + okWaits + ' waits ok, ' + capHits + ' cap hit (expected 17, 16, 1)');
        check(S, lostExits == 0, lostExits + ' nested wait(s) returned without their exit event');
        if (!isWin) { check(S, sigchld > 0, 'no SIGCHLD event reached script while 17 children exited'); }
        var last = sh('exit 0');
        last.waitExit();
        check(S, last.code == 0, 'a wait after the full unwind did not complete cleanly (code ' + last.code + ')');
        // Call done() from a timer instead of from inside run(). The harness ends the run with process.exit(),
        // which unwinds as an exception through whatever called done().
        anchors.push(setTimeout(done, 1));
    }
    nest();
};
