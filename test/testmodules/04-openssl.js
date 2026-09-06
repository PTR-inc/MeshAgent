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
// OpenSSL functions through the real bindings, with no mocking: X.509 and PKCS12 cert generation
// for all 3 cert types, a DER round-trip, RSA sign and verify including tamper cases, the SHA1,
// SHA256, SHA384, SHA512 and MD5 hashes, and RAND_bytes sanity.
//

exports.name = 'OpenSSL';
exports.run = function (check, deepEqual, done) {
    var tls = require('tls');
    var RSA = require('RSA');
    var enc = require('EncryptionStream');

    // Certificate generation across all 3 cert types: ROOT=1, TLS_SERVER=2, TLS_CLIENT=3.
    var certTypes = [1, 2, 3];
    for (var ct = 0; ct < certTypes.length; ++ct) {
        var pfx = tls.generateCertificate('stress-' + certTypes[ct], { certType: certTypes[ct], noUsages: 1 });
        check('OpenSSL', pfx != null && pfx.length > 0, 'generateCertificate(certType=' + certTypes[ct] + ') produced an empty pfx');
        check('OpenSSL', typeof pfx.digest == 'string' && pfx.digest.length > 0, 'generateCertificate() is missing its .digest fingerprint');
    }

    // A fresh cert with its private key, for signing, verifying and the DER round-trip.
    var pfx2 = tls.generateCertificate('openssl-section', { certType: 3, noUsages: 1 });
    var cert = tls.loadCertificate({ pfx: pfx2, passphrase: 'openssl-section' });
    check('OpenSSL', cert != null, 'loadCertificate() from a freshly generated pfx failed');

    var der = cert.toDER();
    check('OpenSSL', der != null && der.length > 0, 'cert.toDER() produced empty output');
    var cert2 = tls.loadCertificate({ der: der });
    var hash1 = cert.getKeyHash().toString('hex');
    var hash2 = cert2.getKeyHash().toString('hex');
    check('OpenSSL', hash1 == hash2 && hash1.length > 0, 'getKeyHash() differs between the original cert and its DER round-trip');

    // cert2 was reloaded from DER only, so it has no private key and signing must be refused.
    var signRefused = false;
    try { RSA.sign(RSA.TYPES.SHA384, cert2, Buffer.alloc(48)); } catch (e) { signRefused = true; }
    check('OpenSSL', signRefused, 'RSA.sign() with a public-key-only certificate should have thrown, but did not');

    // Hash algorithms SHA1, SHA256, SHA384, SHA512 and MD5, via each *Stream.create().syncHash().
    var algos = [
        { name: 'SHA256Stream', size: 32 },
        { name: 'SHA384Stream', size: 48 },
        { name: 'SHA512Stream', size: 64 },
        { name: 'SHA1Stream', size: 20 },
        { name: 'MD5Stream', size: 16 }
    ];
    var HASH_ITERATIONS = 25;
    for (var a = 0; a < algos.length; ++a) {
        var algo = algos[a];
        var mod = require(algo.name);
        for (var h = 0; h < HASH_ITERATIONS; ++h) {
            var payload = enc.GenerateRandom(64 + h);
            var digest = mod.create().syncHash(payload);
            check('OpenSSL', digest.length == algo.size, algo.name + ' produced the wrong digest length (' + digest.length + ' vs ' + algo.size + ')');
            var digest2 = mod.create().syncHash(payload);
            // Wrong digests on macOS and 32-bit ARM are the Duktape_GetBuffer use-after-free, see ISSUES.md.
            check.known('OpenSSL', digest.toString('hex') == digest2.toString('hex'), algo.name + ' was not deterministic across two identical hashes', 'ISSUES.md: Duktape_GetBuffer use-after-free');
        }
    }

    // RSA sign and verify round-trip over a SHA384 digest, plus a tampered-digest negative case.
    var SIGN_ITERATIONS = 15;
    var sha384 = require('SHA384Stream');
    for (var si = 0; si < SIGN_ITERATIONS; ++si) {
        var msg = enc.GenerateRandom(32 + si);
        var digest = sha384.create().syncHash(msg);
        var sig = RSA.sign(RSA.TYPES.SHA384, cert, digest);
        check('OpenSSL', sig != null && sig.length > 0, 'RSA.sign() produced an empty signature');
        check.known('OpenSSL', RSA.verify(RSA.TYPES.SHA384, cert, digest, sig) == true, 'RSA.verify() rejected a signature it just produced', 'ISSUES.md: Duktape_GetBuffer use-after-free');

        var tampered = Buffer.alloc(digest.length);
        for (var ti = 0; ti < digest.length; ++ti) { tampered.writeUInt8(digest.readUInt8(ti), ti); }
        tampered.writeUInt8(tampered.readUInt8(0) ^ 0xFF, 0);
        check('OpenSSL', RSA.verify(RSA.TYPES.SHA384, cert, tampered, sig) == false, 'RSA.verify() accepted a signature over a tampered digest');
    }

    // RNG sanity via EncryptionStream.GenerateRandom(), which is OpenSSL RAND_bytes underneath.
    var r1 = enc.GenerateRandom(256);
    var r2 = enc.GenerateRandom(256);
    check('OpenSSL', r1.length == 256 && r2.length == 256, 'GenerateRandom() returned the wrong length');
    check('OpenSSL', r1.toString('hex') != r2.toString('hex'), 'GenerateRandom() returned identical output twice in a row');

    done();
};
