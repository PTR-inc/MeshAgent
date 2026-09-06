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
// JS Engine: core ECMAScript behavior inside Duktape, covering closures, exceptions, JSON,
// RegExp, Array, String, Math, Date and Buffer.
//

exports.name = 'JS Engine';
exports.run = function (check, deepEqual, done) {
    // closures
    function makeCounter() { var n = 0; return function () { return ++n; }; }
    var c1 = makeCounter(), c2 = makeCounter();
    c1(); c1(); c1(); // Three prior increments on c1 and none on c2, so the counters must differ.
    var c1v = c1(), c2v = c2(); // Each counter is called exactly once here, not inside check().
    check('JSEngine', c1v == 4 && c2v == 1, 'closures did not maintain independent state (c1=' + c1v + ', c2=' + c2v + ')');

    // recursion
    function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
    check('JSEngine', fib(20) == 6765, 'recursive fibonacci(20) produced the wrong result');

    // exceptions
    var caught = null;
    try { throw new Error('probe-12345'); } catch (e) { caught = e.message; }
    check('JSEngine', caught == 'probe-12345', 'try/catch did not capture the thrown Error message');

    // JSON round-trip
    var obj = { a: 1, b: 'two', c: [1, 2, 3, { d: true, e: null }], f: -3.5 };
    check('JSEngine', deepEqual(obj, JSON.parse(JSON.stringify(obj))), 'JSON.stringify/parse round-trip mismatch');

    // RegExp
    var m = 'hello-world-123'.match(/([a-z]+)-([a-z]+)-(\d+)/);
    check('JSEngine', m != null && m[1] == 'hello' && m[2] == 'world' && m[3] == '123', 'RegExp capture groups wrong');
    check('JSEngine', 'AAA-bbb-CCC'.replace(/[A-Z]+/g, 'x') == 'x-bbb-x', 'RegExp global replace wrong');

    // Array methods
    var arr = [];
    for (var i = 0; i < 200; ++i) { arr.push(i); }
    var sum = arr.reduce(function (a, b) { return a + b; }, 0);
    check('JSEngine', sum == (199 * 200) / 2, 'Array.reduce sum wrong (' + sum + ')');
    var evens = arr.filter(function (x) { return (x % 2) == 0; });
    check('JSEngine', evens.length == 100, 'Array.filter count wrong (' + evens.length + ')');
    var doubled = evens.map(function (x) { return x * 2; });
    check('JSEngine', doubled[0] == 0 && doubled[99] == 396, 'Array.map values wrong');
    var sorted = [5, 3, 4, 1, 2].sort(function (a, b) { return a - b; });
    check('JSEngine', sorted.join(',') == '1,2,3,4,5', 'Array.sort wrong (' + sorted.join(',') + ')');

    // String methods
    var s = '  Mixed CASE string  ';
    check('JSEngine', s.trim().toLowerCase() == 'mixed case string', 'String trim/toLowerCase wrong');
    check('JSEngine', 'a,b,,c'.split(',').length == 4, 'String.split wrong');

    // Math and Date sanity
    check('JSEngine', Math.abs(Math.sqrt(2) * Math.sqrt(2) - 2) < 1e-9, 'Math.sqrt sanity failed');
    var d1 = new Date(2026, 0, 1).getTime();
    var d2 = new Date(2026, 0, 2).getTime();
    check('JSEngine', (d2 - d1) == 86400000, 'Date arithmetic (one day in ms) wrong (' + (d2 - d1) + ')');

    // Node-style Buffer. Unlike Node, .toString() here only recognizes 'base64', 'hex' and 'hex:'
    // (plus 'utf16' on Windows) as explicit encodings. 'utf8' is not one of them, so the plain
    // string conversion is the no-argument form.
    var buf = Buffer.from('stress-test-buffer', 'utf8');
    check('JSEngine', buf.toString() == 'stress-test-buffer', 'Buffer.from/toString round-trip wrong');
    var buf2 = Buffer.from(buf.toString('hex'), 'hex');
    check('JSEngine', buf2.toString() == 'stress-test-buffer', 'Buffer hex round-trip wrong');
    var zeroed = Buffer.alloc(16);
    var allZero = true;
    for (var zi = 0; zi < zeroed.length; ++zi) { if (zeroed.readUInt8(zi) != 0) { allZero = false; break; } }
    check('JSEngine', allZero, 'Buffer.alloc() did not zero-fill');

    done();
};
