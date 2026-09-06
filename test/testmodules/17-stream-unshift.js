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
// stream.unshift() on a file read stream. A consumer that hands bytes back must see them again,
// so the bytes a 'data' handler unshifts have to survive until the next read instead of being
// dropped, and the whole file must still arrive exactly once and in order.
// The partial-unshift section is opt-in via --unshift-test, because a build without the read-loop
// fix redelivers the same bytes forever there and never returns. See the note above section 3.
//

exports.name = 'Stream Unshift';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'Unshift';
    var fs = require('fs');

    // The read stream's buffer is FS_READSTREAM_BUFFERSIZE (4096) in ILibDuktape_fs.c. A file
    // larger than that spans several reads, one smaller than it is delivered as a single chunk.
    var BUFSIZE = 4096;

    // Deterministic content, so a mismatch says which byte went missing rather than just "differs".
    function content(size) {
        var s = '';
        for (var i = 0; s.length < size; ++i) { s += ('' + i) + '.'; }
        return (s.slice(0, size));
    }

    var big = content(10000), small = content(1000);
    var bigPath = scratch('unshift-big.bin'), smallPath = scratch('unshift-small.bin');
    function cleanup() {
        try { fs.unlinkSync(bigPath); } catch (e) { }
        try { fs.unlinkSync(smallPath); } catch (e) { }
    }
    try {
        fs.writeFileSync(bigPath, Buffer.from(big));
        fs.writeFileSync(smallPath, Buffer.from(small));
    } catch (e) { check(S, false, 'writing the scratch files threw: ' + e); done(); return; }

    var optIn = false;
    var av = process.argv || [];
    for (var ai = 0; ai < av.length; ++ai) { if (('' + av[ai]) == '--unshift-test') { optIn = true; } }

    var settled = false;
    var guard = setTimeout(function () {
        if (settled) { return; }
        settled = true;
        check(S, false, 'the unshift sections never finished');
        cleanup(); done();
    }, 10000);
    exports._g = guard;

    function finish() {
        if (settled) { return; }
        settled = true;
        try { clearTimeout(guard); } catch (e) { }
        cleanup(); done();
    }

    // --- 1: a plain read with no unshift at all, so the read loop itself stays honest ---------
    function plainRead(next) {
        var got = '';
        var rs = fs.createReadStream(bigPath, { flags: 'rb' });
        rs.on('data', function (d) { got += d.toString(); });
        rs.on('end', function () {
            check(S, got.length == big.length, 'plain read returned ' + got.length + ' bytes (expected ' + big.length + ')');
            check(S, got == big, 'plain read did not return the file byte for byte');
            next();
        });
        rs.resume();
    }

    // --- 2: unshift a whole chunk once, then accept it ---------------------------------------
    // The file is smaller than one buffer, so it arrives as a single chunk. Handing all of it back
    // must not throw it away: it has to come round again. A build that drops it delivers 0 bytes.
    function unshiftWholeChunk(next) {
        var got = '', deliveries = 0, gaveBack = false;
        var rs = fs.createReadStream(smallPath, { flags: 'rb' });
        rs.on('data', function (d) {
            ++deliveries;
            if (!gaveBack) { gaveBack = true; rs.unshift(d); return; }
            got += d.toString();
        });
        rs.on('end', function () {
            check(S, gaveBack, 'the whole-chunk section never got a chunk to unshift');
            check(S, deliveries >= 2, 'a chunk that was unshifted whole was never redelivered (' + deliveries + ' deliveries)');
            check(S, got == small, 'after unshifting a whole chunk the file came back as ' + got.length + ' of ' + small.length + ' bytes');
            next();
        });
        rs.resume();
    }

    // --- 3: partial unshift, the record-framing case (opt-in) --------------------------------
    // A consumer that only takes whole records and hands the trailing partial record back. This is
    // what unshift() exists for. It is gated because on a build whose read loop never clears its
    // unshift count between deliveries the same bytes are redelivered forever and the agent hangs
    // here, which would wedge the whole run rather than fail one check.
    function partialUnshift(next) {
        if (!optIn) {
            console.log('NOTE: [' + S + '] partial-unshift section skipped, pass --unshift-test to run it');
            next();
            return;
        }
        var REC = 100;
        var got = '', deliveries = 0;
        var rs = fs.createReadStream(bigPath, { flags: 'rb' });
        rs.on('data', function (d) {
            ++deliveries;
            if (deliveries > 200) { return; }               // the guard timer reports it, do not spin harder
            var whole = Math.floor(d.length / REC) * REC;
            // A zero length buffer's toString() returns null here rather than an empty string, and
            // concatenating that appends the four characters "null", so skip the empty take entirely.
            if (whole > 0) { got += d.slice(0, whole).toString(); }
            if (whole < d.length) { rs.unshift(d.slice(whole)); }
        });
        rs.on('end', function () {
            check(S, got.length == big.length, 'record-framed read returned ' + got.length + ' bytes (expected ' + big.length + ')');
            check(S, got == big, 'record-framed read did not reassemble the file byte for byte');
            next();
        });
        rs.resume();
    }

    plainRead(function () { unshiftWholeChunk(function () { partialUnshift(finish); }); });
};
