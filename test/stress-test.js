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
// Each must export exports.name and exports.run(check, deepEqual, done). check.known(section, cond,
// msg, ref) records a failure of a defect already in ISSUES.md as KNOWN instead of FAIL. See ISSUES.md.
// A known defect is declared there, in the testmodule that exercises it, and nowhere else: the
// TOTAL line carries the KNOWN count, and test-agent.sh turns it into a KNOWN verdict that
// --lenient accepts and --strict fails. Turn a check.known() back into a check() once it is fixed.
//
// Run from the repo root, because module paths are cwd-relative. Scratch files do not go to the
// working directory, see scratch() below:
//   meshagent test/stress-test.js
//   meshagent -b64exec <base64 of this file>
//
// A timer only fires while its return value stays referenced, so every setTimeout() here and in
// the testmodules is assigned to a variable that stays in scope.
// A native crash kills the process outright, taking the TOTAL line with it, so automate with an
// external timeout.
//

// ---------------------------------------------------------------------------------------------
// tiny harness
// ---------------------------------------------------------------------------------------------

var RESULTS = { pass: 0, fail: 0, known: 0 };
var FAILURES = [];

// Options. Under -b64exec process.argv is [<exe path>, '-b64exec', <payload>], which matches none of these, so every one keeps its default there.
//   --watchdog=<ms>        overall watchdog, default 10000. Raise it under valgrind, about 20x slower.
//   --exclude=a,b          skip testmodules whose filename contains any of these substrings.
//   --fs-test              opt in to 15-fs.js's >2GB section, which needs a scratch dir that supports sparse files.
//   --qemu                 running under qemu-user, which raises the default watchdog unless --watchdog= was given.
//   --only=<file>          run one testmodule and nothing else, which is how an isolated child is told which one is its own.
//   --result-file=<path>   write the failures and the TOTAL line here, which is what an isolated run reads back.

// A real script-file invocation runs every testmodule in its own process by default, with no flag to turn that off.
// process.argv[0] is this script's own path under one of those but the agent's exe path under -b64exec, so the .js suffix is what tells the two apart.
// -b64exec keeps everything in the one shared process, which is the delivery path it exists to test.
var OPT_WATCHDOG = 10000;
var OPT_EXCLUDE = [];
var OPT_QEMU = false;
var OPT_FSTEST = false;
var OPT_ONLY = '';
var OPT_RESULTFILE = '';
(function () {
    var av = process.argv || [];
    var watchdogSet = false;
    for (var i = 0; i < av.length; ++i) {
        var a = ('' + av[i]);
        if (a.indexOf('--watchdog=') == 0) { OPT_WATCHDOG = parseInt(a.substring(11)) || OPT_WATCHDOG; watchdogSet = true; }
        else if (a == '--qemu') { OPT_QEMU = true; }
        else if (a == '--fs-test') { OPT_FSTEST = true; }
        else if (a.indexOf('--only=') == 0) { OPT_ONLY = a.substring(7); }
        else if (a.indexOf('--result-file=') == 0) { OPT_RESULTFILE = a.substring(14); }
        else if (a.indexOf('--exclude=') == 0) {
            var parts = a.substring(10).split(',');
            for (var j = 0; j < parts.length; ++j) { if (parts[j] != '') { OPT_EXCLUDE.push(parts[j]); } }
        }
    }
    if (OPT_QEMU && !watchdogSet) { OPT_WATCHDOG = 60000; }
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

// A check for a defect that is already on record. It passes like any other check, but a
// failure is counted as KNOWN instead of FAIL so the run stays green until the fix lands.
// ref names the ISSUES.md entry, so a KNOWN line can never be an orphan.
function known(section, cond, msg, ref) {
    if (cond) { RESULTS.pass++; }
    else {
        RESULTS.known++;
        console.log('KNOWN [' + section + '] ' + msg + ' (' + ref + ')');
    }
}
// Handed to the testmodules as check.known, so run()'s signature stays as documented.
check.known = known;

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
            // A batch of exactly one section calls done() synchronously in here, reaching finish()'s process.exit() before this stack unwinds.
            // That exit is itself a catchable exception carrying "Process.exit() forced script termination", so without this check
            // it lands here and gets reported as this section throwing, after the TOTAL line has already printed.
            var emsg = (e && e.message ? e.message : ('' + e));
            if (emsg.indexOf('Process.exit() forced script termination') >= 0) { throw e; }
            RESULTS.fail++;
            var msg = 'EXCEPTION: ' + emsg;
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
    var totalLine = 'TOTAL: ' + RESULTS.pass + ' passed, ' + RESULTS.fail + ' failed (of ' + (RESULTS.pass + RESULTS.fail + RESULTS.known) + ')' + (RESULTS.known > 0 ? ', ' + RESULTS.known + ' known' : '');
    console.log('');
    console.log('==================================================');
    console.log(totalLine);
    if (FAILURES.length > 0) {
        console.log('Failures:');
        for (var i = 0; i < FAILURES.length; ++i) { console.log('  ' + FAILURES[i]); }
    }
    console.log('==================================================');
    // Written before exit so the isolated-run orchestrator can read a completed child's own result
    // straight off disk instead of trusting the live stdout pipe - see --result-file= above. The
    // failure lines come first and the TOTAL line last, so a reader that has matched TOTAL knows
    // the whole file landed, even though writeFileSync() of a string this small never splits.
    if (OPT_RESULTFILE) {
        var body = '';
        for (var f = 0; f < FAILURES.length; ++f) { body += 'FAIL ' + FAILURES[f] + '\n'; }
        try { require('fs').writeFileSync(OPT_RESULTFILE, body + totalLine + '\n'); } catch (e) { }
    }
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

// Shared by loadSections() (--only runs) and runIsolated() (the default orchestrator,
// which never requires() any of these - it only needs the filenames to spawn children for).
function discoverFiles() {
    var fs = require('fs');
    var files = fs.readdirSync(TESTMODULES_DIR).filter(function (f) { return (/\.js$/i).test(f); }).sort();
    if (OPT_ONLY) { return files.filter(function (f) { return f == OPT_ONLY; }); }
    if (OPT_EXCLUDE.length > 0) {
        files = files.filter(function (f) {
            for (var x = 0; x < OPT_EXCLUDE.length; ++x) {
                if (f.indexOf(OPT_EXCLUDE[x]) >= 0) { console.log('SKIP ' + f + ' (--exclude)'); return false; }
            }
            return true;
        });
    }
    return files;
}

function loadSections() {
    var files = discoverFiles();
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
            // Filenames are numbered so a section's place in the run order is visible on disk
            // (ls order); carry that number into the console header too, e.g. "01-JS Engine".
            var num = fileName.match(/^(\d+)-/);
            var label = mod.name ? (num ? num[1] + '-' + mod.name : mod.name) : fileName;
            sections.push(wrapSection(label, function (done) {
                mod.run(check, deepEqual, done, scratch);
            }));
        })(mod, files[i]);
    }
    return sections;
}

// ---------------------------------------------------------------------------------------------
// isolated runs: one child process per testmodule (the default for a normal run - see below)
// ---------------------------------------------------------------------------------------------

var TOTAL_RE = /TOTAL: (\d+) passed, (\d+) failed \(of (\d+)\)(?:, (\d+) known)?/;

// Spins on the read rather than sleeping between tries, because every sleep this engine offers
// pumps the chain, and the chain is the machinery this is deliberately not relying on. A file
// caught half written just does not match yet, so the loop keeps going until it does.
function pollResultFile(path, graceMs) {
    var fs = require('fs');
    var deadline = Date.now() + graceMs;
    for (; ;) {
        try {
            var text = fs.readFileSync(path).toString();
            var m = TOTAL_RE.exec(text);
            if (m) { m.text = text; return m; }
        } catch (e) { }
        if (Date.now() >= deadline) { return null; }
    }
}

// Spawning this script again with --only=<file> gives each testmodule its own process, so a native crash costs just
// that module instead of ending the run for every later one, which is what a plain run did after the 06-* sections.
// Each child's TOTAL line is added to this process's own counts, so the final line still parses in test-agent.sh and .ps1.
// Nothing here rests on child_process behaving, because the verdict comes from the result file the child's finish() wrote.
// waitExit() and live stdout are best-effort, since a child's exit ends whichever wait is running rather than its own.
function runIsolated(files) {
    if (files.length == 0) { console.log('WARNING: no test modules found under ' + TESTMODULES_DIR); finish(); return; }
    var cp = require('child_process');
    var fs = require('fs');
    // process.argv[0] is this script's own path as it was actually invoked (relative or absolute,
    // with the right separator for the platform), so a child re-invokes the exact same file.
    var selfPath = (process.argv && process.argv[0]) ? process.argv[0] : (TESTMODULES_DIR.replace(/\/testmodules$/, '') + '/stress-test.js');
    var resultDir = scratch('isolate-results');
    try { fs.mkdirSync(resultDir); } catch (e) { }

    var idx = 0;
    (function step() {
        if (idx >= files.length) {
            // Each result file is removed right after it is read below, so this is normally
            // already empty - removeScratchDir() only unlinks files, not this subdirectory itself.
            try { fs.rmdirSync(resultDir); } catch (e) { }
            finish();
            return;
        }
        var file = files[idx++];
        // execFile() hands this array straight to execve()/execv() as the child's raw argv, where
        // argv[0] is just the conventional program-name slot - the agent's own main() reads the
        // script path from argv[1], so a placeholder has to occupy argv[0] or the script path never
        // arrives and the agent tries to run "--only=..." as if it were the script.
        var resultFile = resultDir + '/' + file.replace(/[^a-zA-Z0-9_.-]/g, '_') + '.txt';
        try { fs.unlinkSync(resultFile); } catch (e) { }
        var args = ['meshagent', selfPath, '--only=' + file, '--watchdog=' + OPT_WATCHDOG, '--result-file=' + resultFile];
        if (OPT_FSTEST) { args.push('--fs-test'); }
        if (OPT_QEMU) { args.push('--qemu'); }
        var c = cp.execFile(process.execPath, args);
        // Live stdout is for the log only, because a pre-existing ILibProcessPipe.c race truncates it between children spawned in a short span.
        // What counts is resultFile below, written by the child's own finish() and read back after it has already stopped.
        var out = '';
        c.stdout.on('data', function (d) { out += d.toString(); });
        c.stderr.on('data', function (d) { out += d.toString(); });
        var exitSeen = false, exitCode = null;
        c.on('exit', function (code) { exitSeen = true; exitCode = code; });
        // Generous headroom over the child's own watchdog: that one already covers a stuck
        // testmodule, this one only needs to catch a hang the child's own JS-level timer cannot
        // reach, such as a native loop with no JS involved.
        var deadlineSec = Math.ceil(OPT_WATCHDOG / 1000) + 15;
        var waitThrew = false;
        try { c.waitExit(deadlineSec); }
        catch (e) { waitThrew = true; }
        process.stdout.write(out);

        // waitExit() is the fast path only, never what the verdict rests on. This branch still has
        // one global continuation state per chain, so any child's exit ends whichever wait happens
        // to be running, and a wait can return before its own child has written anything.
        // Polling for the result file touches neither the chain nor the pipe manager, so the
        // verdict holds whether or not waitExit() behaved.
        var graceMs = (exitSeen || waitThrew) ? 2000 : (deadlineSec * 1000);
        var g = pollResultFile(resultFile, graceMs);
        try { fs.unlinkSync(resultFile); } catch (e) { }
        if (g) {
            RESULTS.pass += parseInt(g[1]);
            RESULTS.fail += parseInt(g[2]);
            RESULTS.known += g[4] ? parseInt(g[4]) : 0;
            // The child's own failure lines, so which check failed survives into the final summary
            // even when its live stdout never arrived. Not echoed here, or a run whose stdout did
            // work would print every failure twice.
            var lines = g.text.split('\n');
            for (var li = 0; li < lines.length; ++li) {
                if (lines[li].indexOf('FAIL ') == 0) { FAILURES.push('[' + file + '] ' + lines[li].substring(5)); }
            }
        }
        // No result file means the child never reached its own finish(). The three cases read very
        // differently, so they are reported apart: a real exit code points at a native crash in the
        // module, while "waitExit() returned without this child ever exiting" is the harness being
        // told the wrong child ended.
        if (!g) {
            try { c.kill(); } catch (e) { }
            RESULTS.fail++;
            var why = exitSeen ? ('exited with code ' + exitCode + ' and left no result file')
                : (waitThrew ? ('did not finish within ' + deadlineSec + 's, killed')
                    : ('waitExit() returned without this child ever exiting, and no result file appeared within ' + deadlineSec + 's'));
            var msg = '[' + file + '] ' + why;
            FAILURES.push(msg);
            console.log('FAIL ' + msg);
        }
        step();
    })();
}

// ---------------------------------------------------------------------------------------------
// run everything
// ---------------------------------------------------------------------------------------------

// Isolated by default for a real script-file invocation, told apart by process.argv[0] ending in .js, which is this
// script's own path there but the agent's exe path under -b64exec.
// An isolated child passes --only=<file> and so takes the shared-process path below, or it would spawn a child of its own.
if (!OPT_ONLY && process.argv && process.argv[0] && (/\.js$/i).test(process.argv[0])) {
    // Each child enforces its own watchdog, and the wait above it is itself bounded, so the
    // orchestrator loop cannot hang - no top-level watchdog needed for this path.
    var ISOFILES = [];
    try { ISOFILES = discoverFiles(); }
    catch (e) {
        RESULTS.fail++;
        var isoLoadMsg = 'EXCEPTION discovering test modules under ' + TESTMODULES_DIR + ': ' + (e && e.message ? e.message : e);
        FAILURES.push('[loader] ' + isoLoadMsg);
        console.log('FAIL [loader] ' + isoLoadMsg);
        finish();
    }
    runIsolated(ISOFILES);
}
else {
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
}
