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
// Datastore: ILibSimpleDataStore Put, PutCompressed, Get, Delete, Compact and Keys, deliberately
// using key lengths that collide under ILibHashtable_DefaultHashFunc.
//

exports.name = 'Datastore';
exports.run = function (check, deepEqual, done, scratch) {
    var fs = require('fs');
    var dbPath = scratch('datastore.db');
    try { if (fs.existsSync(dbPath)) { fs.unlinkSync(dbPath); } } catch (e) { }

    var db = require('SimpleDataStore').Create(dbPath);
    check('Datastore', db != null, 'SimpleDataStore.Create() returned null');
    if (db == null) { done(); return; }

    var NKEYS = 60;

    function S(x) {
        if (x == null) { return null; }
        var str = x.toString();
        var e = str.length;
        while (e > 0 && str.charCodeAt(e - 1) == 0) { --e; }
        return str.substring(0, e);
    }
    // Key lengths sweep 4 to 16 chars, deliberately covering the 5 to 12 range where
    // ILibHashtable_DefaultHashFunc only hashes the last 4 bytes.
    function keyOf(i) { var pad = ''; for (var p = 0; p < (i % 13); ++p) { pad += 'x'; } return 'sk' + i + '_' + pad; }
    function valOf(i) {
        var unit = keyOf(i) + ':v;';
        var target = (i < 3) ? 4000 : (1 + ((i * 37) % 900));
        var v = '';
        while (v.length < target) { v += unit; }
        return v.substring(0, target);
    }
    function isCompressed(i) { return (i % 3) == 0; }
    function isDeleted(i) { return (i % 11) == 3; } // A rotating subset of the keys.

    for (var i = 0; i < NKEYS; ++i) {
        if (isCompressed(i)) { db.PutCompressed(keyOf(i), valOf(i)); } else { db.Put(keyOf(i), valOf(i)); }
    }

    var mismatch = 0;
    for (var i = 0; i < NKEYS; ++i) { if (S(db.Get(keyOf(i))) != valOf(i)) { mismatch++; } }
    check('Datastore', mismatch == 0, mismatch + '/' + NKEYS + ' keys had the wrong value on immediate read-back');

    for (var i = 0; i < NKEYS; ++i) { if (isDeleted(i)) { db.Delete(keyOf(i)); } }

    var wrongState = 0;
    for (var i = 0; i < NKEYS; ++i) {
        var got = S(db.Get(keyOf(i)));
        if (isDeleted(i)) { if (got != null && got.length > 0) { wrongState++; } }
        else { if (got != valOf(i)) { wrongState++; } }
    }
    check('Datastore', wrongState == 0, wrongState + ' keys in the wrong state after Delete() - matches the ' +
        'known ILibHashtable collision-chain-delete bug if it reproduces');

    var dsKeys = db.Keys;
    var present = {};
    for (var ki = 0; ki < dsKeys.length; ++ki) { present[dsKeys[ki]] = 1; }
    var missingFromEnum = 0;
    for (var i = 0; i < NKEYS; ++i) { if (!isDeleted(i) && !present[keyOf(i)]) { missingFromEnum++; } }
    check('Datastore', missingFromEnum == 0, missingFromEnum + ' live keys missing from the Keys enumeration');

    check('Datastore', db.Compact() == 0, 'Compact() returned a non-zero error code');

    var postCompactMismatch = 0;
    for (var i = 0; i < NKEYS; ++i) {
        if (isDeleted(i)) { continue; }
        if (S(db.Get(keyOf(i))) != valOf(i)) { postCompactMismatch++; }
    }
    check('Datastore', postCompactMismatch == 0, postCompactMismatch + ' keys wrong after Compact()');

    done();
};
