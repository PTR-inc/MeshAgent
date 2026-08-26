# MeshAgent build system: issues, decisions and history

One entry per topic. "Where" points at the current file and line. Comments in the code stay short and point here.

Companion documents: [BUILD.md](BUILD.md) (the routing table, the four sources of truth, the macOS signing recipe and the test driver) and [openssl/libstatic/build/README.md](openssl/libstatic/build/README.md) (the OpenSSL buildroot reference, the per-target archive ledger, the riscv64 ASYNC bug write-up and the CI migration record). Where one of those already holds the full text, the entry below is a summary that links there instead of repeating it.

Several entries name a document under `~/.claude/docs/` (for example `meshagent-archid-glibc-floor.md`). Those are the private notes the original comment cited as its source. They are not part of this repository.

## Open issues

### Wrong crypto results from the `linux-armv4` archives (armhf, armhf2, linux-armada370-hf)
- Where: `openssl/libstatic/build/targets.sh:48`, `openssl/libstatic/build/targets.sh:94`
- What: with asm enabled, the `linux-armv4` build produced wrong crypto results under qemu-arm (non-deterministic SHA-384/512 hashes, and `RSA.verify()` rejecting its own fresh signature). asm is therefore disabled for these targets. Reverting to `-no-asm` did not fix it, so the bug is unrelated to asm itself and remains unresolved. Do not re-enable asm without root-causing first, and do not trust any RSA or SHA-384/512 operation on these three targets. The per-target table in [openssl/libstatic/build/README.md](openssl/libstatic/build/README.md#per-target-status) carries the same warning.
- Status: open

### Known native crashes in the 06-* test sections
- Where: `test/testmodules/06-http.js:21`, `test/testmodules/06-websocket.js:21`, `test/testmodules/06-tls.js:19`, `test/testmodules/06-tls.js:55`, `test/test-agent.sh:443`, `test/test-agent.ps1:366`, `test/stress-test.js:28`
- What: a server that has had a session leaves a freed one that `ILibDuktape_net_server_OnDisconnect` (`ILibDuktape_net.c:938`) touches at teardown. Under ASan on glibc this is a heap-use-after-free, and on musl it is a hard SIGSEGV at `process.exit()`. Every check passes and then the process dies. The TLS section has the same shape as the known Windows reconnect crash and the second-connection hang recorded as `meshagent-todo.md` #1 and #2 (a private doc, not in this repository). The per-attempt guard timer in `06-tls.js` only catches a silent hang (defect #2); a crash inside the connect and `end()` cycle (defect #1) kills the process, which only an external timeout catches. That is why the driver runs the 06-* group in its own phase, apart from the core, and why `stress-test.js` must be driven with an external timeout. The SIGSEGV in the 06-* sections has been reproduced on Linux x86-64 and on RISC-V64. Under `--ci` the known TLS crash is a FAIL (`--lenient` keeps it as KNOWN).
- Status: open

### Unaligned CRC32 reads in ILibSimpleDataStore.c
- Where: `test/testmodules/10-datastore-edge.js:19`, `test/testmodules/03-datastore.js:19`
- What: the CRC32 path in `ILibSimpleDataStore.c` does unaligned `uint32_t` reads whenever a key length is not a multiple of 4, which is a SIGBUS on strict-alignment hardware. The 10-* module sweeps every key length from 1 to 17 to exercise it, and the 03-* module deliberately uses key lengths in the 5 to 12 range where `ILibHashtable_DefaultHashFunc` only hashes the last 4 bytes (`meshagent-todo.md` #0, private doc).
- Status: open

### ARCHID 45 no longer reproduces the original xthead-accelerated binary
- Where: `makefile:500`, `makefile:502`, `makefile:508`
- What: ARCH_45 is the original T-Head/Xuantie C906 vendor musl target, restored as it was before the refactor (commit a4ce0e3 had swapped it for a generic rv64gc/glibc build, which now lives as ARCH_145 instead). The toolchain is bring-your-own at `PATH_RISCV64`, like the old `PATH_RPI`. The vendored `openssl/libstatic/linux/riscv64` archive's sha512 asm used to target the same xthead custom-opcode extension, but that archive has since been rebuilt generic (Bootlin riscv64-lp64d musl, rv64gc, no xthead asm). Rebuilding this target will not reproduce the original xthead-accelerated binary until or unless that archive is rebuilt vendor-specific again. On the current toolchain (gcc 14.1.1 via the XuanTie fork) `-mcpu=c906fdv` alone expands to the full T-Head extension set, and the original vendor gcc 10.2.0's hand-spelled `-march=rv64imafdcv0p7xthead` is rejected because `xthead` is no longer a single blob extension name. Source notes: `docs/meshagent-riscv64-cross-compile.md` (private doc).
- Status: open

### test-agent.ps1 phase numbering disagrees with its banners
- Where: `test/test-agent.ps1:33`, `test/test-agent.ps1:469`, `test/test-agent.ps1:505`, `test/test-agent.ps1:470`, `test/test-agent.ps1:506`
- What: the script's help text and section comments still number Dr. Memory and ASan as phases 7 and 8 (the bash driver's numbering, where valgrind is phase 6), while the banners print `[6/7]` and `[7/7]` because there is no valgrind phase on Windows.
- Status: open

### Dr. Memory is broken on Windows 11 24H2 and later
- Where: `test/test-agent.ps1:486`
- What: known upstream breakage on Windows 11 24H2 and later, tracked as DynamoRIO/drmemory #2543 and #2539. The phase is skipped with a note rather than failed.
- Status: worked around

### ARCHID 16 (macOS x86-64) and `___isPlatformVersionAtLeast`
- Where: `makefile:262`
- What: the macOS blocks set a 10.15 deployment floor so clang can resolve `mac_kvm.c`'s `@available` check statically. osxcross ships no compiler-rt for the runtime form (`___isPlatformVersionAtLeast`), and Xcode 15+ cannot target below 10.13 anyway. The private doc `meshagent-osxcross-cross-compile.md` records that ARCHID 16 previously failed to link on that missing symbol while ARCHID 29 built clean.
- Status: worked around

### `verify` documentation disagrees on whether version and object count are gated
- Where: `openssl/libstatic/verify:52`, `openssl/libstatic/verify:66`
- What: the original header of `openssl/libstatic/verify` said it exits non-zero only on a symbol-gate failure, and that version and object count are reported, not gated, because archives are legitimately rebuilt piecemeal. [BUILD.md](BUILD.md#anti-drift-gate) and the README state that the object count must equal the target's `T_OBJS` and is gated. The two descriptions have not been reconciled.
- Status: open

### ARCHID 44 (ARMVIRT32) has no OpenSSL archive
- Where: `makefile:481`, `makefile:484`
- What: OBSOLETE. This is OpenWRT's ARMv7 virtual machine target, not physical hardware, with no device population. No OpenSSL archive exists for it, so it compiles but never links. `ARCHID=44 OBSOLETE_OK=1` attempts it anyway.
- Status: disabled

### ARCHID 31 (FreeBSD x86 32-bit) will not be implemented
- Where: `makefile:27`
- What: FreeBSD 15 dropped 32-bit support, so the 32-bit FreeBSD target is not implemented and will not be done.
- Status: disabled

### `linux/poky` and `linux/poky64` are unbuilt
- Where: `openssl/libstatic/build/targets.sh:105`, `openssl/libstatic/build/targets.sh:108`, `openssl/libstatic/build/build.sh:29`
- What: `poky` is disabled because the Intel Galileo (Quark X1000) has been EOL since 2016 and no current SDK targets it. `poky64` is linked by no ARCHID and is kept for continuity only. The real Yocto 1.6.1 `x86_64-poky-linux` SDK the old `openssl-poky64` script used (`/opt/poky/1.6.1/...`) is defunct, with no public URL, 2014-era and not reproducible on any machine today, so `poky64` stands in with the host's native glibc (`linux-generic64`, no cross toolchain, empty `T_CC`) and is tracked in `targets.sh` so CI builds it through the same path as everything else instead of it being silently absent from the canonical list. The committed archives are still at 1.1.1i, see the "Not built" table in the [README](openssl/libstatic/build/README.md#not-built).
- Status: open

### `riscv64-generic` is consumed by no ARCHID
- Where: `openssl/libstatic/build/targets.sh:68`
- What: glibc rv64gc built with apt's `riscv64-linux-gnu-gcc`, a genuinely separate target from `riscv64`. It was ad-hoc built previously and is now tracked in `targets.sh` so a rebuild is reproducible through the normal path, but no makefile ARCHID currently links it.
- Status: open

## Known limitations and workarounds

### qemu-user sysroot search for cross-built test binaries
- Where: `test/test-agent.sh:234`, `test/test-agent.sh:241`
- What: qemu-user prefixes the ELF `PT_INTERP` path with the sysroot verbatim, so the sysroot must hold the loader at exactly that relative path. glibc loaders live under `/usr/<triple>`, while musl and uClibc loaders exist only under `$BUILDROOT/toolchains` (musl.cc, OpenWrt `staging_dir`, Bootlin). The search roots can be overridden with `QEMU_SYSROOT_ROOTS`. When several roots carry the loader, glibc prefers `/usr` and otherwise the newest match wins. The interpreter's full relative path is matched because `lib/` versus `lib64/` matters, `find -L` lets `lib64` symlinks resolve, and OpenWrt's `staging_dir/host` holds x86_64 host tools rather than the target. The user-facing version of this is in [BUILD.md](BUILD.md#testing-an-agent).
- Status: worked around

### Connection phase needs about 90 s under qemu
- Where: `test/test-agent.sh:544`
- What: the connect timeout is a ceiling, not a wait, since the poll stops the moment the core is seen running. Under qemu a first connect (core download, SHA384 verify, module loads) took about 90 s, and a 60 s limit was killing it mid-transfer. The default is now 15 s natively and 120 s under qemu.
- Status: worked around

### RISC-V vendor builds die with SIGILL on qemu's default CPU model
- Where: `test/test-agent.sh:253`, `test/test-agent.sh:266`, `test/test-agent.sh:314`
- What: a vendor-extension build dies with SIGILL on qemu's default CPU model. ARCHID 45 (Allwinner D1, T-Head C906) is that case in this tree and needs `qemu-riscv64 -cpu thead-c906`. The ELF's RISC-V arch attribute names the extensions, so the driver picks the CPU model from that rather than from the ARCHID, probes once with `-info`, and walks a fallback list when exit code 132 (SIGILL) comes back. Source notes: `docs/meshagent-riscv64-cross-compile.md` (private doc).
- Status: worked around

### Other test-driver limitations
- Where: `test/test-agent.sh:49`, `test/test-agent.sh:135`, `test/test-agent.sh:160`, `test/test-agent.sh:212`, `test/test-agent.sh:369`, `test/test-agent.sh:392`, `test/test-agent.sh:524`, `test/test-agent.sh:594`, `test/test-agent.sh:618`, `test/test-agent.ps1:268`, `test/test-agent.ps1:296`
- What: valgrind is skipped under qemu, which it cannot instrument. Upstream valgrind has no macOS support past 10.13, so LouisBrunner's fork is what brew installs there, and brew refuses to run as root. There is no qemu-user for Darwin, so Mach-O binaries are refused on non-Darwin hosts. macOS ships no coreutils `timeout`, so perl's `alarm` stands in with the same TERM-then-KILL grace handling, and GNU `timeout` re-raises the child's signal on itself, which is why the shell's own "Illegal instruction" message is swallowed. bash's `/dev/tcp` probe tries only the first address a name resolves to, so a host with a link-local IPv6 record ahead of its IPv4 one looks refused while the agent connects fine, and the probe is a hint, not a verdict. A 32-bit binary without `libc6-dbg:i386` makes valgrind report "a function redirection ... cannot be set up", which counts as a startup failure. On macOS libobjc class realization, dyld and libdispatch one-time init leak in every process (762 x 32 B under main on a 26.x run), so suppressions are applied or the leak gate means nothing. On Windows the ASan runtime DLL is needed even by `/MT` builds since VS 17.7 and is not on PATH outside a developer prompt, and the DLL next to the binary may be an ASan runtime from a different MSVC toolset, so the driver probes until the agent starts.
- Status: worked around

### stress-test.js contract and driving rules
- Where: `test/stress-test.js:22`, `test/stress-test.js:26`, `test/stress-test.js:38`, `test/stress-test.js:55`
- What: run from the repo root as `meshagent test/stress-test.js`, or the way meshcore is delivered, `timeout 60 meshagent -b64exec "$(base64 -w0 test/stress-test.js)"`. Sections live under `test/testmodules/`, one file per section, run in filename order, and each must export `exports.name` and `exports.run(check, deepEqual, done)`. argv is empty under `-b64exec`, so `--watchdog=<ms>` (default 10000, raise it under valgrind which is about 20x slower) and `--exclude=a,b` both have defaults that the driver patches into the script. A timer only fires while its return value stays referenced, so every `setTimeout()` is assigned to a variable that stays in scope (`meshagent-todo.md` #0d, private doc). Never name a variable `keys`, because `Object.prototype.keys` is a readonly polyfill and a top-level `var keys = ...` silently does nothing (`meshagent-todo.md` #0b).
- Status: worked around

### Test-module platform limits
- Where: `test/testmodules/13-connect-modules.js:39`, `test/testmodules/13-connect-modules.js:89`, `test/testmodules/05-io.js:66`, `test/testmodules/05-io.js:104`, `test/testmodules/08-child-process.js:86`, `test/testmodules/12-archives.js:29`, `test/testmodules/12-archives.js:64`
- What: `util-descriptors` marshals glibc's `close()` and `execv()` through `lib-finder`, so on a musl agent there is no glibc to find and it throws `cannot find libc` at load. That is a known platform limit, since the self-update path falls back to the service manager, so it is reported but not gated. Missing DMI or SMBIOS data (WSL, containers, qemu-user) is an environment limit, not a defect. On Windows the default fs flags `"w"` and `"r"` are text mode (`meshagent-todo.md` #0m), and `CreateProcessW` gets `lpApplicationName`, which does not search PATH, so a bare `cmd.exe` fails with "Could not exec". A shell's orphaned `sleep` grandchild keeps the stdout pipe open, which on macOS meant no `exit` event for 30 s, so the sleeper is spawned directly. `zip-writer` silently omits empty files (upstream behaviour, not tested), and parallel `getStream()` calls on one zip stall, so entries are read one at a time.
- Status: worked around

### musl builds need the kernel headers appended after musl's own include path
- Where: `build-env.sh:235`, `makefile:948`
- What: `musl-gcc` needs the kernel headers appended after musl's own include path. `-I` would shadow musl's headers with glibc's, so `-idirafter` must be used. The same applies to KVM=1 builds: they only need the X11 headers (type and macro definitions, the real calls are `dlopen()`'d at runtime, see `linux_kvm.c`), so the host's stable, arch-neutral X11 headers work for any target, and cross toolchains do not search host paths by default, hence `KVMINC` adds them with `-idirafter` for every target.
- Status: worked around

### Static-link order: `-lpthread` repeated after `-lcrypto`
- Where: `makefile:751`
- What: static-link order matters, and glibc 2.24 (ARCHID 5, 6, 19 and 20) needs `pthread_atfork` resolved after `-lcrypto` pulls it in, so `-lpthread` is repeated after it.
- Status: worked around

### ASan builds use the host gcc and the host `as`
- Where: `makefile:125`, `makefile:777`
- What: ASAN=1 keeps symbols and stays unstripped (like DEBUG=1) and provides the `halt_on_error=0` recovery mode `test/test-agent.sh`'s ASan phase relies on, with the `<binary>_asan` suffix that script auto-detects. It uses the host's native gcc rather than a pinned cross toolchain because old Bootlin cross-gccs (for example 5.4.0 on ARCHID 5, 6, 19 and 20) have a libasan without `-fsanitize-recover=address` support, and ASan output is not a shipped target anyway. The host `as` is captured before any XDIR block prepends a cross toolchain's `bin/`, and ASAN builds restore it so an old cross `as` is not used.
- Status: worked around

### Stale objects from a differently-flagged invocation
- Where: `makefile:919`, `makefile:858`
- What: objects depend on the flags they were built with, so `$(OBJDIR)/.cflags` is rewritten at parse time, before any dependency is judged, only when CC or CFLAGS change. A tree left half-built by a differently-flagged invocation (a bare `make ARCHID=n`, or `KVM=0` after `KVM=1`) then recompiles instead of linking stale objects. "undefined reference to ILib_POSIX_CrashHandler" was exactly that. Only the inner, `EXENAME=` make touches the stamp, since the dispatching outer make carries the generic CFLAGS. Separately, a bare `make ARCHID=n` used to fall into the compile rules with the generic CFLAGS (no `-D_NOILIBSTACKDEBUG` on musl gave "execinfo.h: No such file", and no `MESH_AGENTID`), so it is now routed to the right OS recipe instead.
- Status: worked around

### clang finds `<triple>-ld` only through PATH, and osxcross breaks on `-target`
- Where: `makefile:630`, `makefile:360`, `openssl/libstatic/build/targets.sh:27`, `fetch-toolchains.sh:283`
- What: clang locates `<triple>-ld` through PATH, not next to itself. Without `$OSXCROSS_BIN` on PATH it silently falls back to the host's `/usr/bin/ld` ("unrecognised emulation mode: llvm"). No `-target` flag is passed to osxcross: it overrides the wrapper's argv0-derived triple and silently breaks its ld64 selection, and `-arch` (native) or the prefixed clang (cross) already fix the target, so only the version floor is stated. For OpenSSL, Configure's `darwin64-*-cc` targets add `-arch` themselves for the same reason. Source notes: `meshagent-osxcross-cross-compile.md` (private doc).
- Status: worked around

### Xcode SDK extraction: hard-link placeholders, scratch space and TMPDIR
- Where: `openssl/libstatic/build/xip-sdk-cpio.py:6`, `build-env.sh:64`, `build-env.sh:78`, `build-env.sh:89`, `build-toolchain-archives.sh:96`, `fetch-toolchains.sh:259`
- What: Apple writes every hard-linked file (nlink>1) in the .xip cpio stream once per link at full size, but only one link carries the bytes, the others are a "NULLcanary" plus NUL fill. The real copy usually sits under another platform's SDK (iPhoneOS, XROS...), so a pattern-restricted `cpio -i` extracts the canary and about 25% of the SDK headers end up reading `NULLcanary`. Unrestricted extraction needs about 45 GB of scratch, and a real run here hit ENOSPC at 11GB free. `xip-sdk-cpio.py` keeps the restriction and resolves the placeholders (wanted canary entries are held by inode and the data-carrying link is re-emitted under each wanted name, data parked on disk, odc "070707" cpio only, which is what xip payloads use). `cpio -d` is required or the pattern-restricted copy-in lacks parent dirs for framework symlinks. The several GB of temporaries are kept off `/tmp`, which is a small tmpfs on WSL and filled up mid-run, since both tools honour `TMPDIR`. A tarball made by the old pattern-only extraction is quarantined by `fetch-toolchains.sh` and extracted again, and the smoke test compiles against the SDK's libc headers because a header-free probe still passes on a canary SDK.
- Status: worked around

### osxcross build.sh quirks
- Where: `fetch-toolchains.sh:281`, `fetch-toolchains.sh:283`
- What: `SDK_VERSION` and `BUILD_FLAVOR` must be explicit or osxcross's `build.sh` prompts and, under `set -e`, dies silently on EOF. `UNATTENDED` skips its final confirmation. Only the pinned SDK is placed in `tarballs/` because `build.sh` picks whichever it holds. It re-extracts the SDK and rebuilds cctools/ld64 every run (about 15 min, no incremental mode of its own) and tests every wrapper at the end. On Darwin nothing is built, since Xcode's clang is used directly.
- Status: worked around

### rcodesign traps
- Where: `build-env.sh:99`, `build-env.sh:137`, `build-env.sh:164`
- What: rcodesign reads every `RCODESIGN_*` environment variable as a config key and aborts on unknown ones ("UnknownField version"), so the build uses no variable with that prefix. rcodesign's p12 parser rejects OpenSSL 3's default PBES2/AES container as "incorrect password", so the identity is generated with legacy PBE (SHA1-3DES). rcodesign wants the password in argv or a non-empty file: an empty password (the self-signed default) can only go via argv, and a real one goes via a 0600 temp file so it stays out of `ps`. The full identity recipe is in [BUILD.md](BUILD.md#macos).
- Status: worked around

### Bootlin 2017.05 archives extract to an unsuffixed directory
- Where: `fetch-toolchains.sh:201`
- What: Bootlin's oldest releases (2017.05, the earliest for x86 and x86-64) extract to `<family>--glibc--stable` with no release suffix, unlike every later release where the top-level dir matches the tarball basename. The directory is renamed into place so the destination (`TC_*_BOOTLIN`, or `p_bootlin_pinned`'s version-suffixed alias) resolves either way.
- Status: worked around

### OpenBSD base tarball has an empty usr/include
- Where: `fetch-toolchains.sh:128`
- What: OpenBSD splits `base79.tgz` (runtime) from `comp79.tgz` (headers and crt objects). `base79` alone has an empty `usr/include`, so both sets are fetched. For FreeBSD the trimmed sysroot keeps `usr/include`, `usr/lib` and `lib/`, because `usr/lib`'s `libfoo.so` symlinks need that last one.
- Status: worked around

### OpenWrt SDK archives must ship staging_dir/host
- Where: `build-toolchain-archives.sh:47`
- What: OpenWrt SDKs are a whole buildroot-style source tree (`dl/`, `build_dir/`, `package/`, `target/` kernel sources) and only `staging_dir/toolchain-*` is the actual compiler. Its gcc wrapper also `exec`s `staging_dir/host`'s own `ld-linux` and libc (a hermetic host runtime, independent of this machine's glibc) via a relative `../../host/lib` path, so that has to ship too. A toolchain-only archive fails at gcc invocation, not link time.
- Status: worked around

### Downloads without a published checksum
- Where: `fetch-toolchains.sh:25`, `fetch-toolchains.sh:73`, `build-env.sh:193`, `fetch-toolchains.sh:252`
- What: the OpenWrt SDKs and the musl.cc prebuilt toolchains (about 100MB each) publish no checksum, so each is gated on a real smoke compile rather than a hash. A destination that reads clean as an archive (xz or gzip's own checksum) catches a truncated download that a checksum-less fetch cannot, and an unknown extension passes. Toolchains and sysroots with no stable public URL at all are bring-your-own and only reported.
- Status: worked around

### Symbol gates for non-glibc archives
- Where: `build-env.sh:239`, `build-env.sh:243`, `openssl/libstatic/build/build.sh:99`, `openssl/libstatic/verify:66`
- What: `GLIBC_ONLY_RE` lists symbols musl and uClibc genuinely lack, proving an archive can link a non-glibc agent. Do not add `__stack_chk_fail` or `__stack_chk_guard`, since both libcs have them. `getcontext`, `setcontext`, `makecontext` and `swapcontext` are POSIX-named so that regex cannot catch them, but musl implements `ucontext.h` on no architecture, so a musl archive referencing them means `__GLIBC__` leaked into the build and the agent link will fail. uClibc's `libc.so` does implement them, so the ucontext gate is fatal only for musl, while the glibc-only gate is fatal for musl and uClibc. The incident behind this is the riscv64 entry under History.
- Status: worked around

### Toolchain mirror must be fetched through the LFS media URL
- Where: `build-env.sh:249`
- What: pre-trimmed toolchains (`TC/`) and BSD sysroots (`SR/`) live on `PTR-inc/meshagent-toolchains` so a fetch is one small file instead of the full upstream release. The URL must be `media.githubusercontent.com/media`, not `raw.*`, because the mirror repo tracks `*.tar.*` via Git LFS and `raw.*` serves only the pointer text.
- Status: worked around

### Static linking for ARCHID 35 and 145
- Where: `makefile:427`, `makefile:519`
- What: real hardware for ARCHID 35 runs vendor glibc firmware, not a musl userland (unlike the OpenWrt musl ARCHIDs, which deploy into an image that ships musl's own dynamic loader). The binary is linked static, or it cannot find `/lib/ld-musl-armhf.so.1` on the device and will not start at all. ARCH_145 is static for the same reason.
- Status: worked around

### `download-artifact` nesting varies with the artifact count
- Where: `.github/workflows/build-openssl-job.yml:179`
- What: `download-artifact` nests under `artifacts/<name>/` with multiple artifacts and flat with one, so the collect step searches instead of assuming depth.
- Status: worked around

### Windows OpenSSL buildroot: MSVC toolset and SDK detection
- Where: `openssl/libstatic/build/windows/env.ps1:86`, `openssl/libstatic/build/windows/env.ps1:104`, `openssl/libstatic/build/windows/env.ps1:117`, `openssl/libstatic/build/windows/env.ps1:139`, `openssl/libstatic/build/windows/env.ps1:145`, `openssl/libstatic/build/windows/env.ps1:229`, `openssl/libstatic/build/windows/build.ps1:52`, `openssl/libstatic/build/windows/build.ps1:58`
- What: VS 2026 (v18) version-stamped the x86/x64 toolset component id (`Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64`) where 2017 to 2022 used a fixed `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`. A wildcard matches both, but `vswhere -requires` only understands wildcards in vswhere 2.6.7+, so the fixed id is tried first. `vcvarsall.bat` is not guaranteed: a v18 install carrying only the versioned v143 toolset packages had no `vcvarsall.bat` anywhere, while `VsDevCmd.bat` (shipped by every VS since 2017) was present and worked, so the script prefers `vcvarsall.bat`, falls back to `VsDevCmd.bat`, and records which one it found because the two take different arguments (`vcvarsall` packs host and target into one token, `VsDevCmd` takes them separately and, unasked, changes directory to the VS default). An installed toolset folder is not proof of a usable toolset: both a props-only version folder carrying no compiler at all (which the product's own default resolution still pointed at) and a newest-installed toolset with an incomplete arm64 lib set (present dir, missing `setargv.obj` and CRT) have been seen on real installs, so the newest toolset complete for the target arch is picked and always pinned with `-vcvars_ver`, which wants `Major.Minor` (for example `14.44`), not the full folder name (`14.44.35207`). A usable toolset is only half the environment: `stdlib.h`, `windows.h` and the import libs live in the Windows SDK, which the individual VC.Tools components do not pull in, so an SDK complete for the target arch (headers and import libs both) is required or the build dies on "Cannot open include file: 'stdlib.h'". `build.ps1` refuses up front rather than after a Configure run, because an incomplete toolset otherwise only shows up as a link failure deep into nmake. OpenSSL's Configure refuses a Cygwin perl, and Git for Windows' bundled `perl.exe` is exactly that, so it is skipped even though it is usually on PATH. Source notes: `meshagent-windows-build-prerequisites.md` (private doc).
- Status: worked around

### Windows OpenSSL buildroot: installer and download handling
- Where: `openssl/libstatic/build/windows/env.ps1:286`, `openssl/libstatic/build/windows/env.ps1:309`, `openssl/libstatic/build/windows/env.ps1:375`, `openssl/libstatic/build/windows/env.ps1:479`, `openssl/libstatic/build/windows/env.ps1:53`
- What: downloads go once into `$BR_DOWNLOADS` and are gated on SHA-256, and a file that fails the check is deleted so a retry re-fetches instead of failing forever on a truncated download. Archives unpack into a staging dir and are swapped into place so an interrupted extract never leaves a half-populated tools dir that the probes would treat as a working install; a ZIP with one top-level folder (nasm) is flattened, one that unpacks flat (strawberry) is taken as-is. Component ids for the VS installer's `--add` are read from the installer's own catalog, which lists every component whether or not it is installed, so this still resolves when the C++ workload has been removed outright (deriving it from installed packages would go blind exactly when needed). Without a catalog the fixed toolset id is offered, but the SDK id is versioned with no fixed alias and cannot be guessed. `--passive` is required: the installer rejects `--norestart` on its own ("requires either --quiet or --passive") and answers with its usage dialog. `setup.exe` hands the real work to a child process and can exit before it finishes, so a toolset not visible immediately afterwards is "not done yet", not proof of failure. `-VsComponents` is never implied, needs elevation, and a non-interactive host cannot answer the prompt, so it prints the command and stops. `$env:BUILDROOT` set after dot-sourcing would leave `BR_DOWNLOADS` and the tarball path addressing the old tree, so everything derived is repointed in one place. A hand-typed buildroot path is normalised (quotes stripped, `%VARS%` and `~` expanded, made absolute).
- Status: worked around

### Windows OpenSSL buildroot: build and verify quirks
- Where: `openssl/libstatic/build/windows/build.ps1:75`, `openssl/libstatic/build/windows/build.ps1:96`, `openssl/libstatic/build/windows/build.ps1:99`, `openssl/libstatic/build/windows/build.ps1:10`, `openssl/libstatic/build/windows/verify.ps1:6`, `openssl/libstatic/build/windows/verify.ps1:22`, `openssl/libstatic/build/windows/verify.ps1:32`, `openssl/libstatic/build/windows/verify.ps1:46`
- What: OpenSSL's makefile can leave a literal file named `NUL`, a reserved device name `Remove-Item` cannot touch without the `\\?\` prefix. Release builds drop `/Zi` and `nasm -g`, which VC-common forces even in release. One `cmd.exe` session is used per target because the vcvars script only mutates its own process, and PATH is extended before calling it so its own `vswhere.exe` call finds it (otherwise a harmless "not recognized" warning). Commands go through a `.cmd` file, not inline quoting, because `cmd.exe`'s quoting breaks once a path like "Program Files" has spaces. ARM64 has no asm path in OpenSSL 1.1.1's `VC-WIN64-ARM` config, so asm is x86 and x64 only (NASM, CPUID-gated). `verify.ps1` checks the toolset too, because an unusable x64 toolset would leave `lib.exe` off PATH and report every archive as 0 objects rather than fail. It performs no CRT (`/MT` vs `/MD`) check, since these archives carry no `/DEFAULTLIB:LIBCMT` directive to key off, and `build.ps1`'s `/MD` to `/MT` patch step is the real gate (`toolset-check.ps1` covers the CRT of the committed archives at agent link time, see [BUILD.md](BUILD.md#windows-msbuild)).
- Status: worked around

### Windows ARM64 OpenSSL is cross-built on an x64 runner
- Where: `.github/workflows/build-openssl-job.yml:118`
- What: arm64 is cross-built with the `x64_arm64` MSVC toolset (`build.ps1`'s VcVars), so one x64 runner covers every Windows OpenSSL target. `build.ps1` always rebuilds, so `force` is irrelevant to that job and the collect step uploads only what changed.
- Status: worked around

### Suffixed OpenSSL archives are inert
- Where: `.github/workflows/build-openssl-job.yml:23`, `openssl/libstatic/verify:3`
- What: the makefile and the `.vcxproj` files link the unsuffixed archive names, so staging a suffixed copy (for example `libcrypto-3.0.16.a`) changes no build. `verify` with no arguments checks every `libcrypto*.a`, suffixed included, and `SFX=-<suffix>` or `SFX=` narrows it.
- Status: worked around

### Host packages that fetch-toolchains.sh does and does not install
- Where: `fetch-toolchains.sh:382`, `fetch-toolchains.sh:423`, `fetch-toolchains.sh:337`, `fetch-toolchains.sh:537`
- What: `curl` (fetch), `tar`, `xz` and `zstd` (extract) and `perl` (OpenSSL's Configure) are checked upfront instead of failing halfway with a bare "command not found", and are fatal. The cross-compilers the OpenSSL build scripts need later are offered but non-fatal, only noted in the summary, and only the "fetch everything" run offers the full set (a single-component or CI call must not). A macOS host only ever fetches the OpenSSL tarball, since its cross toolchains are Linux-only, so the Linux-side extractors are not demanded there. The apt prerequisite list, and why `gcc-multilib` is avoided, is in the [README](openssl/libstatic/build/README.md#host-prerequisites-apt-debianubuntu).
- Status: worked around

## Decisions and rationale

### Bootlin toolchains are pinned to one release, not "latest"
- Where: `build-env.sh:204`, `fetch-toolchains.sh:185`, `makefile:160`, `makefile:247`, `makefile:303`, `makefile:384`, `openssl/libstatic/build/targets.sh:43`, `openssl/libstatic/build/targets.sh:54`, `openssl/libstatic/build/targets.sh:59`
- What: the pin makes the glibc floor the toolchains produce a deliberate, reproducible choice, not whatever the build host's package manager has today. apt cross-gcc on this era of Debian/Ubuntu always floors at GLIBC_2.34 (the libpthread-into-libc merge in glibc 2.34), which is above what most of the real ARMv5, ARMv7 and old-aarch64 hardware population runs (for ARMv5, the Marvell Kirkwood/Orion plug computers and NAS of 2008 to 2013). The shared pin 2020.08-1 ships glibc 2.31, gcc 9.3 and binutils 2.33.1, and binutils 2.33.1 handles hardening fine (`HARDEN=basic` on ARCH_9). ARCHID 9 uses Bootlin armv5-eabi, ARCHID 24 Bootlin armv7-eabihf, and ARCHID 32 Bootlin aarch64, the last one matching the OpenSSL archive's own toolchain exactly, because the point of ARCHID 32 is a lower glibc floor than mainline arm64 (ARCHID 26), which apt's `aarch64-linux-gnu-gcc` defeated. ARCHID 26 itself uses apt `gcc-aarch64-linux-gnu`, a real cross toolchain buildable from any machine, not HOST-gated. Source notes: `meshagent-archid-glibc-floor.md` (private doc).
- Decision: pinned Bootlin releases for every glibc cross target that needs a floor below 2.34.

### x86 and x86-64 pin the oldest Bootlin release (glibc 2.24)
- Where: `build-env.sh:217`, `makefile:196`, `makefile:210`, `makefile:274`, `makefile:287`, `openssl/libstatic/build/targets.sh:35`, `openssl/libstatic/build/targets.sh:37`
- What: ARCHID 5, 6, 19 and 20 pin their own, older Bootlin release (stable-2017.05, glibc 2.24), not the shared `$_BOOTLIN`, and not host `gcc -m32` (apt floors at GLIBC_2.34). glibc 2.17 (RHEL7/CentOS7) would be lower still but has no working toolchain source: manylinux2014 was tried and abandoned because CentOS7's yum repos are broken post-EOL. `x86-64-core-i7` is Bootlin's only published x86-64 toolchain name and defaults to `-march=core-i7`, so `TUNE` in the makefile and the target's flags in `targets.sh` force `-march` and `-mtune` back to a generic x86-64 baseline so this stays a generic x86-64 target, not an accidental Core-i7-only build (the asm modules still gate on runtime CPUID via `OPENSSL_ia32cap_P` regardless). Source notes: `meshagent-glibc-2.28-vs-2.31.md` (private doc).
- Decision: oldest Bootlin release for the x86 families, march reset to generic.

### Per-ARCHID glibc floor pin (`GLIBCVER=`)
- Where: `build-env.sh:225`, `makefile:58`, `makefile:583`, `fetch-toolchains.sh:211`
- What: `make GLIBCVER=2.28 ARCHID=9` maps a glibc version to the Bootlin `stable-<date>` release tag that ships it, so a single target can float below the shared 2.31 pin without repinning every other Bootlin target. Only the tags listed in `bootlin_release_for_glibc` are verified against `toolchains.bootlin.com/downloads/releases/toolchains/`, so confirm a new one actually exists, and for which families, before adding it. 2.24 resolves to the x86 families' oldest release only. It applies to the Bootlin glibc targets only (not uclibc or musl), and ARCHID 5, 6, 19 and 20 default to 2.24 but can still opt into a newer pin. The toolchain lands in its own versioned alias (`<alias>-<glibcver>`) so it cannot collide with, or silently move, a target still on the shared pin.
- Decision: one optional per-target pin, resolved through a verified table.

### mipsel (ARCHID 7) uses a Bootlin uClibc toolchain
- Where: `build-env.sh:210`, `makefile:227`, `openssl/libstatic/build/targets.sh:59`
- What: uClibc, not glibc, matches ARCHID 7's own agent toolchain family. apt's `mipsel-linux-gnu-gcc` is glibc, which the agent's uClibc build cannot link against at all (a separate libc, not just a floor difference), and the dd-wrt uClibc archive ARCHID 7 previously used does not build against a current kernel. The Bootlin name is `mips32el` (little-endian); `mips32` without `el` is big-endian and unrelated. The `linux/mips` archive dir is big-endian, and ARCHID 7 links `linux/mipsel`. Source notes: `meshagent-archid-glibc-floor.md` (private doc).
- Decision: Bootlin mips32el uClibc, replacing the dd-wrt archive.

### musl targets use musl.cc standalone toolchains
- Where: `makefile:399`, `makefile:414`, `build-env.sh:193`, `openssl/libstatic/build/targets.sh:87`, `openssl/libstatic/build/targets.sh:92`, `fetch-toolchains.sh:461`
- What: ARCHID 33 (Alpine) uses `x86_64-linux-musl-cross` from musl.cc, a standalone toolchain with its own kernel-UAPI headers, not the host's `musl-gcc` (a glibc multiarch host has no plain `/usr/include/asm`, and the host headers conflict with glibc's own). ARCHID 35 (armada370-hf) uses musl.cc `arm-linux-musleabihf`, the same toolchain the OpenSSL archive is built with; previously the agent was glibc while the archive was already musl, which could not link at all. That archive is a generic ARMv7 static musl build (Marvell Sheeva/PJ4B is ARMv7-A compatible, and the cortex-a9 toolchain is a NEON-free portable baseline, not SoC-tuned), not Synology-specific, and it will not run on a real Synology DSM glibc target. `aarch64-cortex-a53` uses the musl.cc toolchain with ARMv8 crypto extensions runtime-HWCAP-gated, safe on cores that lack them. Source notes: `meshagent-archid-glibc-floor.md` (private doc).
- Decision: musl.cc prebuilt toolchains for Alpine, armada370-hf, aarch64-cortex-a53 and riscv64.

### macOS: native Xcode clang in CI, osxcross only on Linux developer machines
- Where: `.github/workflows/mac-build.yml:7`, `makefile:610`, `build-env.sh:51`, `build-env.sh:58`, `openssl/libstatic/build/targets.sh:8`, `openssl/libstatic/build/targets.sh:101`
- What: macOS runners with Xcode's clang are what the makefile picks on Darwin, and osxcross is only the Linux developer-machine path, because its Apple-licensed SDK (Xcode license agreement) cannot be provisioned in public CI and is never on the public toolchain mirror. It is either produced locally from an Xcode .xip or fetched from a private URL supplied through `OSXCROSS_SDK_URL`, which deliberately has no default. The two macOS ARCHIDs need different runners, so the pairing in `mac-build.yml` is curated and a `guard` job asserts it still covers exactly what the makefile calls `CLASS=macos`. `SDK_VER` is the SDK marketing version and `DARWIN_VER` the kernel version osxcross derives its tool prefix from (SDK 26.5 gives darwin25.5); the makefile globs the darwin version rather than pinning it, and `HOST` is cleared so the native-only guard does not fire on Linux. The bare osxcross dir proves nothing (a bare clone has `target/bin/xar`), so the prefixed clang is what readiness checks look for. The OpenSSL deployment floor comes from the makefile's ARCH_29 and ARCH_16 `MACOSARCH` (via `make print-macosarch`), since without it Configure inherits the SDK default and the archive's minos can exceed the agent's. On a real macOS runner `targets.sh` uses the native clang, ar, ranlib and nm; host GNU ar and ranlib do not reliably handle Mach-O archives, hence `T_AR`, `T_RANLIB` and `T_NM`.
- Decision: native on Darwin, osxcross elsewhere, SDK never public.

### macOS link flags and re-signing after strip
- Where: `makefile:958`, `makefile:962`, `build-env.sh:114`
- What: `MACOSOPT` trails `$(CFLAGS)` (which ends in `-O2`) so `-O3` wins, and it is repeated on the link line because LTO does its codegen there. `-dead_strip` drops the unreferenced objects the static OpenSSL and jpeg archives still pull in. `FORTIFY=3` and `-fstack-protector-strong` need Apple clang 15+. `-ldl` and `-lutil` are libSystem on macOS. Apple Silicon refuses to exec a binary whose signature does not match the file, and osxcross's strip invalidates ld64's linker signature, so every macOS agent is re-signed after strip with rcodesign (apple-codesign, pure Rust), which works identically on Linux and macOS with no keychain. The identity is self-signed by default, generated once into `$BUILDROOT/private/`, and kept stable so TCC's Screen Recording and Accessibility grants survive agent self-updates (ad-hoc changes every build and re-prompts). It must be the same on every host that builds updates, and CI gets it as a secret (`CI` set means no auto-generation, and a PR build without the secret signs ad-hoc). The full rules and recipe are in [BUILD.md](BUILD.md#macos).
- Decision: `-O3` plus LTO plus `-dead_strip`, and a stable self-signed identity.

### Apple SDK archives are packed into `$BUILDROOT/private/` behind an explicit flag
- Where: `build-toolchain-archives.sh:16`, `build-toolchain-archives.sh:84`, `build-toolchain-archives.sh:96`
- What: the macOS SDK is proprietary Apple content (the Xcode/macOS SDK license agreement), not something PTR-inc owns or can redistribute outside Apple's own channels, unlike every other toolchain here. It is packed into `$BUILDROOT/private/`, never the same directory as the redistributable archives, so a blanket upload of `$BUILDROOT/*.tar.xz` cannot sweep it onto the public `TC/` mirror, and only when the caller passes `--i-have-rights-to-redistribute-this`. Without the flag an `Xcode_*.xip` name on the command line fails instead of silently packing Apple's SDK. The SDK tarball `fetch-toolchains.sh osxcross` consumes is also dropped in `$BR_DOWNLOADS` so the same machine can build osxcross from it without a second extraction.
- Decision: private destination and an explicit acknowledgement flag, required every time.

### xz, not zstd, for the mirrored toolchain and sysroot archives
- Where: `build-bsd-sysroot-archives.sh:17`, `build-toolchain-archives.sh:25`
- What: measured against `zstd -19` on the largest archives here, zstd compressed about 25 to 30% faster but produced files 30 to 90% bigger, and both formats decompress in under 2s regardless. xz wins outright for this content, so it is the only format shipped.
- Decision: `.tar.xz` only.

### What can be trimmed from a toolchain archive
- Where: `build-toolchain-archives.sh:4`, `build-toolchain-archives.sh:63`
- What: unlike the BSD sysroots (headers and libs consumed by an external compiler, where a 70%+ reduction was seen), a cross toolchain is the compiler, so `bin/`, `libexec/`, `lib/` and the target sysroot are all load-bearing and cannot be dropped. What is safe to cut is gdb, locale, man, doc and info under `share/`, and the unused ELF symbol tables in the toolchain's own binaries (`strip --strip-unneeded`, which keeps the dynamic symbols the binaries need to run). Expect a modest reduction, order 10 to 20%, plus whatever `xz -9` buys. Every archive is smoke-tested after trimming (compiles and links a tiny C program with the trimmed copy's gcc) before it is kept, since a stripped cc1 that no longer runs is worse than not shipping an archive at all.
- Decision: trim `share/` and strip binaries, smoke-test every archive.

### Version-less toolchain aliases
- Where: `makefile:158`, `fetch-toolchains.sh:452`, `fetch-toolchains.sh:459`
- What: version-less toolchain names under `$BUILDROOT/toolchains` and `../ToolChains/` are symlinks created by `fetch-toolchains.sh`, so a toolchain bump (env.sh's `_BOOTLIN`, a musl.cc rename, or the next OpenWrt gcc) is a one-line `build-env.sh` edit, not also a makefile edit.
- Decision: the makefile points at aliases, never at versioned directories.

### OpenSSL version is the only pin, checksum and release tag are derived
- Where: `build-env.sh:25`, `build-env.sh:254`, `build-env.sh:266`, `openssl/libstatic/build/windows/env.ps1:9`
- What: `fetch-toolchains.sh` and `env.ps1` look the sha256 up from openssl.org's own `<tarball>.sha256` sidecar at download time (both the current release series and every "old" series resolve through that one URL shape, and two formats have been observed, bare hex or `sha256sum` two-column), so there is no separate checksum file to keep in sync by hand. 1.x releases are tagged `OpenSSL_1_1_1w`, 3.x and later `openssl-3.5.7`. `env.ps1` reads the version out of `build-env.sh` rather than restating it, with `$env:OPENSSL_VERSION` as a one-session override.
- Decision: one version string, everything else looked up.

### BSD releases live only in the makefile's ARCH_30 and ARCH_37 blocks
- Where: `build-env.sh:36`, `.github/workflows/freebsd-build.yml:12`, `.github/workflows/openbsd-build.yml:12`
- What: the OS release is not hardcoded in `build-env.sh`. It is read from the `BSDREL` field of the ARCH_30 and ARCH_37 blocks via `make print-bsdrel`, so there is exactly one place a FreeBSD or OpenBSD version bump has to happen, and `fetch-toolchains.sh` and the two BSD agent workflows resolve the same values the same way. The BSD workflows cross-compile (clang plus a base sysroot, no BSD VM) and restate nothing.
- Decision: `BSDREL` in the ARCH block is the single home.

### CI matrices are generated, never hand-written
- Where: `.github/workflows/build-openssl-job.yml:6`, `.github/workflows/build-openssl-job.yml:66`, `.github/workflows/linux-build.yml:9`, `.github/actions/openssl-build-target/action.yml:45`, `openssl/libstatic/build/consistency.sh:61`, `openssl/libstatic/build/consistency.sh:75`
- What: every per-target decision (Configure target, compiler, asm, extra flags, libc family, toolchain provisioning, object count) comes from `targets.sh`, and on Windows from `build.ps1`'s own `$Targets`. The dispatcher only decides which targets to dispatch and on what runner (`T_CI`, with `macos` meaning a macOS runner with Xcode's clang), and restates no recipe, version, URL or checksum. Windows names are grepped from `build.ps1`, not run, so the resolve job needs no pwsh (act's image has none), and `consistency.sh` check 5 asserts that parse agrees with `build.ps1 --names-json` wherever pwsh exists. `linux-build.yml` takes its ARCHID list from `make print-archids` and toolchains from each block's own `FETCH` and `APTPKG` fields via `make print-toolchain`, with `YES=1` letting the makefile's `ensure_toolchain` provision the compiler itself. `BR_FETCH=1` makes `build.sh` provision from the target's own `T_FETCH` tokens, so no per-target toolchain installation steps live in YAML. Each pinned value has exactly one home (`build-env.sh` or an `ARCH_` block), and check 6 greps for any literal copy. The full migration record is in the [README](openssl/libstatic/build/README.md#ci-sources-targetssh-directly-2026-08-24) and the rules in [BUILD.md](BUILD.md#rules).
- Decision: workflows curate, scripts decide.

### `build_libs` for every OpenSSL target
- Where: `openssl/libstatic/build/targets.sh:29`, `openssl/libstatic/build/targets.sh:76`
- What: the repo ships only `libcrypto.a` and `libssl.a`, MeshAgent does not need the OpenSSL CLI, the OpenBSD CLI link needs crt objects and libcompiler_rt that MeshAgent does not use, and 3.x's apps and fuzz link pulls 64-bit atomics that the 32-bit targets lack. Previously only the bsd and macos targets set it, so a local `build.sh` linked `apps/` while CI did not.
- Decision: `T_MAKE=build_libs` everywhere.

### Where asm is enabled, and `-Os` only for space-constrained targets
- Where: `openssl/libstatic/build/targets.sh:36`, `openssl/libstatic/build/targets.sh:43`, `openssl/libstatic/build/targets.sh:56`, `openssl/libstatic/build/targets.sh:82`
- What: asm is enabled where OpenSSL gates it at runtime: x86 and x86-64 on CPUID (`OPENSSL_ia32cap_P`, libc-agnostic), AArch64 on `getauxval(AT_HWCAP)` (`crypto/armcap.c`). Everything configured as `linux-generic32` (arm, arm-linaro, pogo) has no asm modules regardless of flags, and 1.1.1 has no RISC-V asm. `mips` (big-endian) and `mipsel` (little-endian) are both glibc apt builds with asm, which builds clean and runs correct crypto under qemu-mipsel. `-Os` is applied only to genuinely IoT, router or flash-constrained targets, so arm64, alpine-x86-64, freebsd and openbsd (general-purpose server, desktop or container distros) do not take it. The full table is in the [README](openssl/libstatic/build/README.md#per-target-status).
- Decision: runtime-gated asm only, `-Os` per target.

### armhf target flags
- Where: `openssl/libstatic/build/targets.sh:47`
- What: ARMv6 plus VFPv2 hard float. `-mfpu=vfp` because armv6 implies no FPU, and `-marm` because the default `-mthumb` has no hard-float VFP ABI.
- Decision: as stated.

### pogo (ARCHID 13) is softfloat
- Where: `openssl/libstatic/build/targets.sh:103`
- What: plain apt `arm-linux-gnueabi-gcc` (no "hf"), matching real PogoPlug hardware's ABI (ARMv5TE, softfloat). A hardfloat toolchain would silently produce a binary that does not run on the device. arm-linaro (ARCHID 24) is the plain apt `arm-linux-gnueabihf-gcc` hardfloat armv7-a+fp build.
- Decision: softfloat apt toolchain.

### Hardening flavours, `CEXTRA` and `LDEXTRA`, and `WARN`
- Where: `makefile:677`, `makefile:683`, `makefile:192`, `makefile:93`
- What: three hardening flavours (`full`, `basic`, `none`) are kept byte-identical to what each target used before, and `NOLDHARDEN=1` exists because old binutils on some targets reject `-z noexecstack`, `-z relro` and `-z now`. `CEXTRA` and `LDEXTRA` are user hooks only, added last on the compile and link lines so they never drop the per-target hardening, tuning or link sets, and where they conflict they win (gcc and clang take the last `-O`, `-f`, `-m`, `-std` and `-D` of a name, and `-UNAME` undefines one). `WARN=1` shows warnings and the default suppresses them with `-w`, which both gcc/clang and GNU ld recognise, so one flag covers compile and link.
- Decision: as stated.

### ARCHIDs 100 and above report the classic id
- Where: `makefile:49`, `makefile:521`
- What: an ARCHID of 100 or more is the modern, updated build of ARCHID minus 100 (145 is today's 45) and presents the classic id (`MESH_AGENTID = ARCHID-100`, see `SERVER_ARCHID`) to the server, because MeshCentral only knows the classic numbers. ARCH_145 is a generic RISC-V64 (rv64gc, no vendor extensions) static musl build that reuses the `linux/riscv64` OpenSSL archive, which is itself now a generic Bootlin riscv64-lp64d musl build (`-march=rv64gc -mabi=lp64d`, matching `TUNE`), so unlike ARCH_45 this target's toolchain and its OpenSSL archive actually agree.
- Decision: as stated.

### Native-only targets are HOST-gated, CROSS defaults to 1
- Where: `makefile:608`, `makefile:553`, `makefile:557`
- What: `HOST` names the machine a native target must be built on. Those blocks have no cross compiler, just plain gcc or clang, so "gcc exists" says nothing about whether it can produce this target, and an empty `HOSTOK` means the wrong machine. `CROSS` uses `?=` so a command-line `CROSS=` (highest precedence in make) still wins. ARCHID 25 cross-compiles by default with the Raspberry Pi buildroot toolchain, which works from any host, and `CROSS=0` builds natively on the Pi with the apt `arm-linux-gnueabihf-gcc` already set as CC. BSD targets likewise default to clang plus sysroot and `CROSS=0` builds natively.
- Decision: as stated.

### One directory per target and variant under `build/`
- Where: `makefile:145`, `.gitignore`
- What: the binary, its unstripped `DEBUG_` copy and the objects live together, and the agent's runtime side-files (`<exe>.msh`, `.db`, `.log`) stay with their own arch. Switching ARCHID needs no `make clean`, and `-MMD -MP` tracks headers. The layout is documented in [BUILD.md](BUILD.md#build-output-layout). The `.gitignore` was rewritten from the stock Visual Studio template (which carried its own commentary about Azure publish settings, NuGet, bower, RIA/Silverlight and so on) down to what this repo produces.
- Decision: as stated.

### OpenSSL targets build sequentially
- Where: `openssl/libstatic/build/build.sh:48`
- What: `build.sh` once had a `BR_JOBS` fan-out (slot-throttled with `wait -n`, cores split as `nproc / BR_JOBS`, per-target logs replayed in listed order). It was removed on 2026-08-26 because it needed bash 4.3 (macOS ships 3.2), hid live output, and the OpenSSL `make -j$(nproc)` already uses the whole machine. Each target's output is still kept in `$BR_WORK/<target>.log` with a verdict in `<target>.status`.
- Decision: sequential builds, `MAKE_JOBS` only.

### `fetch-toolchains.sh` lives at the repo root
- Where: `fetch-toolchains.sh:4`, `build-env.sh:7`, `build-env.sh:11`
- What: it also wires the two OpenWrt toolchains the agent's own cross-compile needs (ARCHID 28 and 40, and 36) into `../ToolChains/`, so it serves the agent build and not just OpenSSL. `build-env.sh` moved to the repo root for the same reason, while `targets.sh` and `flags.txt` stayed under `openssl/libstatic/build/`. `REPO` derives from the script's own location, not a hardcoded checkout path, and `REPO=...` stages into a different checkout.
- Decision: as stated.

### Windows prerequisites are pinned portable ZIPs
- Where: `openssl/libstatic/build/windows/env.ps1:73`
- What: the prerequisites `Install-BuildRootWindows` can provision (Strawberry Perl and NASM) are pinned the same way the OpenSSL tarball is, with a fixed version, URL and SHA-256, so an unattended install can never pick up a substituted archive. Both are portable ZIPs: no installer, no admin rights, no PATH edits, everything under `$BUILDROOT\tools`. The URLs are literal rather than built from the versions, because Strawberry's release tag (`SP_5380_5361`) does not derive from its version string.
- Decision: as stated.

### Orphan archive directories are kept, not deleted
- Where: `openssl/libstatic/build/orphans.txt:1`, `openssl/libstatic/verify:11`
- What: archive dirs under `openssl/libstatic/` that no `targets.sh` target builds and no makefile ARCHID links are kept as historical artifacts and listed in `orphans.txt`, one per line, so `verify` passes on them while still failing on any new orphan. Retiring an entry means deleting its line and the dir.
- Decision: as stated.

## History and incidents

### 2026-08-24: riscv64 OpenSSL archive was glibc while ARCHID 45 and 145 consume it as musl
- Where: `openssl/libstatic/build/targets.sh:63`, `openssl/libstatic/build/flags.txt:24`, `openssl/libstatic/verify:66`
- What: the `riscv64` case in `targets.sh` used to say "glibc rv64gc (apt)" and build with `riscv64-linux-gnu-gcc` while `linux/riscv64` was already consumed as a musl target by the makefile, a real mismatch and not a one-off contamination. `defined(__GLIBC__)` from that glibc compile left OpenSSL's `ASYNC_POSIX` (`crypto/async/arch/async_posix.h`) compiled in, which musl can never satisfy because it has no `ucontext.h` implementation on any arch. This went undetected until an actual agent link was attempted 2026-08-24 (`undefined reference to getcontext/setcontext/makecontext`). Fixed the same day: the case now builds with the musl.cc toolchain, `flags.txt` gained `no-async` (ASYNC has no user in this codebase and `no-engine` already blocks the only thing that would call it, so disabling it outright is the real fix regardless of libc), and `verify` gained the ucontext column. The full write-up, including why `libucontext` was rejected, is in the [README](openssl/libstatic/build/README.md#the-riscv64-asyncucontext-bug-2026-08-24--read-before-touching-a-musl-target). Source notes: `meshagent-static-musl-direction.md` (private doc).
- Status: fixed
- Since: 2026-08-24

### 2026-08-24: eight per-family OpenSSL workflows replaced by one dispatcher
- Where: `.github/workflows/build-openssl-job.yml:6`, `.github/workflows/build-system-checks.yml:4`
- What: the eight per-family `openssl-*.yml` workflows each carried their own copy of every target's recipe and drifted from `targets.sh` repeatedly. `build-openssl-job.yml` replaced them. `build-system-checks.yml` replaced `verify-openssl-libs.yml` and runs on any change to a build-system file, not just `openssl/libstatic`, because the old path filter listed a single workflow, so edits to the other seven OpenSSL workflows skipped the audit entirely. The record is in the [README](openssl/libstatic/build/README.md#ci-sources-targetssh-directly-2026-08-24).
- Status: done
- Since: 2026-08-24

### 2026-08-24: T-Head/Xuantie riscv64 toolchain built from source and mirrored
- Where: `makefile:176`, `build-env.sh:198`, `fetch-toolchains.sh:151`
- What: the C906 vendor toolchain `riscv64-unknown-linux-musl` has no public upstream URL (the XuanTie repo only ships source, and a prebuilt needs their account-gated OCC portal). It was built from source once and is mirrored at `PTR-inc/meshagent-toolchains/TC`, fetched via `./fetch-toolchains.sh riscv64-xthead`, with the same LFS setup as the BSD sysroots. A miss is not fatal, and ARCH_45 stays bring-your-own. Source notes: `docs/meshagent-riscv64-cross-compile.md` (private doc), and the [README](openssl/libstatic/build/README.md#sources-since-none-of-these-have-one-unified-fetcher) for the rebuild cost.
- Status: done
- Since: 2026-08-24

### ARCHID 45 restored after commit a4ce0e3, ARCHID 145 added
- Where: `makefile:500`, `makefile:521`
- What: commit a4ce0e3 had swapped the original vendor ARCH_45 for a generic rv64gc/glibc build. The vendor target was restored as it was before that commit, and the generic build became the new ARCH_145 (rv64gc, musl, static, reports as 45). See the open issue on ARCHID 45 reproducibility above.
- Status: done

### ARCHID 27 (armhf2) now links the armhf archive through a symlink
- Where: `openssl/libstatic/build/targets.sh:49`
- What: ARCHID 27 (armhf2, the "Raspbian 7 2015" Pi1 target) used to build its OpenSSL archive separately with its own toolchain. That toolchain is gone and unreproducible, and what replaced it was byte-identical to armhf, so `openssl/libstatic/linux/armhf2` is now a symlink to `armhf` instead of a second build, and there is no `armhf2` case in `targets.sh` any more. The agent build itself (ARCHID 27, `KVM=0`) is still a distinct makefile target, it just links the same archive.
- Status: done

### aarch64-cortex-a53 and armada370-hf moved from dd-wrt to musl.cc toolchains
- Where: `openssl/libstatic/build/targets.sh:87`, `build-env.sh:193`
- What: `aarch64-cortex-a53` was previously built with a dd-wrt-archive toolchain. dd-wrt is no longer fetched by `fetch-toolchains.sh` at all, and any note still saying "dd-wrt-archive toolchain" for aarch64-cortex-a53 or linux-armada370-hf is stale (see the [README](openssl/libstatic/build/README.md#buildroot-layout)).
- Status: done

### Xcode SDK extraction hit ENOSPC at 11GB free
- Where: `build-toolchain-archives.sh:96`
- What: an unrestricted extraction of the Xcode .xip needs about 45GB of scratch, and a real run here hit ENOSPC at 11GB free. That, plus the NULLcanary problem, is why `xip-sdk-cpio.py` exists and why `TMPDIR` is moved off `/tmp` on WSL. See the extraction entry under Known limitations.
- Status: worked around

### The earlier pattern-only pbzx patch produced canary SDKs
- Where: `build-env.sh:78`, `fetch-toolchains.sh:259`
- What: an earlier patch to osxcross's `gen_sdk_package_pbzx.sh` restricted the cpio pattern only, which produced SDK tarballs full of `NULLcanary` placeholder headers. `osxcross_patch_pbzx` now undoes that earlier patch and routes through `xip-sdk-cpio.py`, and `fetch-toolchains.sh` quarantines any tarball whose headers are not real rather than building a toolchain that cannot compile `hello.c`.
- Status: fixed

### Windows toolset failures seen on real installs
- Where: `openssl/libstatic/build/windows/env.ps1:117`, `openssl/libstatic/build/windows/env.ps1:104`
- What: a props-only toolset version folder carrying no compiler at all, which the product's own default resolution still pointed at, leaving an unpinned vcvars call with no `cl.exe`. A newest-installed toolset with an incomplete arm64 lib set (present dir, missing `setargv.obj` and CRT) that surfaced as a late `LNK1181: setargv.obj` failure. A VS 2026 (v18) install carrying only versioned v143 toolset packages and no `vcvarsall.bat`. These are why the toolset is always pinned to one verified complete on disk. Source notes: `meshagent-windows-build-prerequisites.md` (private doc), which records the incomplete toolset as 14.51 with 14.44 being the only complete one on that machine.
- Status: worked around

### windows-build.yml before the toolset matrix
- Where: `.github/workflows/windows-build.yml:22`, `.github/workflows/windows-build.yml:28`
- What: the workflow previously ran `msbuild MeshAgent-2022.sln /p:Configuration=Release /p:Platform=<platform>` over a plain `platform: [x64, x86, ARM64]` matrix, with `windows-11-arm` for ARM64 and `windows-2022` otherwise, uploading `build/win-*/*.exe` as `meshagent-windows-<platform>`. It now carries a platform-plus-toolset matrix with the `v145` (VS 2026) legs commented out and `continue-on-error` for them, ready to re-enable.
- Status: done

### `flags.d/` override protocol removed
- Where: `build-env.sh:30`, `openssl/libstatic/build/windows/env.ps1:67`
- What: `flags.txt` is the single source of truth for every builder (`build.sh`, `windows/build.ps1`, CI). There used to be a `flags.d/<name>.txt` override protocol whose loader was pasted into eight workflows and implemented in none of `flags.txt`'s actual consumers, so an override file would have changed CI without changing any local build. Both are gone, and per-target deltas live in `targets.sh` as `T_FLAGS` edits and `T_EXTRA`, or the `Asm` field in `build.ps1`'s `$Targets`. Details in the [README](openssl/libstatic/build/README.md#what-every-script-does).
- Status: done

### Second `verify.sh` with its own musl list deleted
- Where: `openssl/libstatic/verify:11`, `openssl/libstatic/build/build.sh:99`
- What: there used to be two auditors, `openssl/libstatic/verify` and a `build/verify.sh`, each with its own copy of the "which targets are musl" list, and the lists disagreed (both `build/verify.sh` and `build.sh` omitted `riscv64`, which is exactly how the glibc-built archive got past the gate). Both now derive the list from `targets.sh`'s `T_LIBC`, and `build/verify.sh` is deleted. Details in the [README](openssl/libstatic/build/README.md#what-every-script-does).
- Status: done

### state.txt ledgers folded into the README
- Where: `openssl/libstatic/build/README.md`
- What: the per-target provenance ledger used to live in two separate `state.txt` files (`libstatic/state.txt` and the older, stale `libstatic/linux/state.txt`). Both were folded into the README's "Per-target status" section and removed 2026-08-24. Comments in the makefile that cite `state.txt` for the riscv64 archive's provenance refer to that ledger.
- Status: done
- Since: 2026-08-24
