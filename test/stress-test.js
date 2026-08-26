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
// MeshAgent global stress test harness. It is self-contained and needs no network, server or user.
// The test sections live under test/testmodules/, one file per section, run in filename order.
// Each must export exports.name and exports.run(check, deepEqual, done). See ISSUES.md.
//
// Run from the repo root, because module paths are cwd-relative. Scratch files do not go to the
// working directory, see scratch() below:
//   meshagent test/stress-test.js
//   meshagent -b64exec <base64 of this file>
//
// A timer only fires while its return value stays referenced, so every setTimeout() here and in
// the testmodules is assigned to a variable that stays in scope.
// A native crash in the 06-* sections kills the process outright, so automate with an external timeout.
//

// ---------------------------------------------------------------------------------------------
// tiny harness
// ---------------------------------------------------------------------------------------------

var RESULTS = { pass: 0, fail: 0 };
var FAILURES = [];

// Options. argv is empty under -b64exec, so both have defaults:
//   --watchdog=<ms>        overall watchdog, default 10000. Raise it under valgrind, which is about 20x slower.
//   --exclude=a,b          skip testmodules whose filename contains any of these substrings.
var OPT_WATCHDOG = 10000;
var OPT_EXCLUDE = [];
(function () {
    var av = process.argv || [];
    for (var i = 0; i < av.length; ++i) {
        var a = ('' + av[i]);
        if (a.indexOf('--watchdog=') == 0) { OPT_WATCHDOG = parseInt(a.substring(11)) || OPT_WATCHDOG; }
        else if (a.indexOf('--exclude=') == 0) {
            var parts = a.substring(10).split(',');
            for (var j = 0; j < parts.length; ++j) { if (parts[j] != '') { OPT_EXCLUDE.push(parts[j]); } }
        }
    }
})();

// Never name a variable 'keys'. Object.prototype.keys is a readonly polyfill, so a top-level
// 'var keys = ...' silently does nothing. Kept as a blanket convention.

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

// Every section is function(done). Synchronous sections call done() at the end, and async
// sections call it from a callback or a timer.
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

var FINISHED = false;
function finish() {
    if (FINISHED) { return; }
    FINISHED = true;
    removeScratchDir();
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

// ---------------------------------------------------------------------------------------------
// scratch files
// ---------------------------------------------------------------------------------------------

// Every scratch file a section writes goes under this directory, never the working directory, so a
// run cannot leave residue inside the repository. The pid keeps concurrent runs apart. Sections get
// it as the fourth argument to run().
var SCRATCH_DIR = null;
function scratch(name) {
    if (SCRATCH_DIR == null) {
        // tmpdir() ends with a separator on Windows and Linux, but on macOS it comes from TMPDIR.
        var base = require('os').tmpdir();
        if (!(/[\\\/]$/).test(base)) { base += '/'; }
        SCRATCH_DIR = base + 'meshagent-stresstest-' + (process.pid || 0);
        try { require('fs').mkdirSync(SCRATCH_DIR); } catch (e) { }
    }
    return SCRATCH_DIR + '/' + name;
}

// Windows refuses to unlink a file whose stream is still open, so this can legitimately fail.
// Say where the leftovers are rather than failing the run over them.
function removeScratchDir() {
    if (SCRATCH_DIR == null) { return; }
    var fs = require('fs'), left = [];
    try {
        var entries = fs.readdirSync(SCRATCH_DIR);
        for (var i = 0; i < entries.length; ++i) {
            var e = ('' + entries[i]);
            if (e == '.' || e == '..') { continue; }
            try { fs.unlinkSync(SCRATCH_DIR + '/' + e); } catch (x) { left.push(e); }
        }
    } catch (e) { return; }
    if (left.length == 0) { try { fs.rmdirSync(SCRATCH_DIR); } catch (e) { } }
    else { console.log('NOTE: ' + left.length + ' scratch file(s) still open, left in ' + SCRATCH_DIR); }
}

// Anchored on this top-level var so it survives GC, because an unreferenced setTimeout return
// value can be collected before it ever fires.
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
    if (OPT_EXCLUDE.length > 0) {
        files = files.filter(function (f) {
            for (var x = 0; x < OPT_EXCLUDE.length; ++x) {
                if (f.indexOf(OPT_EXCLUDE[x]) >= 0) { console.log('SKIP ' + f + ' (--exclude)'); return false; }
            }
            return true;
        });
    }
    if (files.length == 0) { console.log('WARNING: no test modules found under ' + TESTMODULES_DIR); }

    var sections = [];
    for (var i = 0; i < files.length; ++i) {
        var modName = files[i].replace(/\.js$/i, '');
        // require() resolves relative to the cwd, not to this file, so try the cwd-relative form
        // first and fall back to the file-relative one.
        var mod = null;
        try { mod = require('./' + TESTMODULES_DIR + '/' + modName); }
        catch (e) { mod = require('./testmodules/' + modName); }
        (function (mod, fileName) {
            sections.push(wrapSection(mod.name || fileName, function (done) {
                mod.run(check, deepEqual, done, scratch);
            }));
        })(mod, files[i]);
    }
    return sections;
}

// ---------------------------------------------------------------------------------------------
// run everything
// ---------------------------------------------------------------------------------------------

armWatchdog(OPT_WATCHDOG);

// A throw out of loadSections() would otherwise unwind silently and leave the process idling
// until the watchdog fires. Report it and exit instead.
var SECTIONS = [];
try { SECTIONS = loadSections(); }
catch (e) {
    RESULTS.fail++;
    var loadMsg = 'EXCEPTION loading test modules from ' + TESTMODULES_DIR + ': ' + (e && e.message ? e.message : e);
    FAILURES.push('[loader] ' + loadMsg);
    console.log('FAIL [loader] ' + loadMsg);
    finish();
}

runAll(SECTIONS, function () {
    // clearTimeout() on an already-elapsed timer throws 'Invalid Parameter' here, where Node does nothing.
    try { clearTimeout(watchdogTimer); } catch (e) { }
    finish();
});
