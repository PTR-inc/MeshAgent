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
// WebSocket: a plain ws upgrade over a loopback http server, one echo frame each way, then
// the client ends the session.
//
// KNOWN DEFECT: a server that has had a session leaves a freed one that ILibDuktape_net_server_OnDisconnect
// (ILibDuktape_net.c:938) touches at teardown, a heap-use-after-free under ASan on glibc and a hard
// SIGSEGV on musl at process.exit(). Every check passes and then the process dies, hence the 06- group.
//

exports.name = 'WebSocket';
exports.run = function (check, deepEqual, done) {
    var S = 'WebSocket';
    var http = require('http');

    var srv = http.createServer();
    srv.on('request', function (req, rsp) { rsp.end('nf'); });
    srv.on('upgrade', function (msg, sck, head) {
        check(S, msg.url == '/ws', 'upgrade url was ' + msg.url);
        var ws = sck.upgradeWebSocket();
        ws.on('data', function (d) { ws.write('srv:' + d.toString()); });
        ws.on('end', function () { });
    });
    srv.listen();
    var port = srv.address().port;
    check(S, port > 0, 'http server did not bind');

    var finished = false;
    var guard = setTimeout(function () { if (!finished) { finished = true; check(S, false, 'websocket section timed out'); done(); } }, 8000);
    exports._g = guard;
    function finish() { if (finished) { return; } finished = true; try { clearTimeout(guard); } catch (e) { } done(); }

    var req = http.request(http.parseUri('ws://127.0.0.1:' + port + '/ws'));
    req.on('upgrade', function (res, ws, head) {
        check(S, true, 'client upgraded');
        ws.on('data', function (d) {
            check(S, d.toString() == 'srv:ping-1', 'echo was "' + d.toString() + '" (expected srv:ping-1)');
            try { ws.end(); } catch (e) { }
            finish();
        });
        ws.write('ping-1');
    });
    req.on('error', function (e) { check(S, false, 'websocket request errored: ' + e); finish(); });
    req.end();
};
