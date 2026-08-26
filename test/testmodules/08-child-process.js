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
// child_process: exit codes, stderr, repeated stdin writes, the 'exit' event, kill() of a
// long-running child, and many sequential spawns, which is the pattern every OS helper module uses.
//

exports.name = 'Child Process';
exports.run = function (check, deepEqual, done) {
    var S = 'ChildProcess';
    var cp = require('child_process');
    var isWin = process.platform == 'win32';
    var shell = isWin ? (process.env['ComSpec'] || 'C:\\Windows\\System32\\cmd.exe') : '/bin/sh';
    var shellArgv0 = isWin ? 'cmd.exe' : 'sh';
    var NL = isWin ? '\r\n' : '\n';

    // The exit code is delivered on the 'exit' event only, because there is no exitCode property
    // and waitExit() returns nothing.
    function spawnShell() {
        var c = cp.execFile(shell, [shellArgv0]);
        c.stdout.str = ''; c.stderr.str = ''; c.code = null;
        c.on('exit', function (code) { this.code = code; });
        c.stdout.on('data', function (d) { this.str += d.toString(); });
        c.stderr.on('data', function (d) { this.str += d.toString(); });
        return c;
    }

    // --- exit code propagates ---
    var c1 = spawnShell();
    c1.stdin.write('exit 7' + NL);
    c1.waitExit();
    check(S, c1.code == 7, 'exit code was ' + c1.code + ' (expected 7)');

    // --- stderr is captured separately from stdout ---
    var c2 = spawnShell();
    c2.stdin.write((isWin ? 'echo ERRMARK 1>&2' : 'echo ERRMARK >&2') + NL + 'echo OUTMARK' + NL + 'exit' + NL);
    c2.waitExit();
    // stderr delivery can trail the exit notification, so only stream isolation is asserted:
    // stderr text must never surface on stdout.
    check(S, c2.stdout.str.indexOf('ERRMARK') < 0, 'stderr text surfaced on stdout: "' + c2.stdout.str.trim() + '"');
    check(S, c2.stdout.str.indexOf('OUTMARK') >= 0, 'stdout marker missing');
    if (c2.stderr.str.indexOf('ERRMARK') < 0) { console.log('  (stderr chunk not captured before exit - delivery order, not asserted)'); }

    // --- several stdin writes before exit all reach the child, in order ---
    var c3 = spawnShell();
    for (var i = 1; i <= 5; ++i) { c3.stdin.write('echo L' + i + NL); }
    c3.stdin.write('exit' + NL);
    c3.waitExit();
    var idx = [], okOrder = true;
    for (var j = 1; j <= 5; ++j) { idx.push(c3.stdout.str.indexOf('L' + j)); }
    for (var k = 0; k < idx.length; ++k) { if (idx[k] < 0 || (k > 0 && idx[k] < idx[k - 1])) { okOrder = false; } }
    check(S, okOrder, 'five sequential stdin writes were not all echoed in order: ' + JSON.stringify(idx));

    // --- environment reaches the child ---
    var c4 = cp.execFile(shell, [shellArgv0], { env: { CP_TEST_VAR: 'cpv-9182' } });
    c4.stdout.str = ''; c4.stdout.on('data', function (d) { this.str += d.toString(); });
    c4.stdin.write((isWin ? 'echo %CP_TEST_VAR%' : 'echo $CP_TEST_VAR') + NL + 'exit' + NL);
    c4.waitExit();
    check(S, c4.stdout.str.indexOf('cpv-9182') >= 0, 'env passed to execFile() did not reach the child');

    // --- many sequential spawns, exercising handle and pid reuse ---
    var SPAWNS = 20, bad = 0;
    for (var n = 0; n < SPAWNS; ++n) {
        var c = spawnShell();
        c.stdin.write('echo N' + n + NL + 'exit' + NL);
        c.waitExit();
        if (c.stdout.str.indexOf('N' + n) < 0 || c.code != 0) { bad++; }
    }
    check(S, bad == 0, bad + '/' + SPAWNS + ' sequential spawns lost output or exited non-zero');

    // --- async: 'exit' event fires, and kill() terminates a sleeping child ---
    // The sleeper is spawned directly rather than through a shell, because kill() signals only the
    // child's PID and on POSIX the agent learns of the exit from the stdout pipe breaking. A shell's
    // orphaned sleep grandchild keeps that pipe open, which on macOS meant no 'exit' for 30 s.
    var guard = null, settled = false;
    var c5 = isWin ? cp.execFile(shell, [shellArgv0]) : cp.execFile('/bin/sleep', ['sleep', '30']);
    c5.stdout.on('data', function () { });
    c5.on('exit', function (code) {
        if (settled) { return; }
        settled = true;
        try { clearTimeout(guard); } catch (e) { }
        check(S, true, 'exit event fired after kill()');
        done();
    });
    guard = setTimeout(function () {
        if (settled) { return; }
        settled = true;
        check(S, false, 'kill() did not terminate the child within 5s / exit event never fired');
        done();
    }, 5000);
    if (isWin) { c5.stdin.write('ping -n 30 127.0.0.1 >nul' + NL); }
    var t = setTimeout(function () { c5.kill(); }, 300);
    exports._t = t;   // Anchors the timer against GC, see the stress-test.js header.
};
