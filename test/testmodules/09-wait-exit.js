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
// the ProcessPipe races that only show with many children alive at once. The blocks marked
// 2026-09-17 cover the review fixes: detached children, a child with closed stdio, a stopped child,
// a retried wait after process.exit(), a wait from an already ended wait's last pass, socket.close()
// inside a wait, and clearTimeout() inside a nested wait.
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
    // Debug builds expose child_process._stackRemaining(). The stack lines are information only, no check depends on them.
    var stackLeft = cp._stackRemaining, stackPrev = -1;
    function kb(n) { return Math.round(n / 1024) + ' KB'; }
    if (stackLeft) { var s0 = stackLeft(); console.log(s0 < 0 ? 'stack: bound not available, depth cap only' : ('stack: ' + kb(s0) + ' free at start')); }

    // --- a wait nested inside another wait. The outer child's 'exit' handler runs inside the outer
    //     wait's loop, spawns a second child and waits for it there ---
    var outer = sleeper(0.3), nestOK = false, innerCode = -1, nestErr = null, innerExits = -1;
    outer.on('exit', function () {
        var inner = sh('exit 5');
        try { inner.waitExit(); nestOK = true; innerCode = inner.code; } catch (e) { nestErr = '' + e; }
        innerExits = inner.exits;
    });
    outer.waitExit();
    check(S, nestOK && innerCode == 5, 'nested waitExit() inside another waitExit() failed (ok=' + nestOK + ', code=' + innerCode + ', exit events=' + innerExits + ', err=' + nestErr + ')');

    // --- the timeout throws, and a timer armed before the wait fires inside it and waits on a second
    //     child there. The deadline has millisecond precision, so waitExit(1000) throws about one
    //     second after the call. The base timer runs inside the wait, so the 100 ms timer is
    //     dispatched before that deadline ---
    var hung = sleeper(3), threw = null, t0 = Date.now(), timerNestOK = false, timerCode = -1, timerErr = null, timerExits = -1;
    anchors.push(setTimeout(function () {
        var viaTimer = sh('exit 5');
        try { viaTimer.waitExit(); timerNestOK = true; timerCode = viaTimer.code; } catch (e) { timerErr = '' + e; }
        timerExits = viaTimer.exits;
    }, 100));
    try { hung.waitExit(1000); } catch (e) { threw = '' + e; }
    var took = Date.now() - t0;
    check(S, timerNestOK && timerCode == 5, 'timer inside a wait: nested waitExit() failed (ok=' + timerNestOK + ', code=' + timerCode + ', exit events=' + timerExits + ', err=' + timerErr + ')');
    check(S, threw != null && threw.indexOf('timed out') >= 0, 'waitExit(1000) did not throw a timeout: ' + threw);
    check(S, took >= 900 && took < 2500, 'waitExit(1000) returned after ' + took + 'ms, expected about 1 second');
    hung.kill();

    // --- the timed out child exits later, from the kill. Its exit ends nothing, because no wait tagged
    //     with it is live any more, so a later wait runs to its own child's end. A wait on an already
    //     exited child returns at once ---
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

    // --- two waits pending on the same child. A timer inside the outer wait calls waitExit() on the
    //     same child, and its one exit must end both waits. Before, the second call failed with
    //     "waitExit() already in progress" ---
    var twice = sleeper(0.3), innerDone = false, innerErr = null; t1 = Date.now();
    anchors.push(setTimeout(function () { try { twice.waitExit(); innerDone = true; } catch (e) { innerErr = '' + e; } }, 100));
    twice.waitExit(); d1 = Date.now() - t1;
    check(S, innerDone && innerErr == null && twice.exits == 1 && d1 >= 200 && d1 < 3000, 'two waits on one child: inner=' + innerDone + ' err=' + innerErr + ' exits=' + twice.exits + ' took ' + d1 + 'ms');

    // --- promise.wait() nested inside promise.wait(). The outer promise settles from a child's
    //     'exit' handler, which runs inside the outer wait's loop and waits there for a second
    //     promise that another child's exit settles ---
    var host = sleeper(0.3), pv = null, inner = null, perr = null;
    var p1 = new promise(function (res) {
        host.on('exit', function () {
            var second = sleeper(0.2);
            var p2 = new promise(function (r2) { second.on('exit', function () { r2('inner'); }); });
            try { inner = promise.wait(p2); } catch (e) { perr = '' + e; }
            res('outer');
        });
    });
    try { pv = promise.wait(p1); } catch (e) { perr = '' + e; }
    check(S, pv == 'outer' && inner == 'inner' && perr == null, 'nested promise.wait(): outer=' + pv + ' inner=' + inner + ' err=' + perr);

    // --- promise.wait() nested inside waitExit(). A timer inside the wait blocks on a promise that a
    //     second timer resolves, so both kinds of wait share one stack of continuations ---
    var pHost = sleeper(0.3), mixed = null, mixedErr = null; t1 = Date.now();
    anchors.push(setTimeout(function () {
        var p3 = new promise(function (r3) { anchors.push(setTimeout(function () { r3('mixed'); }, 50)); });
        try { mixed = promise.wait(p3); } catch (e) { mixedErr = '' + e; }
    }, 100));
    pHost.waitExit(); d1 = Date.now() - t1;
    check(S, mixed == 'mixed' && mixedErr == null && pHost.exits == 1 && pHost.code == 0, 'promise.wait() inside waitExit(): value=' + mixed + ' err=' + mixedErr + ' exits=' + pHost.exits + ' code=' + pHost.code + ' took ' + d1 + 'ms');

    // --- 'exit' fires once even with stdout and stderr both piped. Each pipe breaking used to run
    //     the exit handler again ---
    var both = sh(isWin ? 'echo out & echo err 1>&2 & exit 3' : 'echo out; echo err >&2; exit 3');
    both.waitExit();
    check(S, both.exits == 1 && both.code == 3, "'exit' fired " + both.exits + ' time(s) with code ' + both.code + ', expected once with 3');

    // --- process.exit() inside a wait. A child agent calls process.exit(3) from a timer two waits deep.
    //     Every wait must throw and unwind before the script engine is destroyed, so the child ends
    //     with code 3 instead of crashing ---
    var exitScript = [
        "var cp = require('child_process'), win = process.platform == 'win32';",
        "function slp() { return (win ? cp.execFile(process.env['windir'] + '\\\\System32\\\\cmd.exe', ['cmd.exe', '/c', 'ping -n 3 127.0.0.1 > nul']) : cp.execFile('/bin/sh', ['sh', '-c', 'sleep 2'])); }",
        "var a = slp();",
        "var k1 = setTimeout(function () { var b = slp(); var k2 = setTimeout(function () { console.log('EXIT_CALLED'); process.exit(3); }, 100); b.waitExit(); console.log('INNER_RETURNED'); }, 100);",
        "a.waitExit();",
        "console.log('OUTER_RETURNED');"
    ].join('\n');
    var ex = cp.execFile(process.execPath, ['meshagent', '-b64exec', Buffer.from(exitScript).toString('base64')]), exOut = '', exCode = -1;
    ex.stdout.on('data', function (d) { exOut += d.toString(); });
    ex.stderr.on('data', function (d) { exOut += d.toString(); });
    ex.on('exit', function (c) { exCode = c; });
    try { ex.waitExit(20000); } catch (e) { exOut += ' [' + e + ']'; ex.kill(); }
    var exOK = exCode == 3 && exOut.indexOf('EXIT_CALLED') >= 0 && exOut.indexOf('RETURNED') < 0;
    check(S, exOK, 'process.exit(3) two waits deep: child code=' + exCode + ', output: ' + exOut.replace(/\s+/g, ' ').substring(0, 300));

    // --- 2026-09-17 review fixes. Each block below covers one of them ---

    // --- a detached child has no pipes, so its exit only ever arrives through the SIGCHLD relay. That
    //     path never ended the wait, so waitExit() ran to its deadline and then read the freed child
    //     record. Now it returns as soon as the child is reaped ---
    if (!isWin) {
        var det = cp.execFile(shell, [shellArgv0, '-c', 'exit 4'], { detached: true, type: cp.SpawnTypes.DETACHED }), detErr = null;
        det.exits = 0; det.code = null; det.on('exit', function (c) { this.exits++; this.code = c; });
        t1 = Date.now();
        try { det.waitExit(3000); } catch (e) { detErr = '' + e; }
        d1 = Date.now() - t1;
        check(S, detErr == null && det.exits == 1 && det.code == 4 && d1 < 2000, 'detached child: err=' + detErr + ' exits=' + det.exits + ' code=' + det.code + ' took ' + d1 + 'ms (expected a prompt return with code 4)');
    }

    // --- a child that closes its own stdout and stderr and keeps running. The pipe reap used to block
    //     the whole event loop in waitpid() until the child exited, so a timer armed inside the wait
    //     could only fire afterwards. Now the reap polls, the timer fires on time and 'exit' still
    //     arrives once with the real code ---
    if (!isWin) {
        var quiet = sh('exec >/dev/null 2>&1; sleep 0.6'), tickAt = -1; t1 = Date.now();
        anchors.push(setTimeout(function () { tickAt = Date.now() - t1; }, 150));
        var quietErr = null;
        try { quiet.waitExit(3000); } catch (e) { quietErr = '' + e; }
        d1 = Date.now() - t1;
        check(S, quietErr == null && quiet.exits == 1 && quiet.code == 0 && d1 >= 500, 'child with closed stdio: err=' + quietErr + ' exits=' + quiet.exits + ' code=' + quiet.code + ' took ' + d1 + 'ms');
        check(S, tickAt >= 0 && tickAt < 450, 'timer inside the wait fired at ' + tickAt + 'ms while a child ran with closed stdio, expected about 150 ms (the pipe reap blocked the loop)');
    }

    // --- a stopped child raises SIGCHLD too. The relay used to publish that as an exit with code 0,
    //     which ended the wait and closed the pipes of a live child. Now only a real reap is published,
    //     so the wait lasts until the continued child really exits ---
    if (!isWin) {
        var stopped = sleeper(0.8), stopErr = null; t1 = Date.now();
        sh('kill -STOP ' + stopped.pid).waitExit(3000);
        anchors.push(setTimeout(function () { sh('kill -CONT ' + stopped.pid).waitExit(3000); }, 300));
        try { stopped.waitExit(3000); } catch (e) { stopErr = '' + e; }
        d1 = Date.now() - t1;
        check(S, stopErr == null && stopped.exits == 1 && stopped.code == 0 && d1 >= 700, 'stopped then continued child: err=' + stopErr + ' exits=' + stopped.exits + ' code=' + stopped.code + ' took ' + d1 + 'ms (a stop must not count as an exit)');
    }

    // --- process.exit() inside a wait, and the script catches the abort and waits again. The chain now
    //     refuses every wait after the abort at once, so the retry throws without running a loop pass and
    //     the process still ends with the requested code ---
    var stickyScript = [
        "var cp = require('child_process'), win = process.platform == 'win32';",
        "function slp() { return (win ? cp.execFile(process.env['windir'] + '\\\\System32\\\\cmd.exe', ['cmd.exe', '/c', 'ping -n 4 127.0.0.1 > nul']) : cp.execFile('/bin/sh', ['sh', '-c', 'sleep 3'])); }",
        "var a = slp();",
        "var k = setTimeout(function () { process.exit(3); }, 100);",
        "try { a.waitExit(); console.log('FIRST_RETURNED'); }",
        "catch (e) { var b = slp(); var t = Date.now(); try { b.waitExit(); console.log('SECOND_RETURNED'); } catch (e2) { console.log('SECOND_REFUSED after ' + (Date.now() - t) + 'ms: ' + e2); } }"
    ].join('\n');
    var st = cp.execFile(process.execPath, ['meshagent', '-b64exec', Buffer.from(stickyScript).toString('base64')]), stOut = '', stCode = -1; t1 = Date.now();
    st.stdout.on('data', function (d) { stOut += d.toString(); });
    st.stderr.on('data', function (d) { stOut += d.toString(); });
    st.on('exit', function (c) { stCode = c; });
    try { st.waitExit(20000); } catch (e) { stOut += ' [' + e + ']'; st.kill(); }
    d1 = Date.now() - t1;
    var stOK = stCode == 3 && stOut.indexOf('SECOND_REFUSED') >= 0 && stOut.indexOf('RETURNED') < 0 && d1 < 2500;
    check(S, stOK, 'process.exit(3) with a retried wait: child code=' + stCode + ', took ' + d1 + 'ms, output: ' + stOut.replace(/\s+/g, ' ').substring(0, 300));

    // --- a wait started from a handler that runs after its enclosing wait has already ended. The
    //     enclosing wait cannot return until the new one ends, so the new one is refused. Whether the
    //     second child's 'exit' runs inside the first wait's last pass or in the main loop depends on
    //     timing, so both outcomes pass. Only a hang or another error is a failure ---
    var fa = sh('exit 0'), fb = sh('exit 0'), lateErr = null, lateOK = false, lateRan = false;
    fb.on('exit', function () { lateRan = true; var fc = sh('exit 0'); try { fc.waitExit(2000); lateOK = true; } catch (e) { lateErr = '' + e; } });
    fa.waitExit(2000);
    if (!lateRan) { fb.waitExit(2000); }
    check(S, lateRan && (lateOK || (lateErr != null && lateErr.indexOf('enclosing wait') >= 0)), "wait from another child's exit handler: ran=" + lateRan + ' ok=' + lateOK + ' err=' + lateErr);
    console.log('  (' + (lateOK ? "second child's exit ran in a later pass, its wait was allowed" : "second child's exit ran in the ended wait's last pass, its wait was refused") + ')');

    // --- socket.close() then waitExit() inside a dgram 'message' handler. close() removes the socket's
    //     chain link through the base timer, which the nested wait runs, so the link's list node was
    //     freed while the enclosing loop was parked on it. The removal is now deferred until every
    //     wait has returned, and a later wait still works ---
    var dg = require('dgram').createSocket({ type: 'udp4' }), dgOK = false, dgErr = null, dgGot = false;
    dg.bind({ port: 0, address: '127.0.0.1', exclusive: true });
    var dgPort = dg.address().port;
    var pdg = new promise(function (res) {
        dg.on('message', function () { dgGot = true; dg.close(); var c = sh('exit 0'); try { c.waitExit(2000); dgOK = c.code == 0; } catch (e) { dgErr = '' + e; } res(); });
    });
    dg.send(Buffer.from('x'), dgPort, '127.0.0.1');
    try { promise.wait(pdg, 3000); } catch (e) { dgErr = '' + e; }
    var afterDg = sh('exit 0'); afterDg.waitExit(2000);
    check(S, dgGot && dgOK && dgErr == null && afterDg.code == 0, 'socket.close() then waitExit() inside a dgram message handler: got=' + dgGot + ' ok=' + dgOK + ' err=' + dgErr + ' later wait code=' + afterDg.code);

    // --- clearTimeout() inside a nested wait, of a timer that is already due in the same timer pass as
    //     the caller. The due timers of the outer pass used to be invisible to clearTimeout() while a
    //     nested wait ran, so the cleared timer fired anyway on freed memory. Now every pass is searched ---
    var tbFired = false, tbCleared = false, tbFiredAfterClear = false, tb = null;
    var ta = setTimeout(function () { var c = sleeper(0.2); c.waitExit(2000); clearTimeout(tb); tbCleared = true; }, 0);
    tb = setTimeout(function () { tbFired = true; if (tbCleared) { tbFiredAfterClear = true; } }, 0);
    anchors.push(ta); anchors.push(tb);
    var ptc = new promise(function (res) { anchors.push(setTimeout(res, 400)); });
    try { promise.wait(ptc, 3000); } catch (e) { }
    check(S, tbCleared && !tbFiredAfterClear, 'clearTimeout() inside a nested wait: cleared=' + tbCleared + ' fired=' + tbFired + ' fired after the clear=' + tbFiredAfterClear);

    // --- depth cap: 16 nested waits with 17 children alive at once. The 17th nested wait throws,
    //     and every child's exit still reaches its own wait, so no pipe read was skipped and no fd
    //     or pid was mixed up. A SIGCHLD listener adds the second waitpid() path that raced the
    //     pipe reap. The children sleep 2 seconds, all 17 spawns are done well inside the first
    //     second, and the whole module has to stay inside the harness's 10 second watchdog ---
    var depth = 0, maxDepth = 0, capHits = 0, okWaits = 0, launched = 0, lostExits = 0, sigchld = 0;
    var onSig = function () { sigchld++; };
    if (!isWin) { try { process.on('SIGCHLD', onSig); } catch (e) { } }
    function nest() {
        ++depth; if (depth > maxDepth) { maxDepth = depth; }
        if (stackLeft) { var sl = stackLeft(); if (sl >= 0) { console.log('depth ' + depth + ': ' + kb(sl) + ' free' + (stackPrev >= 0 ? (' (' + kb(stackPrev - sl) + ' per level)') : '')); stackPrev = sl; } }
        var c = sleeper(2);
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
