# MeshAgent build system - Linux, macOS and FreeBSD/OpenBSD (this makefile); Windows builds
# via Visual Studio (MeshAgent-2022.sln), not this file.
#
# See BUILD.md at the repo root for: dependency setup (jpeg-turbo, OpenSSL), toolchain
# provisioning (fetch-toolchains.sh), platform-specific notes (ChromeOS, KVM/X11, FreeBSD,
# Alpine), and testing (test/test-agent.sh). This file only documents ARCHIDs and switches.
#
#   make list                     # every ARCHID: class, toolchain readiness, how to fetch it
#   make list-archs [FILTER=...]  # same, narrowed by CLASS (generic/openwrt/vendor/bsd/macos)
#
# Standard builds:
#
#   make macos   ARCHID=16      # macOS x86 64 bit   (Xcode clang on a Mac, osxcross elsewhere)
#   make macos   ARCHID=29      # macOS ARM 64 bit   (same - host detected, nothing to pass)
#   make linux   ARCHID=5       # Linux x86 32 bit (glibc 2.24)
#   make linux   ARCHID=6       # Linux x86 64 bit (glibc 2.24)
#   make linux   ARCHID=7       # Linux MIPSEL
#   make linux   ARCHID=9       # Linux ARM 32 bit
#   make linux   ARCHID=19      # Linux x86 32 bit NOKVM (glibc 2.24)
#   make linux   ARCHID=20      # Linux x86 64 bit NOKVM (glibc 2.24)
#   make linux   ARCHID=24      # Linux ARM 32 bit HardFloat (Linaro)
#   make linux   ARCHID=26      # Linux ARM 64 bit (apt glibc, GLIBC_2.34 floor)
#   make linux   ARCHID=32      # Linux ARM 64 bit, legacy-ABI compat (Bootlin glibc 2.31, pinned)
#   make linux   ARCHID=33      # Alpine Linux x86 64 bit (MUSL)
#   make linux   ARCHID=35      # Synology - Linux ARMADA 370 Hardfloat
#   gmake freebsd ARCHID=30     # FreeBSD x86 64 bit
#   ARCHID=31                   # FreeBSD x86 32 bit - not implemented, will not be done (freebsd 15 dropped 32-bit support)
#   gmake openbsd ARCHID=37     # OpenBSD x86 64 bit
#
# Raspberry Pi Builds:
#
#   make linux ARCHID=25           # Linux ARM 32 bit HardFloat, cross-compiled (default)
#   make linux ARCHID=25 CROSS=0   # ...built natively on the Pi instead
#
# OpenWRT Builds:
#
#   make linux ARCHID=28          # Linux MIPS24KC/MUSL (OpenWRT)
#   make linux ARCHID=36          # Linux x86_64/MUSL (OpenWRT)
#   make linux ARCHID=40          # Linux MIPSEL24KC/MUSL (OpenWRT)
#   make linux ARCHID=41          # Linux AARCH64/CORTEX-A53/MUSL (OpenWRT)
#   make linux ARCHID=44          # Linux ARMVIRT32/MUSL (OpenWRT)
#
# RISC-V Builds:
#
#   make linux ARCHID=45          # Linux RISC-V 64 bit (T-Head/Xuantie C906 vendor musl, dynamic)
#   make linux ARCHID=145         # Linux RISC-V 64 bit (generic rv64gc, musl, static) - reports as 45
#
# ARCHIDs >= 100 are the modern/updated equivalent of ARCHID-100 and present the classic id
# (MESH_AGENTID = ARCHID-100) to the server, which only knows the classic numbers.
#
# Windows builds (ARCHID 1-4, 21-22, 34, 42-43) use Visual Studio, not this makefile - see
# MeshAgent-2022.sln.
#
# Special builds:
#
#   make linux ARCHID=6 WEBLOG=1 KVM=0      # Linux x86 64 bit, with Web Logging, and KVM disabled
#   make linux ARCHID=6 DEBUG=1             # Linux x86 64 bit, with debug symbols and automated crash handling
#   make linux ARCHID=9 GLIBCVER=2.28       # Linux ARM 32 bit, pinned to a lower glibc floor than the
#                                            # default Bootlin toolchain; see env.sh's bootlin_release_for_glibc
#
# Required build switches:
#	ARCHID									Architecture ID
#
#
# Optional build switches:
#	ASAN                     1 = Build with AddressSanitizer                : Default is disabled; binary suffixed _asan, see test/test-agent.sh
#	BIGCHAINLOCK             1 = No Compiler/Atomics support                : Default is Compiler support present
#	BSDREL                   OS release for the bsd sysroot/triple, e.g. 7.8 : Default is the ARCH_30/37 block's pin (14.3/7.9); ARCHID 30/37 only
#	CRASH_HANDLER            0 = Disable crash handler                      : Default is crash handler enabled
#	CROSS                    0 = Build natively                             : Default is 1 (cross-compile); ARCHID 25/30/31/37 only
#	DEBUG                    0 = Release, 1 = DEBUG                         : Default is Release
#	DYNAMICTLS               1 = Link OpenSSL dynamically                   : Default is static (LINUXSSL/MACSSL/BSDSSL archives)
#	FIPS                     1 = FIPS mode (implies DYNAMICTLS, NOWEBRTC)   : Default is disabled
#	FSWATCH_DISABLE          1 = Remove fswatchter support                  : Default is fswatcher supported
#	GLIBCVER                 Pin glibc floor, e.g. 2.28                     : Default is 2.24 (5/6/19/20) or the shared Bootlin pin 2.31 (others)
#	IPADDR_MONITOR_DISABLE   1 = No IPAddress Monitoring                    : Default is IPAddress Monitoring Enabled
#	IFADDR_DISABLE           1 = Don't use ifaddrs.h                        : Default is use IFADDR
#	JPEGVER                  e.g. v80 = Use jpeg8 libturbojpeg build        : Default is jpeg62
#	KVM                      1 = KVM Enabled, 0 = KVM Disabled              : Default depends on ARCHID
#	KVM_ALL_TILES            0 = Normal, 1 = All Tiles                      : Default is Normal Tiling Algorithm
#	LEGACY_LD                0 = Standard, 1 = Legacy                       : Default is Standard (CentOS 5.11 requires Legacy)
#	MEMTRACK                 1 = Enable memory tracking                     : Default is disabled
#	NET_SEND_FORCE_FRAGMENT  1 = net.send() fragments sends                 : Default is normal send operation
#	NOTLS                    1 = TLS Support Compiled Out                   : Default is TLS Support Compiled In
#	NOTURBOJPEG              1 = Don't use Turbo JPEG                       : Default is USE TurboJPEG
#	NOWEBRTC                 1 = WebRTC Compiled Out                        : Default is WebRTC Compiled In
#	SSL_EXPORTABLE_KEYS      1 = Export SSL Keys for debugging              : Default is DO NOT export SSL keys
#	SSL_TRACE                1 = Enable SSL Tracing                         : Default is tracing disabled
#	TLS_WRITE_TRACE          1 = Enable TLS Send Tracing                    : Default is tracing disabled
#	WARN                     1 = Show compiler/linker warnings              : Default is 0 (warnings suppressed)
#	WatchDog                 WatchDog timer interval.                       : Default is 6000000
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

# Compiler defaults - a target block below may override CC/STRIP.
CC = gcc
STRIP = strip

# Captured before any XDIR block prepends a cross toolchain's bin/ - ASAN
# builds restore this so the host's `as` (not an old cross-`as`) is used.
HOSTPATH := $(PATH)

# Need to be separate for dependency generation
INCDIRS = -I. -Iopenssl/include -Ilib-jpeg-turbo/includes -Imicrostack -Imicroscript -Imeshcore -Imeshconsole

# WARN=1 shows compiler/linker warnings; default is suppressed. -w is
# recognized by both gcc/clang and GNU ld, so one flag covers compile+link.
WARN ?= 0
WARNFLAGS = $(if $(filter 1,$(WARN)),,-w)

# Compiler and linker flags
CFLAGS ?= -std=gnu99 -g -Wall -D_POSIX -DMICROSTACK_PROXY $(CWATCHDOG) -fno-strict-aliasing $(INCDIRS) -DDUK_USE_DEBUGGER_SUPPORT -DDUK_USE_INTERRUPT_COUNTER -DDUK_USE_DEBUGGER_INSPECT -DDUK_USE_DEBUGGER_PAUSE_UNCAUGHT
LDFLAGS ?= -L. -lpthread -lutil -lm
LDINT =

WatchDog = 6000000
KVMMaxTile = 0

# One directory per target+variant under build/: the binary, its unstripped DEBUG_ copy and
# the objects live together, and the agent's runtime side-files (<exe>.msh/.db/.log) stay
# with their own arch. Switching ARCHID needs no `make clean`; -MMD -MP tracks headers.
OUTDIR  = build/$(ARCHNAME)$(EXENAME2)$(if $(DEBUG),-debug)
OUTBIN  = $(OUTDIR)/$(EXENAME)_$(ARCHNAME)$(EXENAME2)
OBJDIR  = $(OUTDIR)/obj
OBJECTS = $(patsubst %.c,$(OBJDIR)/%.o,$(SOURCES))

ifeq ($(FIPS),1)
DYNAMICTLS = 1
NOWEBRTC = 1
endif

# Cross-compiler roots. Version-less names are symlinks created by
# ./fetch-toolchains.sh, so a toolchain bump is not also a makefile edit.
# Pinned Bootlin/musl.cc paths match the OpenSSL archive toolchains too - see meshagent-archid-glibc-floor.md.
PATH_X86 = ../ToolChains/x86-i686-glibc/
PATH_X86_64 = ../ToolChains/x86-64-glibc/
PATH_MIPS = ../ToolChains/mips32el-uclibc/
PATH_MIPS24KC = ../ToolChains/toolchain-mips_24kc_musl/
PATH_MIPSEL24KC = ../ToolChains/toolchain-mipsel_24kc_musl/
PATH_OPENWRT_ARMVIRT32 = ../ToolChains/toolchain-arm_cortex-a15+neon-vfpv4_musl_eabi/
PATH_OPENWRT_X86_64 = ../ToolChains/toolchain-x86_64_musl/
PATH_ARM5 = ../ToolChains/armv5-eabi-glibc/
PATH_LINARO = ../ToolChains/armv7-eabihf-glibc/
PATH_AARCH64 = ../ToolChains/aarch64-glibc/
PATH_AARCH64_CORTEXA53 = ../ToolChains/toolchain-aarch64_generic_musl/
PATH_ARMADA370_HF = ../ToolChains/arm-linux-musleabihf-cross/
PATH_X86_64_MUSL = ../ToolChains/x86_64-linux-musl-cross/
PATH_RPI = ../ToolChains/arm-rpi-4.9.3-linux-gnueabihf/
# Vendor T-Head/Xuantie C906 musl SDK - no public upstream URL, but built
# from source once and mirrored at PTR-inc/meshagent-toolchains/TC (fetch
# via ./fetch-toolchains.sh riscv64-xthead). See ARCH_45 below.
PATH_RISCV64 = ../ToolChains/riscv64-linux-musl-x86_64/
PATH_RISCV64_MUSL = ../ToolChains/riscv64-linux-musl-cross/

# ----------------------------------------------------------------------------
# Target table: one block per ARCHID, sorted. Fields (ARCHNAME is the only
# required one):
#   ARCHNAME  binary suffix; also the openssl/jpeg archive dir unless OSSLARCH
#   OSSLARCH  archive dir when it differs from ARCHNAME
#   CLASS     generic | openwrt | vendor | native | bsd | macos  (make list-archs)
#   XDIR      SDK root - derives PATH, STAGING_DIR, CC, STRIP and INCDIRS
#   XPREFIX   gcc/strip prefix inside $(XDIR)bin/ ; XSTRIP overrides it for strip
#   XTRIPLE   triple subdir added to PATH ; XSYSROOT=1 passes --sysroot=$(XDIR)
#   BSDREL    bsd class: OS release used for the (default) cross-build triple and sysroot
#   TUNE      -march/-mcpu/-mabi flags for this silicon
#   HARDEN    full (default) | basic | none
#   NOLDHARDEN 1 = old binutils, link without -z noexecstack/relro/now
#   KVM LMS   feature defaults
# ----------------------------------------------------------------------------

# Bootlin x86-i686 glibc 2.24 (pinned) - its oldest published x86 release
# (stable-2017.05), not host gcc -m32 (apt floors at GLIBC_2.34). glibc 2.17
# (RHEL7/CentOS7) would be lower still but has no working toolchain source -
# manylinux2014 was tried and abandoned (CentOS7's yum repos are broken
# post-EOL). See meshagent-glibc-2.28-vs-2.31.md.
define ARCH_5
  ARCHNAME = x86
  CLASS    = generic
  XDIR     = $(PATH_X86)
  XPREFIX  = i686-linux-
  XTRIPLE  = i686-buildroot-linux-gnu
  FETCH    = bootlin-x86
  KVM      = 1
  LMS      = 1
endef

# Bootlin x86-64-core-i7 glibc 2.24 (pinned), same floor fix as ARCH_5.
# TUNE resets -march=core-i7 back to generic - this target must not inherit it.
define ARCH_6
  ARCHNAME = x86-64
  CLASS    = generic
  XDIR     = $(PATH_X86_64)
  XPREFIX  = x86_64-linux-
  XTRIPLE  = x86_64-buildroot-linux-gnu
  FETCH    = bootlin-x86-64
  TUNE     = -march=x86-64 -mtune=generic
  KVM      = 1
  LMS      = 1
endef

# mipsel, uClibc (Bootlin mips32el, pinned) - linux/mips dir is big-endian,
# this is linux/mipsel. Matches the OpenSSL archive's uClibc toolchain family.
# See meshagent-archid-glibc-floor.md.
define ARCH_7
  ARCHNAME = mips
  OSSLARCH = mipsel
  CLASS    = vendor
  XDIR     = $(PATH_MIPS)
  XPREFIX  = mipsel-linux-
  XTRIPLE  = mipsel-buildroot-linux-uclibc
  FETCH    = bootlin-mipsel-uclibc
  HARDEN   = basic
  CHAINLOCK = 1
  NOLDHARDEN = 1
  CFLAGS  += -DBADMATH
  IPADDR_MONITOR_DISABLE = 1
  IFADDR_DISABLE = 1
  KVM      = 0
  LMS      = 0
endef

# ARMv5TE/armel - Bootlin armv5-eabi glibc 2.31 (pinned), not apt's
# GLIBC_2.34-floor gcc. binutils 2.33.1 handles hardening fine (HARDEN=basic).
define ARCH_9
  ARCHNAME = arm
  CLASS    = generic
  XDIR     = $(PATH_ARM5)
  XPREFIX  = arm-linux-
  XTRIPLE  = arm-buildroot-linux-gnueabi
  FETCH    = bootlin-armv5
  HARDEN   = basic
  CFLAGS  += -D_NOFSWATCHER -DILIBCHAIN_GLOBAL_LOCK
  KVM      = 0
  LMS      = 0
endef

# macOS: Xcode clang when built on a Mac, osxcross when cross-built from Linux
# (see the CLASS=macos block below). 10.15 floor: lets clang resolve mac_kvm.c's
# @available check statically - osxcross ships no compiler-rt for the runtime
# form (___isPlatformVersionAtLeast) and Xcode 15+ can't target below 10.13 anyway.
define ARCH_16
  ARCHNAME = osx-x86-64
  CLASS    = macos
  OSXARCH  = x86_64
  MACOSARCH = -mmacosx-version-min=10.15
  KVM      = 1
  LMS      = 0
  HOST     = darwin
  FETCH    = osxcross
endef

# Same toolchain as ARCH_5 - see there.
define ARCH_19
  ARCHNAME = x86
  CLASS    = generic
  XDIR     = $(PATH_X86)
  XPREFIX  = i686-linux-
  XTRIPLE  = i686-buildroot-linux-gnu
  FETCH    = bootlin-x86
  EXENAME2 = _nokvm
  KVM      = 0
  LMS      = 1
endef

# Same toolchain as ARCH_6 - see there.
define ARCH_20
  ARCHNAME = x86-64
  CLASS    = generic
  XDIR     = $(PATH_X86_64)
  XPREFIX  = x86_64-linux-
  XTRIPLE  = x86_64-buildroot-linux-gnu
  FETCH    = bootlin-x86-64
  TUNE     = -march=x86-64 -mtune=generic
  EXENAME2 = _nokvm
  KVM      = 0
  LMS      = 1
endef

# ARMv7 hardfloat - Bootlin armv7-eabihf glibc 2.31 (pinned), not apt's
# GLIBC_2.34-floor gcc. See meshagent-archid-glibc-floor.md.
define ARCH_24
  ARCHNAME = arm-linaro
  CLASS    = generic
  XDIR     = $(PATH_LINARO)
  XPREFIX  = arm-linux-
  XTRIPLE  = arm-buildroot-linux-gnueabihf
  FETCH    = bootlin-armv7hf
  HARDEN   = basic
  CFLAGS  += -D_NOFSWATCHER
  KVM      = 0
  LMS      = 0
endef

# Cross-compiles by default; CROSS=0 builds natively on the Pi instead.
# See meshagent-archid-glibc-floor.md.
define ARCH_25
  ARCHNAME = armhf
  CLASS    = generic
  CC       = arm-linux-gnueabihf-gcc
  STRIP    = arm-linux-gnueabihf-strip
  HARDEN   = none
  NOLDHARDEN = 1
  KVM      = 1
  LMS      = 0
  APTPKG   = gcc-arm-linux-gnueabihf
endef

# apt gcc-aarch64-linux-gnu, not HOST-gated - a real cross toolchain,
# buildable from any machine. See meshagent-archid-glibc-floor.md.
define ARCH_26
  ARCHNAME = arm64
  CLASS    = generic
  CC       = aarch64-linux-gnu-gcc
  STRIP    = aarch64-linux-gnu-strip
  HARDEN   = none
  KVM      = 1
  LMS      = 0
  APTPKG   = gcc-aarch64-linux-gnu
endef

define ARCH_28
  ARCHNAME = mips24kc
  CLASS    = openwrt
  XDIR     = $(PATH_MIPS24KC)
  XPREFIX  = mips-openwrt-linux-musl-
  XTRIPLE  = mips-openwrt-linux-musl
  XSYSROOT = 1
  FETCH    = openwrt-mips24kc
  HARDEN   = basic
  NOLDHARDEN = 1
  CFLAGS  += -DBADMATH
  KVM      = 0
  LMS      = 0
endef

# No -target here: it overrides the osxcross wrapper's argv0-derived triple and
# silently breaks its ld64 selection. -arch (native) / the prefixed clang (cross)
# already fix the target; the version floor is all that's left to state.
define ARCH_29
  ARCHNAME = osx-arm-64
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
  CLASS    = bsd
  CC       = clang
  CFLAGS  += -I/usr/local/include
  KVM      = 0
  LMS      = 0
  HOST     = freebsd
  BSDREL   = 14.3
endef

# Legacy-ABI arm64 compat target: Bootlin aarch64--glibc--stable (2.31,
# pinned), matching the OpenSSL archive's own toolchain. See meshagent-archid-glibc-floor.md.
define ARCH_32
  ARCHNAME = aarch64
  CLASS    = generic
  XDIR     = $(PATH_AARCH64)
  XPREFIX  = aarch64-linux-
  XTRIPLE  = aarch64-buildroot-linux-gnu
  FETCH    = bootlin-aarch64
  HARDEN   = basic
  KVM      = 1
  LMS      = 0
endef

# musl.cc x86_64-linux-musl-cross - a standalone toolchain with its own
# kernel-UAPI headers, not the host's musl-gcc (no plain /usr/include/asm
# on a glibc multiarch host, and conflicts with glibc's own headers).
define ARCH_33
  ARCHNAME = alpine-x86-64
  CLASS    = generic
  XDIR     = $(PATH_X86_64_MUSL)
  XPREFIX  = x86_64-linux-musl-
  XTRIPLE  = x86_64-linux-musl
  FETCH    = muslcc-x86_64
  KVM      = 0
  LMS      = 1
  CRASH_HANDLER = 0
endef

# musl.cc arm-linux-musleabihf (matches the OpenSSL archive's own toolchain -
# previously mismatched: agent glibc vs. an already-musl archive it could not
# link against at all). See meshagent-archid-glibc-floor.md.
define ARCH_35
  ARCHNAME = linux-armada370-hf
  CLASS    = vendor
  XDIR     = $(PATH_ARMADA370_HF)
  XPREFIX  = arm-linux-musleabihf-
  XTRIPLE  = arm-linux-musleabihf
  FETCH    = muslcc-armhf
  TUNE     = -march=armv7-a -marm -mfpu=vfp -mfloat-abi=hard
  HARDEN   = basic
  KVM      = 0
  LMS      = 0
  # Real hardware here runs vendor glibc firmware, not a musl userland (unlike
  # the OpenWrt musl ARCHIDs, which deploy into an image that ships musl's own
  # dynamic loader) - static, or the binary can't find /lib/ld-musl-armhf.so.1
  # on the device and won't start at all.
  LDINT    = -static
endef

define ARCH_36
  ARCHNAME = openwrt_x86_64
  CLASS    = openwrt
  XDIR     = $(PATH_OPENWRT_X86_64)
  XPREFIX  = x86_64-openwrt-linux-musl-
  XTRIPLE  = x86_64-openwrt-linux-musl
  XSYSROOT = 1
  FETCH    = openwrt-openwrt_x86_64
  HARDEN   = basic
  CFLAGS  += -DBADMATH
  KVM      = 0
  LMS      = 0
endef

define ARCH_37
  ARCHNAME = openbsd_x86-64
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
  CLASS    = openwrt
  XDIR     = $(PATH_MIPSEL24KC)
  XPREFIX  = mipsel-openwrt-linux-musl-
  XTRIPLE  = mips-openwrt-linux-musl
  XSYSROOT = 1
  FETCH    = openwrt-mipsel24kc
  HARDEN   = basic
  CFLAGS  += -DBADMATH
  KVM      = 0
  LMS      = 0
endef

define ARCH_41
  ARCHNAME = aarch64-cortex-a53
  CLASS    = openwrt
  XDIR     = $(PATH_AARCH64_CORTEXA53)
  XPREFIX  = aarch64-openwrt-linux-
  XTRIPLE  = aarch64-openwrt-linux-musl
  HARDEN   = basic
  KVM      = 0
  LMS      = 0
endef

# OBSOLETE: not physical hardware - OpenWRT's ARMv7 VM target, no device
# population. No OpenSSL archive exists for it (compiles, never links).
# Build with ARCHID=44 OBSOLETE_OK=1 to attempt it anyway.
define ARCH_44
  ARCHNAME = armvirt32
  CLASS    = openwrt
  XDIR     = $(PATH_OPENWRT_ARMVIRT32)
  XPREFIX  = arm-openwrt-linux-
  XSTRIP   = arm-openwrt-linux-muslgnueabi-
  XTRIPLE  = arm-openwrt-linux-muslgnueabi
  XSYSROOT = 1
  HARDEN   = basic
  CFLAGS  += -DBADMATH
  KVM      = 0
  LMS      = 0
  OBSOLETE = 1
endef

# Original ARCHID=45 target, restored as it was pre-refactor (commit a4ce0e3
# had swapped it for a generic rv64gc/glibc build - see ARCH_145 below for
# that instead). T-Head/Xuantie C906 vendor musl toolchain, not fetchable -
# bring-your-own SDK at PATH_RISCV64 (like the old PATH_RPI). The vendored
# openssl/libstatic/linux/riscv64 archive's sha512 asm used to target this
# same xthead custom-opcode extension; per openssl/libstatic/state.txt that
# archive has since been rebuilt generic (Bootlin riscv64-lp64d musl,
# rv64gc, no xthead asm) - rebuilding this target won't reproduce the
# original xthead-accelerated binary until/unless that archive is rebuilt
# vendor-specific again. See docs/meshagent-riscv64-cross-compile.md.
define ARCH_45
  ARCHNAME = riscv64
  CLASS    = vendor
  XDIR     = $(PATH_RISCV64)
  XPREFIX  = riscv64-unknown-linux-musl-
  XTRIPLE  = riscv64-unknown-linux-musl
  # -mcpu=c906fdv alone now expands to the full T-Head extension set on this
  # toolchain (gcc 14.1.1 via the XuanTie fork) - the original vendor gcc
  # 10.2.0's hand-spelled -march=rv64imafdcv0p7xthead is rejected here
  # ('xthead' is no longer a single blob extension name).
  TUNE     = -mcpu=c906fdv -mcmodel=medany -mabi=lp64d
  HARDEN   = basic
  KVM      = 0
  LMS      = 0
  FETCH    = riscv64-xthead
endef

# New target: generic RISC-V64 (rv64gc, no vendor extensions), musl, static. Reports
# MESH_AGENTID=45 to the server (see SERVER_ARCHID) - it is the updated 45, not a new id.
# runs against real hardware's own musl dynamic loader being absent, same
# reasoning as ARCH_35. Reuses the linux/riscv64 OpenSSL archive, which per
# state.txt is itself now a generic Bootlin riscv64-lp64d musl build
# (-march=rv64gc -mabi=lp64d, matching TUNE below) - unlike ARCH_45 above,
# this target's toolchain and its OpenSSL archive actually agree.
define ARCH_145
  ARCHNAME = riscv64-generic-musl
  OSSLARCH = riscv64
  CLASS    = generic
  XDIR     = $(PATH_RISCV64_MUSL)
  XPREFIX  = riscv64-linux-musl-
  XTRIPLE  = riscv64-linux-musl
  TUNE     = -march=rv64gc -mabi=lp64d
  HARDEN   = basic
  KVM      = 0
  LMS      = 0
  LDINT    = -static
  FETCH    = muslcc-riscv64
endef

$(eval $(ARCH_$(ARCHID)))

# ARCHIDs >= 100 are the modern/updated build of ARCHID-100 (145 = today's 45) and identify
# themselves to the server with the classic id - MeshCentral only knows the classic numbers.
SERVER_ARCHID := $(shell [ "$(ARCHID)" -ge 100 ] 2>/dev/null && echo $$(( $(ARCHID) - 100 )) || echo "$(ARCHID)")
# These goals do not need a target selected.
ifeq ($(filter $(MAKECMDGOALS),list list-archs print-archids clean cleanbin),)
$(if $(ARCHNAME),,$(error unknown or missing ARCHID '$(ARCHID)' - run 'make list'))
ifeq ($(OBSOLETE),1)
ifneq ($(OBSOLETE_OK),1)
$(error ARCHID $(ARCHID) ($(ARCHNAME)) is marked OBSOLETE - see its ARCH_$(ARCHID) block. Pass OBSOLETE_OK=1 to build it anyway)
endif
endif
endif

# CROSS defaults to 1 (cross-compile) - pass CROSS=0 to build natively instead.
# ?= so a command-line CROSS= (highest precedence in make) still wins.
CROSS ?= 1

# ARCHID 25 cross-compiles by default (Raspberry Pi buildroot toolchain, works
# from any host); CROSS=0 builds natively on the Pi instead, using the plain
# apt arm-linux-gnueabihf-gcc already set as CC in the ARCH_25 block above.
ifeq ($(ARCHID),25)
ifneq ($(CROSS),0)
CC = $(PATH_RPI)bin/arm-linux-gnueabihf-gcc --sysroot=$(PATH_RPI)arm-linux-gnueabihf/sysroot
STRIP = $(PATH_RPI)bin/arm-linux-gnueabihf-strip
HOST =
endif
endif

# BSD targets cross-compile by default (clang + sysroot); CROSS=0 builds
# natively. SYSROOT defaults to the shared env.sh/fetch-toolchains.sh tree.
# := so these capture HOST/BUILDROOT before the cross-guard clears HOST below.
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

# ---- derived from the block above -----------------------------------------
OSSLARCH ?= $(ARCHNAME)

# Optional per-ARCHID glibc floor pin: `make ARCHID=9 GLIBCVER=2.28`. Repoints
# XDIR at the version-specific alias fetch-toolchains.sh creates, for the
# Bootlin glibc targets only (not uclibc/musl). 5/6/19/20 default to 2.24 (see
# their block) but can still opt into a newer pin here. See
# meshagent-glibc-2.28-vs-2.31.md.
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
CC = $(XDIR)bin/$(XPREFIX)gcc$(if $(XSYSROOT), --sysroot=$(XDIR),)
STRIP = $(XDIR)bin/$(if $(XSTRIP),$(XSTRIP),$(XPREFIX))strip
INCDIRS += -I$(XDIR)include
endif

# ---- toolchain availability -------------------------------------------------
# FETCH  = ./fetch-toolchains.sh component that installs this target's compiler
# APTPKG = apt package that does. Neither set = bring your own (see README).
CCBIN = $(firstword $(CC))

# HOST names the machine a native target must be built on - those blocks have
# no cross compiler, just plain gcc/clang, so "gcc exists" says nothing about
# whether it can produce this target. Empty HOSTOK = wrong machine.
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

# macOS targets: on Darwin, Xcode's clang (`gcc` is clang there) with -arch;
# anywhere else, osxcross's <triple>-apple-darwin<ver>-clang from $OSXCROSS_BIN
# (build-env.sh's location; `./fetch-toolchains.sh osxcross` builds it, given
# the Apple-licensed SDK). The darwin version is whatever osxcross was built
# with - globbed, not pinned here. HOST is cleared so the native-only guard in
# ensure_toolchain doesn't fire on Linux; the compiler check covers it instead.
ifeq ($(CLASS),macos)
ifneq ($(UNAME_S),darwin)
OSXCROSS_BIN ?= $(BUILDROOT)/osxcross/target/bin
# clang locates <triple>-ld through PATH, not next to itself: without this it
# silently falls back to the host's /usr/bin/ld ("unrecognised emulation mode: llvm").
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

# Run before every build: if the compiler is absent, offer to fetch it
# (default yes; YES=1 or a non-tty answers for you).
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
    ""|[yY]|[yY][eE][sS]) sudo apt-get update && sudo apt-get install -y $(APTPKG) || exit 1 ;; \
    *) echo "  run: sudo apt-get install -y $(APTPKG)"; exit 1 ;; \
  esac; \
  command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ] || \
    { echo "  installed, but $$cc is still not there - check the ARCH_$(ARCHID) block"; exit 1; }; \
else \
  echo "  no automated source for this toolchain - see openssl/libstatic/build/README.md"; exit 1; \
fi
endef

# Three hardening flavours, kept byte-identical to what each target used before.
HARDEN ?= full
CEXTRA_full  = -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security -fstack-protector -fno-strict-aliasing
CEXTRA_basic = -D_FORTIFY_SOURCE=2 -D_NOILIBSTACKDEBUG -D_NOFSWATCHER -Wformat -Wformat-security -fno-strict-aliasing
CEXTRA_none  = -fno-strict-aliasing
CHARDEN = $(CEXTRA_$(HARDEN))$(if $(CHAINLOCK), -DILIBCHAIN_GLOBAL_LOCK,)$(if $(TUNE), $(TUNE),)
# CEXTRA / LDEXTRA are user hooks only (`make linux ARCHID=6 CEXTRA=-DFOO LDEXTRA=-Wl,-Map=x`):
# added LAST on the compile and link lines, so they never drop the per-target hardening/
# tuning/link sets and, where they conflict, they win (gcc/clang take the last -O, -f, -m,
# -std and -D of a name; use -UNAME to undefine one).
CEXTRA ?=
LDEXTRA ?=

# Old binutils on these targets reject -z noexecstack/relro/now.
SKIPFLAGS = $(if $(NOLDHARDEN),1,0)

ifeq ($(WEBLOG),1)
CFLAGS += -D_REMOTELOGGINGSERVER -D_REMOTELOGGING
endif

ifeq ($(KVM),1)
# Mesh Agent KVM, this is only included in builds that have KVM support
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
OSSLARCH ?= $(ARCHNAME)
LINUXSSL = -Lopenssl/libstatic/linux/$(OSSLARCH)
MACSSL = -Lopenssl/libstatic/macos/$(ARCHNAME)
BSDSSL = -Lopenssl/libstatic/bsd/$(ARCHNAME)
CFLAGS += -DMICROSTACK_TLS_DETECT
# Repeats -lpthread after -lcrypto: static-link order matters, and glibc 2.24
# (ARCHID 5/6/19/20) needs pthread_atfork resolved after it's pulled in.
LDINT += -lssl -lcrypto -lpthread
endif

ifeq ($(DYNAMICTLS),1)
LINUXSSL = 
MACSSL = 
BSDSSL = 
INCDIRS = -I. -I/usr/include/openssl -Imicrostack -Imicroscript -Imeshcore -Imeshconsole
endif

ifeq ($(DEBUG),1)
# Debug Build, include Symbols
CFLAGS += -g -D_DEBUG 
STRIP = $(NOECHO) $(NOOP)
SYMBOLCP = $(NOECHO) $(NOOP)
else
CFLAGS += -O2
STRIP += $(OUTBIN)
SYMBOLCP = cp $(OUTBIN) $(dir $(OUTBIN))DEBUG_$(notdir $(OUTBIN))
endif

ifeq ($(ASAN),1)
# Keeps symbols/unstripped (like DEBUG=1) and gives the halt_on_error=0 recovery
# mode test/test-agent.sh's ASan phase relies on. Suffix matches what that
# script auto-detects: <binary>_asan. Uses the host's native gcc rather than a
# pinned cross toolchain - old Bootlin cross-gccs (e.g. 5.4.0 on ARCHID 5/6/19/20)
# have a libasan without -fsanitize-recover=address support, and ASan output
# isn't a shipped target anyway.
EXENAME2 := $(EXENAME2)_asan
CC = gcc
export PATH := $(HOSTPATH)
CFLAGS += -fsanitize=address -fsanitize-recover=address -fno-omit-frame-pointer
LDFLAGS += -fsanitize=address
STRIP = $(NOECHO) $(NOOP)
SYMBOLCP = $(NOECHO) $(NOOP)
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

ifeq ($(CRASH_HANDLER),0)
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

ifeq ($(BIGCHAINLOCK),1)
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

GCCTEST := $(shell $(CC) meshcore/dummy.c -o /dev/null -no-pie > /dev/null 2>&1 ; echo $$? )
ifeq ($(GCCTEST),0)
LDFLAGS += -no-pie
endif

GITTEST := $(shell git log -1 > /dev/null 2>&1 ; echo $$? )
ifeq ($(GITTEST),0)
$(shell echo "// This file is auto-generated, any edits may be overwritten" > microscript/ILibDuktape_Commit.h )
$(shell git log -1 | grep "Date: " | awk '{ aLen=split($$0, a, " "); printf "#define SOURCE_COMMIT_DATE \"%s-%s-%s %s%s\"\n", a[6], a[3], a[4], a[5], a[7]; }' >> microscript/ILibDuktape_Commit.h )
$(shell git log -1 --format=%H | awk '{ printf "#define SOURCE_COMMIT_HASH \"%s\"\n", $$0; }' >> microscript/ILibDuktape_Commit.h )
endif

.PHONY: all clean cleanbin list list-archs print-toolchain print-ossldir print-bsdrel print-macosarch print-archids

# The OS recipes (linux/macos/freebsd/openbsd) re-invoke make with EXENAME= and the full
# per-target CFLAGS; that inner make is the only one meant to reach the compile rules. A bare
# `make ARCHID=n` used to fall into them with the generic CFLAGS (no -D_NOILIBSTACKDEBUG on
# musl -> "execinfo.h: No such file", no MESH_AGENTID) - route it to the right recipe instead.
ifeq ($(origin EXENAME),command line)
all: $(EXENAME)
else
OSGOAL = $(if $(filter macos,$(CLASS)),macos,$(if $(filter bsd,$(CLASS)),$(BSDHOST),linux))
all:
	@echo "ARCHID=$(ARCHID) ($(ARCHNAME)) is built by the '$(OSGOAL)' recipe - running: make $(OSGOAL) ARCHID=$(ARCHID)"
	@$(MAKE) --no-print-directory $(OSGOAL) ARCHID=$(ARCHID)
endif

# One line per ARCHID with its toolchain status, narrowable: make list FILTER=openwrt
list list-archs:
	@printf "%6s  %-20s %-8s %-9s %s\n" ARCHID TARGET CLASS TOOLCHAIN COMPILER
	@awk '/^define ARCH_/{id=$$2; sub(/ARCH_/,"",id); n=""; c="-"; o=""} \
	      /^  ARCHNAME/{n=$$3} /^  CLASS/{c=$$3} /^  OBSOLETE/{o="1"} \
	      /^endef/{if(id!="" && n!="" && (f=="" || c==f)) print id, n, c, o; id=""}' \
	      f="$(FILTER)" $(firstword $(MAKEFILE_LIST)) | sort -n | \
	while read -r id n c o; do \
	  if [ "$$o" = "1" ]; then st=OBSOLETE; how="see ARCH_$$id block - build with OBSOLETE_OK=1"; \
	  else \
	    i=$$($(MAKE) -s --no-print-directory ARCHID=$$id print-toolchain); \
	    cc=$${i%%|*}; r=$${i#*|}; fetch=$${r%%|*}; r=$${r#*|}; \
	    apt=$${r%%|*}; r=$${r#*|}; host=$${r%%|*}; hostok=$${r#*|}; \
	    if [ -n "$$host" ] && [ -z "$$hostok" ]; then st=n/a; how="native build - run it on $$host"; \
	    elif command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ]; then st=ready; how="$$cc"; \
	    elif [ -n "$$fetch" ]; then st=MISSING; how="./fetch-toolchains.sh $$fetch"; \
	    elif [ -n "$$apt" ]; then st=MISSING; how="apt-get install $$apt"; \
	    else st=MISSING; how="bring your own ($$cc)"; fi; \
	  fi; \
	  printf "%6s  %-20s %-8s %-9s %s\n" "$$id" "$$n" "$$c" "$$st" "$$how"; \
	done

# Machine-readable ARCHID list, OBSOLETE blocks excluded, optionally narrowed:
#   make print-archids            all buildable ARCHIDs
#   make print-archids CLASS=generic
# CI loops over this instead of hardcoding an ARCHID list of its own.
print-archids:
	@awk '/^define ARCH_/{id=$$2; sub(/ARCH_/,"",id); c="-"; o=""} \
	      /^  CLASS/{c=$$3} /^  OBSOLETE/{o="1"} \
	      /^endef/{if(id!="" && o=="" && (f=="" || c==f)) print id; id=""}' \
	      f="$(CLASS)" $(firstword $(MAKEFILE_LIST)) | sort -n | tr '\n' ' '
	@echo

# Machine-readable single-target probes: the toolchain the loop above needs,
# and the openssl/libstatic/ dir this target links (openssl/.../build.sh list).
print-toolchain:
	@echo '$(CCBIN)|$(FETCH)|$(APTPKG)|$(HOST)|$(HOSTOK)'

print-ossldir:
	@echo '$(if $(filter macos,$(CLASS)),macos/$(ARCHNAME),$(if $(filter bsd,$(CLASS)),bsd/$(ARCHNAME),linux/$(OSSLARCH)))'

# The OS release a bsd target cross-builds against - CI reads this to pick the
# matching sysroot tarball, so the release lives in one place (the block).
print-bsdrel:
	@echo '$(BSDREL)'

# The deployment floor a macos target is built for - targets.sh passes the
# same flag to OpenSSL's Configure so archive and agent agree on minos.
print-macosarch:
	@echo '$(MACOSARCH)'


# Objects depend on the flags they were built with: $(OBJDIR)/.cflags is rewritten - at parse
# time, so its mtime is settled before any dependency is judged - only when CC/CFLAGS change.
# A tree left half-built by a differently-flagged invocation (a bare `make ARCHID=n`, KVM=0
# after KVM=1) then recompiles instead of linking stale objects ("undefined reference to
# ILib_POSIX_CrashHandler" was exactly that). Only the inner, EXENAME= make does this - the
# dispatching outer make carries the generic CFLAGS and must not touch the stamp.
FLAGSTAMP = $(OBJDIR)/.cflags
ifeq ($(origin EXENAME),command line)
_FLAGLINE = $(subst ','"'"',$(CC) $(CFLAGS))
$(shell mkdir -p $(OBJDIR); printf '%s\n' '$(_FLAGLINE)' | cmp -s - $(FLAGSTAMP) 2>/dev/null || printf '%s\n' '$(_FLAGLINE)' > $(FLAGSTAMP))
endif

$(OBJDIR)/%.o: %.c $(FLAGSTAMP)
	@mkdir -p $(@D)
	$(V)$(CC) $(CFLAGS) -MMD -MP -c $< -o $@ $(WARNFLAGS)

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

# KVM=1 only needs X11 headers (type/macro defs - real calls are dlopen()'d
# at runtime, see linux_kvm.c), so the host's stable, arch-neutral X11 headers
# work for any target. Cross toolchains don't search host paths by default.
KVMINC = $(if $(filter 1,$(KVM)), -idirafter /usr/include)

linux:
	$(ensure_toolchain)
	$(MAKE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)" ADDITIONALFLAGS="-lrt -z noexecstack -z relro -z now" CFLAGS="-DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) $(CFLAGS) $(CHARDEN) $(CEXTRA) $(KVMINC)" LDFLAGS="$(LINUXSSL) $(LINUXFLAGS) $(LDFLAGS) $(LDINT) $(LDEXTRA) -ldl"
	$(SYMBOLCP)
	$(STRIP)

# MACOSOPT trails $(CFLAGS) (which ends in -O2) so -O3 wins; it is repeated on the
# link line because LTO does its codegen there. -dead_strip drops the unreferenced
# objects the static OpenSSL/jpeg archives still pull in. FORTIFY=3 and
# -fstack-protector-strong: Apple clang 15+. -ldl/-lutil are libSystem on macOS.
MACOSOPT = -O3 -flto
# Apple Silicon execs nothing whose signature doesn't match the file, and strip
# invalidates ld64's linker signature - re-sign after strip (build-env.sh
# macos_sign: self-signed identity in $BUILDROOT/private, generated once).
# SIGN=0 skips it; SIGN_ADHOC=1 signs ad-hoc without an identity.
MACOS_SIGN = $(if $(filter 0,$(SIGN)),@echo "  not signed (SIGN=0)",@bash -c '. ./build-env.sh >/dev/null && macos_sign "$$1"' _ "$(OUTBIN)")
macos:
	$(ensure_toolchain)
	$(MAKE) $(MAKEFILE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(MACOSKVMSOURCES)" CFLAGS="$(MACOSARCH) -std=gnu99 -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) -D_POSIX -D_NOILIBSTACKDEBUG -D_NOHECI -DMICROSTACK_PROXY -D__APPLE__ $(CWEBLOG) -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CHARDEN) -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fstack-protector-strong $(MACOSOPT) $(CEXTRA)" LDFLAGS="$(MACOSARCH) $(MACSSL) $(MACOSFLAGS) -L. -lpthread -lz -framework IOKit -framework ApplicationServices -framework SystemConfiguration -framework CoreServices -framework CoreGraphics -framework CoreFoundation -Wl,-dead_strip $(MACOSOPT) $(LDFLAGS) $(LDINT) $(LDEXTRA)"
	$(SYMBOLCP)
	$(STRIP)
	$(MACOS_SIGN)

freebsd:
	$(ensure_toolchain)
	$(MAKE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)"  CFLAGS="-std=gnu99 -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) -D_POSIX -D_FREEBSD -D_NOHECI -D_NOILIBSTACKDEBUG -DMICROSTACK_PROXY -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CHARDEN) $(CEXTRA)" LDFLAGS="$(BSDSSL) $(BSDFLAGS) -L. -lpthread -ldl -lz -lutil $(LDFLAGS) $(LDINT) $(LDEXTRA)"
	$(SYMBOLCP)
	$(STRIP)

openbsd:
	$(ensure_toolchain)
	$(MAKE) EXENAME="$(OUTBIN)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)"  CFLAGS="-std=gnu99 -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(SERVER_ARCHID) -D_POSIX -D_FREEBSD -D_OPENBSD -D_NOHECI -D_NOILIBSTACKDEBUG -DMICROSTACK_PROXY -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CHARDEN) $(CEXTRA)" LDFLAGS="$(BSDSSL) $(BSDFLAGS) -L. -lpthread -lz -lutil $(LDFLAGS) $(LDINT) $(LDEXTRA)"
	$(SYMBOLCP)
	$(STRIP)

