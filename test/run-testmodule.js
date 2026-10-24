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
// Runs one test/testmodules/*.js on its own, with the same run(check, deepEqual, done, scratch) contract the
// stress-test.js driver uses, for a checkout that does not carry that driver. From the repo root:
//     meshagent test/run-testmodule.js test/testmodules/19-module-replace.js
// Exit code 0 when every check passed, 1 otherwise. The TOTAL line has the driver's format.
//

var fs = require('fs');
var RESULTS = { pass: 0, fail: 0, known: 0 };
var FAILURES = [];

function check(section, cond, msg) {
    if (cond) { RESULTS.pass++; }
    else {
        RESULTS.fail++;
        FAILURES.push('[' + section + '] ' + msg);
        console.log('FAIL [' + section + '] ' + msg);
    }
}
// A check for a defect that is already on record, counted as KNOWN instead of FAIL. ref names the entry
check.known = function (section, cond, msg, ref) {
    if (cond) { RESULTS.pass++; }
    else {
        RESULTS.known++;
        console.log('KNOWN [' + section + '] ' + msg + ' (' + ref + ')');
    }
};

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

// In script mode process.argv starts with this script, the binary is not in it
var modPath = process.argv[process.argv.length - 1];
if (process.argv.length < 2 || !/\.js$/i.test(modPath)) {
    console.log('usage: meshagent test/run-testmodule.js test/testmodules/<name>.js');
    exit(2);
}

// A process.exit() before the chain runs is lost, so the exit goes through a timer
function exit(code) { setTimeout(function () { process.exit(code); }, 0); }

// Per-process scratch directory, as the driver gives each testmodule
var sep = process.platform == 'win32' ? '\\' : '/';
var tmp = process.env['TEMP'] || process.env['TMPDIR'] || '/tmp';
var scratch = tmp + sep + 'ma-testmodule-' + process.pid;
try { fs.mkdirSync(scratch); } catch (e) { }

// require() resolves relative to the cwd, so the module path is given relative to the repo root
var mod = require('./' + modPath.replace(/\\/g, '/').replace(/\.js$/i, ''));
console.log('=== ' + (mod.name || modPath) + ' ===');
// A module that never calls done() would leave the run waiting forever, so it ends as a failure after 5 minutes
var runLimit = setTimeout(function () { console.log('TIMEOUT: the module did not finish within 300 s'); RESULTS.fail++; FAILURES.push('[run] timed out'); finishRun(); }, 300000);
var runFinished = false;
mod.run(check, deepEqual, finishRun, scratch);
function finishRun() {
    if (runFinished) { return; }
    runFinished = true;
    clearTimeout(runLimit);
    var total = RESULTS.pass + RESULTS.fail + RESULTS.known;
    console.log('TOTAL: ' + RESULTS.pass + ' passed, ' + RESULTS.fail + ' failed (of ' + total + ')' + (RESULTS.known ? ', ' + RESULTS.known + ' known' : ''));
    for (var i = 0; i < FAILURES.length; ++i) { console.log('  ' + FAILURES[i]); }
    try {
        var files = fs.readdirSync(scratch);
        for (var f = 0; f < files.length; ++f) { try { fs.unlinkSync(scratch + sep + files[f]); } catch (e) { } }
        fs.rmdirSync(scratch);
    } catch (e) { }
    exit(RESULTS.fail == 0 ? 0 : 1);
}
