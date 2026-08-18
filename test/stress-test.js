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
// MeshAgent global stress test - mainloop.
//
// Self-contained - no external network, no MeshCentral server, no user interaction. This file is
// only the harness (pass/fail tracking, section runner, watchdog); the actual test sections live
// as separate files under test/testmodules/, one per section, loaded and run in filename order.
// Drop a new file into test/testmodules/ to add a section - nothing in this file needs editing.
//
// Each testmodules/*.js file must export:
//   exports.name = 'Section Name';
//   exports.run = function (check, deepEqual, done) { ... check(...) calls ...; done(); };
// - check(section, cond, msg)   records a pass/fail (section is normally exports.name)
// - deepEqual(a, b)             recursive structural equality helper
// - done()                      call when the section (sync or async) is finished
//
// Run standalone, e.g. (cwd must be the repo root - module paths below are cwd-relative):
//   meshagent test/stress-test.js
//   meshagent -b64exec <base64 of this file>
//
// Exits 0 if every check passes, 1 otherwise. Every individual failure is printed as it's
// found, plus a final summary. A watchdog forces a failing exit if an async section hangs.
//
// IMPORTANT: setTimeout()/setInterval() only fire if their return value stays referenced
// somewhere reachable - the returned timer object is what keeps the underlying timer alive,
// and (unlike setImmediate(), which self-anchors) nothing else roots it, so a bare
// `setTimeout(fn, ms);` with the return value discarded can be garbage collected before it
// ever fires, silently (see meshagent-todo.md #0d). Every timer in this file and in the
// testmodules is assigned to a variable that stays in scope for exactly this reason - don't
// drop that pattern in new sections.
//
// A hang or crash specifically in the TLS Connections section may be the known Windows
// reconnect-after-end()/second-sequential-connection defects (meshagent-todo.md #1/#2) - a
// SIGSEGV has now been reproduced with this exact pattern on Linux x86-64 and RISC-V64 too.
// A native crash there kills the whole process outright (no JS-level exception to catch), so
// wrap invocation with an external `timeout` command when automating this, e.g.:
//   timeout 60 meshagent -b64exec "$(base64 -w0 test/stress-test.js)"
//

// ---------------------------------------------------------------------------------------------
// tiny harness
// ---------------------------------------------------------------------------------------------

var RESULTS = { pass: 0, fail: 0 };
var FAILURES = [];

// NB: never name a local 'keys' - Object.prototype.keys is a readonly polyfill, and a top-level
// 'var keys = ...' silently no-ops (see meshagent-todo.md #0b). Harmless inside a function, but
// kept as a blanket convention here for safety.

function check(section, cond, msg) {
    if (cond) { RESULTS.pass++; }
    else {
        RESULTS.fail++;
        FAILURES.push('[' + section + '] ' + msg);
        console.log('FAIL [' + section + '] ' + msg);
    }
}

function deepEqual(a, b) {
    if (a === b) { return true; }
    if (typeof a !== typeof b) { return false; }
    if (a == null || b == null) { return false; }
    if (typeof a !== 'object') { return false; }
    var ak = Object.keys(a), bk = Object.keys(b);
    if (ak.length != bk.length) { return false; }
    for (var i = 0; i < ak.length; ++i) {
        if (!deepEqual(a[ak[i]], b[ak[i]])) { return false; }
    }
    return true;
}

// Every section is function(done) - synchronous sections just call done() at the end,
// async sections (TLS, streaming IO) call it from a callback/timeout.
function wrapSection(name, fn) {
    return function (next) {
        console.log('=== ' + name + ' ===');
        try {
            fn(function () { next(); });
        }
        catch (e) {
            RESULTS.fail++;
            var msg = 'EXCEPTION: ' + (e && e.message ? e.message : e);
            FAILURES.push('[' + name + '] ' + msg);
            console.log('FAIL [' + name + '] ' + msg);
            next();
        }
    };
}

function runAll(sections, done) {
    var i = 0;
    function step() {
        if (i >= sections.length) { done(); return; }
        var s = sections[i++];
        s(step);
    }
    step();
}

function finish() {
    console.log('');
    console.log('==================================================');
    console.log('TOTAL: ' + RESULTS.pass + ' passed, ' + RESULTS.fail + ' failed (of ' + (RESULTS.pass + RESULTS.fail) + ')');
    if (FAILURES.length > 0) {
        console.log('Failures:');
        for (var i = 0; i < FAILURES.length; ++i) { console.log('  ' + FAILURES[i]); }
    }
    console.log('==================================================');
    process.exit(RESULTS.fail == 0 ? 0 : 1);
}

// Anchored on this top-level var so it survives GC (see the header comment / meshagent-todo.md
// #0d) - an unreferenced setTimeout return value can be collected before it ever fires.
var watchdogTimer = null;
function armWatchdog(ms) {
    watchdogTimer = setTimeout(function () {
        RESULTS.fail++;
        FAILURES.push('[watchdog] stress test did not complete within ' + ms + 'ms');
        console.log('FAIL [watchdog] did not complete within ' + ms + 'ms - forcing exit');
        finish();
    }, ms);
}

// ---------------------------------------------------------------------------------------------
// load every section from test/testmodules/, in filename order
// ---------------------------------------------------------------------------------------------

var TESTMODULES_DIR = 'test/testmodules';

function loadSections() {
    var fs = require('fs');
    var files = fs.readdirSync(TESTMODULES_DIR).filter(function (f) { return (/\.js$/i).test(f); }).sort();
    if (files.length == 0) { console.log('WARNING: no test modules found under ' + TESTMODULES_DIR); }

    var sections = [];
    for (var i = 0; i < files.length; ++i) {
        var modName = files[i].replace(/\.js$/i, '');
        var mod = require('./testmodules/' + modName);
        (function (mod, fileName) {
            sections.push(wrapSection(mod.name || fileName, function (done) {
                mod.run(check, deepEqual, done);
            }));
        })(mod, files[i]);
    }
    return sections;
}

// ---------------------------------------------------------------------------------------------
// run everything
// ---------------------------------------------------------------------------------------------

armWatchdog(120000);
runAll(loadSections(), function () {
    clearTimeout(watchdogTimer);
    finish();
});
