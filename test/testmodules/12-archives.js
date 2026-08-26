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
// Archives: a zip-writer to zip-reader round-trip checking the file list, per-entry CRC and content.
// Pure JS over the native compressed-stream, as used by file transfer and the installer.
// tar-encoder is a server-pushed module and not embedded in the agent, so it is not tested here.
//

exports.name = 'Archives';
exports.run = function (check, deepEqual, done) {
    var S = 'Archives';
    var fs = require('fs');
    var dir = 'meshagent-stresstest-archive';
    var zipPath = dir + '.zip';
    // No 0-byte member, because zip-writer silently omits empty files. That is upstream behaviour and not tested.
    var files = [
        { name: 'a.txt', data: Buffer.from('alpha file contents\n') },
        { name: 'b.bin', data: require('EncryptionStream').GenerateRandom(70000) },
        { name: 'c.txt', data: Buffer.from(new Array(3001).join('0123456789')) }
    ];

    function cleanup() {
        for (var i = 0; i < files.length; ++i) { try { fs.unlinkSync(dir + '/' + files[i].name); } catch (e) { } }
        try { fs.rmdirSync(dir); } catch (e) { }
        try { fs.unlinkSync(zipPath); } catch (e) { }
    }
    cleanup();
    fs.mkdirSync(dir);
    var paths = [];
    for (var i = 0; i < files.length; ++i) {
        var fd = fs.openSync(dir + '/' + files[i].name, 'wb');
        if (files[i].data.length > 0) { fs.writeSync(fd, files[i].data); }
        fs.closeSync(fd);
        paths.push(dir + '/' + files[i].name);
    }

    var finished = false;
    var guard = setTimeout(function () { if (!finished) { check(S, false, 'archive section timed out'); finished = true; cleanup(); done(); } }, 10000);
    exports._g = guard;
    function finish() { if (finished) { return; } finished = true; try { clearTimeout(guard); } catch (e) { } cleanup(); done(); }

    // --- zip: write, then read back ---
    var zw = require('zip-writer').write({ files: paths, basePath: dir });
    var out = fs.createWriteStream(zipPath, { flags: 'wb' });
    out.on('finish', function () {
        check(S, fs.statSync(zipPath).size > 0, 'zip-writer produced an empty file');
        require('zip-reader').read(zipPath).then(function (zip) {
            var names = zip.files;
            check(S, names.length == files.length, 'zip lists ' + names.length + ' entries (expected ' + files.length + '): ' + JSON.stringify(names));
            // Entries are read one at a time, because parallel getStream() calls on one zip stall.
            // 'data' chunks are reused by the stream, so each one is copied before it is kept.
            var fi = 0;
            function nextEntry() {
                if (fi >= files.length) { try { zip.close(); } catch (e) { } finish(); return; }
                var f = files[fi++], entry = null;
                for (var n = 0; n < names.length; ++n) { if (names[n] == f.name || names[n].slice(-f.name.length) == f.name) { entry = names[n]; } }
                if (entry == null) { check(S, false, f.name + ' missing from the zip'); nextEntry(); return; }
                check(S, zip.crc(entry) == crc32(f.data), f.name + ': stored CRC ' + zip.crc(entry).toString(16) + ' != crc32(content) ' + crc32(f.data).toString(16));
                var acc = [];
                var rs = zip.getStream(entry);
                rs.on('data', function (d) { var c = Buffer.alloc(d.length); d.copy(c); acc.push(c); });
                rs.on('end', function () {
                    var got = Buffer.concat(acc);
                    check(S, got.toString('hex') == f.data.toString('hex'), f.name + ': ' + got.length + ' bytes read back (expected ' + f.data.length + ', ' + acc.length + ' chunks)');
                    nextEntry();
                });
                rs.resume();
            }
            nextEntry();
        }, function (err) { check(S, false, 'zip-reader rejected: ' + err); finish(); });
    });
    zw.pipe(out);

};
