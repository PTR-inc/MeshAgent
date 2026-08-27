#!/usr/bin/env python3
"""Print format, wordsize, machine and member count of a static archive, without binutils.

Walks the ar container itself, so GNU (.a), BSD (Mach-O .a) and COFF (.lib) archives all work
on any host. Output is one line: format=ELF|MACHO|COFF class=32|64 machine=<name> members=<n>.
"""
import struct, sys

ELF = {3: 'i386', 62: 'x86_64', 40: 'arm', 183: 'aarch64', 8: 'mips', 243: 'riscv'}
MACHO = {7: 'i386', 0x01000007: 'x86_64', 12: 'arm', 0x0100000c: 'arm64'}
COFF = {0x14c: 'i386', 0x8664: 'x86_64', 0x1c4: 'arm', 0xaa64: 'arm64'}

def classify(b):
    if b[:4] == b'\x7fELF':
        cls = 32 if b[4] == 1 else 64
        end = '<' if b[5] == 1 else '>'
        return 'ELF', cls, ELF.get(struct.unpack(end + 'H', b[18:20])[0], 'unknown')
    magic = struct.unpack('<I', b[:4])[0]
    if magic in (0xfeedface, 0xfeedfacf):
        cpu = struct.unpack('<I', b[4:8])[0]
        return 'MACHO', 64 if magic == 0xfeedfacf else 32, MACHO.get(cpu, 'unknown')
    m = struct.unpack('<H', b[:2])[0]
    if m == 0 and struct.unpack('<H', b[2:4])[0] == 0xffff:   # anonymous /GL object
        m = struct.unpack('<H', b[6:8])[0]
    if m in COFF:
        return 'COFF', 32 if m in (0x14c, 0x1c4) else 64, COFF[m]
    return None

def main(path):
    d = open(path, 'rb').read()
    if d[:8] != b'!<arch>\n':
        sys.exit('not an ar archive: ' + path)
    off, seen, members = 8, {}, 0
    while off + 60 <= len(d):
        name = d[off:off + 16].decode('ascii', 'replace').rstrip()
        size = int(d[off + 48:off + 58])
        body = off + 60
        skip = 0
        if name.startswith('#1/'):                                  # BSD long name, stored in the body
            skip = int(name[3:])
            name = d[body:body + skip].decode('ascii', 'replace').rstrip('\0')
        off = body + size + (size & 1)
        if name in ('/', '//', '/SYM64/') or name.startswith('__.SYMDEF'):
            continue
        members += 1
        c = classify(d[body + skip:body + skip + 24])
        if c:
            seen[c] = seen.get(c, 0) + 1
    if not seen:
        sys.exit('no recognised objects in ' + path)
    fmt, cls, mach = max(seen, key=seen.get)
    print('format=%s class=%d machine=%s members=%d' % (fmt, cls, mach, members))

if __name__ == '__main__':
    main(sys.argv[1])
