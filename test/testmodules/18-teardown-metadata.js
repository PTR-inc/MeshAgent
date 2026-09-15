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
// Chain teardown with listening servers still in the chain.
// A server's listen() stored a pointer into a Duktape string as the chain link's metadata. The
// teardown destroys the JS heap first and then walks the links, so the walk freed the metadata
// through a pointer into freed memory. glibc keeps those pages mapped and the canary check just
// fails, musl returns them with munmap and the agent died with SIGSEGV on every exit, connect
// mode ended by SIGTERM included. The fix copies the string into an ILibMemory block.
// Each child below builds the state and calls process.exit(0), which is the same teardown that a
// SIGTERM reaches. It runs under a shell so the exit status survives: the agent's own child
// process exit code is WEXITSTATUS, which reads 0 for a death by signal.
// Section 2 is a second defect on the same exit path: the accepted connection object's finalizer
// was wiped by the readable stream's singleton finalizer, so a collected connection left the pooled
// socket pointing at its freed session and the disconnect callback read it afterwards.
//

exports.name = 'Teardown Metadata';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'Teardown';
    var fs = require('fs');
    var cp = require('child_process');
    var isWin = process.platform == 'win32';
    var shell = isWin ? (process.env['ComSpec'] || 'C:\\Windows\\System32\\cmd.exe') : '/bin/sh';
    var shellArgv = isWin ? ['cmd.exe', '/Q'] : ['sh'];
    var NL = isWin ? '\r\n' : '\n';

    // Runs a child agent on the script, through a shell, and returns { out, code } where code is
    // the shell's view of the exit status (139 for SIGSEGV on POSIX).
    function runChild(name, src) {
        var path = scratch(name);
        try { fs.writeFileSync(path, src); }
        catch (e) { return { out: 'writing ' + name + ' threw: ' + e, code: null }; }
        var c = cp.execFile(shell, shellArgv);
        c.stdout.str = ''; c.stderr.str = '';
        c.stdout.on('data', function (d) { this.str += d.toString(); });
        c.stderr.on('data', function (d) { this.str += d.toString(); });
        if (isWin) {
            c.stdin.write('"' + process.execPath + '" "' + path + '"' + NL + 'echo EXIT=%ERRORLEVEL%' + NL + 'exit' + NL);
        }
        else {
            c.stdin.write('"' + process.execPath + '" "' + path + '"; echo EXIT=$?' + NL + 'exit' + NL);
        }
        var timedOut = false;
        try { c.waitExit(30000); }
        catch (e) { timedOut = true; try { c.kill(); } catch (e2) { } }
        try { fs.unlinkSync(path); } catch (e) { }
        var out = c.stdout.str + c.stderr.str;
        var m = (/EXIT=(-?\d+)/).exec(out);
        return { out: out, code: m ? parseInt(m[1], 10) : null, timedOut: timedOut };
    }
    function crashed(code) {
        return (code == 139 || code == 134 || code == 3221225477 || code == -1073741819);
    }

    // --- 1. listening TCP and HTTP servers, no connections, exit ---
    var r1 = runChild('teardown-servers.js', [
        "var net = require('net'), http = require('http');",
        "var tcp = net.createServer(function (c) { });",
        "tcp.listen({ port: 0, host: '127.0.0.1' });",
        "var web = http.createServer(function (req, res) { });",
        "web.listen({ port: 0, host: '127.0.0.1' });",
        "console.log('LISTENING ' + tcp.address().port + ' ' + web.address().port);",
        "var t = setTimeout(function () { process.exit(0); }, 300);"
    ].join('\n') + '\n');
    check(S, !r1.timedOut, 'the servers-only child did not exit within 30s');
    check(S, r1.out.indexOf('LISTENING ') >= 0, 'the servers-only child never reported its servers listening: "' + r1.out.trim() + '"');
    if (r1.code === null) { check(S, false, 'no exit status from the shell for the servers-only child: "' + r1.out.trim() + '"'); }
    else if (crashed(r1.code)) {
        check(S, false, 'the servers-only child crashed in chain teardown (shell status ' + r1.code + '): a server link still held a pointer into the destroyed JS heap as its metadata');
    }
    else { check(S, r1.code == 0, 'the servers-only child exited with ' + r1.code + ' (expected 0)'); }

    // --- 2. an accepted connection still open at exit, see the header ---
    var r2 = runChild('teardown-session.js', [
        "var http = require('http');",
        "var web = http.createServer(function (req, res) { });",
        "web.listen({ port: 0, host: '127.0.0.1' });",
        "var req = http.request({ host: '127.0.0.1', port: web.address().port, path: '/hold', method: 'GET' }, function (res) { });",
        "req.on('error', function () { });",
        "req.end();",
        "var t = setTimeout(function () { process.exit(0); }, 300);"
    ].join('\n') + '\n');
    check(S, !r2.timedOut, 'the open-session child did not exit within 30s');
    if (r2.code === null) { check(S, false, 'no exit status from the shell for the open-session child: "' + r2.out.trim() + '"'); }
    else {
        check(S, !crashed(r2.code) && r2.code == 0, 'exit with an accepted server connection still open crashed or failed (shell status ' + r2.code + '): the connection object\'s finalizer did not run, so the pooled socket still pointed at its freed session');
    }

    done();
};
