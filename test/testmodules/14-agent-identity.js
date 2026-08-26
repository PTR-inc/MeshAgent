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
// Agent identity: the embedded pieces the server relies on to know which agent this is. A streamed
// SHA384 of the running binary, which is what the update path hashes, must be stable across runs and
// change for a one-byte-different copy. _agentNodeId() must yield the node id once <agent>.db has a SelfNodeCert.
//

exports.name = 'Agent Identity';
exports.run = function (check, deepEqual, done) {
    var S = 'Identity';
    var fs = require('fs');
    var sha = require('SHA384Stream');

    var settled = false;
    var guard = setTimeout(function () { if (!settled) { settled = true; check(S, false, 'identity section timed out'); done(); } }, 20000);
    exports._g = guard;
    function finish() { if (settled) { return; } settled = true; try { clearTimeout(guard); } catch (e) { } done(); }

    function hashOf(path, cb) {
        var h = sha.create();
        h.on('hash', function (buf) { cb(buf.toString('hex')); });
        var rs = fs.createReadStream(path, { flags: 'rb' });
        rs.pipe(h);
        rs.resume();
    }

    var size = fs.statSync(process.execPath).size;
    check(S, size > 0, 'process.execPath (' + process.execPath + ') has size ' + size);

    hashOf(process.execPath, function (h1) {
        check(S, h1 != null && h1.length == 96, 'streamed SHA384 of the running agent is ' + (h1 ? h1.length : 'null') + ' hex chars (expected 96)');
        hashOf(process.execPath, function (h2) {
            check(S, h1 == h2, 'SHA384 of the same binary differed across two streamed runs');
            var oneShot = sha.create().syncHash(fs.readFileSync(process.execPath)).toString('hex');
            check(S, h1 == oneShot, 'streamed SHA384 of the binary != syncHash() of the whole file');

            var copy = 'meshagent-stresstest-identity.bin';
            try {
                var src = fs.readFileSync(process.execPath);
                var pos = Math.floor(src.length / 3);
                src.writeUInt8(src.readUInt8(pos) ^ 0x5A, pos);
                fs.writeFileSync(copy, src);
            } catch (e) { check(S, false, 'could not write a modified copy: ' + e); finish(); return; }
            hashOf(copy, function (h3) {
                try { fs.unlinkSync(copy); } catch (e) { }
                check(S, h3 != null && h3 != h1, 'a one-byte change in the binary did not change its hash');
                nodeId();
            });
        });
    });

    function nodeId() {
        var id = null;
        try { id = require('_agentNodeId')(); } catch (e) { check(S, false, '_agentNodeId() threw: ' + e); finish(); return; }
        check(S, typeof id == 'string', '_agentNodeId() returned ' + typeof id);
        check(S, id == '' || /^[0-9a-f]{96}$/i.test(id), '_agentNodeId() "' + id + '" is neither empty nor a 96-char hex hash');
        if (id != '') {
            // With a .db present the id must be derived from SelfNodeCert, so read it back the same way.
            try {
                var db = require('SimpleDataStore').Create(process.execPath + '.db', { readOnly: true });
                var pfx = db.GetBuffer('SelfNodeCert');
                check(S, pfx != null && pfx.length > 0, 'node id is set but SelfNodeCert is missing from ' + process.execPath + '.db');
            } catch (e) { check(S, false, 'could not read SelfNodeCert back: ' + e); }
        }
        finish();
    }
};
