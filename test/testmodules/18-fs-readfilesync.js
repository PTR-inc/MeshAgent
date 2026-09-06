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
// fs.readFileSync() and the 64-bit fs option parsing, on small files. The large-file positions
// themselves are in 15-fs-large-file.js; this section covers what changed around them:
//   - readFileSync() returns the bytes actually read, on a regular file and on an empty one.
//   - readFileSync() on a source with no usable length (a FIFO, /proc) goes through the growing
//     buffer: exact 4096 boundary, several growth steps, and zero bytes.
//   - {position: "5"} is accepted as a number, {position: "abc"} means "not given" (continue at the
//     current offset) instead of 0, and a position past 2^32 on a small file reads nothing and does
//     not throw.
//   - With --fs-test: readFileSync() on a >2 GB sparse file throws a JS error and the process
//     carries on, instead of taking the agent down.
//

exports.name = 'ReadFileSync';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'ReadFileSync';
    var fs = require('fs');
    var cp = require('child_process');
    var isWin = process.platform == 'win32';
    var isLinux = process.platform == 'linux';

    var HEX = '0123456789ABCDEF';
    var pattern = HEX + HEX + HEX + HEX;                                    // 64 bytes, byte at offset p is HEX[p % 16]
    var small = scratch('rfs-small.bin');
    var empty = scratch('rfs-empty.bin');
    fs.writeFileSync(small, pattern);
    fs.writeFileSync(empty, '');

    // --- regular file: exact bytes, exact length ---
    var b1 = fs.readFileSync(small);
    check(S, b1.length == 64 && b1.toString() == pattern, 'readFileSync() of a 64 byte file gave ' + b1.length + ' bytes');
    var b2 = fs.readFileSync(empty);
    check(S, b2.length == 0, 'readFileSync() of an empty file gave length ' + b2.length);

    // --- sources without a usable length: the growing buffer ---
    if (isLinux) {
        var st = fs.readFileSync('/proc/self/status').toString();
        check(S, st.length > 0 && st.indexOf('Name:') >= 0, 'readFileSync(/proc/self/status) gave ' + st.length + ' bytes without a Name: line');
    }
    if (!isWin) {
        // A FIFO reports no length, so readFileSync() reads it until EOF through the growing buffer.
        // tee writes the reference copy before each FIFO write, so it is complete when the FIFO hits EOF.
        var fifo = scratch('rfs-fifo');
        var ref = scratch('rfs-fifo-ref.bin');
        var mk = cp.execFile('/bin/sh', ['sh', '-c', 'mkfifo "' + fifo + '"']);
        mk.waitExit();
        var sizes = [4096, 100000, 4097, 0];
        for (var si = 0; si < sizes.length; ++si) {
            var n = sizes[si];
            var writer = cp.execFile('/bin/sh', ['sh', '-c', 'head -c ' + n + ' /dev/urandom | tee "' + ref + '" > "' + fifo + '"']);
            var got = null, err = null;
            try { got = fs.readFileSync(fifo); } catch (e) { err = e; }
            writer.waitExit();
            if (err != null) { check(S, false, 'readFileSync() of a ' + n + ' byte FIFO threw: ' + err); continue; }
            var want = fs.readFileSync(ref);
            var same = (got.length == n && want.length == n);
            for (var i = 0; same && i < n; ++i) { if (got[i] != want[i]) { same = false; } }
            check(S, same, 'readFileSync() of a ' + n + ' byte FIFO gave ' + got.length + ' bytes' + (got.length == n ? ' with wrong content' : ''));
        }
        try { fs.unlinkSync(fifo); } catch (e) { }
        try { fs.unlinkSync(ref); } catch (e) { }
    }

    // --- option coercion on readSync ---
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

    // --- async fs.read with a string position, then createReadStream with string start/end ---
    var settled = false;
    var guard = setTimeout(function () { if (!settled) { settled = true; check(S, false, 'async fs.read or createReadStream never finished'); done(); } }, 5000);
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
            bigFile();
        });
        rs.resume();
    });

    // --- readFileSync on a file Duktape cannot hold: must throw, not exit ---
    function bigFile() {
        if (settled) { return; }
        var enabled = false;
        var av = process.argv || [];
        for (var ai = 0; ai < av.length; ++ai) { if (('' + av[ai]) == '--fs-test') { enabled = true; } }
        if (enabled && !isWin) {
            // 2 GB + 1 byte, sparse. That is past Duktape's buffer ceiling on every build, so nothing
            // is allocated: the read is refused before the buffer exists, and the agent must stay up.
            var big = scratch('rfs-big.bin');
            try {
                var wfd = fs.openSync(big, 'wb');
                fs.writeSync(wfd, Buffer.from('Z'), 0, 1, 2147483648);
                fs.closeSync(wfd);
                var threw = null, back = null;
                try { back = fs.readFileSync(big); } catch (e) { threw = e; }
                check(S, threw != null, 'readFileSync() of a ' + fs.statSync(big).size + ' byte file returned ' + (back ? back.length + ' bytes' : back) + ' instead of throwing');
                if (threw != null) { console.log('NOTE: [' + S + '] readFileSync() past 2 GB threw: ' + threw); }
            } catch (e) { check(S, false, 'sparse file setup threw: ' + e); }
            try { fs.unlinkSync(big); } catch (e) { }
        } else {
            console.log('NOTE: [' + S + '] the >2 GB readFileSync() check is skipped, pass --fs-test to run it');
        }
        settled = true;
        try { clearTimeout(guard); } catch (e) { }
        done();
    }
};
