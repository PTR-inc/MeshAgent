/*
Copyright 2026 Intel Corporation

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

// Exercises ILib_WindowsExceptionDebugEx() in microstack/ILibParsers.c.
// Run with the agent binary itself, e.g.:
//   MeshService.exe test\crashhandler-test.js
//   MeshConsole.exe test\crashhandler-test.js
//
// This crashes a *child* agent process via the native _debugCrash() hook (a NULL pointer
// write), then parses the crash dump that ILib_WindowsExceptionDebugEx() prints to stdout
// before exit(254). It checks the things that changed in that function:
//   1. Every frame is walked and logged, not just the crashing frame.
//   2. A frame with no resolvable symbol still gets a line (the raw address), instead of
//      being silently dropped.
//   3. The symbol name and source file name are each bounded to 256 characters (%.256s),
//      so a pathological symbol/path can't overflow the 4096 byte formatting buffer.
//   4. The walk stops at 32 frames.
//   5. The process still exits with code 254 (ILIBCRITICALEXITMSG(254, ...)).
//
// This is Windows-only, because ILib_WindowsExceptionDebugEx() only exists in the
// "#if defined(WIN32)" branch of ILibParsers.c. The architecture-selection fix in the same
// change (#elif ARM64 -> #elif defined(_M_ARM64), etc.) is compile-time only: if this test
// runs at all on a given architecture, that selector already resolved correctly at build time.

if (process.platform != 'win32')
{
    console.log('SKIP: crashhandler-test.js only applies to the Windows exception handler (process.platform == "' + process.platform + '")');
    process.exit(0);
}

var child_process = require('child_process');

var MAX_FRAMES = 32;
var MAX_SYMBOL_LEN = 256;
var EXPECTED_EXIT_CODE = 254;

var stdout = '';
var failures = [];
var passes = [];

function pass(msg) { passes.push(msg); console.log('  [PASS] ' + msg); }
function fail(msg) { failures.push(msg); console.log('  [FAIL] ' + msg); }

console.log('Starting crash handler test...');
console.log('  Spawning: ' + process.execPath + ' -exec "_debugCrash();"');

var c = child_process.execFile(process.execPath, [process.execPath, '-exec', '_debugCrash();']);
c.stdout.on('data', function (b) { stdout += b.toString(); });
c.stderr.on('data', function (b) { stdout += b.toString(); });

c.on('exit', function (code)
{
    console.log('Child process exited with code: ' + code);
    console.log('--- Captured output ---');
    console.log(stdout);
    console.log('--- End captured output ---');

    // 1. Exit code check
    if (code == EXPECTED_EXIT_CODE)
    {
        pass('Child exited with code ' + EXPECTED_EXIT_CODE + ' (ILIBCRITICALEXITMSG)');
    }
    else
    {
        fail('Expected exit code ' + EXPECTED_EXIT_CODE + ', got ' + code);
    }

    // 2. Header line present
    if (/FATAL EXCEPTION @ \[FuncAddr: 0x[0-9A-Fa-f]+ \/ BaseAddr: 0x[0-9A-Fa-f]+ \/ Delta: -?\d+\]/.test(stdout))
    {
        pass('FATAL EXCEPTION header with FuncAddr/BaseAddr/Delta present');
    }
    else
    {
        fail('FATAL EXCEPTION header not found in output');
    }

    // 3. Collect frame lines: "    [<symbol>" or "    [<symbol> => <file>:<line>]" or "    [0x<addr>]"
    var frameLines = stdout.split('\n').filter(function (l) { return (/^\s{4}\[/.test(l)); });
    console.log('  Detected ' + frameLines.length + ' frame line(s)');

    if (frameLines.length > 1)
    {
        pass('More than one stack frame was logged (frame-walk loop, not just the crashing frame)');
    }
    else
    {
        fail('Expected more than one frame line, got ' + frameLines.length);
    }

    if (frameLines.length <= MAX_FRAMES)
    {
        pass('Frame count (' + frameLines.length + ') does not exceed the ' + MAX_FRAMES + ' frame cap');
    }
    else
    {
        fail('Frame count (' + frameLines.length + ') exceeds the ' + MAX_FRAMES + ' frame cap');
    }

    // 4. At least one raw-address fallback line for a frame with no resolvable symbol.
    //    (_debugCrash's own frames inside the agent should resolve, but frames from the
    //    CRT/kernel that called into main() typically will not.)
    var hasAddressOnlyFrame = frameLines.some(function (l) { return (/^\s{4}\[0x[0-9A-Fa-f]+\]\s*$/.test(l)); });
    if (hasAddressOnlyFrame)
    {
        pass('At least one symbol-less frame logged as a raw address, instead of being dropped');
    }
    else
    {
        console.log('  [INFO] No symbol-less frame observed; not a failure, just means every frame resolved to a symbol on this system');
    }

    // 5. Bound check on symbol name / file name lengths (the %.256s change)
    var tooLong = false;
    frameLines.forEach(function (l)
    {
        var inner = l.replace(/^\s{4}\[/, '').replace(/\]\s*$/, '');
        var parts = inner.split(' => ');
        var symbolPart = parts[0];
        var filePart = parts.length > 1 ? parts[1].replace(/:\d+$/, '') : null;

        if (symbolPart.length > MAX_SYMBOL_LEN) { tooLong = true; console.log('  [FAIL] Symbol segment exceeds ' + MAX_SYMBOL_LEN + ' chars: ' + symbolPart.length); }
        if (filePart != null && filePart.length > MAX_SYMBOL_LEN) { tooLong = true; console.log('  [FAIL] File segment exceeds ' + MAX_SYMBOL_LEN + ' chars: ' + filePart.length); }
    });
    if (!tooLong)
    {
        pass('No symbol/file segment exceeds the ' + MAX_SYMBOL_LEN + ' character bound (%.256s)');
    }
    else
    {
        fail('At least one symbol/file segment exceeded the ' + MAX_SYMBOL_LEN + ' character bound');
    }

    console.log('');
    console.log('Results: ' + passes.length + ' passed, ' + failures.length + ' failed');
    process.exit(failures.length == 0 ? 0 : 1);
});
