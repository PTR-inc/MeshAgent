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

    // Round-trips the payload twice: once with the default flags and once with explicit binary
    // flags. On Windows the defaults are "w"/"r", i.e. text mode - see meshagent-todo.md #0m.
    // Each round-trip gets its own file: Windows refuses to unlink a file whose read stream is
    // still open, so reusing one path makes the next createWriteStream fail with a sharing error.
    var streamFiles = [];
    function streamRoundTrip(label, path, wopts, ropts, next) {
        streamFiles.push(path);
        try { if (fs.existsSync(path)) { fs.unlinkSync(path); } } catch (e) { }
        var ws = wopts == null ? fs.createWriteStream(path) : fs.createWriteStream(path, wopts);
        ws.on('finish', function () {
            var chunks = '';
            var rs = ropts == null ? fs.createReadStream(path) : fs.createReadStream(path, ropts);
            rs.on('data', function (chunk) { chunks += chunk.toString('hex'); });
            rs.on('end', function () {
                check('IO', chunks == streamPayload.toString('hex'),
                    'streaming read-back did not match the streamed write [' + label + '] - read ' +
                    (chunks.length / 2) + ' of ' + streamPayload.length + ' bytes');
                next();
            });
            // Unlike Node, attaching a 'data' listener alone does not start the flow here -
            // resume() must be called after listeners are attached, or 'data'/'end' never fire.
            rs.resume();
        });
        ws.end(streamPayload);
    }

    streamRoundTrip('default flags', streamPath + '.1', null, null, function () {
        streamRoundTrip('binary flags', streamPath + '.2', { flags: 'wb' }, { flags: 'rb' }, function () {
            for (var fi = 0; fi < streamFiles.length; ++fi) {
                try { fs.unlinkSync(streamFiles[fi]); } catch (e) { }
            }
            testChildProcess(done);
        });
    });

    function testChildProcess(next) {
        try {
            var cp = require('child_process');
            var isWin = process.platform == 'win32';
            // Windows CreateProcessW gets lpApplicationName, which does not search PATH - a bare
            // 'cmd.exe' fails with "Could not exec". Use the full path from %ComSpec%.
            var shell = isWin ? (process.env['ComSpec'] || 'C:\\Windows\\System32\\cmd.exe') : '/bin/sh';
            var child = cp.execFile(shell, [isWin ? 'cmd.exe' : 'sh']);
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
