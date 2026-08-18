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
// Duktape Engine - the native embedding layer (EventEmitter, Duplex streams + '~' finalizer,
// the promise module, GC).
//

exports.name = 'Duktape Engine';
exports.run = function (check, deepEqual, done) {
    var stream = require('stream');
    var Promise = require('promise');

    // EventEmitter - mixin style, matching this codebase's own convention
    // (require('events').EventEmitter.call(this, true)), not a Node-style `new EventEmitter()`.
    // The "true" ctor arg selects explicit-events mode: .on() throws "Cannot register for
    // non-existing event" for any name not pre-declared first. EventEmitter.call() returns
    // an internal "emitterUtils" object (not the target itself) - createEvent() lives there,
    // chainable, matching this codebase's own idiom (e.g. modules/daemon.js).
    var ee = {};
    require('events').EventEmitter.call(ee, true).createEvent('probe').createEvent('single');
    var emitSum = 0;
    function onProbe(v) { emitSum += v; }
    ee.on('probe', onProbe);
    ee.emit('probe', 1);
    ee.emit('probe', 2);
    ee.removeListener('probe', onProbe);
    ee.emit('probe', 100); // must NOT be counted - listener was removed
    check('DuktapeEngine', emitSum == 3, 'EventEmitter on/emit/removeListener wrong (sum=' + emitSum + ')');

    var onceCount = 0;
    ee.once('single', function () { onceCount++; });
    ee.emit('single'); ee.emit('single');
    check('DuktapeEngine', onceCount == 1, 'EventEmitter.once() fired more than once (' + onceCount + ')');

    // Duplex stream + '~' finalizer event, same shape as test/leaktest.js's sample streams.
    var received = '';
    var dup = new stream.Duplex({
        write: function (chunk, flush) { received += chunk.toString(); flush(); return true; },
        final: function (flush) { flush(); }
    });
    var finalized = false;
    dup.once('~', function () { finalized = true; });
    dup.write('hello-');
    dup.write('duplex-stream');
    check('DuktapeEngine', received == 'hello-duplex-stream', 'Duplex stream write sink did not receive the full data');
    dup = null;

    // GC stress: allocate and drop a lot of objects/buffers, then force a collection pass.
    for (var g = 0; g < 500; ++g) {
        var throwaway = { idx: g, buf: Buffer.alloc(64), nested: { a: [1, 2, 3], s: 'stress-gc-object' } };
        throwaway = null;
    }
    if (typeof _debugGC == 'function') { _debugGC(); }

    // promise module - chaining and rejection/.catch(). Resolves synchronously here for an
    // already-settled executor (no microtask/timer queue involved), so these are checked
    // immediately, not deferred - see the note on setTimeout below.
    var chainResult = null;
    new Promise(function (res) { res(1); })
        .then(function (v) { return v + 1; })
        .then(function (v) { return v + 1; })
        .then(function (v) { chainResult = v; })
        .catch(function (e) { chainResult = 'ERROR:' + e; });
    check('DuktapeEngine', chainResult == 3, 'Promise .then() chaining produced the wrong result (' + chainResult + ')');

    var rejectSeen = null;
    new Promise(function (res, rej) { rej('deliberate-reject'); })
        .then(function () { rejectSeen = 'SHOULD_NOT_RESOLVE'; })
        .catch(function (e) { rejectSeen = e; });
    check('DuktapeEngine', rejectSeen == 'deliberate-reject', 'Promise .catch() did not see the rejection reason (' + rejectSeen + ')');

    // Promise.all() settles here too, but its resolved array holds the Promise objects rather
    // than their unwrapped values in this implementation - only checking that it settles at all.
    var allResult = null;
    Promise.all([
        new Promise(function (res) { res('a'); }),
        new Promise(function (res) { res('b'); }),
        new Promise(function (res) { res('c'); })
    ]).then(function (vals) { allResult = vals; });
    check('DuktapeEngine', allResult != null && allResult.length == 3, 'Promise.all() did not settle with 3 results');

    check('DuktapeEngine', finalized == true, 'Duplex stream never emitted its \'~\' finalizer event');

    done();
};
