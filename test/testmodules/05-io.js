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
// IO - fs sync read/write/stat/exists/unlink, streaming read/write, and a child_process
// round-trip.
//

exports.name = 'IO';
exports.run = function (check, deepEqual, done) {
    var fs = require('fs');

    // --- sync read/write/stat/exists/unlink round-trip ---
    var binPath = 'meshagent-stresstest-io.bin';
    try { if (fs.existsSync(binPath)) { fs.unlinkSync(binPath); } } catch (e) { }

    var payload = Buffer.alloc(4096);
    for (var i = 0; i < payload.length; ++i) { payload.writeUInt8(i & 0xFF, i); }

    var fd = fs.openSync(binPath, 'wb');
    fs.writeSync(fd, payload);
    fs.closeSync(fd);

    check('IO', fs.existsSync(binPath), 'file did not exist after writeSync/closeSync');
    var st = fs.statSync(binPath);
    check('IO', st.size == payload.length, 'statSync() size mismatch (' + st.size + ' vs ' + payload.length + ')');

    var fd2 = fs.openSync(binPath, 'rb');
    var readBack = Buffer.alloc(payload.length);
    fs.readSync(fd2, readBack);
    fs.closeSync(fd2);
    check('IO', payload.toString('hex') == readBack.toString('hex'), 'readSync() content mismatch after a writeSync round-trip');

    fs.unlinkSync(binPath);
    check('IO', !fs.existsSync(binPath), 'unlinkSync() did not remove the file');

    // --- mkdir/rmdir + readdir sanity ---
    var dirPath = 'meshagent-stresstest-dir';
    try { if (fs.existsSync(dirPath)) { fs.rmdirSync(dirPath); } } catch (e) { }
    fs.mkdirSync(dirPath);
    check('IO', fs.existsSync(dirPath), 'mkdirSync() did not create the directory');
    var entries = fs.readdirSync('.');
    check('IO', Object.prototype.toString.call(entries) == '[object Array]' || entries.length >= 0, 'readdirSync() did not return an array-like result');
    fs.rmdirSync(dirPath);
    check('IO', !fs.existsSync(dirPath), 'rmdirSync() did not remove the directory');

    // --- streaming IO (async) ---
    var streamPath = 'meshagent-stresstest-stream.bin';
    try { if (fs.existsSync(streamPath)) { fs.unlinkSync(streamPath); } } catch (e) { }
    var streamPayload = Buffer.alloc(65536);
    for (var si = 0; si < streamPayload.length; ++si) { streamPayload.writeUInt8((si * 7) & 0xFF, si); }

    var ws = fs.createWriteStream(streamPath);
    ws.on('finish', function () {
        var chunks = '';
        var rs = fs.createReadStream(streamPath);
        rs.on('data', function (chunk) { chunks += chunk.toString('hex'); });
        rs.on('end', function () {
            check('IO', chunks == streamPayload.toString('hex'), 'streaming read-back did not match the streamed write');
            try { fs.unlinkSync(streamPath); } catch (e) { }
            testChildProcess(done);
        });
        // Unlike Node, attaching a 'data' listener alone does not start the flow here -
        // resume() must be called after listeners are attached, or 'data'/'end' never fire.
        rs.resume();
    });
    ws.end(streamPayload);

    function testChildProcess(next) {
        try {
            var cp = require('child_process');
            var isWin = process.platform == 'win32';
            var child = isWin ? cp.execFile('cmd.exe', ['cmd.exe']) : cp.execFile('/bin/sh', ['sh']);
            child.stdout.str = '';
            child.stdout.on('data', function (chunk) { this.str += chunk.toString(); });
            child.stdin.write(isWin ? 'echo STRESS_TEST_MARKER_12345\r\nexit\r\n' : 'echo STRESS_TEST_MARKER_12345\nexit\n');
            child.waitExit();
            check('IO', child.stdout.str.indexOf('STRESS_TEST_MARKER_12345') >= 0,
                'child_process stdout did not contain the expected marker (platform=' + process.platform + ')');
        }
        catch (e) {
            check('IO', false, 'child_process test threw: ' + (e && e.message ? e.message : e));
        }
        next();
    }
};
