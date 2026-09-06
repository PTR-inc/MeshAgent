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
// TLS Connections: repeated local TLS handshakes against a self-signed https server, offline.
// This is the same shape as the known Windows reconnect and hang defects.
//

exports.name = 'TLS Connections';
exports.run = function (check, deepEqual, done) {
    var https = require('https');
    var tls = require('tls');
    var TLS_ATTEMPTS = 8;

    var pfx = tls.generateCertificate('tls-stresstest', { certType: 2, noUsages: 1 });
    check('TLS', pfx != null && pfx.length > 0, 'generateCertificate() for the TLS server produced an empty pfx');

    // The https.createServer() emitter declares no plain 'error' event, unlike the net and tls
    // socket emitters. Registering one would throw "Cannot register for non-existing event".
    var srv = https.createServer({ pfx: pfx, passphrase: 'tls-stresstest' });
    srv.on('request', function (req, res) { res.end(); });
    srv.on('clientError', function (e) { console.log('  (server clientError, ignored) ' + e); });
    srv.listen();

    var port = srv.address().port;
    check('TLS', port > 0, 'https server did not bind to a port');

    var attempt = 0, okCount = 0, failCount = 0;

    function attemptDone() {
        attempt++;
        if (attempt < TLS_ATTEMPTS) { nextAttempt(); }
        else {
            check('TLS', okCount == TLS_ATTEMPTS, 'only ' + okCount + '/' + TLS_ATTEMPTS +
                ' local TLS handshakes succeeded (' + failCount + ' failed/timed out)');
            try { srv.close(); } catch (e) { }
            done();
        }
    }

    // Per-attempt guard timer, anchored on this outer var so it is not collected before it fires
    // It only catches a silent hang, the second defect. A crash inside the
    // connect and end() cycle (defect #1) kills the process, which only an external timeout catches.
    var attemptGuard = null;
    function nextAttempt() {
        var settled = false;
        attemptGuard = setTimeout(function () {
            if (settled) { return; }
            settled = true;
            failCount++;
            console.log('  attempt ' + (attempt + 1) + '/' + TLS_ATTEMPTS + ': TIMEOUT');
            attemptDone();
        }, 3000);

        var s = tls.connect({ host: '127.0.0.1', port: port, rejectUnauthorized: false }, function () {
            if (settled) { return; }
            settled = true;
            clearTimeout(attemptGuard);
            okCount++;
            s.end();
            attemptDone();
        });
        s.on('error', function (e) {
            if (settled) { return; }
            settled = true;
            clearTimeout(attemptGuard);
            failCount++;
            console.log('  attempt ' + (attempt + 1) + '/' + TLS_ATTEMPTS + ': error - ' + e);
            attemptDone();
        });
    }

    nextAttempt();
};
