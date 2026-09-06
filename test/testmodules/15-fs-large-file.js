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
// Large files: fs positions past 2 GB. readSync, the async fs.read and writeSync must all honour a
// position above 2^31, because the file APIs carried a 32-bit int position and a fseek(long) for a
// long time, which silently read nothing past 2 GB. A sparse file keeps this cheap on disk, but the
// scratch directory still needs to support sparse files (some CI runners and network mounts do not),
// so this section is opt-in via --fs-test rather than part of the default run. argv is empty under
// -b64exec, so the flag has no effect there and the section stays skipped.
//

exports.name = 'Large files';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'LargeFile';
    var fs = require('fs');

    var enabled = false;
    var av = process.argv || [];
    for (var ai = 0; ai < av.length; ++ai) { if (('' + av[ai]) == '--fs-test') { enabled = true; } }
    if (!enabled) {
        console.log('NOTE: [' + S + '] skipped, pass --fs-test to run it');
        done();
        return;
    }

    if (process.platform == 'win32') {
        // NTFS zero-fills everything below the write offset unless the file is marked sparse first, so a
        // 2 GB scratch file is too expensive there. The Windows SetFilePointerEx path stays untested here.
        console.log('NOTE: [' + S + '] positions past 2 GB are not tested on Windows');
        done();
        return;
    }

    var path = scratch('large.bin');
    try { if (fs.existsSync(path)) { fs.unlinkSync(path); } } catch (e) { }
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
    exports._g = guard;
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
            done();
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
};
