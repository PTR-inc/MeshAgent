#!/usr/bin/env python3
"""Filters the cpio stream of an Xcode .xip down to the macOS SDK subtree without
breaking Apple's hard-link placeholders. It sits between pbzx and cpio in the pipeline.

A plain pattern-restricted cpio is not enough because Apple writes only one link of each
hard-linked file with real bytes, and the others are a "NULLcanary" plus NUL fill. The real
copy usually sits under another platform's SDK, so about 25% of the SDK headers would read
`NULLcanary`, while an unrestricted extraction needs about 45 GB of scratch.

Only odc ("070707") cpio is handled, because that is what xip payloads use.
"""
import sys
import fnmatch

WANTED = [
    "*/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/*",
    "*/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/c++/v1/*",
    "*/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1/*",
    "*/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/share/man/*",
]
CANARY = b"NULLcanary"
HDR = 76  # The odc header is always 76 bytes.

inp = sys.stdin.buffer
out = sys.stdout.buffer


def read_exact(n):
    buf = bytearray()
    while len(buf) < n:
        chunk = inp.read(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return bytes(buf)


def emit(hdr, name, data):
    # The namesize and filesize fields are rewritten because the entry may have been renamed.
    nb = name + b"\0"
    h = hdr[:59] + b"%06o" % len(nb) + b"%011o" % len(data)
    out.write(h + nb + data)


# Hard-link groups are keyed by device and inode. The bytes travel with the first link in
# the stream and every later link is a canary, so the data for open groups is parked on
# disk rather than in RAM and released once all nlink members have passed.
import os, tempfile
spool = tempfile.mkdtemp(prefix="xip-sdk-cpio.")
seen = {}      # How many links of each group have passed so far.
nlinks = {}    # The nlink count of each group.
pending = {}   # Wanted canary entries of each group that are still waiting for their bytes.
kept = dropped = fixed = 0


def spool_path(key):
    return os.path.join(spool, "%s-%s" % (key[0].decode(), key[1].decode()))


def group_done(key):
    if seen.get(key, 0) >= nlinks.get(key, 1):
        try: os.unlink(spool_path(key))
        except OSError: pass
        seen.pop(key, None); nlinks.pop(key, None)


while True:
    hdr = read_exact(HDR)
    if len(hdr) < HDR:
        break
    if hdr[:6] != b"070707":
        sys.stderr.write("xip-sdk-cpio: not an odc cpio stream (magic %r)\n" % hdr[:6])
        sys.exit(1)
    key = (hdr[6:12], hdr[12:18])
    nlink = int(hdr[36:42], 8)
    mode = int(hdr[18:24], 8)
    namesize = int(hdr[59:65], 8)
    filesize = int(hdr[65:76], 8)
    name = read_exact(namesize)[:-1]
    data = read_exact(filesize)
    if name == b"TRAILER!!!":
        break
    wanted = any(fnmatch.fnmatchcase(name.decode("utf-8", "surrogateescape"), p) for p in WANTED)
    linked = nlink > 1 and (mode & 0o170000) == 0o100000
    canary = linked and filesize >= len(CANARY) and data[:len(CANARY)] == CANARY \
        and not data[len(CANARY):].strip(b"\0")
    if linked:
        nlinks[key] = nlink
        seen[key] = seen.get(key, 0) + 1
        if not canary:
            with open(spool_path(key), "wb") as f: f.write(data)
            for phdr, pname in pending.pop(key, []):
                emit(phdr, pname, data); kept += 1; fixed += 1
    if wanted:
        if canary:
            sp = spool_path(key)
            if os.path.exists(sp):
                with open(sp, "rb") as f: emit(hdr, name, f.read())
                kept += 1; fixed += 1
            else:
                pending.setdefault(key, []).append((hdr, name))
        else:
            emit(hdr, name, data); kept += 1
    else:
        dropped += 1
    if linked:
        group_done(key)

emit(hdr, b"TRAILER!!!", b"")
out.flush()
import shutil
shutil.rmtree(spool, ignore_errors=True)
unres = sum(len(v) for v in pending.values())
sys.stderr.write("xip-sdk-cpio: kept %d (%d hard-link placeholders resolved), dropped %d, unresolved %d\n"
                 % (kept, fixed, dropped, unres))
if unres:
    for v in pending.values():
        for _, n in v[:20]:
            sys.stderr.write("  unresolved: %s\n" % n.decode("utf-8", "replace"))
    sys.exit(1)
