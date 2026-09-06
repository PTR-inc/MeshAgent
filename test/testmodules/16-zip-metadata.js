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
// Zip metadata: what zip-writer records beyond the bytes and what zip-reader gives back. Directory
// entries (empty directories survive), Unix modes, the extended timestamp extra field, the archive
// comment, the store option, info() and extractAll(), plus the reader rejecting a zip-slip entry,
// a truncated file and random bytes. 12-archives.js already covers the plain content round trip.
//

exports.name = 'Zip metadata';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'ZipMeta';
    var fs = require('fs');
    var posix = process.platform != 'win32';
    var root = scratch('zipmeta');
    var src = root + '/src', dst = root + '/dst', dstStore = root + '/dst-store';
    var zipDefault = root + '/default.zip', zipStore = root + '/store.zip';
    var comment = 'stress test comment';
    var bData = require('EncryptionStream').GenerateRandom(3000);
    var aData = Buffer.from('alpha file contents\n');

    function rmTree(p) {
        var st = null;
        try { st = fs.statSync(p); } catch (e) { return; }
        if (st.isDirectory()) {
            var entries = [];
            try { entries = fs.readdirSync(p); } catch (e) { }
            for (var i = 0; i < entries.length; ++i) {
                var e = '' + entries[i];
                if (e != '.' && e != '..') { rmTree(p + '/' + e); }
            }
            try { fs.rmdirSync(p); } catch (e) { }
        }
        else { try { fs.unlinkSync(p); } catch (e) { } }
    }
    function writeFile(p, data) { var fd = fs.openSync(p, 'wb'); if (data.length > 0) { fs.writeSync(fd, data); } fs.closeSync(fd); }
    function readFile(p) { try { return (fs.readFileSync(p)); } catch (e) { return (null); } }
    function sameBytes(p, data) { var b = readFile(p); return (b != null && b.toString('hex') == data.toString('hex')); }
    function modeOf(p) { try { return (fs.statSync(p).mode & 511); } catch (e) { return (-1); } }
    function isDir(p) { try { return (fs.statSync(p).isDirectory()); } catch (e) { return (false); } }

    rmTree(root);
    fs.mkdirSync(root);
    fs.mkdirSync(src);
    fs.mkdirSync(src + '/sub');
    fs.mkdirSync(src + '/emptydir');
    writeFile(src + '/a.txt', aData);
    writeFile(src + '/empty.txt', Buffer.alloc(0));
    writeFile(src + '/sub/b.bin', bData);
    if (posix) {
        fs.chmodSync(src + '/a.txt', 493);
        fs.chmodSync(src + '/sub/b.bin', 384);
    }
    var aStatMtime = Date.parse(fs.statSync(src + '/a.txt').mtime);

    var finished = false;
    var guard = setTimeout(function () { if (!finished) { check(S, false, 'zip metadata section timed out'); finished = true; rmTree(root); done(); } }, 15000);
    exports._g = guard;
    function finish() { if (finished) { return; } finished = true; try { clearTimeout(guard); } catch (e) { } rmTree(root); done(); }

    function writeZip(path, options, next) {
        var zw = null;
        try { zw = require('zip-writer').write(options); }
        catch (e) { check(S, false, 'zip-writer.write() threw: ' + e); finish(); return; }
        var out = fs.createWriteStream(path, { flags: 'wb' });
        out.on('finish', function () { next(); });
        zw.pipe(out);
    }

    writeZip(zipDefault, { files: [src], comment: comment }, function () {
        // A writer without the comment or extra field support leaves the offsets pointing anywhere.
        try { checkRawLayout(); } catch (e) { check(S, false, 'raw layout check threw: ' + e); }
        writeZip(zipStore, { files: [src], store: true }, function () { readDefault(); });
    });

    // Looks at the bytes directly, so the writer is checked without trusting the reader.
    function checkRawLayout() {
        var z = readFile(zipDefault);
        if (z == null || z.length < 22) { check(S, false, 'default zip is missing or shorter than one end record'); return; }
        var eocdr = z.length - 22 - comment.length;
        check(S, z.readUInt32LE(eocdr) == 0x06054b50 && z.readUInt16LE(eocdr + 20) == comment.length && z.slice(eocdr + 22).toString() == comment,
            'end of central directory record does not carry the ' + comment.length + ' byte comment');
        check(S, z.readUInt32LE(0) == 0x04034b50, 'zip does not start with a local file header');
        // Every file entry must carry the extended timestamp extra field in the central directory.
        var cd = z.readUInt32LE(eocdr + 16), missing = [];
        for (var n = 0; n < z.readUInt16LE(eocdr + 10) && cd + 46 <= eocdr; ++n) {
            var nameLen = z.readUInt16LE(cd + 28), extraLen = z.readUInt16LE(cd + 30), commentLen = z.readUInt16LE(cd + 32);
            var name = z.slice(cd + 46, cd + 46 + nameLen).toString();
            var ex = cd + 46 + nameLen, end = ex + extraLen, hasUT = false;
            while (ex + 4 <= end) {
                if (z.readUInt16LE(ex) == 0x5455) { hasUT = true; }
                ex += 4 + z.readUInt16LE(ex + 2);
            }
            if (!hasUT && name.slice(-1) != '/') { missing.push(name); }
            cd += 46 + nameLen + extraLen + commentLen;
        }
        check(S, missing.length == 0, 'entries without an extended timestamp extra field: ' + JSON.stringify(missing));
        var madeBy = z.readUInt16LE(z.readUInt32LE(eocdr + 16) + 4) >>> 8;
        check(S, madeBy == (posix ? 3 : 0), 'central directory version-made-by host is ' + madeBy + ' (expected ' + (posix ? 3 : 0) + ')');
    }

    function readDefault() {
        require('zip-reader').read(zipDefault).then(function (zip) {
            if (typeof zip.info != 'function' || zip.directories == null) {
                check(S, false, 'zip-reader has no info() or directories, so the metadata checks cannot run');
                try { zip.close(); } catch (x) { }
                finish();
                return;
            }
            var names = zip.files.slice().sort();
            check(S, deepEqual(names, ['a.txt', 'empty.txt', 'sub/b.bin']), 'files are ' + JSON.stringify(names));
            var dirs = zip.directories.slice().sort();
            check(S, deepEqual(dirs, ['emptydir/', 'sub/']), 'directories are ' + JSON.stringify(dirs));

            var a = zip.info('a.txt');
            check(S, a != null && a.size == aData.length && a.compression == 8, 'info(a.txt) is ' + JSON.stringify(a));
            check(S, a != null && a.crc == zip.crc('a.txt'), 'info(a.txt).crc differs from crc(a.txt)');
            var b = zip.info('sub/b.bin');
            check(S, b != null && b.size == bData.length && b.compressedSize > 0, 'info(sub/b.bin) is ' + JSON.stringify(b));
            var e = zip.info('empty.txt');
            check(S, e != null && e.size == 0, 'info(empty.txt) is ' + JSON.stringify(e));
            check(S, zip.info('nope.txt') == null, 'info() of an unknown name did not return null');
            if (a != null) {
                var mt = a.mtime instanceof Date ? a.mtime.getTime() : NaN;
                check(S, !isNaN(mt) && Math.abs(mt - aStatMtime) <= 2000, 'info(a.txt).mtime ' + (a.mtime ? a.mtime.toISOString() : a.mtime) + ' is not within 2 s of the source mtime ' + new Date(aStatMtime).toISOString());
                if (posix) {
                    check(S, (a.mode & 511) == 493, 'info(a.txt).mode is ' + (a.mode & 511).toString(8) + ' (expected 755)');
                    check(S, b != null && (b.mode & 511) == 384, 'info(sub/b.bin).mode is ' + (b ? (b.mode & 511).toString(8) : null) + ' (expected 600)');
                }
            }

            zip.extractAll(dst).then(function () {
                check(S, sameBytes(dst + '/a.txt', aData), 'extracted a.txt differs from the source');
                check(S, sameBytes(dst + '/sub/b.bin', bData), 'extracted sub/b.bin differs from the source');
                var emptyStat = null;
                try { emptyStat = fs.statSync(dst + '/empty.txt'); } catch (x) { }
                check(S, emptyStat != null && emptyStat.size == 0, 'empty.txt was not extracted as a 0-byte file');
                check(S, isDir(dst + '/emptydir'), 'the empty directory was not recreated');
                if (posix) {
                    check(S, modeOf(dst + '/a.txt') == 493, 'extracted a.txt has mode ' + modeOf(dst + '/a.txt').toString(8) + ' (expected 755)');
                    check(S, modeOf(dst + '/sub/b.bin') == 384, 'extracted sub/b.bin has mode ' + modeOf(dst + '/sub/b.bin').toString(8) + ' (expected 600)');
                }
                check(S, zip.info('a.txt') == null, 'info() after extractAll() closed the zip did not return null');
                readStore();
            }, function (err) { check(S, false, 'extractAll rejected: ' + err); finish(); });
        }, function (err) { check(S, false, 'zip-reader rejected the default zip: ' + err); finish(); });
    }

    function readStore() {
        require('zip-reader').read(zipStore).then(function (zip) {
            var b = zip.info('sub/b.bin');
            check(S, b != null && b.compression == 0 && b.compressedSize == bData.length, 'store option: info(sub/b.bin) is ' + JSON.stringify(b));
            zip.extractAll(dstStore).then(function () {
                check(S, sameBytes(dstStore + '/sub/b.bin', bData) && sameBytes(dstStore + '/a.txt', aData), 'stored entries did not extract byte for byte');
                rejects();
            }, function (err) { check(S, false, 'extractAll of the stored zip rejected: ' + err); finish(); });
        }, function (err) { check(S, false, 'zip-reader rejected the stored zip: ' + err); finish(); });
    }

    // A hand built archive with one stored entry named "../evil.txt", a 10 byte file and random bytes.
    function rejects() {
        var slip = root + '/slip.zip', tiny = root + '/tiny.bin', garbage = root + '/garbage.bin';
        writeFile(slip, buildStoredZip([{ name: 'ok.txt', data: Buffer.from('hello') }, { name: '../evil.txt', data: Buffer.from('pwned\n') }]));
        writeFile(tiny, Buffer.from('PK\x03\x04tiny'));
        writeFile(garbage, require('EncryptionStream').GenerateRandom(100));
        require('zip-reader').read(slip).then(function (zip) {
            zip.extractAll(root + '/slip-out').then(function () {
                check(S, false, 'an entry named ../evil.txt was extracted without complaint');
                badFiles();
            }, function (err) {
                check(S, ('' + err).indexOf('Unsafe path') >= 0, 'zip-slip entry rejected with an unexpected reason: ' + err);
                badFiles();
            });
        }, function (err) { check(S, false, 'zip-reader rejected the zip-slip archive before extraction: ' + err); badFiles(); });

        function badFiles() {
            require('zip-reader').read(tiny).then(function (zip) { check(S, false, 'a 10 byte file was accepted as a zip'); try { zip.close(); } catch (x) { } nextBad(); },
                function (err) { check(S, true, ''); nextBad(); });
            function nextBad() {
                require('zip-reader').read(garbage).then(function (zip) { check(S, false, '100 random bytes were accepted as a zip'); try { zip.close(); } catch (x) { } finish(); },
                    function (err) { check(S, true, ''); finish(); });
            }
        }
    }

    function buildStoredZip(entries) {
        var parts = [], central = [], offset = 0;
        for (var i = 0; i < entries.length; ++i) {
            var name = Buffer.from(entries[i].name), data = entries[i].data, crc = crc32(data);
            var lh = Buffer.alloc(30);
            lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0, 6); lh.writeUInt16LE(0, 8);
            lh.writeUInt16LE(0, 10); lh.writeUInt16LE(0x21, 12); lh.writeUInt32LE(crc, 14); lh.writeUInt32LE(data.length, 18);
            lh.writeUInt32LE(data.length, 22); lh.writeUInt16LE(name.length, 26); lh.writeUInt16LE(0, 28);
            var cd = Buffer.alloc(46);
            cd.writeUInt32LE(0x02014b50, 0); cd.writeUInt16LE(20, 4); cd.writeUInt16LE(20, 6); cd.writeUInt16LE(0, 8); cd.writeUInt16LE(0, 10);
            cd.writeUInt16LE(0, 12); cd.writeUInt16LE(0x21, 14); cd.writeUInt32LE(crc, 16); cd.writeUInt32LE(data.length, 20); cd.writeUInt32LE(data.length, 24);
            cd.writeUInt16LE(name.length, 28); cd.writeUInt16LE(0, 30); cd.writeUInt16LE(0, 32); cd.writeUInt16LE(0, 34); cd.writeUInt16LE(0, 36);
            cd.writeUInt32LE(0, 38); cd.writeUInt32LE(offset, 42);
            parts.push(lh, name, data);
            central.push(cd, name);
            offset += 30 + name.length + data.length;
        }
        var cdBuf = Buffer.concat(central);
        var eocdr = Buffer.alloc(22);
        eocdr.writeUInt32LE(0x06054b50, 0); eocdr.writeUInt16LE(0, 4); eocdr.writeUInt16LE(0, 6); eocdr.writeUInt16LE(entries.length, 8);
        eocdr.writeUInt16LE(entries.length, 10); eocdr.writeUInt32LE(cdBuf.length, 12); eocdr.writeUInt32LE(offset, 16); eocdr.writeUInt16LE(0, 20);
        parts.push(cdBuf, eocdr);
        return (Buffer.concat(parts));
    }

    var crcTable = null;
    function crc32(buf) {
        if (crcTable == null) {
            crcTable = [];
            for (var n = 0; n < 256; ++n) { var c = n; for (var k = 0; k < 8; ++k) { c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); } crcTable[n] = c >>> 0; }
        }
        var crc = 0xFFFFFFFF;
        for (var i = 0; i < buf.length; ++i) { crc = crcTable[(crc ^ buf[i]) & 0xFF] ^ (crc >>> 8); }
        return ((crc ^ 0xFFFFFFFF) >>> 0);
    }
};
