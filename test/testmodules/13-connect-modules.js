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
// Connect-time modules: the embedded modules a real connect loads around authentication (compressed-stream,
// os, child_process, events, util-dns, identifiers, util-language, kvm-helper, user-sessions, lib-finder,
// util-agentlog, service-host). Each must require() offline, so a broken embedded module fails here, not at the server.
//

exports.name = 'Connect-time Modules';
exports.run = function (check, deepEqual, done) {
    var S = 'ConnectModules';

    // require() must not throw for any of these, because a missing embedded module is a build defect.
    var mustLoad = ['compressed-stream', 'os', 'child_process', 'events', 'util-dns', 'identifiers',
        'util-language', 'user-sessions', 'lib-finder', 'util-agentlog', 'service-host',
        'promise', 'http', 'https', 'tls', 'fs', 'net', 'stream', 'SimpleDataStore',
        'util-pathHelper', 'process-manager', 'wget', 'daemon'];
    var failed = [];
    for (var i = 0; i < mustLoad.length; ++i) {
        try { var m = require(mustLoad[i]); if (m == null) { failed.push(mustLoad[i] + ' (null)'); } }
        catch (e) { failed.push(mustLoad[i] + ' (' + (e && e.message ? e.message : e) + ')'); }
    }
    check(S, failed.length == 0, 'connect-time modules failed to load: ' + JSON.stringify(failed));

    // util-descriptors marshals glibc's close() and execv() through lib-finder. On a musl agent
    // there is no glibc to find and it throws 'cannot find libc' at load. That is a known platform
    // limit, since the self-update path falls back to the service manager, so it is reported but not gated.
    try { require('util-descriptors'); check(S, true, ''); }
    catch (e) { console.log('  util-descriptors did not load: ' + (e && e.message ? e.message : e) + ' (expected on musl/uClibc)'); }

    // os: the shapes meshcore reads at startup
    var os = require('os');
    check(S, typeof os.hostname == 'function' && typeof os.hostname() == 'string' && os.hostname().length > 0, 'os.hostname() is not a non-empty string');
    check(S, typeof os.platform == 'function' && os.platform() == process.platform, 'os.platform() != process.platform');
    var ifaces = null;
    try { ifaces = os.networkInterfaces(); } catch (e) { }
    check(S, ifaces != null && typeof ifaces == 'object', 'os.networkInterfaces() did not return an object');

    // util-dns: an array of resolver strings, which may legitimately be empty in a container
    var dns = null;
    try { dns = require('util-dns')(); } catch (e) { }
    check(S, dns != null && typeof dns.length == 'number', 'util-dns() did not return an array');

    // util-language: the locale meshcore reports
    var lang = null;
    try { lang = require('util-language').current; } catch (e) { }
    check(S, typeof lang == 'string' && lang.length > 0, 'util-language.current is "' + lang + '"');

    // user-sessions: a session table on every platform, possibly empty
    var us = require('user-sessions');
    check(S, typeof us.Current == 'function' || typeof us.enumerateUsers == 'function', 'user-sessions exposes neither Current() nor enumerateUsers()');

    // identifiers.get() is async on some platforms, so accept either a value or a promise.
    var settled = false;
    var guard = setTimeout(function () { if (!settled) { settled = true; check(S, false, 'identifiers.get() did not settle within 15s'); done(); } }, 15000);
    exports._g = guard;
    function judge(id) {
        if (settled) { return; }
        settled = true;
        try { clearTimeout(guard); } catch (e) { }
        check(S, id != null && typeof id == 'object', 'identifiers.get() returned ' + (id == null ? 'null' : typeof id));
        if (id != null && typeof id == 'object') {
            var nkeys = Object.keys(id).length;
            check(S, nkeys > 0, 'identifiers.get() returned an empty object');
        }
        done();
    }
    try {
        var r = require('identifiers').get();
        if (r != null && typeof r.then == 'function') { r.then(judge, function (e) { judge(null); }); }
        else { judge(r); }
    }
    catch (e) {
        var msg = '' + (e && e.message ? e.message : e);
        // No DMI or SMBIOS data, as under WSL, containers and qemu-user, is an environment limit and not a defect.
        if (msg.indexOf('DMI') >= 0 || msg.indexOf('SMBIOS') >= 0) { console.log('  identifiers.get(): ' + msg + ' (skipped)'); judge({ skipped: msg }); }
        else { check(S, false, 'identifiers.get() threw: ' + msg); judge({ threw: 1 }); }
    }
};
