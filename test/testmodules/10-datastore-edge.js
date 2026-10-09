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
// Datastore edge cases: every key length 1..17, reopen-after-close persistence, overwrite, missing
// keys, a 1 MB value, and GetBuffer versus Get. The CRC32 path in ILibSimpleDataStore.c does unaligned
// uint32_t reads whenever a key length is not a multiple of 4, a SIGBUS on strict-alignment hardware.
//

exports.name = 'Datastore Edge Cases';
exports.run = function (check, deepEqual, done, scratch) {
    var S = 'DatastoreEdge';
    var fs = require('fs');
    var dbPath = scratch('datastore-edge.db');
    try { if (fs.existsSync(dbPath)) { fs.unlinkSync(dbPath); } } catch (e) { }

    function T(x) {   // Trims the trailing NULs the store pads with.
        if (x == null) { return null; }
        var s = x.toString(), e = s.length;
        while (e > 0 && s.charCodeAt(e - 1) == 0) { --e; }
        return s.substring(0, e);
    }

    var db = require('SimpleDataStore').Create(dbPath);
    check(S, db != null, 'Create() returned null');
    if (db == null) { done(); return; }

    // --- every key length 1..17 ---
    var badLen = [];
    for (var len = 1; len <= 17; ++len) {
        var key = ''; while (key.length < len) { key += String.fromCharCode(97 + (key.length % 26)); }
        db.Put(key, 'v' + len);
        if (T(db.Get(key)) != 'v' + len) { badLen.push(len); }
    }
    check(S, badLen.length == 0, 'key lengths with a wrong read-back: ' + JSON.stringify(badLen) + ' (non-multiple-of-4 lengths are the unaligned CRC32 path)');

    // --- missing key and overwrite ---
    var miss = db.Get('never-put');
    check(S, miss == null || T(miss) == '', 'Get() of a never-stored key returned "' + T(miss) + '"');
    db.Put('ow', 'first'); db.Put('ow', 'second-longer-value'); db.Put('ow', 'x');
    check(S, T(db.Get('ow')) == 'x', 'overwrite sequence read back "' + T(db.Get('ow')) + '" (expected x)');

    // --- 1 MB value ---
    var big = Buffer.alloc(1024 * 1024);
    for (var i = 0; i < big.length; ++i) { big.writeUInt8((i * 31) & 0xFF, i); }
    db.Put('big', big);
    var gb = db.GetBuffer('big');
    check(S, gb != null && gb.length == big.length && gb.toString('hex') == big.toString('hex'), '1 MB value did not round-trip (' + (gb ? gb.length : 'null') + ' bytes)');

    // --- Delete then Keys ---
    db.Delete('ow');
    var keys = db.Keys, hasOw = false, hasBig = false;
    for (var k = 0; k < keys.length; ++k) { if (keys[k] == 'ow') { hasOw = true; } if (keys[k] == 'big') { hasBig = true; } }
    check(S, !hasOw && hasBig, 'Keys after Delete: ow=' + hasOw + ' big=' + hasBig + ' (expected false/true)');

    // --- reopen: everything survives a close followed by Create() on the same file ---
    db = null;
    try { _debugGC(); } catch (e) { }
    var db2 = require('SimpleDataStore').Create(dbPath);
    check(S, db2 != null, 'reopen Create() returned null');
    if (db2 != null) {
        var lost = [];
        for (var len2 = 1; len2 <= 17; ++len2) {
            var key2 = ''; while (key2.length < len2) { key2 += String.fromCharCode(97 + (key2.length % 26)); }
            if (T(db2.Get(key2)) != 'v' + len2) { lost.push(len2); }
        }
        check(S, lost.length == 0, 'key lengths lost across reopen: ' + JSON.stringify(lost));
        var gb2 = db2.GetBuffer('big');
        check(S, gb2 != null && gb2.length == big.length, '1 MB value lost across reopen');
        var ow2 = db2.Get('ow');
        check(S, ow2 == null || T(ow2) == '', 'deleted key came back after reopen');
        check(S, db2.Compact() == 0, 'Compact() after reopen failed');
    }
    db2 = null;
    try { _debugGC(); } catch (e) { }
    try { fs.unlinkSync(dbPath); } catch (e) { }

    done();
};
