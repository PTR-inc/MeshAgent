# MeshAgent build system for Linux, macOS, FreeBSD and OpenBSD. Windows is built with
# Visual Studio from MeshAgent-2022.sln, not from this file.
#
# 'make list' shows every ARCHID with its toolchain status, and covers dependency setup with
# fetch-toolchains.sh, platform notes and testing with test/test-agent.sh. This header
# only documents the ARCHIDs and the build switches.
#
#   make list                     # every ARCHID with its class, toolchain readiness and how to fetch it
#   make list-archs [FILTER=...]  # the same list, narrowed to one CLASS (generic, openwrt, vendor, bsd or macos)
#   make listflags                # the same list, plus each ARCHID's EXTRA cflags (make list flags also works)
#
# Standard builds. The ARCHID alone picks the OS recipe (linux, macos, freebsd or openbsd), so
# `make ARCHID=6` and `make linux ARCHID=6` do the same thing. BSD hosts need gmake.
#
#   make ARCHID=16      # macOS x86 64 bit (Xcode clang on a Mac, osxcross elsewhere)
#   make ARCHID=29      # macOS ARM 64 bit (the host is detected, nothing extra to pass)
#   make ARCHID=5       # Linux x86 32 bit (glibc 2.24)
#   make ARCHID=6       # Linux x86 64 bit (glibc 2.24)
#   make ARCHID=7       # Linux MIPSEL
#   make ARCHID=9       # Linux ARM 32 bit
#   make ARCHID=19      # Linux x86 32 bit NOKVM (glibc 2.24)
#   make ARCHID=20      # Linux x86 64 bit NOKVM (glibc 2.24)
#   make ARCHID=24      # Linux ARM 32 bit HardFloat (Linaro)
#   make ARCHID=26      # Linux ARM 64 bit (apt glibc, GLIBC_2.34 floor)
#   make ARCHID=32      # Linux ARM 64 bit, legacy-ABI compat (Bootlin glibc 2.31, pinned)
#   make ARCHID=33      # Alpine Linux x86 64 bit (MUSL)
#   make ARCHID=35      # Synology - Linux ARMADA 370 Hardfloat
#   gmake ARCHID=30     # FreeBSD x86 64 bit
#   ARCHID=31           # FreeBSD x86 32 bit is not implemented and will not be, because FreeBSD 15 dropped 32-bit support
#   gmake ARCHID=37     # OpenBSD x86 64 bit
#
# Raspberry Pi Builds:
#
#   make ARCHID=25           # Linux ARM 32 bit HardFloat, cross-compiled (default)
#   make ARCHID=25 CROSS=0   # the same target built natively on the Pi instead
#
# OpenWRT Builds:
#
#   make ARCHID=28          # Linux MIPS24KC/MUSL (OpenWRT)
#   make ARCHID=36          # Linux x86_64/MUSL (OpenWRT)
#   make ARCHID=40          # Linux MIPSEL24KC/MUSL (OpenWRT)
#   make ARCHID=41          # Linux AARCH64/CORTEX-A53/MUSL (OpenWRT)
#
# RISC-V Builds:
#
#   make ARCHID=45          # Linux RISC-V 64 bit, T-Head Xuantie C906 vendor musl toolchain, dynamic
#   make ARCHID=46          # Linux RISC-V 64 bit, generic rv64gc, musl, static, uses SERVER_ARCHID=45
#   make ARCHID=47          # Linux RISC-V 32 bit, generic rv32gc, musl, static, uses SERVER_ARCHID=45
#
# Other builds:
#
#   make ARCHID=60          # Linux SPARC64 (SPARC V9), glibc, dynamic, no vendor hardware, uses SERVER_ARCHID=45
#   make ARCHID=70          # Linux PowerPC64LE (POWER8), glibc, dynamic, no vendor hardware, uses SERVER_ARCHID=45
#
# Some ARCHIDs (47, 60 and 70 above) report a different, classic SERVER_ARCHID to the server,
# set directly in their ARCH_ block, because MeshCentral only knows the classic numbers.
# TODO: generate a list useable by meshcentral repo to use as source ARCHID list
#
# Windows builds (ARCHID 1-4, 21-22, 34, 42-43) use Visual Studio from MeshAgent-2022.sln,
# not this makefile.
#
# Special builds:
#
#   make ARCHID=6 WEBLOG=1 KVM=0      # Linux x86 64 bit with web logging on and KVM off
#   make ARCHID=6 DEBUG=1             # Linux x86 64 bit with debug symbols and automated crash handling
#   make ARCHID=9 GLIBCVER=2.28       # Linux ARM 32 bit pinned to a lower glibc floor than the
#                                            # default Bootlin toolchain. See bootlin_release_for_glibc in env.sh.
#
# Required build switches:
#	ARCHID									Architecture ID
#
#
# Optional build switches:
#	ASAN                     1 = Build with AddressSanitizer                : Default is disabled. The binary gets the suffix _asan, see test/test-agent.sh
#	BSDREL                   OS release for the bsd sysroot and triple, such as 7.8 : Default is the pin in the ARCH_30 or ARCH_37 block (14.3 and 7.9). ARCHID 30 and 37 only
#	CROSS                    0 = Build natively                             : Default is 1 (cross-compile). ARCHID 25, 30, 31 and 37 only
#	DEBUG                    0 = Release, 1 = DEBUG                         : Default is Release
#	DYNAMICTLS               1 = Link OpenSSL dynamically                   : Default is static, from the LINUXSSL, MACSSL and BSDSSL archives
#	FIPS                     1 = FIPS mode (implies DYNAMICTLS and NOWEBRTC) : Default is disabled
#	FSWATCH_DISABLE          1 = Remove fswatcher support                   : Default is fswatcher supported
#	GLIBCVER                 Pin the glibc floor, such as 2.28              : Default is 2.24 for ARCHID 5, 6, 19 and 20, or the shared Bootlin pin 2.31 for the others
#	IPADDR_MONITOR_DISABLE   1 = No IPAddress Monitoring                    : Default is IPAddress Monitoring Enabled
#	IFADDR_DISABLE           1 = Don't use ifaddrs.h                        : Default is use IFADDR
#	ILIBCHAIN_GLOBAL_LOCK    1 = No compiler atomics support                : Default is compiler atomics support present
#	JPEGVER                  e.g. v80 = Use jpeg8 libturbojpeg build        : Default is jpeg62
#	KVM                      1 = KVM Enabled, 0 = KVM Disabled              : Default depends on ARCHID
#	KVM_ALL_TILES            0 = Normal, 1 = All Tiles                      : Default is Normal Tiling Algorithm
#	LEGACY_LD                0 = Standard, 1 = Legacy                       : Default is Standard (CentOS 5.11 requires Legacy)
#	MEMTRACK                 1 = Enable memory tracking                     : Default is disabled
#	NET_SEND_FORCE_FRAGMENT  1 = net.send() fragments sends                 : Default is normal send operation
#	NOILIBSTACKDEBUG         0 = Crash handler in, 1 = out                  : Default is in for DEBUG=1 only, and always out on musl, uClibc, BSD and macOS
#	NOTLS                    1 = TLS Support Compiled Out                   : Default is TLS Support Compiled In
#	NOTURBOJPEG              1 = Don't use Turbo JPEG                       : Default is USE TurboJPEG
#	NOWEBRTC                 1 = WebRTC Compiled Out                        : Default is WebRTC Compiled In
#	OPT                      -O2, -Os or another gcc -O level                : Default is -O2, and -Os for the openwrt and vendor classes. Release only
#	SSL_EXPORTABLE_KEYS      1 = Export SSL Keys for debugging              : Default is DO NOT export SSL keys
#	SSL_TRACE                1 = Enable SSL Tracing                         : Default is tracing disabled
#	TLS_WRITE_TRACE          1 = Enable TLS Send Tracing                    : Default is tracing disabled
#	WARN                     0 = Hide compiler and linker warnings          : Default is 1 (warnings shown, the tree builds clean)
#	WatchDog                 WatchDog timer interval.                       : Default is 180000 (3 minutes, above the 2 minute timeouts of the wmi and exec functions)
#	WEBLOG                   1 = Enable WebLogging Interface                : Default is disabled
#	WEBRTCDEBUG              1 = Enable WebRTC Instrumentation              : Default is disabled
#

# Microstack & Microscript
SOURCES = microstack/ILibAsyncServerSocket.c microstack/ILibAsyncSocket.c microstack/ILibAsyncUDPSocket.c microstack/ILibParsers.c microstack/ILibMulticastSocket.c
SOURCES += microstack/ILibRemoteLogging.c microstack/ILibWebClient.c microstack/ILibWebServer.c microstack/ILibCrypto.c
SOURCES += microstack/ILibSimpleDataStore.c microstack/ILibProcessPipe.c microstack/ILibIPAddressMonitor.c
SOURCES += microscript/duktape.c microscript/duk_module_duktape.c microscript/ILibDuktape_DuplexStream.c microscript/ILibDuktape_Helpers.c
SOURCES += microscript/ILibDuktape_net.c microscript/ILibDuktape_ReadableStream.c microscript/ILibDuktape_WritableStream.c
SOURCES += microscript/ILibDuktapeModSearch.c 
SOURCES += microscript/ILibDuktape_SimpleDataStore.c microscript/ILibDuktape_GenericMarshal.c
SOURCES += microscript/ILibDuktape_fs.c microscript/ILibDuktape_SHA256.c microscript/ILibduktape_EventEmitter.c
SOURCES += microscript/ILibDuktape_EncryptionStream.c microscript/ILibDuktape_Polyfills.c microscript/ILibDuktape_Dgram.c
SOURCES += microscript/ILibDuktape_ScriptContainer.c microscript/ILibDuktape_MemoryStream.c microscript/ILibDuktape_NetworkMonitor.c
SOURCES += microscript/ILibDuktape_ChildProcess.c microscript/ILibDuktape_HttpStream.c microscript/ILibDuktape_Debugger.c
SOURCES += microscript/ILibDuktape_CompressedStream.c meshcore/zlib/adler32.c meshcore/zlib/deflate.c meshcore/zlib/inffast.c meshcore/zlib/inflate.c meshcore/zlib/inftrees.c meshcore/zlib/trees.c meshcore/zlib/zutil.c

SOURCES += $(ADDITIONALSOURCES)

# Mesh Agent core
SOURCES += meshcore/agentcore.c meshconsole/main.c meshcore/meshinfo.c

# Mesh Agent settings
EXENAME = meshagent

# Compiler defaults. A target block below may override CC and STRIP.
CC = gcc
STRIP = strip

# Captured before any XDIR block prepends a cross toolchain's bin/ directory, so ASAN
# builds can restore it and use the host's `as` instead of an old cross-toolchain `as`.
HOSTPATH := $(PATH)

# Kept separate because dependency generation needs the include directories on their own.
INCDIRS = -I. $(OSSLINC) -Ilib-jpeg-turbo/includes -Imicrostack -Imicroscript -Imeshcore -Imeshconsole

# Warnings show by default and the tree builds clean with -Wall, so a new one is visible at once. WARN=0 hides
# them with -w, which gcc, clang and GNU ld all take, so one flag covers both compiling and linking.
WARN ?= 1
WARNFLAGS = $(if $(filter 0,$(WARN)),-w,)

# Compiler and linker flags
# 64-bit file offsets on the 32-bit targets, so stat() works past 2 GB and readdir() does not fail with EOVERFLOW
# on 64-bit directory offsets, which is what every readdirSync() returned empty under qemu-user. No effect on 64-bit.
CFLAGS ?= -std=$(CSTD) -g -Wall -D_POSIX -D_FILE_OFFSET_BITS=64 -DMICROSTACK_PROXY $(CWATCHDOG) -fno-strict-aliasing $(INCDIRS) -DDUK_USE_DEBUGGER_SUPPORT -DDUK_USE_INTERRUPT_COUNTER -DDUK_USE_DEBUGGER_INSPECT -DDUK_USE_DEBUGGER_PAUSE_UNCAUGHT
# Snapshot before any ARCH_<id> block's `CFLAGS +=` runs (that eval happens further down), so
# `make list`/print-cflags-extra can show just the per-ARCHID addition, not the whole line.
BASE_CFLAGS := $(CFLAGS)
LDFLAGS ?= -L. -lpthread -lutil -lm
LDINT =

WatchDog = 180000
KVMMaxTile = 0

# One directory per target and variant under build/, so the binary, its unstripped DEBUG_ copy,
# the objects and the agent's runtime side-files (.msh, .db and .log) stay with their own arch.
# Switching ARCHID therefore needs no `make clean`, and -MMD -MP tracks header changes.
OUTDIR  = build/$(ARCHNAME)$(EXENAME2)$(if $(DEBUG),-debug)
OUTBIN  = $(OUTDIR)/$(EXENAME)_$(ARCHNAME)$(EXENAME2)
OBJDIR  = $(OUTDIR)/obj
OBJECTS = $(patsubst %.c,$(OBJDIR)/%.o,$(SOURCES))

ifeq ($(FIPS),1)
DYNAMICTLS = 1
NOWEBRTC = 1
endif

# Cross-compiler roots. The version-less names are symlinks created by ./fetch-toolchains.sh,
# so bumping a toolchain does not also mean editing this makefile. The pinned Bootlin and
# musl.cc paths match the toolchains the OpenSSL archives were built with.
PATH_X86 = ../ToolChains/x86-i686-glibc/
PATH_X86_64 = ../ToolChains/x86-64-glibc/
PATH_MIPS = ../ToolChains/mips32el-uclibc/
PATH_MIPS24KC = ../ToolChains/toolchain-mips_24kc_musl/
PATH_MIPSEL24KC = ../ToolChains/toolchain-mipsel_24kc_musl/
PATH_OPENWRT_X86_64 = ../ToolChains/toolchain-x86_64_musl/
PATH_ARM5 = ../ToolChains/armv5-eabi-glibc/
PATH_LINARO = ../ToolChains/armv7-eabihf-glibc/
PATH_AARCH64 = ../ToolChains/aarch64-glibc/
PATH_SPARC64 = ../ToolChains/sparc64-glibc/
PATH_POWERPC64LE = ../ToolChains/powerpc64le-glibc/
PATH_AARCH64_CORTEXA53 = ../ToolChains/toolchain-aarch64_generic_musl/
PATH_ARMADA370_HF = ../ToolChains/arm-linux-musleabihf-cross/
PATH_X86_64_MUSL = ../ToolChains/x86_64-linux-musl-cross/
PATH_RPI = ../ToolChains/arm-rpi-4.9.3-linux-gnueabihf/
# Vendor T-Head Xuantie C906 musl SDK. It has no public upstream URL, so it was built from
# source once and mirrored at PTR-inc/meshagent-toolchains/TC, which is what
# ./fetch-toolchains.sh riscv64-xthead downloads. See ARCH_45 below.
PATH_RISCV64 = ../ToolChains/riscv64-linux-musl-x86_64/
PATH_RISCV64_MUSL = ../ToolChains/riscv64-linux-musl-cross/
PATH_RISCV32_MUSL = ../ToolChains/riscv32-linux-musl-cross/

# Zig's bundled Clang, for CCOVERRIDE - see its own doc comment above the target table. Zig's own
# layout has no bin/ subdirectory (the binary sits at $(PATH_ZIG)zig directly, unlike a normal
# cross toolchain), so CCOVERRIDE lines reference it as $(PATH_ZIG)zig, not $(PATH_ZIG)bin/zig.
PATH_ZIG = ../ToolChains/zig/

# ----------------------------------------------------------------------------
# Target table, one block per ARCHID, sorted. ARCHNAME is the only required field.
#   ARCHNAME  binary suffix, and also the jpeg archive directory
#   OSSLTARGET the openssl/build/targets.sh target whose prefix openssl/$(OSSLVER)/<target>/ this links
#   OSSLVER   optional, pins this target to another installed OpenSSL series than openssl/VERSION
#   CLASS     one of generic, openwrt, vendor, native, bsd or macos (used by make list-archs)
#   XDIR      SDK root, from which PATH, STAGING_DIR, CC, STRIP and INCDIRS are derived
#   XPREFIX   gcc and strip prefix inside $(XDIR)bin/. XSTRIP overrides it for strip only
#   XTRIPLE   triple subdirectory added to PATH. XSYSROOT=1 also passes --sysroot=$(XDIR)
#   CCOVERRIDE  replaces the whole $(XDIR)bin/$(XPREFIX)gcc[...] rule wholesale when set - the
#             compiler command verbatim (may be multi-word, e.g. a `zig cc -target ...` line;
#             CCBIN's $(firstword $(CC)) already handles that for the toolchain-presence check).
#             XSYSROOT's implicit --sysroot=$(XDIR) is NOT applied on top - bake --sysroot into
#             CCOVERRIDE itself if the override needs one. XDIR/XPREFIX/XTRIPLE keep governing
#             STRIP/PATH/INCDIRS as usual, so a real toolchain directory can stay in place for
#             those while only the compiler swaps out - point XDIR at a directory with no real
#             toolchain only if STRIP is not needed either (or is separately overridden via
#             XSTRIP with its own real path). A zig cc override specifically needs
#             -Wno-date-time added (zig's clang errors on ScriptContainer.c's __TIME__/__DATE__
#             use by default; neither the vendor toolchains nor upstream clang/gcc do) - see
#             ARCH_45's CCOVERRIDE for a worked example, including the CFLAGS reasons above.
#             `zig cc` also embeds DWARF debug info by default even with no -g flag on the
#             command line (unlike plain clang/gcc), which is why a zig-built ARCHID's DEBUG_
#             binary (see STRIP_AND_SYMBOLCP below) now resolves real file/line frames inside
#             OpenSSL too - deliberately left on, since $(STRIP) below already removes it from
#             the shipped OUTBIN and only the pre-strip debug copy carries the extra size.
#   BSDREL    bsd class only, the OS release used for the default cross-build triple and sysroot
#   TUNE      the -march, -mcpu and -mabi flags for this silicon
#   HARDEN    one of full (the default), basic or none
#   NOLDHARDEN 1 = old binutils, so link without -z noexecstack, -z relro and -z now
#   KVM LMS   feature defaults
# ----------------------------------------------------------------------------

# Bootlin x86-i686 glibc 2.24 (pinned), its oldest published x86 release (stable-2017.05),
# rather than host gcc -m32, because apt toolchains floor at GLIBC_2.34. A glibc 2.17 floor
# would be lower still but has no working toolchain source.
define ARCH_5
  ARCHNAME = x86
  OSSLTARGET = linux-i686-glibc
  CLASS    = generic
  XDIR     = $(PATH_X86)
  XPREFIX  = i686-linux-
  XTRIPLE  = i686-buildroot-linux-gnu
  FETCH    = bootlin-x86
  # 2026-08-30: CC moved to zig via CCOVERRIDE - same glibc 2.24 floor as the Bootlin toolchain
  # it replaces (linux-i686-glibc's own OSSLTARGET pin). XDIR/XPREFIX/XTRIPLE/FETCH untouched, so
  # the Bootlin toolchain stays in place for STRIP.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target x86-linux-gnu.2.24 -Wno-date-time
  # zig's bundled lld does not resolve -l:lib-jpeg-turbo/.../libturbojpeg.a (a slash-containing
  # name passed to the GNU-ld/gold -l: exact-filename extension) the way GNU ld does - "unable to
  # find library". LEGACY_LD's plain-relative-path linking already exists for exactly this class
  # of linker difference and works identically well with lld.
  LEGACY_LD = 1
  KVM      = 1
  LMS      = 1
endef

# Bootlin x86-64-core-i7 glibc 2.24 (pinned), the same floor fix as ARCH_5.
# TUNE resets -march=core-i7 back to generic because this target must not inherit it.
define ARCH_6
  ARCHNAME = x86-64
  OSSLTARGET = linux-x86_64-glibc
  CLASS    = generic
  XDIR     = $(PATH_X86_64)
  XPREFIX  = x86_64-linux-
  XTRIPLE  = x86_64-buildroot-linux-gnu
  FETCH    = bootlin-x86-64
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same glibc 2.24 floor. TUNE dropped, not just
  # replaced: zig's -march=/-mtune= route through a -mcpu= lookup with no 'x86-64'/'generic'
  # entries ("unknown target CPU"), unlike real clang/gcc - and zig's default x86_64 baseline is
  # already generic, so the override was only ever needed for the old core-i7-named toolchain.
  # Previously: TUNE = -march=x86-64 -mtune=generic.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target x86_64-linux-gnu.2.24 -Wno-date-time
  # See ARCH_5's comment: zig's lld needs LEGACY_LD's plain-relative-path libjpeg linking.
  LEGACY_LD = 1
  KVM      = 1
  LMS      = 1
endef

# mipsel on uClibc (Bootlin mips32el, pinned). The linux/mips directory is big-endian,
# this target uses linux/mipsel. The toolchain matches the uClibc family the OpenSSL
# archive was built with.
define ARCH_7
  ARCHNAME = mips
  OSSLTARGET = linux-mips32r1el-musl
  CLASS    = vendor
  XDIR     = $(PATH_MIPS)
  XPREFIX  = mipsel-linux-
  XTRIPLE  = mipsel-buildroot-linux-uclibc
  FETCH    = bootlin-mipsel-uclibc
  HARDEN   = basic
  NOLDHARDEN = 1
  CFLAGS  += -DBADMATH
  # 2026-08-31: dynamic uClibc -> static musl. The old binary needed a compatible uClibc-ng on the
  # device itself, which nothing here can guarantee, so it now carries its own libc. zig defaults
  # this triple to mips32r2, so -mcpu=mips32 pins the MIPS32r1 baseline the target exists for.
  # The Bootlin uClibc toolchain stays in XDIR/XPREFIX/XTRIPLE/FETCH only to supply STRIP, the
  # same way ARCH_28 and ARCH_40 keep their OpenWrt toolchains - nothing links uClibc any more.
  # XTRIPLE still reading uclibc is what keeps NOILIBSTACKDEBUG off, which musl needs too.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target mipsel-linux-musleabi -mcpu=mips32 -Wno-date-time
  LDINT    = -static
  IPADDR_MONITOR_DISABLE = 1
  IFADDR_DISABLE = 1
  KVM      = 0
  LMS      = 0
endef

# ARMv5TE armel using Bootlin armv5-eabi glibc 2.31 (pinned) rather than apt's gcc, whose
# floor is GLIBC_2.34. Its binutils 2.33.1 handles hardening fine, so HARDEN=basic.
define ARCH_9
  ARCHNAME = arm
  OSSLTARGET = linux-armv5sf-glibc
  CLASS    = generic
  XDIR     = $(PATH_ARM5)
  XPREFIX  = arm-linux-
  XTRIPLE  = arm-buildroot-linux-gnueabi
  FETCH    = bootlin-armv5
  HARDEN   = basic
  CFLAGS  += -D_NOFSWATCHER
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same glibc 2.31 floor.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target arm-linux-gnueabi.2.31 -Wno-date-time
  KVM      = 0
  LMS      = 0
endef

# macOS uses Xcode clang on a Mac and osxcross when cross-built from Linux (see the CLASS=macos
# block below). The 10.15 floor lets clang resolve the @available check in mac_kvm.c statically,
# because osxcross ships no compiler-rt for ___isPlatformVersionAtLeast.
define ARCH_16
  ARCHNAME = osx-x86-64
  OSSLTARGET = macos-x86_64
  CLASS    = macos
  OSXARCH  = x86_64
  MACOSARCH = -mmacosx-version-min=10.15
  KVM      = 1
  LMS      = 0
  HOST     = darwin
  FETCH    = osxcross
endef

# Same toolchain as ARCH_5, see there.
define ARCH_19
  ARCHNAME = x86
  OSSLTARGET = linux-i686-glibc
  CLASS    = generic
  XDIR     = $(PATH_X86)
  XPREFIX  = i686-linux-
  XTRIPLE  = i686-buildroot-linux-gnu
  FETCH    = bootlin-x86
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same glibc 2.24 floor as ARCH_5.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target x86-linux-gnu.2.24 -Wno-date-time
  EXENAME2 = _nokvm
  KVM      = 0
  LMS      = 1
endef

# Same toolchain as ARCH_6, see there.
define ARCH_20
  ARCHNAME = x86-64
  OSSLTARGET = linux-x86_64-glibc
  CLASS    = generic
  XDIR     = $(PATH_X86_64)
  XPREFIX  = x86_64-linux-
  XTRIPLE  = x86_64-buildroot-linux-gnu
  FETCH    = bootlin-x86-64
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same reasoning and same glibc 2.24 floor as
  # ARCH_6. Previously: TUNE = -march=x86-64 -mtune=generic.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target x86_64-linux-gnu.2.24 -Wno-date-time
  EXENAME2 = _nokvm
  KVM      = 0
  LMS      = 1
endef

# ARMv7 hardfloat using Bootlin armv7-eabihf glibc 2.31 (pinned) rather than apt's gcc,
# whose floor is GLIBC_2.34.
define ARCH_24
  ARCHNAME = arm-linaro
  OSSLTARGET = linux-armv7hf-glibc
  CLASS    = generic
  XDIR     = $(PATH_LINARO)
  XPREFIX  = arm-linux-
  XTRIPLE  = arm-buildroot-linux-gnueabihf
  FETCH    = bootlin-armv7hf
  HARDEN   = basic
  CFLAGS  += -D_NOFSWATCHER
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same glibc 2.31 floor.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target arm-linux-gnueabihf.2.31 -Wno-date-time
  KVM      = 0
  LMS      = 0
endef

# Cross-compiles by default. CROSS=0 builds natively on the Pi instead.
define ARCH_25
  ARCHNAME = armhf
  OSSLTARGET = linux-armv6hf-glibc
  CLASS    = generic
  CC       = arm-linux-gnueabihf-gcc
  STRIP    = arm-linux-gnueabihf-strip
  HARDEN   = none
  NOLDHARDEN = 1
  KVM      = 1
  LMS      = 0
  APTPKG   = gcc-arm-linux-gnueabihf
endef

# apt gcc-aarch64-linux-gnu is a real cross toolchain, so this target is not HOST-gated and
# builds from any machine.
define ARCH_26
  ARCHNAME = arm64
  OSSLTARGET = linux-aarch64-glibc
  CLASS    = generic
  # 2026-08-30: CC moved to zig directly, not via the CCOVERRIDE indirection every other switched
  # ARCH block uses: this one sets CC without going through XDIR/XPREFIX, and an inline
  # CCOVERRIDE-conditional CC line does not work placed in the same define block as CCOVERRIDE's
  # own assignment - a define block's whole text expands in one pass when eval'd (standard
  # recursive-variable behaviour), so CC's reference would resolve before CCOVERRIDE's own line
  # in the same block took effect, always empty (worse: writing that literal construct out again
  # here as an example, even inside a comment, was tried and caused a genuine Make "Recursive
  # variable references itself" parse error - a comment inside a define block is not safe from
  # expansion the way an ordinary makefile comment is, so avoid writing eval/override syntax
  # in prose here at all). The shared ifdef-XDIR rule avoids the whole problem because it lives
  # outside any eval'd block, deferred until real use - not an option for a block that sets its
  # own CC directly.
  # Pinned to glibc 2.40 on request, which keeps this ARCHID the "general/newest" aarch64 target
  # and widens the gap from ARCH_32's older 2.31 pin - see targets.sh's own comment on why one
  # archive serves both. The pin is a ceiling, not a floor: it lets the linker pick each symbol's
  # newest version up to 2.40, so the binary now needs GLIBC_2.38 where the unpinned build needed
  # 2.29. That is Ubuntu 24.04 or Debian 13 and newer, and it excludes Debian 12 (2.36), Ubuntu
  # 22.04 (2.35) and RHEL 9 (2.34). The 2.38 requirement comes from __isoc23_sscanf,
  # __isoc23_strtoull and fmod, which glibc versioned at 2.38.
  # Previously: -target aarch64-linux-gnu (unpinned), and before that CC = aarch64-linux-gnu-gcc.
  CC       = $(PATH_ZIG)zig cc -target aarch64-linux-gnu.2.40 -Wno-date-time
  # See ARCH_5's comment: zig's lld needs LEGACY_LD's plain-relative-path libjpeg linking.
  LEGACY_LD = 1
  STRIP    = aarch64-linux-gnu-strip
  HARDEN   = none
  KVM      = 1
  LMS      = 0
  APTPKG   = gcc-aarch64-linux-gnu
endef

define ARCH_28
  ARCHNAME = mips24kc
  OSSLTARGET = linux-mips32r2eb-musl
  CLASS    = openwrt
  XDIR     = $(PATH_MIPS24KC)
  XPREFIX  = mips-openwrt-linux-musl-
  XTRIPLE  = mips-openwrt-linux-musl
  XSYSROOT = 1
  FETCH    = openwrt-mips24kc
  HARDEN   = basic
  NOLDHARDEN = 1
  CFLAGS  += -DBADMATH
  # 2026-08-30: CC moved to zig via CCOVERRIDE. XSYSROOT's implicit --sysroot=$(XDIR) does not
  # apply on top of an override (see CCOVERRIDE's own doc comment) - not needed anyway, zig
  # bundles its own musl headers for this target, same as every other zig-switched musl OpenSSL
  # target this session (no --sysroot was needed for any of them either). soft-float musleabi:
  # OpenWrt's mips24kc toolchain defaults to soft-float, confirmed via -Q --help=target when this
  # was first established on the OpenSSL side. XDIR/XPREFIX/XTRIPLE/FETCH untouched, so the
  # OpenWrt toolchain stays in place for STRIP.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target mips-linux-musleabi -Wno-date-time
  KVM      = 0
  LMS      = 0
endef

# No -target here, because it overrides the triple the osxcross wrapper derives from argv0 and
# silently breaks its ld64 selection. -arch on a Mac and the prefixed clang under osxcross
# already fix the target, so the version floor is all that is left to state.
define ARCH_29
  ARCHNAME = osx-arm-64
  OSSLTARGET = macos-arm64
  CLASS    = macos
  OSXARCH  = arm64
  MACOSARCH = -mmacosx-version-min=11.0
  KVM      = 1
  LMS      = 0
  HOST     = darwin
  FETCH    = osxcross
endef

define ARCH_30
  ARCHNAME = freebsd_x86-64
  OSSLTARGET = freebsd-x86_64
  CLASS    = bsd
  CC       = clang
  CFLAGS  += -I/usr/local/include
  KVM      = 0
  LMS      = 0
  HOST     = freebsd
  BSDREL   = 14.3
endef

# Legacy-ABI arm64 compatibility target using Bootlin aarch64--glibc--stable (2.31, pinned),
# which matches the toolchain the OpenSSL archive was built with.
define ARCH_32
  ARCHNAME = aarch64
  OSSLTARGET = linux-aarch64-glibc
  CLASS    = generic
  XDIR     = $(PATH_AARCH64)
  XPREFIX  = aarch64-linux-
  XTRIPLE  = aarch64-buildroot-linux-gnu
  FETCH    = bootlin-aarch64
  HARDEN   = basic
  # 2026-08-30: CC moved to zig via CCOVERRIDE, glibc 2.31 floor pinned (unlike ARCH_26's own
  # linux-aarch64-glibc row, deliberately - see its comment for why).
  CCOVERRIDE = $(PATH_ZIG)zig cc -target aarch64-linux-gnu.2.31 -Wno-date-time
  # See ARCH_5's comment: zig's lld needs LEGACY_LD's plain-relative-path libjpeg linking.
  LEGACY_LD = 1
  KVM      = 1
  LMS      = 0
endef

# musl.cc x86_64-linux-musl-cross is a standalone toolchain with its own kernel UAPI headers.
# The host's musl-gcc is not usable because a glibc multiarch host has no plain
# /usr/include/asm and its headers conflict with glibc's own.
define ARCH_33
  ARCHNAME = alpine-x86-64
  OSSLTARGET = linux-x86_64-musl
  CLASS    = generic
  XDIR     = $(PATH_X86_64_MUSL)
  XPREFIX  = x86_64-linux-musl-
  XTRIPLE  = x86_64-linux-musl
  FETCH    = muslcc-x86_64
  # 2026-08-30: CC moved to zig via CCOVERRIDE.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target x86_64-linux-musl -Wno-date-time
  KVM      = 0
  LMS      = 1
endef

# musl.cc arm-linux-musleabihf, matching the toolchain the OpenSSL archive was built with.
# Previously the agent was glibc and could not link against the musl archive at all.
#
define ARCH_35
  ARCHNAME = linux-armada370-hf
  OSSLTARGET = linux-armv7hf-musl
  CLASS    = vendor
  XDIR     = $(PATH_ARMADA370_HF)
  XPREFIX  = arm-linux-musleabihf-
  XTRIPLE  = arm-linux-musleabihf
  FETCH    = muslcc-armhf
  HARDEN   = basic
  # 2026-08-30: CC moved to zig via CCOVERRIDE. TUNE dropped entirely, not just replaced: the
  # -linux-musleabihf triple already encodes hardfloat, and zig's -march= routes through a
  # -mcpu= lookup with no 'armv7-a' entry (same class of error as x86_64/riscv above) - confirmed
  # dropping it entirely still compiles clean. Previously:
  # TUNE = -march=armv7-a -marm -mfpu=vfp -mfloat-abi=hard.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target arm-linux-musleabihf -Wno-date-time
  KVM      = 0
  LMS      = 0
  # Real hardware here runs vendor glibc firmware, not a musl userland, so unlike the OpenWrt
  # musl ARCHIDs there is no musl loader on the device. Linked static, or the binary cannot
  # find /lib/ld-musl-armhf.so.1 and will not start at all.
  LDINT    = -static
endef

define ARCH_36
  ARCHNAME = openwrt_x86_64
  OSSLTARGET = linux-x86_64-musl
  CLASS    = openwrt
  XDIR     = $(PATH_OPENWRT_X86_64)
  XPREFIX  = x86_64-openwrt-linux-musl-
  XTRIPLE  = x86_64-openwrt-linux-musl
  XSYSROOT = 1
  FETCH    = openwrt-openwrt_x86_64
  HARDEN   = basic
  CFLAGS  += -DBADMATH
  # 2026-08-30: CC moved to zig via CCOVERRIDE - see ARCH_28's comment on why XSYSROOT's implicit
  # --sysroot is neither applied nor needed here.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target x86_64-linux-musl -Wno-date-time
  KVM      = 0
  LMS      = 0
endef

define ARCH_37
  ARCHNAME = openbsd_x86-64
  OSSLTARGET = openbsd-x86_64
  CLASS    = bsd
  CC       = clang
  CFLAGS  += -I/usr/local/include
  KVM      = 0
  LMS      = 0
  HOST     = openbsd
  BSDREL   = 7.9
endef

define ARCH_40
  ARCHNAME = mipsel24kc
  OSSLTARGET = linux-mips32r2el-musl
  CLASS    = openwrt
  XDIR     = $(PATH_MIPSEL24KC)
  XPREFIX  = mipsel-openwrt-linux-musl-
  XTRIPLE  = mips-openwrt-linux-musl
  XSYSROOT = 1
  FETCH    = openwrt-mipsel24kc
  HARDEN   = basic
  CFLAGS  += -DBADMATH
  # 2026-08-30: CC moved to zig via CCOVERRIDE - see ARCH_28's comment (soft-float, and why
  # XSYSROOT's implicit --sysroot is neither applied nor needed here).
  CCOVERRIDE = $(PATH_ZIG)zig cc -target mipsel-linux-musleabi -Wno-date-time
  KVM      = 0
  LMS      = 0
endef

define ARCH_41
  ARCHNAME = aarch64-cortex-a53
  OSSLTARGET = linux-aarch64-musl
  CLASS    = openwrt
  XDIR     = $(PATH_AARCH64_CORTEXA53)
  XPREFIX  = aarch64-openwrt-linux-
  XTRIPLE  = aarch64-openwrt-linux-musl
  HARDEN   = basic
  FETCH    = openwrt-aarch64-cortex-a53
  # 2026-08-30: CC moved to zig via CCOVERRIDE.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target aarch64-linux-musl -Wno-date-time
  KVM      = 0
  LMS      = 0
endef

# The original ARCHID=45 target, restored as it was before commit a4ce0e3 swapped it for a
# generic build. It needs the T-Head Xuantie C906 vendor musl
# SDK at PATH_RISCV64. Its OpenSSL archive is the generic rv64gc one.
define ARCH_45
  ARCHNAME = riscv64
  OSSLTARGET = linux-riscv64-musl
  CLASS    = vendor
  XDIR     = $(PATH_RISCV64)
  XPREFIX  = riscv64-unknown-linux-musl-
  XTRIPLE  = riscv64-unknown-linux-musl
  # 2026-08-30: CC moved to zig via CCOVERRIDE (see its own doc comment above the target table).
  # Investigated reaching the T-Head extension set through zig first: LLVM's riscv64 backend has
  # no -mcpu= alias for c906fdv (only baseline_rv32/baseline_rv64/generic/sifive-*/etc.), and
  # while the vendor gcc's 20 individual extensions do parse one at a time via
  # -Xclang -target-feature -Xclang +xtheadXXX, 4 of them - including the flagship xtheadvector -
  # silently downgrade to "ignoring feature" when combined (LLVM 20.1.2/21.1.0/22.1.8 alike).
  # Nothing in this codebase has a correctness dependency on any of it either way: OpenSSL 1.1.1
  # ships zero RISC-V asm, and the only RISC-V-conditional code here is Duktape's portable
  # __riscv/__riscv_xlen check. So this now matches ARCH_46 exactly rather than attempt a partial,
  # 16-of-20 vendor-extension reconstruction for unmeasured benefit - see meshagent-zig-toolchain.md.
  # -march=rv64gc is dropped (not just replaced) because zig's -target riscv64-linux-musl already
  # defaults to the RV64GC feature set, and zig's own -march= is not clang's - it resolves to a
  # -mcpu= lookup with no 'rv64gc' entry ("unknown CPU: 'rv64gc'"), unlike real clang/gcc.
  # XDIR/XPREFIX/XTRIPLE/FETCH are untouched - the vendor toolchain stays in place for STRIP,
  # since CCOVERRIDE only replaces CC.
  # Previously: TUNE = -mcpu=c906fdv -mcmodel=medany -mabi=lp64d (on this toolchain - gcc 14.1.1
  # from the XuanTie fork - -mcpu=c906fdv alone expands to the full T-Head extension set; the
  # original vendor gcc 10.2.0 spelling -march=rv64imafdcv0p7xthead is rejected here because
  # 'xthead' is no longer a single extension name).
  # -Wno-date-time: zig's clang treats -Wdate-time as an error by default (a reproducibility
  # guard neither upstream clang nor gcc enable on their own), which the vendor gcc never hit.
  # microscript/ILibDuktape_ScriptContainer.c's __TIME__/__DATE__ compileTime string trips it -
  # this will hit any future CCOVERRIDE'd ARCH_<id> block too, not just this one.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target riscv64-linux-musl -Wno-date-time
  TUNE     = -mabi=lp64d
  HARDEN   = basic
  KVM      = 0
  LMS      = 0
  LDINT    = -static
  FETCH    = riscv64-xthead
endef

# Generic RISC-V64 (rv64gc, no vendor extensions), musl, static - same reason as ARCH_35: real
# hardware has no musl loader built in.
define ARCH_46
  ARCHNAME = riscv64-generic
  OSSLTARGET = linux-riscv64-musl
  CLASS    = generic
  XDIR     = $(PATH_RISCV64_MUSL)
  XPREFIX  = riscv64-linux-musl-
  XTRIPLE  = riscv64-linux-musl
  HARDEN   = basic
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same as ARCH_45 (see its own comment for the
  # full riscv64/zig writeup, including why -march=rv64gc is dropped rather than kept - zig's
  # target already defaults to the RV64GC feature set, and its -march= isn't clang's).
  # Previously: TUNE = -march=rv64gc -mabi=lp64d.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target riscv64-linux-musl -Wno-date-time
  TUNE     = -mabi=lp64d
  KVM      = 0
  LMS      = 0
  LDINT    = -static
  FETCH    = muslcc-riscv64
endef

# Generic RISC-V32 (rv32gc), musl, static - same reasoning as ARCH_46, 32-bit instead of 64.
# OpenSSL 1.1.1 has no riscv32 Configure target at all (only linux64-riscv64/BSD-riscv64 exist),
# so this Configures as linux-generic32 like arm/arm-linaro/pogo - no asm regardless of flags.
#
# On direct request this reports SERVER_ARCHID=45 (the classic RISC-V64 identity), even though 45
# is really a 64-bit board and this one is 32-bit. This was pointed out and approved before it was
# built.
define ARCH_47
  ARCHNAME = riscv32-generic
  OSSLTARGET = linux-riscv32-musl
  CLASS    = generic
  XDIR     = $(PATH_RISCV32_MUSL)
  XPREFIX  = riscv32-linux-musl-
  XTRIPLE  = riscv32-linux-musl
  HARDEN   = basic
  # 2026-08-30: CC moved to zig via CCOVERRIDE - same -march=rv32gc-dropped reasoning as
  # ARCH_46/ARCH_45 (confirmed separately for riscv32: 'unknown CPU: rv32gc').
  # Previously: TUNE = -march=rv32gc -mabi=ilp32d.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target riscv32-linux-musl -Wno-date-time
  TUNE     = -mabi=ilp32d
  KVM      = 0
  LMS      = 0
  LDINT    = -static
  FETCH    = muslcc-riscv32
  SERVER_ARCHID = 45
endef

# Generic SPARC64 (SPARC V9), glibc, dynamic - no vendor hardware target, built purely as a
# reference/CI target the same way riscv32-generic (47) is. Reports itself to the server as 45
# (the classic RISC-V64 identity), the same SERVER_ARCHID override ARCH_47 uses, on direct request.
# No real hardware relationship to 45 exists; this is only reusing an already-known agent identity.
define ARCH_60
  ARCHNAME = sparc64-generic
  OSSLTARGET = linux-sparc64-glibc
  CLASS    = generic
  XDIR     = $(PATH_SPARC64)
  XPREFIX  = sparc64-linux-
  XTRIPLE  = sparc64-linux-gnu
  HARDEN   = basic
  KVM      = 0
  LMS      = 0
  FETCH    = bootlin-sparc64
  SERVER_ARCHID = 45
endef

# Generic PowerPC64LE (POWER8), glibc, dynamic - same reasoning as ARCH_60: no vendor hardware,
# built as a reference/CI target, and reports SERVER_ARCHID=45 on the same on-purpose basis.
# Unlike sparc64, OpenSSL's ppc64_asm modules are real and maintained, so asm stays enabled.
define ARCH_70
  ARCHNAME = powerpc64le-generic
  OSSLTARGET = linux-ppc64le-glibc
  CLASS    = generic
  XDIR     = $(PATH_POWERPC64LE)
  XPREFIX  = powerpc64le-linux-
  XTRIPLE  = powerpc64le-linux-gnu
  HARDEN   = basic
  # 2026-08-30: CC moved to zig via CCOVERRIDE, same glibc 2.31 floor.
  CCOVERRIDE = $(PATH_ZIG)zig cc -target powerpc64le-linux-gnu.2.31 -Wno-date-time
  KVM      = 0
  LMS      = 0
  FETCH    = bootlin-powerpc64le
  SERVER_ARCHID = 45
endef

$(eval $(ARCH_$(ARCHID)))

# SERVER_ARCHID is the id reported to the server (MESH_AGENTID). It defaults to ARCHID itself; an
# ARCH_ block sets it directly when the target should report a different, classic id instead (see
# ARCH_47, ARCH_60, ARCH_70) - ?= leaves that override in place.
SERVER_ARCHID ?= $(ARCHID)
# These goals do not need a target selected.
ifeq ($(filter $(MAKECMDGOALS),list list-archs listflags list-flags flags print-archids clean cleanbin),)
$(if $(ARCHNAME),,$(error unknown or missing ARCHID '$(ARCHID)' - run 'make list'))
endif

# CROSS defaults to 1 (cross-compile). Pass CROSS=0 to build natively instead.
# Assigned with ?= so a command-line CROSS= still wins.
CROSS ?= 1

# ARCHID 25 cross-compiles by default with the Raspberry Pi buildroot toolchain, which works from
# any host. CROSS=0 builds natively on the Pi instead, using the plain apt
# arm-linux-gnueabihf-gcc already set as CC in the ARCH_25 block above.
ifeq ($(ARCHID),25)
ifneq ($(CROSS),0)
CC = $(PATH_RPI)bin/arm-linux-gnueabihf-gcc --sysroot=$(PATH_RPI)arm-linux-gnueabihf/sysroot
STRIP = $(PATH_RPI)bin/arm-linux-gnueabihf-strip
HOST =
endif
endif

# BSD targets cross-compile by default with clang and a sysroot, and CROSS=0 builds natively.
# SYSROOT defaults to the tree shared with env.sh and fetch-toolchains.sh. Assigned with := so
# HOST and BUILDROOT are captured before the cross guard below clears HOST.
BSDHOST := $(HOST)
BSDTRIPLE := x86_64-unknown-$(BSDHOST)$(BSDREL)
BUILDROOT ?= /opt/buildroot
ifeq ($(CLASS),bsd)
ifneq ($(CROSS),0)
SYSROOT ?= $(BUILDROOT)/sysroots/$(BSDHOST)-$(BSDREL)
CC = clang --target=$(BSDTRIPLE) --sysroot=$(SYSROOT) -fuse-ld=lld -Wno-unused-command-line-argument
HOST =
endif
endif

# ---- derived from the target block above ----------------------------------
# openssl/VERSION is the default. An ARCH_ block may set OSSLVER to pin one target to another
# installed series, for a staged migration. `make ARCHID=n OSSLVER=3.x.y` beats both, but an
# OSSLVER environment variable only beats the file, never a block, as make's own rules go.
# The per-target include dir comes first so its generated opensslconf.h is the one found.
OSSLVER ?= $(shell tr -d '[:space:]' < openssl/VERSION)
OSSLPREFIX = openssl/$(OSSLVER)/$(OSSLTARGET)
OSSLINC = -I$(OSSLPREFIX)/include -Iopenssl/$(OSSLVER)/include

# Optional glibc floor pin, for example `make ARCHID=9 GLIBCVER=2.28`. It repoints XDIR at the
# version-specific alias that fetch-toolchains.sh creates, for the Bootlin glibc targets only.
# ARCHID 5, 6, 19 and 20 default to 2.24 but can still opt into a newer pin here.
BOOTLIN_GLIBC_FETCH = bootlin-x86 bootlin-x86-64 bootlin-armv5 bootlin-armv7hf bootlin-aarch64
ifdef GLIBCVER
ifneq ($(filter $(FETCH),$(BOOTLIN_GLIBC_FETCH)),)
XDIR := $(patsubst %/,%-$(GLIBCVER)/,$(XDIR))
else
$(error GLIBCVER is not supported for ARCHID=$(ARCHID) (FETCH=$(FETCH)) - only $(BOOTLIN_GLIBC_FETCH))
endif
endif

ifdef XDIR
export PATH := $(XDIR)bin:$(if $(XTRIPLE),$(XDIR)$(XTRIPLE)/bin:,)$(PATH)
export STAGING_DIR := $(XDIR)
# CCOVERRIDE replaces this rule wholesale - see its own doc comment above the target table.
# STRIP/PATH/INCDIRS are untouched by it, so XDIR can still point at a real toolchain directory
# for those while only the compiler comes from CCOVERRIDE.
CC = $(if $(CCOVERRIDE),$(CCOVERRIDE),$(XDIR)bin/$(XPREFIX)gcc$(if $(XSYSROOT), --sysroot=$(XDIR),))
STRIP = $(XDIR)bin/$(if $(XSTRIP),$(XSTRIP),$(XPREFIX))strip
INCDIRS += -I$(XDIR)include
endif

# ---- toolchain availability -------------------------------------------------
# FETCH is the ./fetch-toolchains.sh component that installs this target's compiler, and APTPKG
# is the apt package that does. When neither is set you bring your own compiler (see README).
CCBIN = $(firstword $(CC))

# HOST names the machine a native target must be built on. Those blocks have no cross compiler,
# just plain gcc or clang, so the compiler existing says nothing about whether it can produce
# this target. An empty HOSTOK means this is the wrong machine.
UNAME_S := $(shell uname -s | tr A-Z a-z)
UNAME_M := $(shell uname -m)
HOSTOK_darwin  = $(filter darwin,$(UNAME_S))
HOSTOK_freebsd = $(filter freebsd,$(UNAME_S))
HOSTOK_openbsd = $(filter openbsd,$(UNAME_S))
HOSTOK_alpine  = $(wildcard /etc/alpine-release)
HOSTOK_x86_64  = $(filter x86_64 amd64,$(UNAME_M))
HOSTOK_x86     = $(filter x86_64 amd64 i386 i486 i586 i686,$(UNAME_M))
HOSTOK_arm64   = $(filter aarch64 arm64,$(UNAME_M))
HOSTOK_armhf   = $(filter armv6l armv7l,$(UNAME_M))
HOSTOK = $(if $(HOST),$(HOSTOK_$(HOST)),1)

# On Darwin, macOS targets use Xcode's clang with -arch. Anywhere else they use osxcross's
# <triple>-apple-darwin<ver>-clang from $OSXCROSS_BIN, globbed because the darwin version is whatever
# osxcross was built with. HOST is cleared so ensure_toolchain's native-only guard does not fire on Linux.
ifeq ($(CLASS),macos)
ifneq ($(UNAME_S),darwin)
OSXCROSS_BIN ?= $(BUILDROOT)/osxcross/target/bin
# clang locates <triple>-ld through PATH, not next to itself. Without this it silently falls
# back to the host's /usr/bin/ld, which fails with "unrecognised emulation mode: llvm".
export PATH := $(OSXCROSS_BIN):$(PATH)
OSXTRIPLE = $(if $(filter arm64,$(OSXARCH)),aarch64,$(OSXARCH))
OSXCC := $(firstword $(wildcard $(OSXCROSS_BIN)/$(OSXTRIPLE)-apple-darwin*-clang))
CC = $(or $(OSXCC),$(OSXCROSS_BIN)/$(OSXTRIPLE)-apple-darwin-clang)
STRIP = $(patsubst %-clang,%-strip,$(CC))
HOST =
else
CC = gcc -arch $(OSXARCH)
endif
endif

# Runs before every build. If the compiler is absent it offers to fetch it, defaulting to yes.
# YES=1 or a non-tty answers for you.
define ensure_toolchain
@cc='$(CCBIN)'; \
if [ -z '$(HOSTOK)' ]; then \
  echo "ARCHID=$(ARCHID) ($(ARCHNAME)) is a native build for '$(HOST)'; this is $$(uname -s)/$$(uname -m)."; \
  echo "  build it on that machine (or in a $(HOST) container)"; exit 1; \
fi; \
if command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ]; then exit 0; fi; \
echo "ARCHID=$(ARCHID) ($(ARCHNAME)): compiler '$$cc' not found."; \
if [ -n "$(FETCH)" ] && [ -x ./fetch-toolchains.sh ]; then \
  if [ "$(YES)" = 1 ]; then r=y; \
  elif [ -t 0 ]; then printf "  Fetch it now with 'GLIBCVER=$(GLIBCVER) ./fetch-toolchains.sh $(FETCH)'? [Y/n] "; read -r r; \
  else r=n; echo "  (stdin is not a terminal - re-run with YES=1 to fetch without asking)"; fi; \
  case "$$r" in \
    ""|[yY]|[yY][eE][sS]) GLIBCVER=$(GLIBCVER) ./fetch-toolchains.sh $(FETCH) || exit 1 ;; \
    *) echo "  run: GLIBCVER=$(GLIBCVER) ./fetch-toolchains.sh $(FETCH)"; exit 1 ;; \
  esac; \
  command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ] || \
    { echo "  fetched, but $$cc is still not there - check the path in the ARCH_$(ARCHID) block"; exit 1; }; \
elif [ -n "$(APTPKG)" ]; then \
  if [ "$(YES)" = 1 ]; then r=y; \
  elif [ -t 0 ]; then printf "  Install it now with 'sudo apt-get install -y $(APTPKG)'? [Y/n] "; read -r r; \
  else r=n; echo "  (stdin is not a terminal - re-run with YES=1 to install without asking)"; fi; \
  case "$$r" in \
    ""|[yY]|[yY][eE][sS]) if [ "$(YES)" = 1 ]; then sudo apt-get -qq update >/dev/null && sudo apt-get -qq -y install $(APTPKG) >/dev/null; \
                          else sudo apt-get update && sudo apt-get install -y $(APTPKG); fi || exit 1 ;; \
    *) echo "  run: sudo apt-get install -y $(APTPKG)"; exit 1 ;; \
  esac; \
  command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ] || \
    { echo "  installed, but $$cc is still not there - check the ARCH_$(ARCHID) block"; exit 1; }; \
else \
  echo "  no automated source for this toolchain - see openssl/build/README.md"; exit 1; \
fi
endef

# Three hardening flavours. _FORTIFY_SOURCE=3 also checks heap and variable-length destinations, which
# level 2 only does for compile-time-constant sizes. It needs gcc 12 or clang 15 with glibc 2.34 or
# later, and older headers silently treat it as level 2, while musl has no fortify at all.
HARDEN ?= full
CEXTRA_full  = -D_FORTIFY_SOURCE=3 -Wformat -Wformat-security -fstack-protector -fno-strict-aliasing
CEXTRA_basic = -D_FORTIFY_SOURCE=3 -D_NOFSWATCHER -Wformat -Wformat-security -fno-strict-aliasing
CEXTRA_none  = -fno-strict-aliasing
CHARDEN = $(CEXTRA_$(HARDEN))$(if $(TUNE), $(TUNE),)
# CEXTRA and LDEXTRA are user hooks only, as in `make linux ARCHID=6 CEXTRA=-DFOO LDEXTRA=-Wl,-Map=x`.
# They go last on the compile and link lines, so they never drop the per-target hardening and
# tuning flags, and where they conflict they win because gcc and clang take the last flag of a name.
CEXTRA ?=
LDEXTRA ?=

# Old binutils on these targets reject -z noexecstack, -z relro and -z now.
SKIPFLAGS = $(if $(NOLDHARDEN),1,0)

ifeq ($(WEBLOG),1)
CFLAGS += -D_REMOTELOGGINGSERVER -D_REMOTELOGGING
endif

ifeq ($(KVM),1)
# Mesh Agent KVM sources, only included in builds that have KVM support.
LINUXKVMSOURCES = meshcore/KVM/Linux/linux_kvm.c meshcore/KVM/Linux/linux_events.c meshcore/KVM/Linux/linux_tile.c meshcore/KVM/Linux/linux_compression.c
MACOSKVMSOURCES = meshcore/KVM/MacOS/mac_kvm.c meshcore/KVM/MacOS/mac_events.c meshcore/KVM/MacOS/mac_tile.c meshcore/KVM/Linux/linux_compression.c
CFLAGS += -D_LINKVM
	ifneq ($(JPEGVER),)
		ifeq ($(LEGACY_LD),1)
			LINUXFLAGS = lib-jpeg-turbo/linux/$(ARCHNAME)/$(JPEGVER)/libturbojpeg.a
		else
			LINUXFLAGS = -l:lib-jpeg-turbo/linux/$(ARCHNAME)/$(JPEGVER)/libturbojpeg.a
		endif
		MACOSFLAGS = ./lib-jpeg-turbo/macos/$(ARCHNAME)/$(JPEGVER)/libturbojpeg.a
	else
		ifeq ($(NOTURBOJPEG),1)
			LINUXFLAGS = -ljpeg
		else
			ifeq ($(LEGACY_LD),1)
				LINUXFLAGS = lib-jpeg-turbo/linux/$(ARCHNAME)/libturbojpeg.a
			else
				LINUXFLAGS = -l:lib-jpeg-turbo/linux/$(ARCHNAME)/libturbojpeg.a
			endif
			MACOSFLAGS = ./lib-jpeg-turbo/macos/$(ARCHNAME)/libturbojpeg.a
		endif
	endif
	BSDFLAGS = /usr/local/lib/libjpeg.a
endif

ifeq ($(LMS),0)
CFLAGS += -D_NOHECI
endif

ifeq ($(WEBRTCDEBUG),1)
# Adds WebRTC Debug Interfaces
CFLAGS += -D_WEBRTCDEBUG
endif

ifneq ($(WatchDog),0)
CWATCHDOG := -DILibChain_WATCHDOG_TIMEOUT=$(WatchDog)
endif

ifeq ($(NOTLS),1)
SOURCES += microstack/nossl/sha384-512.c microstack/nossl/sha224-256.c microstack/nossl/md5.c microstack/nossl/sha1.c
CFLAGS += -DMICROSTACK_NOTLS
LINUXSSL =
MACSSL =
BSDSSL =
else
LINUXSSL = -L$(OSSLPREFIX)/lib
MACSSL = -L$(OSSLPREFIX)/lib
BSDSSL = -L$(OSSLPREFIX)/lib
CFLAGS += -DMICROSTACK_TLS_DETECT
# -lpthread is repeated after -lcrypto because static link order matters, and glibc 2.24
# (ARCHID 5, 6, 19 and 20) needs pthread_atfork resolved after libcrypto pulls it in.
LDINT += -lssl -lcrypto -lpthread
endif

ifeq ($(DYNAMICTLS),1)
LINUXSSL = 
MACSSL = 
BSDSSL = 
INCDIRS = -I. -I/usr/include/openssl -Imicrostack -Imicroscript -Imeshcore -Imeshconsole
endif

DEBUGBIN = $(dir $(OUTBIN))DEBUG_$(notdir $(OUTBIN))
PREMTIME = $(OUTBIN).premtime
# Every function and object in its own section, so the linker can drop the unreferenced ones. macOS
# gets the same from -dead_strip, and the BSD recipes are left as they are.
ifeq ($(filter bsd macos,$(CLASS)),)
CFLAGS += -ffunction-sections -fdata-sections
LDFLAGS += -Wl,--gc-sections
endif

ifeq ($(DEBUG),1)
# Debug build, so keep the symbols.
CFLAGS += -g -D_DEBUG
SNAP_OUTBIN_MTIME = $(NOECHO) $(NOOP)
STRIP_AND_SYMBOLCP = $(NOECHO) $(NOOP)
else
# Speed by default. The openwrt and vendor classes are routers and boards short on flash and RAM, so
# they default to size. OPT=-O2 or OPT=-Os overrides either.
OPT ?= $(if $(filter openwrt vendor,$(CLASS)),-Os,-O2)
CFLAGS += $(OPT)
# linux:/macos:/etc. always re-run, so a simple copy+strip step would overwrite DEBUGBIN's real
# symbols with an already-stripped OUTBIN even when nothing changed. Comparing file times does not
# work directly, since strip changes OUTBIN's time too - so that time is saved first.
# For a zig-built ARCHID (see CCOVERRIDE/PATH_ZIG above), DEBUGBIN also inherits real file/line
# debug info from OpenSSL itself - zig cc embeds DWARF by default with no -g needed, see
# openssl/build/targets.sh's top-of-file comment. This strip step removes all of it from OUTBIN.
SNAP_OUTBIN_MTIME = if [ -e "$(OUTBIN)" ]; then touch -r "$(OUTBIN)" "$(PREMTIME)"; else rm -f "$(PREMTIME)"; fi
STRIP_AND_SYMBOLCP = if [ ! -e "$(PREMTIME)" ] || [ -n "$$(find "$(OUTBIN)" -newer "$(PREMTIME)" 2>/dev/null)" ] || [ ! -e "$(DEBUGBIN)" ]; then cp "$(OUTBIN)" "$(DEBUGBIN)" && $(STRIP) "$(OUTBIN)"; else echo "  $(OUTBIN) unchanged - keeping existing $(DEBUGBIN) symbols"; fi; rm -f "$(PREMTIME)"
endif

ifeq ($(ASAN),1)
# Keeps the binary unstripped like DEBUG=1 and enables the halt_on_error=0 recovery mode that
# the ASan phase of test/test-agent.sh relies on, with the <binary>_asan suffix that script detects.
# Uses the host gcc because old Bootlin cross-gccs lack -fsanitize-recover=address.
EXENAME2 := $(EXENAME2)_asan
CC = gcc
export PATH := $(HOSTPATH)
CFLAGS += -fsanitize=address -fsanitize-recover=address -fno-omit-frame-pointer
LDFLAGS += -fsanitize=address
SNAP_OUTBIN_MTIME = $(NOECHO) $(NOOP)
STRIP_AND_SYMBOLCP = $(NOECHO) $(NOOP)
endif

ifeq ($(SSL_TRACE),1)
CFLAGS += -DSSL_TRACE
endif

ifeq ($(IPADDR_MONITOR_DISABLE),1)
CFLAGS += -DNO_IPADDR_MONITOR
endif

ifeq ($(IFADDR_DISABLE),1)
CFLAGS += -DNO_IFADDR
endif

ifeq ($(FSWATCH_DISABLE),1)
CFLAGS += -D_NOFSWATCHER
endif

# The crash handler (_NOILIBSTACKDEBUG compiles it out) is a debug aid, so it is only in for DEBUG=1, and never
# where it cannot work: musl and uClibc have no execinfo.h, and the BSD and macOS recipes do not link -lexecinfo.
# NOILIBSTACKDEBUG=0 or 1 overrides that.
ifndef NOILIBSTACKDEBUG
ifeq ($(DEBUG)$(findstring musl,$(XTRIPLE))$(findstring uclibc,$(XTRIPLE))$(filter bsd macos,$(CLASS)),1)
NOILIBSTACKDEBUG = 0
else
NOILIBSTACKDEBUG = 1
endif
endif
ifeq ($(NOILIBSTACKDEBUG),0)
# ILibParsers.h tests !(_NOILIBSTACKDEBUG) by value, so undefine it rather than pass =0, which the #ifndef sites would still see as set.
CFLAGS += -U_NOILIBSTACKDEBUG
else
CFLAGS += -D_NOILIBSTACKDEBUG
endif

ifeq ($(SSL_EXPORTABLE_KEYS),1)
CFLAGS += -D_SSL_KEYS_EXPORTABLE
endif

ifeq ($(TLS_WRITE_TRACE),1)
CFLAGS += -D_TLSLOG
endif

ifeq ($(NET_SEND_FORCE_FRAGMENT),1)
CFLAGS += -D_DEBUG_NET_FRAGMENT_SEND
endif

ifeq ($(KVM_ALL_TILES),1)
CFLAGS += -DKVM_ALL_TILES
endif

ifeq ($(ILIBCHAIN_GLOBAL_LOCK),1)
CFLAGS += -DILIBCHAIN_GLOBAL_LOCK
endif

ifeq ($(NOWEBRTC),1)
CFLAGS += -DNO_WEBRTC -DOLDSSL
SOURCES += microstack/ILibWebRTC.c
else
SOURCES += microstack/ILibWebRTC.c microstack/ILibWrapperWebRTC.c microscript/ILibDuktape_WebRTC.c
endif

ifeq ($(FIPS),1)
CFLAGS += -DFIPSMODE
endif

ifeq ($(MEMTRACK),1)
CFLAGS += -DILIBMEMTRACK
endif

# C17 is C11 plus defect fixes, so gnu17 and gnu11 compile the same code. Pinned to gnu11 rather
# than probed per-compiler: the two Bootlin 2017.05 toolchains (gcc 5.4, the glibc 2.24 pin for
# x86 and x86-64) predate the gnu17 name, and a 2026-08-30 matrix build of every OpenSSL target
# confirmed gnu11 compiles clean everywhere while gnu17 fails on just those two.
CSTD := gnu11

# The crash handler prints raw addresses that only resolve against a non-PIE image, so only builds that
# carry it give up ASLR. Commit 3336756 (branch add-PIE-support) makes the handler PIE-safe via dladdr.
ifeq ($(NOILIBSTACKDEBUG),0)
GCCTEST := $(shell $(CC) meshcore/dummy.c -o /dev/null -no-pie > /dev/null 2>&1 ; echo $$? )
ifeq ($(GCCTEST),0)
LDFLAGS += -no-pie
endif
endif

GITTEST := $(shell git log -1 > /dev/null 2>&1 ; echo $$? )
ifeq ($(GITTEST),0)
# Rewriting this header on every parse changes its mtime and forces a rebuild of everything that
# includes it, so only regenerate when the commit actually changed. The hash covers every value in
# the file, and it is written last so that finding it also proves the file was written completely.
GITHASH := $(shell git log -1 --format=%H )
ifneq ($(shell grep -qs '"$(GITHASH)"' microscript/ILibDuktape_Commit.h && echo uptodate),uptodate)
$(shell echo "// This file is auto-generated, any edits may be overwritten" > microscript/ILibDuktape_Commit.h )
$(shell git log -1 --format=%cI | awk '{ printf "#define SOURCE_COMMIT_DATE \"%s\"\n", $$0; }' >> microscript/ILibDuktape_Commit.h )
$(shell git rev-parse --short=12 HEAD | awk '{ printf "#define SOURCE_COMMIT_HASH_SHORT \"%s\"\n", $$0; }' >> microscript/ILibDuktape_Commit.h )
$(shell git log -1 --date=format:'%y,%m,%d,%H%M' --format=%cd | awk '{ printf "#define SOURCE_COMMIT_FILEVERSION %s\n", $$0; }' >> microscript/ILibDuktape_Commit.h )
$(shell git log -1 --format=%H | awk '{ printf "#define SOURCE_COMMIT_HASH \"%s\"\n", $$0; }' >> microscript/ILibDuktape_Commit.h )
endif
endif

.PHONY: all clean cleanbin list list-archs listflags list-flags flags print-toolchain print-ossldir print-ossltarget print-osslver print-bsdrel print-macosarch print-archids print-archname print-cflags-extra

# The OS recipes re-invoke make with EXENAME= and the full per-target CFLAGS, and that inner make
# is the only one meant to reach the compile rules. A bare `make ARCHID=n` used to fall into them
# with the generic CFLAGS and fail with "execinfo.h: No such file", so route it to the right recipe.
ifeq ($(origin EXENAME),command line)
all: $(EXENAME)
else
OSGOAL = $(if $(filter macos,$(CLASS)),macos,$(if $(filter bsd,$(CLASS)),$(BSDHOST),linux))
all:
	@echo "ARCHID=$(ARCHID) ($(ARCHNAME)) is built by the '$(OSGOAL)' recipe - running: make $(OSGOAL) ARCHID=$(ARCHID)"
	@$(MAKE) --no-print-directory $(OSGOAL) ARCHID=$(ARCHID)
endif

# 'flags' is a no-op goal, only so `make list flags` doesn't fail as "no rule to make target".
flags: ;

# EXTRA cflags cost one extra sub-make per ARCHID to compute, so they're only shown for
# listflags/list-flags/`make list flags` - plain list/list-archs skip that work and the column.
SHOWFLAGS := $(filter flags listflags list-flags,$(MAKECMDGOALS))

# One line per ARCHID with its toolchain status. Narrow it with make list FILTER=openwrt
list list-archs listflags list-flags:
	@echo "default cflags: $(BASE_CFLAGS)"
	@if [ -n "$(SHOWFLAGS)" ]; then \
	  printf "%6s  %-20s %-8s %-9s %-30s %s\n" ARCHID TARGET CLASS TOOLCHAIN COMPILER "EXTRA flags"; \
	else \
	  printf "%6s  %-20s %-8s %-9s %s\n" ARCHID TARGET CLASS TOOLCHAIN COMPILER; \
	fi
	@awk '/^define ARCH_/{id=$$2; sub(/ARCH_/,"",id); n=""; c="-"} \
	      /^  ARCHNAME/{n=$$3} /^  CLASS/{c=$$3} \
	      /^endef/{if(id!="" && n!="" && (f=="" || c==f)) print id, n, c; id=""}' \
	      f="$(FILTER)" $(firstword $(MAKEFILE_LIST)) | sort -n | \
	while read -r id n c; do \
	  i=$$($(MAKE) -s --no-print-directory ARCHID=$$id print-toolchain); \
	  cc=$${i%%|*}; r=$${i#*|}; fetch=$${r%%|*}; r=$${r#*|}; \
	  apt=$${r%%|*}; r=$${r#*|}; host=$${r%%|*}; hostok=$${r#*|}; \
	  if [ -n "$(SHOWFLAGS)" ]; then extra=$$($(MAKE) -s --no-print-directory ARCHID=$$id print-cflags-extra); fi; \
	  if [ -n "$$host" ] && [ -z "$$hostok" ]; then st=n/a; how="native build - run it on $$host"; \
	  elif command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ]; then st=ready; how="$$cc"; \
	  elif [ -n "$$fetch" ]; then st=MISSING; how="./fetch-toolchains.sh $$fetch"; \
	  elif [ -n "$$apt" ]; then st=MISSING; how="apt-get install $$apt"; \
	  else st=MISSING; how="bring your own ($$cc)"; fi; \
	  if [ -n "$(SHOWFLAGS)" ]; then \
	    printf "%6s  %-20s %-8s %-9s %-30s %s\n" "$$id" "$$n" "$$c" "$$st" "$$how" "$${extra:--}"; \
	  else \
	    printf "%6s  %-20s %-8s %-9s %s\n" "$$id" "$$n" "$$c" "$$st" "$$how"; \
	  fi; \
	done

# Machine-readable ARCHID list, so CI can loop over it instead of hardcoding an ARCHID list of
# its own. `make print-archids` lists every ARCHID and `make print-archids CLASS=generic`
# narrows it to one class.
print-archids:
	@awk '/^define ARCH_/{id=$$2; sub(/ARCH_/,"",id); c="-"} \
	      /^  CLASS/{c=$$3} \
	      /^endef/{if(id!="" && (f=="" || c==f)) print id; id=""}' \
	      f="$(CLASS)" $(firstword $(MAKEFILE_LIST)) | sort -n | tr '\n' ' '
	@echo

# Machine-readable single-target probes. print-toolchain gives the loop above what it needs, and
# print-ossltarget names the targets.sh target this ARCHID links, print-osslver the OpenSSL
# series it resolved to, and print-ossldir the prefix made of both.
print-toolchain:
	@echo '$(CCBIN)|$(FETCH)|$(APTPKG)|$(HOST)|$(HOSTOK)'

print-archname:
	@echo '$(ARCHNAME)'

print-ossltarget:
	@echo '$(OSSLTARGET)'

print-osslver:
	@echo '$(OSSLVER)'

print-ossldir:
	@echo '$(OSSLPREFIX)'

# The per-ARCHID addition to CFLAGS (e.g. -DBADMATH, -D_NOFSWATCHER), isolated from BASE_CFLAGS
# by word-filtering, since ARCH_<id> blocks only ever append flags, never remove or reorder them.
print-cflags-extra:
	@echo '$(strip $(filter-out $(BASE_CFLAGS),$(CFLAGS)))'

# The OS release a bsd target cross-builds against. CI reads this to pick the matching sysroot
# tarball, so the release lives in one place, the target block.
print-bsdrel:
	@echo '$(BSDREL)'

# The deployment floor a macos target is built for. targets.sh passes the same flag to OpenSSL's
# Configure so the archive and the agent agree on minos.
print-macosarch:
	@echo '$(MACOSARCH)'


# Objects depend on the flags they were built with. $(OBJDIR)/.cflags is rewritten at parse time,
# only when CC or CFLAGS change, so a tree half-built with other flags recompiles instead of linking
# stale objects ("undefined reference to ILib_POSIX_CrashHandler"). Only the inner EXENAME= make does this.
FLAGSTAMP = $(OBJDIR)/.cflags
ifeq ($(origin EXENAME),command line)
_FLAGLINE = $(subst ','"'"',$(CC) $(CFLAGS))
$(shell mkdir -p $(OBJDIR); printf '%s\n' '$(_FLAGLINE)' | cmp -s - $(FLAGSTAMP) 2>/dev/null || printf '%s\n' '$(_FLAGLINE)' > $(FLAGSTAMP))
endif

# CCACHE=1 wraps only the compile step. Linking always runs, so a changed archive, header or
# commit hash is never served from the cache. The compiler is identified by content rather than
# mtime and size, so a refetched toolchain of the same size cannot look like the old one.
ifeq ($(CCACHE),1)
CCWRAP = ccache
export CCACHE_COMPILERCHECK ?= content
endif

$(OBJDIR)/%.o: %.c $(FLAGSTAMP)
	@mkdir -p $(@D)
	$(V)$(CCWRAP) $(CC) $(CFLAGS) -MMD -MP -c $< -o $@ $(WARNFLAGS)

-include $(shell find $(OBJDIR) -name '*.d' 2>/dev/null)

$(EXENAME): $(OBJECTS)
ifeq ($(SKIPFLAGS), 1)
	$(V)$(CC) $^ $(LDFLAGS) -lrt -o $@ $(WARNFLAGS)
else
	$(V)$(CC) $^ $(LDFLAGS) $(ADDITIONALFLAGS) -o $@ $(WARNFLAGS)
endif
clean:
	rm -rf build/*/obj

cleanbin:
	rm -f build/*/$(EXENAME)_* build/*/DEBUG_$(EXENAME)_*

# KVM=1 only needs the X11 headers for types and macros, because the real calls are dlopen()'d at
# runtime in linux_kvm.c, so the host's arch-neutral X11 headers work for any target.
# Cross toolchains do not search host paths by default, hence -idirafter. Only X11 is staged in,
# because handing a cross compiler the whole of /usr/include makes Buildroot toolchains warn.
X11INC  = build/hostinc
KVMINC  = $(if $(filter 1,$(KVM)), -idirafter $(X11INC))
STAGE_X11 = $(if $(filter 1,$(KVM)), mkdir -p $(X11INC) && ln -sfn /usr/include/X11 $(X11INC)/X11, :)

linux:
	$(ensure_toolchain)
	$(V)$(STAGE_X11)
	$(SNAP_OUTBIN_MTIME)
	$(MAKE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)" ADDITIONALFLAGS="-lrt -z noexecstack -z relro -z now" CFLAGS="-DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) $(CFLAGS) $(CHARDEN) $(CEXTRA) $(KVMINC)" LDFLAGS="$(LINUXSSL) $(LINUXFLAGS) $(LDFLAGS) $(LDINT) $(LDEXTRA) -ldl"
	$(STRIP_AND_SYMBOLCP)

# MACOSOPT trails $(CFLAGS), which carries $(OPT), so -O3 wins. It is repeated on the link line
# because LTO does its codegen there, and -dead_strip drops the unreferenced objects the static
# OpenSSL and jpeg archives still pull in. -D_FORTIFY_SOURCE=3 and -fstack-protector-strong need Apple clang 15 or later.
MACOSOPT = -O3 -flto
# Apple Silicon executes nothing whose signature does not match the file, and strip invalidates
# ld64's linker signature, so re-sign after strip with macos_sign from build-env.sh (a self-signed
# identity in $BUILDROOT/private). SIGN=0 skips it and SIGN_ADHOC=1 signs ad-hoc without an identity.
MACOS_SIGN = $(if $(filter 0,$(SIGN)),@echo "  not signed (SIGN=0)",@bash -c '. ./build-env.sh >/dev/null && macos_sign "$$1"' _ "$(OUTBIN)")
macos:
	$(ensure_toolchain)
	$(SNAP_OUTBIN_MTIME)
	$(MAKE) $(MAKEFILE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(MACOSKVMSOURCES)" CFLAGS="$(MACOSARCH) -std=$(CSTD) -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) -D_POSIX -D_NOHECI -DMICROSTACK_PROXY -D__APPLE__ $(CWEBLOG) -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CHARDEN) -fstack-protector-strong $(MACOSOPT) $(CEXTRA)" LDFLAGS="$(MACOSARCH) $(MACSSL) $(MACOSFLAGS) -L. -lpthread -lz -framework IOKit -framework ApplicationServices -framework SystemConfiguration -framework CoreServices -framework CoreGraphics -framework CoreFoundation -Wl,-dead_strip $(MACOSOPT) $(LDFLAGS) $(LDINT) $(LDEXTRA)"
	$(STRIP_AND_SYMBOLCP)
	$(MACOS_SIGN)

freebsd:
	$(ensure_toolchain)
	$(SNAP_OUTBIN_MTIME)
	$(MAKE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)"  CFLAGS="-std=$(CSTD) -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) -D_POSIX -D_FREEBSD -D_NOHECI -DMICROSTACK_PROXY -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CHARDEN) $(CEXTRA)" LDFLAGS="$(BSDSSL) $(BSDFLAGS) -L. -lpthread -ldl -lz -lutil $(LDFLAGS) $(LDINT) $(LDEXTRA)"
	$(STRIP_AND_SYMBOLCP)

openbsd:
	$(ensure_toolchain)
	$(SNAP_OUTBIN_MTIME)
	$(MAKE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)"  CFLAGS="-std=$(CSTD) -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) -D_POSIX -D_FREEBSD -D_OPENBSD -D_NOHECI -DMICROSTACK_PROXY -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CHARDEN) $(CEXTRA)" LDFLAGS="$(BSDSSL) $(BSDFLAGS) -L. -lpthread -lz -lutil $(LDFLAGS) $(LDINT) $(LDEXTRA)"
	$(STRIP_AND_SYMBOLCP)

