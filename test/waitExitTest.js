// waitExit() test: nesting, loud timeouts, infinite escape, depth cap.
// Works on Windows and Linux/BSD/macOS.
var cp = require('child_process');
var win = process.platform == 'win32';
var pass = 0, fail = 0;
function ok(cond, name) { console.log((cond ? 'PASS ' : 'FAIL ') + name); if (cond) { ++pass; } else { ++fail; } }
function sh(c) { return (win ? cp.execFile(process.env['windir'] + '\\System32\\cmd.exe', ['cmd.exe', '/c', c]) : cp.execFile('/bin/sh', ['sh', '-c', c])); }
function slp(s) { return (sh(win ? ('ping -n ' + (s + 1) + ' 127.0.0.1 > nul') : ('sleep ' + s))); }

// 1) Nested waitExit: timer fires inside outer wait, waits on second child
var nestOK = false, code = -1;
var outer = slp(3);
var t1 = setTimeout(function ()
{
    var inner = sh('exit 5');
    inner.on('exit', function (c) { code = c; });
    try { inner.waitExit(); nestOK = true; } catch (e) { }
}, 400);
outer.waitExit();
ok(nestOK && code == 5, 'nested waitExit inside outer waitExit');

// 2) Timeout throws, and how to catch it: kill (or retry / wait longer)
var hung = slp(30);
var threw = false, t = Date.now();
try
{
    hung.waitExit(500);            // no arg = 2 min default, same throw
}
catch (e)
{
    threw = true;                  // e: "waitExit() timed out after 500ms, child (pid=N) still running"
    hung.kill();
}
ok(threw, 'waitExit(500) threw on timeout: catcher killed child');

// 3) Stale token: the timed-out child above must not disturb a later wait
var later = slp(2);
t = Date.now();
later.waitExit();
ok(Date.now() - t > 1500, 'later waitExit unaffected by timed-out wait');

// 4) Explicit infinite: waitExit(-1) (or 0) never times out
var c2 = slp(2);
t = Date.now();
c2.waitExit(-1);
ok(Date.now() - t > 1500, 'waitExit(-1) waited for full child duration');

// 5) waitExit on already-exited child returns immediately
t = Date.now();
c2.waitExit();
ok(Date.now() - t < 500, 're-waitExit on exited child is instant');

// 6) Depth cap: nest to 16, depth 17 must throw, loop must survive
var refs = [], depth = 0, maxD = 0, capHit = 0, okWaits = 0, launched = 0;
function nest()
{
    ++depth; if (depth > maxD) { maxD = depth; }
    var c = slp(3);
    if (++launched < 17) { refs.push(setTimeout(nest, 30)); }
    try { c.waitExit(); ++okWaits; }
    catch (e) { if (('' + e).indexOf('nesting depth') >= 0) { ++capHit; } c.kill(); }
    --depth;
    if (depth == 0)
    {
        ok(maxD == 17 && okWaits == 16 && capHit == 1, 'depth cap: 16 nested OK, 17th threw');
        var last = sh('exit 0');
        last.waitExit();
        ok(true, 'loop healthy after full unwind');
        console.log(fail == 0 ? ('ALL ' + pass + ' TESTS PASSED') : (fail + ' TEST(S) FAILED'));
        process.exit(fail == 0 ? 0 : 1);
    }
}
nest();
