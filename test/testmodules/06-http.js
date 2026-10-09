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
// HTTP: plain-http loopback without TLS, so transport bugs stay separable from the known TLS
// defects. Covers a GET and POST body round-trip, headers, a multi-chunk response and a 404.
//
// KNOWN DEFECT: a server that has had a session leaves a freed one that ILibDuktape_net_server_OnDisconnect
// (ILibDuktape_net.c:938) touches at teardown, a heap-use-after-free under ASan on glibc and a hard
// SIGSEGV on musl at process.exit(). Every check passes and then the process dies, hence the 06- group.
//

exports.name = 'HTTP';
exports.run = function (check, deepEqual, done) {
    var S = 'HTTP';
    var http = require('http');

    var BODY = 'post-body-' + require('EncryptionStream').GenerateRandom(24).toString('hex');
    var CHUNKS = 6, CHUNK = 'chunk-payload-0123456789';

    var srv = http.createServer();
    srv.on('request', function (req, rsp) {
        if (req.url == '/get') {
            rsp.statusCode = 200;
            rsp.setHeader('X-Stress', 'yes');
            rsp.end('get-ok');
        }
        else if (req.url == '/post') {
            var acc = '';
            req.on('data', function (d) { acc += d.toString(); });
            req.on('end', function () { rsp.end('echo:' + acc); });
        }
        else if (req.url == '/chunks') {
            rsp.statusCode = 200;
            for (var i = 0; i < CHUNKS; ++i) { rsp.write(CHUNK); }
            rsp.end();
        }
        else { rsp.statusCode = 404; rsp.end('nf'); }
    });
    srv.listen();
    var port = srv.address().port;
    check(S, port > 0, 'http server did not bind');

    var guard = setTimeout(function () { check(S, false, 'HTTP section timed out'); finish(); }, 8000);
    exports._g = guard;
    var finished = false;
    function finish() {
        if (finished) { return; }
        finished = true;
        try { clearTimeout(guard); } catch (e) { }
        done();
    }

    function request(method, path, body, cb) {
        var opt = http.parseUri('http://127.0.0.1:' + port + path);
        opt.method = method;
        if (body != null) { opt.headers = { 'Content-Length': '' + body.length }; }
        var req = http.request(opt, function (res) {
            var acc = '';
            res.on('data', function (d) { acc += d.toString(); });
            res.on('end', function () { cb(null, res, acc); });
        });
        req.on('error', function (e) { cb(e); });
        if (body != null) { req.write(body); }
        req.end();
    }

    request('GET', '/get', null, function (e, res, txt) {
        check(S, e == null, 'GET errored: ' + e);
        check(S, res && res.statusCode == 200, 'GET status ' + (res && res.statusCode) + ' (expected 200)');
        check(S, txt == 'get-ok', 'GET body "' + txt + '" (expected get-ok)');
        check(S, res && res.headers && (res.headers['x-stress'] == 'yes' || res.headers['X-Stress'] == 'yes'), 'custom response header missing');

        request('POST', '/post', BODY, function (e2, res2, txt2) {
            check(S, e2 == null && txt2 == 'echo:' + BODY, 'POST echo mismatch: "' + txt2 + '"');

            request('GET', '/chunks', null, function (e3, res3, txt3) {
                var want = ''; for (var i = 0; i < CHUNKS; ++i) { want += CHUNK; }
                check(S, e3 == null && txt3 == want, 'multi-write response reassembled to ' + (txt3 ? txt3.length : 0) + ' bytes (expected ' + want.length + ')');

                request('GET', '/missing', null, function (e4, res4) {
                    check(S, e4 == null && res4.statusCode == 404, 'unknown path status ' + (res4 && res4.statusCode) + ' (expected 404)');
                    finish();
                });
            });
        });
    });

};
