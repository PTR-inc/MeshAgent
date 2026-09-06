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
// Streaming digests: the streamed result of every *Stream digest, from many odd-sized writes and
// the 'hash' event, must equal its one-shot syncHash(). Also crc32-stream and the native crc32
// against a known vector and across chunk boundaries.
//

exports.name = 'Streaming Digests';
exports.run = function (check, deepEqual, done) {
    var S = 'Digests';
    var enc = require('EncryptionStream');
    var payload = enc.GenerateRandom(100000);

    // odd-sized, boundary-crossing chunks
    function chunksOf(buf) {
        var out = [], off = 0, sizes = [1, 7, 63, 64, 65, 1000, 4097, 33333];
        var i = 0;
        while (off < buf.length) {
            var n = Math.min(sizes[i % sizes.length], buf.length - off);
            out.push(buf.slice(off, off + n)); off += n; i++;
        }
        return out;
    }
    var parts = chunksOf(payload);

    // --- crc32: known vector, and streamed must equal one-shot ---
    // crc32 is a global polyfill function from ILibDuktape_Polyfills.c, not a module.
    check(S, crc32(Buffer.from('123456789')) == 0xCBF43926, 'crc32("123456789") = ' + crc32(Buffer.from('123456789')).toString(16) + ' (expected cbf43926)');
    var cs = require('crc32-stream').create();
    for (var c = 0; c < parts.length; ++c) { cs.write(parts[c]); }
    cs.end();
    check(S, cs.value == crc32(payload), 'crc32-stream over ' + parts.length + ' chunks != crc32 one-shot');
    var running = 0;
    for (var c2 = 0; c2 < parts.length; ++c2) { running = crc32(parts[c2], running); }
    check(S, running == crc32(payload), 'chained crc32(chunk, prev) != one-shot');

    // --- *Stream digests: streamed versus syncHash ---
    var algos = ['SHA256Stream', 'SHA384Stream', 'SHA512Stream', 'SHA1Stream', 'MD5Stream'];
    var pending = algos.length;
    var guard = setTimeout(function () { check(S, false, 'streamed digests timed out (' + pending + ' still pending)'); pending = 0; done(); }, 8000);
    exports._g = guard;

    algos.forEach(function (name) {
        var mod = require(name);
        var oneShot = mod.create().syncHash(payload).toString('hex');
        var h = mod.create();
        h.on('hash', function (buf) {
            check(S, buf.toString('hex') == oneShot, name + ' streamed over ' + parts.length + ' chunks != syncHash()');
            if (--pending == 0) { try { clearTimeout(guard); } catch (e) { } done(); }
        });
        for (var p = 0; p < parts.length; ++p) { h.write(parts[p]); }
        h.end();
    });
};
