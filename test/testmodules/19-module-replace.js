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
// addModule() against a module that is already loaded: the loaded instance leaves require()'s cache, the
// next require() compiles the new copy and code holding the old instance keeps it. Also the version,
// identical-copy, same-version and file-date rules of addModule(), a native name that stays native, a
// replacement made during a require() cycle, the disk file rule per disk mode, and the replacement again
// with the JavaScript debugger attached, checked through the debugger's own eval, and the 60 s offline timer that
// starts the cached core (about 65 s of wall time, in a second agent process). The debugger part needs
// attachDebugger() (a debug build, or -allowDiskModules) and modules/duktape-debugger.js under the cwd.
// Leaves heap-wide state behind (the module path, a JS copy of 'net' in the table), so it expects the driver's
// default one-process-per-module run, not its single-heap mode.
//

exports.name = 'Module Replace';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'ModuleReplace';
    var fs = require('fs');
    var sep = process.platform == 'win32' ? '\\' : '/';
    function src(v, extra) { return '/*! @module-version=' + v + ' */\nmodule.exports = { v: ' + v + (extra ? ', ' + extra : '') + ' };\n'; }
    function dsrc(tag) { return 'module.exports = { tag: "' + tag + '" };\n'; }
    function throws(fn) { try { fn(); return false; } catch (e) { return true; } }

    // 1. Two versions added before the first load: the higher one is what loads
    check(S, addModule('mr1', src(1)) === true, 'first copy of a new module is added');
    check(S, addModule('mr1', src(2)) === true, 'higher version is added');
    check(S, require('mr1').v === 2, 'require() gives the higher version');
    check(S, getJSModuleInfo('mr1').version === 2, 'getJSModuleInfo() reports version 2');

    // 2. The replacement after a load: a new instance from the next require(), the old one stays usable
    addModule('mr2', src(1));
    var a = require('mr2');
    check(S, a.v === 1, 'loaded version 1');
    check(S, addModule('mr2', src(2)) === true, 'higher version replaces a loaded module');
    var b = require('mr2');
    check(S, b !== a, 'require() after the replacement gives a new instance');
    check(S, b.v === 2, 'the new instance is the new copy');
    check(S, a.v === 1, 'the old instance is untouched');
    check(S, require('mr2') === b, 'the new instance is cached again');

    // 3. A lower version after the load is refused and nothing is dropped
    check(S, addModule('mr2', src(1)) === false, 'lower version is refused');
    check(S, require('mr2') === b, 'refused copy leaves the cached instance alone');

    // 4. The identical text again counts as in use, and nothing is dropped
    check(S, addModule('mr2', src(2)) === true, 'identical copy reports in use');
    check(S, require('mr2') === b, 'identical copy leaves the cached instance alone');

    // 5. Same version, different content: a copy added after the built-in set wins, and a loaded module is replaced by it
    addModule('mr5', src(1));
    var c = require('mr5');
    check(S, addModule('mr5', src(1, 'tag: "b"')) === true, 'same version with other content is taken after the built-in set');
    check(S, getJSModule('mr5').indexOf('tag') > 0, 'table holds the later copy');
    check(S, require('mr5').tag === 'b' && c.tag === undefined, 'loaded module gets the later copy on its next require()');

    // 6. No version line on either side: the file date decides, an undated copy never beats a dated one
    check(S, addModule('mr6', dsrc('a'), '2026-01-01T00:00:00.000Z') === true, 'dated first copy is added');
    check(S, addModule('mr6', dsrc('b'), '2025-01-01T00:00:00.000Z') === false, 'older date is refused');
    check(S, addModule('mr6', dsrc('c'), '2026-06-01T00:00:00.000Z') === true, 'newer date is added');
    check(S, addModule('mr6', dsrc('d')) === false, 'undated copy loses against a dated one');
    check(S, require('mr6').tag === 'c', 'the newest dated copy loads');
    check(S, getJSModuleDate('mr6') === 1780272000, 'getJSModuleDate() is the date in seconds, got ' + getJSModuleDate('mr6'));
    check(S, addModule('mr6b', dsrc('a')) === true, 'undated first copy is added');
    check(S, addModule('mr6b', dsrc('b')) === true, 'undated copy replaces an undated one');
    check(S, require('mr6b').tag === 'b', 'the last undated copy loads');

    // 7. A native module keeps its native binding when a JS copy of its name is added
    var net = require('net');
    check(S, typeof net.createServer == 'function', 'net is the native module');
    check(S, addModule('net', src(9, 'fake: true')) === true, 'a JS copy of a native name lands in the table');
    var net2 = require('net');
    check(S, net2 === net && typeof net2.createServer == 'function', 'require() still gives the native module');
    var netInfo = getJSModuleInfo('net');
    check(S, netInfo != null && netInfo.source == 'native', 'getJSModuleInfo() reports net as native');
    check(S, netInfo != null && netInfo.ignored != null && netInfo.ignored.version === 9 && netInfo.ignored.source == 'server', 'getJSModuleInfo() shows the JS copy of net as ignored, got ' + JSON.stringify(netInfo));
    check(S, getModules(true).indexOf('http') >= 0 && getModules().indexOf('http') < 0, 'getModules(true) lists a native module, getModules() does not');
    check(S, getJSModulesLoaded()['net'] != null && getJSModulesLoaded()['net'].source == 'native', 'a loaded native module is in getJSModulesLoaded()');
    check(S, getJSModuleInfo('mr1').ignored === undefined, 'a JS module has no ignored copy');

    // 8. A replacement made while the module is loading: no hang, the loader finishes, the new copy is what stays cached
    var c1v2 = src(2);
    addModule('mrc1', '/*! @module-version=1 */\nmodule.exports = { v: 1 };\nmodule.exports.dep = require("mrc2");\n');
    addModule('mrc2', 'addModule("mrc1", ' + JSON.stringify(c1v2) + ');\nmodule.exports = { again: require("mrc1") };\n');
    var first = null;
    check(S, !throws(function () { first = require('mrc1'); }), 'a replacement during the load does not throw');
    check(S, first != null && first.v === 1, 'the first require() returns the instance it started');
    check(S, first != null && first.dep.again.v === 2, 'the require() inside the cycle already gets the new copy');
    check(S, require('mrc1').v === 2, 'after the cycle the new copy is the cached one');

    // 9. Disk files per disk mode: 0 never, 1 only for a name the table has no module for, 2 and 3 always
    var mode = getJSModuleDiskMode();
    fs.writeFileSync(scratch + sep + 'mr9disk.js', 'module.exports = { from: "disk" };\n');
    fs.writeFileSync(scratch + sep + 'mr9tab.js', 'module.exports = { from: "disk" };\n');
    addModule('mr9tab', 'module.exports = { from: "table" };\n');
    setModulePath(scratch);
    if (mode == 0) {
        check(S, throws(function () { require('mr9disk'); }), 'disk mode 0: a disk file is not loaded');
    } else {
        check(S, require('mr9disk').from === 'disk', 'disk mode ' + mode + ': a disk file for a new name loads');
    }
    check(S, require('mr9tab').from === (mode >= 2 ? 'disk' : 'table'), 'disk mode ' + mode + ': a disk file for a table name ' + (mode >= 2 ? 'wins' : 'is ignored'));

    // 10. The 60 s offline timer. An agent with a cached core and no server starts that core after the timer, in a fresh heap.
    //     A second agent process runs from a copy of the binary in the scratch directory. A helper run of the copy puts a core into its
    //     .db that writes a marker file, then the copy runs as an agent with no server. It runs once the other parts are done, because the debugger part
    //     below needs this heap to run no JavaScript between its attach and resume, and the poll timer here would be that JavaScript
    var timerStarted = false, realDone = done;
    done = function () { if (!timerStarted) { timerStarted = true; timerPart(); } };
    function timerPart() {
        var win = process.platform == 'win32';
        var tExe = scratch + sep + 'mr-timer-agent' + (win ? '.exe' : ''), tDb = win ? tExe.replace(/\.exe$/i, '.db') : tExe + '.db';
        var marker = scratch + sep + 'timer-core-ran.json', prepFile = scratch + sep + 'timer-prep.js';
        var coreJs = 'require("fs").writeFileSync(' + JSON.stringify(marker) + ', JSON.stringify({ ran: true, mode: getJSModuleDiskMode() }));\n';
        var prep = [
            "var ds = require('SimpleDataStore').Create(" + JSON.stringify(tDb) + ");",
            "ds.PutCompressed('CoreModule', Buffer.concat([Buffer.alloc(4), Buffer.from(" + JSON.stringify(coreJs) + ")]));",
            "ds.Compact();",
            "setTimeout(function () { process.exit(0); }, 0);"
        ].join('\n');
        try { fs.writeFileSync(tExe, fs.readFileSync(process.execPath)); if (!win) { fs.chmodSync(tExe, 0x1ed); } fs.writeFileSync(prepFile, prep); }
        catch (e) { check(S, false, 'timer: could not set up the agent copy: ' + e); try { fs.unlinkSync(tExe); } catch (e2) { } realDone(); return; }

        var timer = null, agent = null, started = 0, early = null, finished = false;
        // Ends the part once. A child that never starts or never exits must not leave the run waiting, so every path ends here
        function finish() {
            if (finished) { return; }
            finished = true;
            if (timer != null) { clearInterval(timer); timer = null; }
            clearTimeout(watchdog);
            try { fs.unlinkSync(tExe); } catch (e) { }	// The copy is 3 MB or more, so it goes now
            realDone();
        }
        function stop() {
            if (timer != null) { clearInterval(timer); timer = null; }
            if (agent == null) { finish(); return; }
            var a = agent; agent = null;
            a.on('exit', finish);
            setTimeout(finish, 5000);	// In case the killed agent never reports its exit
            try { a.kill(); } catch (e) { finish(); }
        }
        var watchdog = setTimeout(function () { check(S, false, 'timer: no result within 150 s'); stop(); }, 150000);
        var prepChild = require('child_process').execFile(tExe, [tExe, prepFile]);
        prepChild.on('error', function (e) { check(S, false, 'timer: the helper run did not start: ' + e); finish(); });
        prepChild.on('exit', function (code) {
            if (finished) { return; }
            check(S, fs.existsSync(tDb), 'timer: the helper run wrote the .db (exit code ' + code + ')');
            if (!fs.existsSync(tDb)) { finish(); return; }
            agent = require('child_process').execFile(tExe, [tExe, 'run']);
            agent.on('error', function (e) { check(S, false, 'timer: the agent copy did not start: ' + e); agent = null; stop(); });
            agent.stdout.on('data', function () { });
            agent.stderr.on('data', function () { });
            started = Date.now();
            timer = setInterval(function () {
                var elapsed = Date.now() - started;
                if (early == null && elapsed >= 20000) { early = fs.existsSync(marker); check(S, early === false, 'timer: the cached core does not start before the 60 s timer'); }
                if (fs.existsSync(marker)) {
                    var r = null;
                    try { r = JSON.parse(fs.readFileSync(marker).toString()); } catch (e) { }
                    check(S, r != null && r.ran === true, 'timer: the cached core started after the timer');
                    check(S, elapsed >= 55000, 'timer: it started on the 60 s timer, after ' + elapsed + ' ms');
                    stop();
                }
                else if (elapsed >= 100000) { check(S, false, 'timer: the cached core did not start within 100 s'); stop(); }
            }, 1000);
        });
    }

    // 11. The replacement with the JavaScript debugger attached. Duktape pauses a heap on attach and a heap cannot resume itself,
    //     so a second agent process plays the browser over the web engine's websocket and reads the result back through the
    //     debugger's eval. This heap runs no JavaScript between the attach and the resume, the first opcode would enter the paused loop
    if (typeof attachDebugger != 'function') { console.log('  debugger: attachDebugger() not on this build, skipped'); done(); return; }
    var dbgSrc = null;
    try { dbgSrc = fs.readFileSync('modules' + sep + 'duktape-debugger.js').toString(); } catch (e) { }
    if (dbgSrc == null) { console.log('  debugger: modules/duktape-debugger.js not found under the cwd, skipped'); done(); return; }
    addModule('duktape-debugger', dbgSrc);

    var resultFile = scratch + sep + 'dbg-result.json', clientFile = scratch + sep + 'dbg-client.js';
    var client = [
        "var port = parseInt(process.argv[process.argv.length - 2]), testPort = parseInt(process.argv[process.argv.length - 1]);",
        "var fs = require('fs');",
        "var seen = [], pending = [], ws = null, result = { attached: false, resumed: false, evals: {} };",
        "function out() { result.seen = seen; fs.writeFileSync(" + JSON.stringify(resultFile) + ", JSON.stringify(result)); setTimeout(function () { process.exit(0); }, 0); }",
        "function send(obj, replyCmd, cb) { if (replyCmd) { pending.push({ cmd: replyCmd, cb: cb }); } ws.write(JSON.stringify(obj)); }",
        "function evalIn(expr, cb) { send({ cmd: 'EVAL', eval: expr }, 'EVAL', function (j) { result.evals[expr] = j.val; cb(); }); }",
        "setTimeout(function () { result.timeout = seen; out(); }, 15000);",
        "var http = require('http');",
        "var req = http.request(http.parseUri('ws://127.0.0.1:' + port + '/'));",
        "req.on('error', function (e) { result.error = String(e); out(); });",
        "req.on('upgrade', function (response, s, head) {",
        "    ws = s;",
        "    s.on('data', function (buf) {",
        "        var j = null; try { j = JSON.parse(buf.toString()); } catch (e) { return; }",
        "        seen.push(j.cmd);",
        "        for (var i = 0; i < pending.length; ++i) { if (pending[i].cmd == j.cmd) { var p = pending.splice(i, 1)[0]; p.cb(j); return; } }",
        "    });",
        "    // The web engine answers ATTACH with its own ATTACH once the transport handshake is done",
        "    send({ cmd: 'ATTACH' }, 'ATTACH', function () {",
        "        result.attached = true;",
        "        send({ cmd: 'RESUME' });",
        "        // The resume is handled on the test heap's chain, after this message. An eval answered means it went through,",
        "        // and only then may the test heap run JavaScript again without entering the paused loop",
        "        evalIn('1 + 1', function () {",
        "            result.resumed = true;",
        "            // Tells the test heap to do its replacement, its answer means it is done, then the evals read the result back",
        "            var r = http.request({ protocol: 'http:', host: '127.0.0.1', port: testPort, path: '/resumed', method: 'GET' });",
        "            r.on('error', function (e) { result.error = 'test heap: ' + e; out(); });",
        "            r.on('response', function (rsp) {",
        "                rsp.on('data', function () { });",
        "                rsp.on('end', function () {",
        "                    evalIn(\"getJSModuleInfo('mrd').version\", function () {",
        "                        evalIn(\"require('mrd').v\", function () {",
        "                            send({ cmd: 'DETACH' });",
        "                            setTimeout(out, 500);",
        "                        });",
        "                    });",
        "                });",
        "            });",
        "            r.end();",
        "        });",
        "    });",
        "});",
        "req.end();"
    ].join('\n');
    fs.writeFileSync(clientFile, client);

    var timer = null, child = null, testServer = null, finished = false;
    function finish() {
        if (finished) { return; }
        finished = true;
        if (timer != null) { clearTimeout(timer); timer = null; }
        if (testServer != null) { try { testServer.close(); } catch (e) { } testServer = null; }
        done();
    }
    timer = setTimeout(function () { timer = null; check(S, false, 'debugger: timed out, the client did not finish'); finish(); }, 25000);

    // The client calls this once it resumed the heap. A request handler only runs when the request comes in,
    // so no JavaScript of this heap runs between the attach and the resume, where a timer poll would have
    var replaced = false;
    testServer = require('http').createServer();
    testServer.on('request', function (req, rsp) {
        if (!replaced) {
            replaced = true;
            addModule('mrd', src(1));
            var d1 = require('mrd');
            check(S, addModule('mrd', src(2)) === true, 'debugger: replacement accepted while attached');
            var d2 = require('mrd');
            check(S, d2 !== d1 && d2.v === 2 && d1.v === 1, 'debugger: new instance after the replacement while attached');
        }
        rsp.statusCode = 200; rsp.end('ok');
    });
    testServer.listen({ port: 0 });
    var testPort = testServer.address().port;

    attachDebugger({ webport: 0, transport: 0, wait: 0 }).then(function (port) {
        check(S, port > 0, 'debugger: web engine on port ' + port);
        child = require('child_process').execFile(process.execPath, [process.execPath, clientFile, String(port), String(testPort)]);
        child.stdout.on('data', function () { });
        child.stderr.on('data', function () { });
        child.on('exit', function (code) {
            var r = null;
            try { r = JSON.parse(fs.readFileSync(resultFile).toString()); } catch (e) { }
            check(S, r != null, 'debugger: the client wrote a result (exit code ' + code + ')');
            if (r != null) {
                check(S, r.error == null, 'debugger: client error ' + r.error);
                var got = ', client saw ' + JSON.stringify(r.seen) + (r.timeout ? ' and timed out' : '');
                check(S, r.attached === true, 'debugger: attached' + got);
                check(S, r.resumed === true, 'debugger: resumed' + got);
                check(S, replaced, 'debugger: the heap ran after the resume' + got);
                check(S, String(r.evals["getJSModuleInfo('mrd').version"]) == '2', "debugger: eval sees version 2, got " + r.evals["getJSModuleInfo('mrd').version"] + got);
                check(S, String(r.evals["require('mrd').v"]) == '2', "debugger: eval require() gives the new copy, got " + r.evals["require('mrd').v"] + got);
            }
            finish();
        });
    }, function (e) { check(S, false, 'debugger: attachDebugger() rejected: ' + e); finish(); });
};
