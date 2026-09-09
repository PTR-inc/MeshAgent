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

// fs, covering everything that changed to support positions and lengths above 2^31: readFileSync() on sources
// with and without a usable length, position coercion, and with --fs-test the >2 GB paths through readSync,
// the async fs.read, writeSync and createReadStream, which all carried a 32-bit position and a fseek(long).
// That section is opt-in because it needs a scratch dir supporting sparse files, which some CI runners and
// network mounts do not, and on Windows also `fsutil sparse setflag`, which needs an elevated prompt.
// The OpenMode section covers the shared, always-binary, non-inheritable open behind every string-mode
// fs call (ILibFile_Open): which mode strings are accepted and refused on every platform, 'x', append,
// a second opener and an unlink while a handle is held, and that a child process does not inherit it.

exports.name = 'FS';
exports.run = function (check, deepEqual, done, scratch) {
    var fs = require('fs');
    var cp = require('child_process');
    var isWin = process.platform == 'win32';
    var isLinux = process.platform == 'linux';

    // Marks fsutil needs the target file to exist first, then asks it to set FILE_ATTRIBUTE_SPARSE.
    // A no-op on non-Windows, since ext4/APFS/etc. scratch files are sparse-capable by default.
    function trySetSparse(path) {
        if (!isWin) { return true; }
        try {
            fs.closeSync(fs.openSync(path, 'w'));
            var shell = process.env['ComSpec'] || 'C:\\Windows\\System32\\cmd.exe';
            var p = cp.execFile(shell, ['cmd.exe', '/c', 'fsutil sparse setflag "' + path + '"']);
            p.code = null;
            p.on('exit', function (code) { this.code = code; });
            p.waitExit();
            return p.code === 0;
        } catch (e) { return false; }
    }

    openModeChecks();
    readFileSyncChecks();

    // --- the string-mode open: accepted and refused modes, x, append, sharing, unlink, inheritance ---
    function openModeChecks() {
        var S = 'OpenMode';
        var p = scratch('om-file.bin');
        function rm(f) { try { fs.unlinkSync(f); } catch (e) { } }
        // --openmode-trace names every mode right before it is tried, so a build that dies on one leaves the
        // offender as the last line. Run the agent unredirected, or block buffering eats it (see the run notes).
        var TRACE = false, av = process.argv || [];
        for (var t = 0; t < av.length; ++t) { if (('' + av[t]) == '--openmode-trace') { TRACE = true; } }
        function step(what) { if (TRACE) { console.log('  [' + S + '] --- ' + what); } }
        function opens(mode) {
            if (TRACE) { console.log('  [' + S + '] openSync(path, "' + mode + '")'); } try { fs.closeSync(fs.openSync(p, mode)); return true; } catch (e) { return false; } }
        // An empty Buffer's toString() returns null on this engine (a Buffer polyfill defect, on record), so
        // the empty case is spelled out rather than letting it read as "readFileSync threw".
        function content() { try { var b = fs.readFileSync(p); return (b.length == 0 ? '' : b.toString()); } catch (e) { return null; } }

        step('accepted modes');
        // Every mode the agent's own modules and the server-pushed cores send, plus the plain forms.
        // b is inert, N (the CRT no-inherit letter) has to stay accepted because meshcore.js still sends rbN and wbN.
        fs.writeFileSync(p, 'seed');
        var ok = ['r', 'rb', 'rbN', 'r+', 'rb+', 'r+b', 'w', 'wb', 'wbN', 'w+', 'wb+', 'a', 'ab', 'abN', 'a+', 'ab+'];
        for (var i = 0; i < ok.length; ++i) {
            check(S, opens(ok[i]), 'openSync(path, "' + ok[i] + '") threw, but that mode has to open');
        }

        step('refused modes, the three the CRT itself accepts');
        // Strings Node throws on. These three are valid CRT modes, so a build without the common mode
        // check opens them instead of dying, which makes them the safe probe for whether it has one.
        fs.writeFileSync(p, 'seed');
        var badSafe = ['rt', 'wt', 'r,ccs=UTF-8'];
        for (var j = 0; j < badSafe.length; ++j) {
            check(S, !opens(badSafe[j]), 'openSync(path, "' + badSafe[j] + '") opened, but that mode has to be refused');
        }

        // A mode the CRT's own parser rejects is not an error return: _wfopen_s calls the invalid-parameter
        // handler, which with none installed is __fastfail(FAST_FAIL_INVALID_ARG), and no JS catch can help.
        // Refusing 'rt' above proves this build checks the mode before the CRT sees it, which is what makes
        // the rest safe here. On POSIX fopen just returns NULL, so they always run there.
        step('probing whether this build checks the mode before the CRT sees it');
        var fatalSafe = !isWin || !opens('rt');
        if (!fatalSafe) { console.log('NOTE: [' + S + '] skipping the invalid-mode and "ax" checks: this build hands the mode to _wfopen_s, which terminates the process on a mode its parser rejects'); }
        var badFatal = ['rx', 'xw', 'Na+', '', 'q'];
        if (fatalSafe) {
            for (var jf = 0; jf < badFatal.length; ++jf) {
                check(S, !opens(badFatal[jf]), 'openSync(path, "' + badFatal[jf] + '") opened, but that mode has to be refused');
            }
        }
        var rtThrew = false;
        try { fs.readFileSync(p, { flags: 'rt' }); } catch (e) { rtThrew = true; }
        check(S, rtThrew, 'readFileSync(path, {flags:"rt"}) did not throw');
        check(S, content() == 'seed', 'the refused opens changed the file to "' + content() + '"');

        step('x semantics');
        // x: create only if the path is new. CREATE_NEW on Windows, O_EXCL on POSIX, both for w and a.
        rm(p);
        check(S, opens('wx'), 'openSync("wx") on a missing file threw');
        check(S, !opens('wx'), 'openSync("wx") on an existing file opened instead of failing');
        check(S, !opens('wx+'), 'openSync("wx+") on an existing file opened instead of failing');
        // 'x' after 'a' is one of the modes the CRT parser rejects, so these are gated like badFatal above.
        if (fatalSafe) {
            check(S, !opens('ax'), 'openSync("ax") on an existing file opened instead of failing');
            check(S, !opens('ax+'), 'openSync("ax+") on an existing file opened instead of failing');
            rm(p);
            check(S, opens('ax'), 'openSync("ax") on a missing file threw');
            rm(p);
            check(S, opens('ax+'), 'openSync("ax+") on a missing file threw');
        }
        rm(p);
        check(S, opens('wx+'), 'openSync("wx+") on a missing file threw');

        step('append and truncate semantics');
        // a and a+: every write lands at the end, a+ can also read from the start.
        fs.writeFileSync(p, 'AAAA');
        var afd = fs.openSync(p, 'a');
        fs.writeSync(afd, Buffer.from('BB'));
        fs.closeSync(afd);
        check(S, content() == 'AAAABB', 'after openSync("a") + writeSync the file is "' + content() + '" (expected "AAAABB")');
        var apfd = fs.openSync(p, 'a+');
        var rb = Buffer.alloc(6);
        var rn = fs.readSync(apfd, rb, { position: 0, length: 6 });
        check(S, rb.slice(0, rn).toString() == 'AAAABB', 'readSync through an "a+" handle gave "' + rb.slice(0, rn).toString() + '"');
        fs.writeSync(apfd, Buffer.from('CC'));
        fs.closeSync(apfd);
        check(S, content() == 'AAAABBCC', 'after openSync("a+") + writeSync the file is "' + content() + '" (expected "AAAABBCC")');
        // w+ truncates, r+ does not.
        fs.closeSync(fs.openSync(p, 'r+'));
        check(S, content() == 'AAAABBCC', 'openSync("r+") truncated the file to "' + content() + '"');
        fs.closeSync(fs.openSync(p, 'w+'));
        check(S, content() == '', 'openSync("w+") left "' + content() + '" instead of truncating');

        step('binary round trip');
        // Always binary: every byte value through a w/r pair with no b, which on Windows used to be text mode.
        var all = Buffer.alloc(256);
        for (var v = 0; v < 256; ++v) { all[v] = v; }
        var wfd = fs.openSync(p, 'w');
        fs.writeSync(wfd, all);
        fs.closeSync(wfd);
        var rfd = fs.openSync(p, 'r');
        var back = Buffer.alloc(300);
        var bn = fs.readSync(rfd, back, { position: 0, length: 300 });
        fs.closeSync(rfd);
        var same = (bn == 256);
        for (var k = 0; same && k < 256; ++k) { if (back[k] != k) { same = false; } }
        check(S, same, 'a w/r round trip of all 256 byte values gave ' + bn + ' bytes' + (bn == 256 ? ' with a changed byte' : '') + ', so the open is not binary');
        var stat = fs.statSync(p);
        check(S, stat.size == 256, 'statSync after the binary write reports ' + stat.size + ' bytes (expected 256)');

        step('sharing, unlink under an open handle');
        // Shared: a second opener while a handle is held, in both directions, and an unlink under an open handle.
        // On POSIX this always worked. On Windows the old open was exclusive for every write mode and blocked delete for every mode.
        var held = fs.openSync(p, 'w');
        fs.writeSync(held, Buffer.from('held'));
        var secondOk = false;
        try { fs.closeSync(fs.openSync(p, 'r')); secondOk = true; } catch (e) { }
        check(S, secondOk, 'openSync("r") while another handle holds the file for "w" threw');
        var rfsOk = null;
        try { rfsOk = fs.readFileSync(p).length; } catch (e) { }
        check(S, rfsOk !== null, 'readFileSync() while another handle holds the file for "w" threw');
        fs.closeSync(held);
        var held2 = fs.openSync(p, 'r');
        var wOk = false;
        try { fs.closeSync(fs.openSync(p, 'a')); wOk = true; } catch (e) { }
        check(S, wOk, 'openSync("a") while another handle holds the file for "r" threw');
        var unlinkOk = false;
        try { fs.unlinkSync(p); unlinkOk = true; } catch (e) { }
        check(S, unlinkOk, 'unlinkSync() while a handle holds the file for "r" threw');
        check(S, !opens('r'), 'openSync("r") on a path unlinked under an open handle succeeded');
        fs.closeSync(held2);
        check(S, !fs.existsSync(p), 'the file is still there after unlink and close');

        step('another process holds the file with FileShare::Read');
        // MeshCentral issue 7832: a file another process holds open cannot be downloaded. The holder allows
        // readers, but the old read open asked for share FILE_SHARE_READ only (the CRT's _SH_SECURE), which
        // does not permit the holder's own write access, so Windows refused it where Explorer copies happily.
        // The holder is a real second process, because the share check only applies across handles.
        if (isWin) {
            var lockPath = scratch('om-locked.log');
            var readyPath = scratch('om-locked.ready');
            var stopPath = scratch('om-locked.stop');
            rm(readyPath); rm(stopPath);
            fs.writeFileSync(lockPath, 'LOCKED-CONTENT');
            // execFile() does not search PATH on Windows, so powershell.exe is named in full.
            var psExe = (process.env['SystemRoot'] || 'C:\\Windows') + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
            // The Windows spawn pastes the arguments into one command line separated by single spaces, with no
            // quoting and no escaping (ILibProcessPipe.c), so the payload is quoted here and uses single quotes
            // inside. Passing it unquoted makes PowerShell see a dozen broken arguments and exit without running.
            var psCmd = "$ErrorActionPreference='Stop';" +
                "$s=New-Object System.IO.FileStream('" + lockPath + "',[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read);" +
                "New-Item -ItemType File -Force -Path '" + readyPath + "' | Out-Null;" +
                "while(-not (Test-Path '" + stopPath + "')){Start-Sleep -Milliseconds 50};" +
                "$s.Close()";
            var holder = null, holderOut = '';
            try {
                holder = cp.execFile(psExe, ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '"' + psCmd + '"']);
                // Whatever PowerShell complains about is the first thing worth seeing if this check fails.
                try { holder.stdout.on('data', function (d) { holderOut += d.toString(); }); } catch (e) { }
                try { holder.stderr.on('data', function (d) { holderOut += d.toString(); }); } catch (e) { }
            } catch (e) { holderOut = 'execFile threw: ' + e; }
            // Waits on the marker file rather than the child, so this cannot fail for a child_process reason.
            var hDeadline = Date.now() + 15000, holding = false;
            while (holder != null && !holding && Date.now() < hDeadline) { try { fs.statSync(readyPath); holding = true; } catch (e) { } }
            check(S, holding, 'the PowerShell holder never signalled ready, so the locked-file checks could not run. Its output was: ' + (holderOut == '' ? '(nothing)' : holderOut.substring(0, 400)));
            if (holding) {
                var lockGot = null;
                try { lockGot = fs.readFileSync(lockPath).toString(); } catch (e) { }
                check(S, lockGot == 'LOCKED-CONTENT', 'readFileSync() of a file another process holds ReadWrite with FileShare::Read gave ' + (lockGot == null ? 'a throw' : '"' + lockGot + '"'));
                var lockRb = false;
                try { fs.closeSync(fs.openSync(lockPath, 'rb')); lockRb = true; } catch (e) { }
                check(S, lockRb, 'openSync("rb") of a file another process holds ReadWrite with FileShare::Read threw');
                // rbN is the exact mode the server-pushed meshcore.js download path uses.
                var lockRbN = false;
                try { fs.closeSync(fs.openSync(lockPath, 'rbN')); lockRbN = true; } catch (e) { }
                check(S, lockRbN, 'openSync("rbN"), the mode meshcore.js downloads with, threw on a file another process holds');
            }
            try { fs.writeFileSync(stopPath, 'x'); } catch (e) { }
            var relDeadline = Date.now() + 15000, released = false;
            while (!released && Date.now() < relDeadline) { try { fs.unlinkSync(lockPath); released = true; } catch (e) { } }
            if (!released && holder != null) { try { holder.kill(); } catch (e) { } }
            rm(lockPath); rm(readyPath); rm(stopPath);
        }

        step('child does not inherit');
        // Not inherited: a child that lists its own descriptors must not see the file this process holds open.
        // Every open is close-on-exec now, so exec drops it. Output goes through a rename so the reader never
        // sees a half-written listing, and the wait is on the filesystem so no child_process wait is involved.
        if (isLinux) {
            var keep = fs.openSync(p, 'w');
            var out = scratch('om-child-fds.txt');
            rm(out);
            cp.execFile('/bin/sh', ['sh', '-c', 'ls -l /proc/self/fd > "' + out + '.tmp" 2>&1; mv "' + out + '.tmp" "' + out + '"']);
            var dl = Date.now() + 5000, listing = null;
            while (listing == null && Date.now() < dl) { try { listing = fs.readFileSync(out).toString(); } catch (e) { } }
            fs.closeSync(keep);
            rm(out);
            check(S, listing != null && listing.indexOf('->') >= 0, 'the child never produced a descriptor listing' + (listing == null ? '' : ': ' + listing.substring(0, 80)));
            check(S, listing != null && listing.indexOf(p) < 0, 'the child inherited the file this process had open:\n' + listing);
        }
        rm(p);
    }

    // --- readFileSync() on small files, and the growing buffer for sources with no length ---
    function readFileSyncChecks() {
        var S = 'ReadFileSync';
        var HEX = '0123456789ABCDEF';
        var pattern = HEX + HEX + HEX + HEX;                                // 64 bytes, byte at offset p is HEX[p % 16]
        var small = scratch('rfs-small.bin');
        var empty = scratch('rfs-empty.bin');
        fs.writeFileSync(small, pattern);
        fs.writeFileSync(empty, '');

        var b1 = fs.readFileSync(small);
        check(S, b1.length == 64 && b1.toString() == pattern, 'readFileSync() of a 64 byte file gave ' + b1.length + ' bytes');
        var b2 = fs.readFileSync(empty);
        check(S, b2.length == 0, 'readFileSync() of an empty file gave length ' + b2.length);

        if (isLinux) {
            var st = fs.readFileSync('/proc/self/status').toString();
            check(S, st.length > 0 && st.indexOf('Name:') >= 0, 'readFileSync(/proc/self/status) gave ' + st.length + ' bytes without a Name: line');
        }
        if (!isWin) {
            // A FIFO reports no length, so readFileSync() reads it until EOF through the growing buffer.
            // tee writes the reference copy before each FIFO write, so it is complete when the FIFO hits EOF.
            var fifo = scratch('rfs-fifo');
            var ref = scratch('rfs-fifo-ref.bin');
            // Waits on the filesystem rather than mk.waitExit(), so this fs section cannot fail for
            // a child_process reason. On this branch a child's exit ends whichever wait is running
            // rather than its own, so waitExit() can return before mkfifo has done anything.
            cp.execFile('/bin/sh', ['sh', '-c', 'mkfifo "' + fifo + '"']);
            var mkDeadline = Date.now() + 5000, haveFifo = false;
            while (!haveFifo && Date.now() < mkDeadline) { try { fs.statSync(fifo); haveFifo = true; } catch (e) { } }
            check(S, haveFifo, 'mkfifo did not create ' + fifo + ' within 5s');
            var sizes = haveFifo ? [4096, 100000, 4097, 0] : [];
            for (var si = 0; si < sizes.length; ++si) {
                var n = sizes[si];
                try { fs.unlinkSync(ref); } catch (e) { }
                cp.execFile('/bin/sh', ['sh', '-c', 'head -c ' + n + ' /dev/urandom | tee "' + ref + '" > "' + fifo + '"']);
                var got = null, err = null;
                try { got = fs.readFileSync(fifo); } catch (e) { err = e; }
                // The reference copy is complete once it reaches n bytes, which is a plain stat, so
                // the writer never has to be waited on through child_process.
                var refDeadline = Date.now() + 5000, refDone = false;
                while (!refDone && Date.now() < refDeadline) { try { refDone = (fs.statSync(ref).size == n); } catch (e) { } }
                if (err != null) { check(S, false, 'readFileSync() of a ' + n + ' byte FIFO threw: ' + err); continue; }
                var want = fs.readFileSync(ref);
                var same = (got.length == n && want.length == n);
                for (var i = 0; same && i < n; ++i) { if (got[i] != want[i]) { same = false; } }
                check(S, same, 'readFileSync() of a ' + n + ' byte FIFO gave ' + got.length + ' bytes' + (got.length == n ? ' with wrong content' : ''));
            }
            try { fs.unlinkSync(fifo); } catch (e) { }
            try { fs.unlinkSync(ref); } catch (e) { }
        }

        optionCoercionChecks(small);
    }

    // --- position/length as a string, and the async paths, on the same small file ---
    function optionCoercionChecks(small) {
        var S = 'ReadFileSync';
        var fd = fs.openSync(small, 'rb');
        var b = Buffer.alloc(4);
        function rd(opts) { var k = fs.readSync(fd, b, opts); return (b.slice(0, k).toString()); }
        check(S, rd({ position: 0, length: 4 }) == '0123', 'readSync at position 0 did not return "0123"');
        var cont = rd({ position: 'abc', length: 4 });
        check(S, cont == '4567', 'readSync with position "abc" returned "' + cont + '" (expected "4567", continuing where the last read stopped, not "0123")');
        var str = rd({ position: '8', length: 4 });
        check(S, str == '89AB', 'readSync with position "8" returned "' + str + '" (expected "89AB")');
        var far = fs.readSync(fd, b, { position: 4294967296, length: 4 });
        check(S, far == 0, 'readSync at position 2^32 on a 64 byte file returned ' + far + ' bytes (expected 0)');
        fs.closeSync(fd);

        var settled = false;
        var guard = setTimeout(function () { if (!settled) { settled = true; check(S, false, 'async fs.read or createReadStream never finished'); largeFileChecks(); } }, 5000);
        exports._g = guard;
        var afd = fs.openSync(small, fs.constants.O_RDONLY);
        fs.read(afd, { buffer: Buffer.alloc(4), length: 4, position: '12' }, function (err, k, buf) {
            if (settled) { return; }
            var s = err ? null : buf.slice(0, k).toString();
            check(S, s == 'CDEF', 'async fs.read with position "12" returned "' + s + '" (err=' + err + ')');
            fs.closeSync(afd);

            var got = '';
            var rs = fs.createReadStream(small, { flags: 'rb', start: '10', end: '19' });
            rs.on('data', function (d) { got += d.toString(); });
            rs.on('end', function () {
                check(S, got == 'ABCDEF0123', 'createReadStream start="10" end="19" returned "' + got + '" (expected "ABCDEF0123")');
                settled = true;
                try { clearTimeout(guard); } catch (e) { }
                largeFileChecks();
            });
            rs.resume();
        });
    }

    // --- positions and sizes above 2 GB, opt-in since a non-sparse scratch write there is expensive ---
    function largeFileChecks() {
        var S = 'LargeFile';
        var enabled = false;
        var av = process.argv || [];
        for (var ai = 0; ai < av.length; ++ai) { if (('' + av[ai]) == '--fs-test') { enabled = true; } }
        if (!enabled) {
            console.log('NOTE: [' + S + '] skipped, pass --fs-test to run it');
            done();
            return;
        }

        var path = scratch('large.bin');
        var big = scratch('rfs-big.bin');
        try { if (fs.existsSync(path)) { fs.unlinkSync(path); } } catch (e) { }
        try { if (fs.existsSync(big)) { fs.unlinkSync(big); } } catch (e) { }

        if (isWin && (!trySetSparse(path) || !trySetSparse(big))) {
            console.log('NOTE: [' + S + '] fsutil sparse setflag failed, skipping (needs an elevated prompt and an NTFS scratch volume)');
            done();
            return;
        }

        var TWO = 2147483648;
        var marks = [
            { at: 0, text: 'MARK-AT-THE-START' },
            { at: 1000, text: 'MARK-BELOW-2GB!!!' },
            { at: TWO, text: 'MARK-AT-2GB-EXACT' },
            { at: TWO + 1000, text: 'MARK-2GB-PLUS1000' }
        ];
        var last = marks[marks.length - 1];
        var expectedSize = last.at + last.text.length;

        function cleanup() { try { fs.unlinkSync(path); } catch (e) { } }
        function readAt(fd, pos) {
            var b = Buffer.alloc(17);
            var n = fs.readSync(fd, b, { position: pos, length: 17 });
            return (b.slice(0, n).toString());
        }

        try {
            var wfd = fs.openSync(path, 'wb');
            for (var i = 0; i < marks.length; ++i) {
                var m = Buffer.from(marks[i].text);
                fs.writeSync(wfd, m, 0, m.length, marks[i].at);
            }
            fs.closeSync(wfd);
        } catch (e) { check(S, false, 'writing the sparse file threw: ' + e); cleanup(); done(); return; }

        var size = fs.statSync(path).size;
        check(S, size == expectedSize, 'statSync() size is ' + size + ' (expected ' + expectedSize + ')');

        var rfd = fs.openSync(path, 'rb');
        for (var r = 0; r < marks.length; ++r) {
            var got = readAt(rfd, marks[r].at);
            check(S, got == marks[r].text, 'readSync at ' + marks[r].at + ' returned "' + got + '" (expected "' + marks[r].text + '")');
        }
        fs.closeSync(rfd);

        // writeSync past 2 GB into an existing file, then read the bytes back
        var extraAt = TWO + 5000, extraText = 'WRITTEN-PAST-2GB!';
        try {
            var ufd = fs.openSync(path, 'r+b');
            fs.writeSync(ufd, Buffer.from(extraText), 0, extraText.length, extraAt);
            fs.closeSync(ufd);
            var vfd = fs.openSync(path, 'rb');
            var back = readAt(vfd, extraAt);
            fs.closeSync(vfd);
            check(S, back == extraText, 'writeSync at ' + extraAt + ' then readSync returned "' + back + '"');
        } catch (e) { check(S, false, 'writeSync past 2 GB threw: ' + e); }

        // The async read uses a real descriptor, not the FILE* mapped one that openSync('rb') hands out.
        var settled = false;
        var guard = setTimeout(function () { if (!settled) { settled = true; check(S, false, 'async fs.read or createReadStream past 2 GB never finished'); cleanup(); done(); } }, 5000);
        exports._g2 = guard;
        var afd = fs.openSync(path, fs.constants.O_RDONLY);
        fs.read(afd, { buffer: Buffer.alloc(17), length: 17, position: last.at }, function (err, n, buf) {
            if (settled) { return; }
            var s = err ? null : buf.slice(0, n).toString();
            check(S, s == last.text, 'async fs.read at ' + last.at + ' returned "' + s + '" (err=' + err + ')');
            fs.closeSync(afd);
            streamAt(0);
        });

        // createReadStream with start and end past 2 GB, one marker at a time. The flow only starts
        // after resume(), because attaching a 'data' listener alone does not start it here.
        function streamAt(i) {
            if (settled) { return; }
            if (i >= marks.length) {
                settled = true;
                try { clearTimeout(guard); } catch (e) { }
                cleanup();
                bigFileCheck();
                return;
            }
            var m = marks[i], got = '';
            var rs = fs.createReadStream(path, { flags: 'rb', start: m.at, end: m.at + m.text.length - 1 });
            rs.on('data', function (d) { got += d.toString(); });
            rs.on('end', function () {
                check(S, got == m.text, 'createReadStream start=' + m.at + ' returned "' + got + '" (expected "' + m.text + '")');
                streamAt(i + 1);
            });
            rs.resume();
        }

        // readFileSync() on a file Duktape cannot hold: it must throw, not take the agent down.
        // 2 GB + 1 byte is past Duktape's buffer ceiling on every build, so nothing is allocated:
        // the read is refused before the buffer exists.
        function bigFileCheck() {
            try {
                var bfd = fs.openSync(big, 'wb');
                fs.writeSync(bfd, Buffer.from('Z'), 0, 1, TWO);
                fs.closeSync(bfd);

                // The size has to survive as an exact number, not a float or a wrapped 32-bit value.
                // On a 32-bit build this is what -D_FILE_OFFSET_BITS=64 buys: without it stat() fills
                // in a 32-bit st_size and 2147483649 comes back as something else entirely.
                var bigSize = fs.statSync(big).size;
                check(S, bigSize === TWO + 1, 'statSync() of the 2 GB + 1 byte file reported ' + bigSize + ' (expected ' + (TWO + 1) + ')');

                var threw = null, back2 = null;
                try { back2 = fs.readFileSync(big); } catch (e) { threw = e; }
                check(S, threw != null, 'readFileSync() of a ' + bigSize + ' byte file returned ' + (back2 ? back2.length + ' bytes' : back2) + ' instead of throwing');
                // The agent's own size check has to be the one that fires, on every word size. If
                // duktape's allocator refuses the buffer first the message is a bare
                // "RangeError: buffer too long", which does not say which file was too big.
                var emsg = threw == null ? '' : ('' + (threw.message ? threw.message : threw));
                check(S, emsg.indexOf('too large to read into memory') >= 0, 'readFileSync() past 2 GB threw "' + emsg + '", expected the agent\'s own "too large to read into memory"');
                check(S, emsg.indexOf(big) >= 0, 'readFileSync() error "' + emsg + '" does not name the file it refused');

                // The refusal unwinds through duk_safe_call, so the engine has to come out usable.
                var stillOk = null;
                try { stillOk = fs.readFileSync(scratch('rfs-small.bin')).length; } catch (e) { }
                check(S, stillOk === 64, 'a normal readFileSync() after the refused one gave ' + stillOk + ' (expected 64), so the throw left the engine unusable');

                // Every refused readFileSync() must close its FILE* on the way out. Before the
                // duk_safe_call rework the throw jumped straight past fclose(), so the descriptors
                // piled up one per call. 20 attempts makes a leak obvious against normal churn.
                if (isLinux) {
                    var before = fs.readdirSync('/proc/self/fd').length;
                    for (var li = 0; li < 20; ++li) { try { fs.readFileSync(big); } catch (e) { } }
                    var after = fs.readdirSync('/proc/self/fd').length;
                    check(S, after <= before + 2, '20 refused readFileSync() calls took the open descriptor count from ' + before + ' to ' + after + ', so the refused path leaks its FILE*');
                }

                // The bytes read from past 2 GB have to survive the trip into OpenSSL. The agent is
                // built with -D_FILE_OFFSET_BITS=64 and the vendored OpenSSL archive is not, so this
                // is the one place where a 64-bit file offset and that library meet in one call.
                var zfd = fs.openSync(big, 'rb');
                var zb = Buffer.alloc(1);
                var zn = fs.readSync(zfd, zb, { position: TWO, length: 1 });
                fs.closeSync(zfd);
                var sha = require('SHA256Stream');
                var gotHash = zn == 1 ? sha.create().syncHash(zb.slice(0, 1)).toString('hex') : null;
                var wantHash = sha.create().syncHash(Buffer.from('Z')).toString('hex');
                check(S, gotHash == wantHash, 'SHA256 of the byte read at offset ' + TWO + ' is ' + gotHash + ' (expected ' + wantHash + ', read ' + zn + ' byte(s))');
            } catch (e) { check(S, false, 'sparse file setup for the >2 GB readFileSync() check threw: ' + e); }
            try { fs.unlinkSync(big); } catch (e) { }
            done();
        }
    }
};
