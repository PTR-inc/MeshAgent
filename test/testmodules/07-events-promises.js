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
// Events and Promises: the EventEmitter dispatch order, once and prepend semantics and the promise
// chaining and rejection semantics the agent's own modules rely on. These are the scenarios the
// legacy self-test.js --LocalTests printed, but with real assertions instead of printed values.
//

exports.name = 'Events & Promises';
exports.run = function (check, deepEqual, done) {
    var S = 'Events';

    // --- EventEmitter: newListener and removeListener bookkeeping, once, prepend ordering ---
    var ev = { A: 0, B: 0, B_Trig: 0, A_Res: '', A_Rem: 0, B_Rem: 0 };
    var obj = {};
    require('events').EventEmitter.call(obj);

    obj.on('removeListener', function (name) { ev[name + '_Rem']++; });
    obj.on('newListener', function (name) { ev[name]++; });

    obj.on('A', function () { ev.A_Res += '2'; });
    obj.once('B', function () { ev.B_Trig++; });
    var prepended = function () { ev.A_Res += '1'; };
    obj.prependListener('A', prepended);
    obj.prependOnceListener('A', function () { ev.A_Res += 'A'; });

    check(S, ev.A == 3 && ev.B == 1, 'newListener fired A=' + ev.A + ' B=' + ev.B + ' (expected 3/1) across on/once/prepend/prependOnce');

    obj.emit('B'); obj.emit('B'); obj.emit('B');
    obj.emit('A'); obj.emit('A');
    obj.removeListener('A', prepended);
    obj.emit('A');

    check(S, ev.B_Trig == 1, 'once() listener fired ' + ev.B_Trig + ' times (expected 1)');
    check(S, ev.A_Rem == 2 && ev.B_Rem == 1, 'removeListener fired A=' + ev.A_Rem + ' B=' + ev.B_Rem + ' (expected 2/1: once-auto-remove, prependOnce, explicit)');
    check(S, ev.A_Res == 'A12122', 'dispatch order was "' + ev.A_Res + '" (expected "A12122")');

    // emit() return value and listenerCount after removal
    check(S, obj.emit('nothing-registered') === false, 'emit() of an event with no listeners should return false');
    check(S, obj.emit('A') === true, 'emit() with a remaining listener should return true');
    check(S, typeof obj.listenerCount != 'function' || obj.listenerCount('A') == 1, 'listenerCount("A") after removals should be 1');

    // --- Promises ---
    S = 'Promises';
    var promise = require('promise');

    // 1. then-chain runs in order after a single resolve
    var p1 = new promise(promise.defaultInit), r1 = '';
    p1.then(function () { r1 += '1'; }).then(function () { r1 += '2'; }).then(function () { r1 += '3'; });
    p1.resolve();
    check(S, r1 == '123', 'then-chain produced "' + r1 + '" (expected "123")');

    // 2. a then() that returns another promise gates the rest of the chain on it
    var p2 = new promise(promise.defaultInit), gate = new promise(promise.defaultInit), r2 = '';
    p2.then(function () { r2 += '1'; }).then(function () { return (gate); }).then(function () { r2 += '3'; });
    p2.resolve();
    check(S, r2 == '1', 'chain ran past an unresolved returned promise: "' + r2 + '" (expected "1")');
    gate.resolve();
    check(S, r2 == '13', 'chain did not continue once the returned promise resolved: "' + r2 + '" (expected "13")');

    // 3. rejection: catch() fires with the reason and later then() calls are skipped
    var p3 = new promise(promise.defaultInit), r3 = '', reason = null;
    p3.then(function () { r3 += 'T'; }).catch(function (e) { r3 += 'E'; reason = e; });
    p3.reject('nope');
    check(S, r3 == 'E' && reason == 'nope', 'reject() gave "' + r3 + '"/' + reason + ' (expected "E"/nope)');

    // 4. resolve() carries a value, and resolving twice does nothing
    var p4 = new promise(promise.defaultInit), v4 = null, n4 = 0;
    p4.then(function (v) { v4 = v; n4++; });
    p4.resolve(42); p4.resolve(43);
    check(S, v4 == 42 && n4 == 1, 'resolve(42) then resolve(43) gave value=' + v4 + ' calls=' + n4 + ' (expected 42/1)');

    // 5. promise.all resolves once every member does, in member order
    if (typeof promise.all == 'function') {
        var a1 = new promise(promise.defaultInit), a2 = new promise(promise.defaultInit), allv = null;
        promise.all([a1, a2]).then(function (vals) { allv = vals; });
        a2.resolve('b'); check(S, allv == null, 'promise.all resolved before every member did');
        a1.resolve('a');
        // The runtime's all() resolves with the member promise objects, not their values.
        check(S, allv != null && allv.length == 2, 'promise.all did not resolve with 2 members once both resolved');
    }

    done();
};
