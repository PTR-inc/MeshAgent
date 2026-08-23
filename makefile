# To built libturbojpeg.a
#
# Get the file "libjpeg-turbo-1.4.2.tar.gz", extract it. For Linux 64bit compile:
#   ./configure
# For Linux 32bit compile
#   ./configure --build=i686-pc-linux-gnu "CFLAGS=-m32" "CXXFLAGS=-m32" "LDFLAGS=-m32"
# Then do "make -j8" and get the resulting file /.libs/libturbojpeg.a
#
#
# To build MeshAgent2 on Linux you first got to download the dev libraries to compile the agent, we need x11, txt, ext and jpeg. To install, do this:
#	Using APT:
#		sudo apt-get install libx11-dev libxtst-dev libxext-dev libjpeg62-dev libxrandr-dev
#
#	Using YUM:
#		sudo yum install libX11-devel libXtst-devel libXext-devel libjpeg-devel libXrandr-devel
#
#	NOTE: If you install headers for jpeg8, you need to put the compiled .a in the v80 folder, and specify JPEGVER=v80 when building MeshAgent
#		eg: make linux ARCHID=6 JPEGVER=v80
#
#
# To build for 32 bit on 64 bit linux 
#  sudo apt-get install linux-libc-dev:i386 libc6-dev-i386 libjpeg62-dev:i386 libxrandr-dev:i386
#
# To install ARM Cross Compiler for Raspberry PI
#  sudo apt-get install libc6-armel-cross libc6-dev-armel-cross binutils-arm-linux-gnueabi libncurses5-dev gcc-arm-linux-gnueabihf
#
# To build universal binaries for macOS, you need to install the Xcode command line tools,
# and then use the following commands to build x86_64 and arm64 binaries, then combine them into a universal binary with lipo:
#   make macos ARCHID=16   																		# macOS x86 64 bit
#   make macos ARCHID=29																		# macOS ARM 64 bit
#   lipo -create -output meshagent_osx-universal-64 meshagent_osx-x86-64 meshagent_osx-arm-64	# Combine the two binaries into a universal binary
# 
# Special builds:
#
#   make linux ARCHID=6 WEBLOG=1 KVM=0      # Linux x86 64 bit, with Web Logging, and KVM disabled
#   make linux ARCHID=6 DEBUG=1             # Linux x86 64 bit, with debug symbols and automated crash handling
#
# Compiling lib-turbojpeg from source, using libjpeg-turbo 1.4.2 on linux
#   64 bit JPEG8  -> ./configure --with-jpeg8 
#   64 bit JPEG62 -> ./configure
#   32 bit JPEG8  -> ./configure --with-jpeg8 --host i686-pc-linux-gnu CFLAGS='-O2 -m32' LDFLAGS=-m32
#   32 bit JPEG62 -> ./configure --host i686-pc-linux-gnu CFLAGS='-O2 -m32' LDFLAGS=-m32
#
# Cross compiling lib-turbojpeg from source, using libjpeg-turbo 1.4.2 on macOS
#   Intel Silicon macOS	->	./configure --host=x86_64-apple-darwin20.0.0 CFLAGS='-arch x86_64'
#   Apple Silicon macOS	->	./configure --host=aarch64-apple-darwin20.0.0 CFLAGS='-arch arm64'
#
#
#	NOTE: If you installed jpeg8 headers on your machine, you must specify --with-jpeg8 when building turbo jpeg, otherwise omit --with-jpeg8
#
#
#
#	Note: For ChromeOS, you need to disable rootfs verification, in order to install the meshagent service.
#		  After running the following commands, and rebooting, you should be able to install the meshagent service.
#
#			sudo su -
#			cd /usr/share/vboot/bin/
#			./make_dev_ssd.sh --remove_rootfs_verification
#		
#		The above line will return a warning, but it will tell you the boot partition number, which you 
#		will need when specifying the above command again, this time with the --partions options. Specify the number instead of (ID)
#
#			./make_dev_ssd.sh --remove_rootfs_verification --partitions ID
#			reboot
#
#		When you are ready to install the agent, you'll need to copy the binary to a path that is not marked noexec, like /usr/local,
#		so that you can execute the installer from there.
#
#
# Special Note about KVM Support on Linux: 
#    If you get an error stating that an Xauthority cannot be found, and asking if your DM is configured to use X, 
#    or if you get a black screen when connecting to the login screen, you may need to: 
#    1. Open /etc/gdm/custom.conf or /etc/gdm3/custom.conf
#    2. Uncomment: WaylandEnable=false.
#    3. Add the following line to the [daemon] section:
#       DefaultSession=gnome-xorg.desktop
#
#
# Special note about running on FreeBSD systems:
#	1. You'll need to mount procfs, which isn't mounted by default on FreeBSD. Add the following line to /etc/fstab
#		proc	/proc	procfs	rw	0	0
#	2. If you don't reboot, then you can manually mount with the command:
#		mount -t procfs proc /proc
#	3. In addition, it is recommended to install bash, which you can do with the following command:
#		pkg install bash
#	4. For KVM, my FreeBSD system was setup using X11 and KDE. KVM should work out of the box with that configuration.
#		4a. KVM is disabled by default. To build with KVM support, specify KVM=1 in when building (ie: gmake freebsd ARCHID=30 KVM=1)
#	5. Also note, that to build on FreeBSD, you must use gmake, not make.
#
#
# To build on Alpine Linux (MUSL), you'll need to install the following libraries
#	apk add build-base gcc abuild binutils linux-headers libexecinfo-dev bash binutils-doc gcc-doc
#
#
#
# Standard builds:
#
#   ARCHID=1                                # Windows Console x86 32 bit
#   ARCHID=2                                # Windows Console x86 64 bit
#   ARCHID=3                                # Windows Service x86 32 bit
#   ARCHID=4                                # Windows Service x86 64 bit
#   make macos ARCHID=16					# macOS x86 64 bit
#	make macos ARCHID=29					# macOS ARM 64 bit
#   make linux ARCHID=5						# Linux x86 32 bit
#   make linux ARCHID=6						# Linux x86 64 bit
#   make linux ARCHID=7						# Linux MIPSEL
#   make linux ARCHID=9						# Linux ARM 32 bit
#   make linux ARCHID=19					# Linux x86 32 bit NOKVM
#   make linux ARCHID=20					# Linux x86 64 bit NOKVM
#   make linux ARCHID=24 					# Linux ARM 32 bit HardFloat (Linaro)
#   make linux ARCHID=26 					# Linux ARM 64 bit
#   make linux ARCHID=32 					# Linux ARM 64 bit (glibc/2.24)
#   gmake freebsd ARCHID=30					# FreeBSD x86 64 bit
#   gmake freebsd ARCHID=31					# Reserved for FreeBSD x86 32 bit
#	gmake openbsd ARCHID=37					# OpenBSD x86 64 bit
#
#
# Alpine Linux (MUSL)
#	make linux ARCHID=33					# Alpine Linux x86 64 bit (MUSL)
#
# Raspberry Pi Builds:
#
#	make linux ARCHID=25 CROSS=1			# Linux ARM 32 bit HardFloat, using cross compiler
#
# OpenWRT Builds:
#
#	make linux ARCHID=28					# Linux MIPS24KC/MUSL (OpenWRT)
#	make linux ARCHID=36					# Linux x86_64/MUSL (OpenWRT)
#	make linux ARCHID=40					# Linux MIPSEL24KC/MUSL (OpenWRT)
#	make linux ARCHID=41					# Linux ARMADA/CORTEX-A53/MUSL (OpenWRT)
#   make linux ARCHID=44					# Linux ARMVIRT32/MUSL (OpenWRT)
#
# RISC-V Builds:
#
#	make linux ARCHID=45					# Linux RISC-V 64 bit (generic rv64gc, glibc - also runs on T-Head C906)
#
# Synology Builds
#
#	make linux ARCHID=35					# Linux ARMADA 370 Hardfloat
#
# Windows Builds for ARCHID:
#   1 - 4 are Windows builds. please use Visual Studio to compile.
#   21 - 22 are Windows builds, please use Visual Studio to compile.
#   34 is Windows build, please use Visual Studio to compile.
#   42 - 43 are Windows builds, please use Visual Studio to compile.
# 
# Required build switches:
#	ARCHID									Architecture ID
# 
# 
# Optional build switches:
#	BIGCHAINLOCK							1 = No Compiler/Atomics support		=> Default is Compiler support present
#	DEBUG									0 = Release, 1 = DEBUG				=> Default is Release
#	FSWATCH_DISABLE							1 = Remove fswatchter support		=> Default is fswatcher supported
#	IPADDR_MONITOR_DISABLE					1 = No IPAddress Monitoring			=> Default is IPAddress Monitoring Enabled
#	IFADDR_DISABLE							1 = Don't use ifaddrs.h				=> Default is use IFADDR
#	KVM										1 = KVM Enabled, 0 = KVM Disabled   => Default depends on ARCHID
#	KVM_ALL_TILES							0 = Normal, 1 = All Tiles			=> Default is Normal Tiling Algorithm
#	LEGACY_LD								0 = Standard, 1 = Legacy			=> Default is Standard (CentOS 5.11 requires Legacy)
#	NET_SEND_FORCE_FRAGMENT					1 = net.send() fragments sends		=> Default is normal send operation
#	NOTLS									1 = TLS Support Compiled Out		=> Default is TLS Support Compiled In
#	NOTURBOJPEG								1 = Don't use Turbo JPEG			=> Default is USE TurboJPEG
#	SSL_EXPORTABLE_KEYS						1 = Export SSL Keys for debugging	=> Default is DO NOT export SSL keys
#	TLS_WRITE_TRACE							1 = Enable TLS Send Tracing			=> Default is tracing disabled
#	WatchDog								WatchDog timer interval.			=> Default is 6000000
#	WEBLOG									1 = Enable WebLogging Interface		=> Default is disabled
#	WEBRTCDEBUG								1 = Enable WebRTC Instrumentation	=> Default is disabled
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

# Compiler defaults - a target stanza below may override CC/STRIP.
CC = gcc
STRIP = strip

# Need to be separate for dependency generation
INCDIRS = -I. -Iopenssl/include -Ilib-jpeg-turbo/includes -Imicrostack -Imicroscript -Imeshcore -Imeshconsole

# Compiler and linker flags
CFLAGS ?= -std=gnu99 -g -Wall -D_POSIX -DMICROSTACK_PROXY $(CWATCHDOG) -fno-strict-aliasing $(INCDIRS) -DDUK_USE_DEBUGGER_SUPPORT -DDUK_USE_INTERRUPT_COUNTER -DDUK_USE_DEBUGGER_INSPECT -DDUK_USE_DEBUGGER_PAUSE_UNCAUGHT
LDFLAGS ?= -L. -lpthread -lutil -lm
LDEXTRA =

WatchDog = 6000000
KVMMaxTile = 0

# Per-ARCHID object tree: switching ARCHID no longer needs `make clean`, and
# -MMD -MP makes a header edit actually trigger a rebuild.
OBJDIR  = obj/$(ARCHNAME)$(EXENAME2)$(if $(DEBUG),-debug)
OBJECTS = $(patsubst %.c,$(OBJDIR)/%.o,$(SOURCES))

ifeq ($(FIPS),1)
DYNAMICTLS = 1
NOWEBRTC = 1
endif

# Cross-compiler roots. Version-less names are symlinks created by
# ./fetch-toolchains.sh, so a toolchain bump is not also a makefile edit.
# Bootlin/musl.cc pinned-release paths (mips/arm5/linaro/aarch64/armada370-hf) -
# see meshagent-archid-glibc-floor.md: apt cross-gcc on this era of Debian/
# Ubuntu floors at GLIBC_2.34, above most of the real hardware population for
# these targets; the OpenSSL archives fetch-toolchains.sh wires here are what
# openssl/libstatic/build/targets.sh now builds those archives with too, so
# the agent and its OpenSSL archive are the same toolchain/libc family again.
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

# ----------------------------------------------------------------------------
# Target table: one stanza per ARCHID, sorted. Fields (ARCHNAME is the only
# required one):
#   ARCHNAME  binary suffix; also the openssl/jpeg archive dir unless OSSLARCH
#   OSSLARCH  archive dir when it differs from ARCHNAME
#   CLASS     generic | openwrt | vendor | native | bsd | macos  (make list-archs)
#   XDIR      SDK root - derives PATH, STAGING_DIR, CC, STRIP and INCDIRS
#   XPREFIX   gcc/strip prefix inside $(XDIR)bin/ ; XSTRIP overrides it for strip
#   XTRIPLE   triple subdir added to PATH ; XSYSROOT=1 passes --sysroot=$(XDIR)
#   BSDREL    bsd class: OS release used for the CROSS=1 triple and sysroot
#   TUNE      -march/-mcpu/-mabi flags for this silicon
#   HARDEN    full (default) | basic | none
#   NOLDHARDEN 1 = old binutils, link without -z noexecstack/relro/now
#   KVM LMS   feature defaults
# ----------------------------------------------------------------------------

# Bootlin x86-i686 glibc 2.31 (pinned), not host gcc -m32 - host apt gcc floors
# at GLIBC_2.34 (libpthread-into-libc merge), above what 32-bit x86 hardware's
# generally older population runs. No longer HOST-gated: a real cross
# toolchain, buildable from any machine. See meshagent-archid-glibc-floor.md.
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

# Bootlin x86-64-core-i7 glibc 2.31 (pinned), not host gcc - same floor fix as
# ARCH_5. -mtune/-march forced back to a generic baseline: Bootlin's toolchain
# defaults to -march=core-i7, which this "generic x86-64" target must not
# silently inherit. No longer HOST-gated. See meshagent-archid-glibc-floor.md.
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

# mipsel, uClibc. Archive dir is linux/mipsel - linux/mips is big-endian.
# uClibc (Bootlin mips32el, pinned) - matches the OpenSSL archive's own
# toolchain family again; previously mismatched (agent uClibc vs. an
# apt-glibc-built archive it could not link against). See
# meshagent-archid-glibc-floor.md.
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

# ARMv5TE/armel - Bootlin armv5-eabi glibc 2.31 (pinned), not apt. apt's
# arm-linux-gnueabi-gcc floors at GLIBC_2.34, above what most real ARMv5
# hardware (Marvell Kirkwood/Orion plug computers and NAS, 2008-2013) runs.
# binutils 2.33.1 here handles -z noexecstack/relro/now fine - HARDEN=basic,
# not none/NOLDHARDEN as the old CodeSourcery-era toolchain required.
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

define ARCH_16
  ARCHNAME = osx-x86-64
  CLASS    = macos
  CC       = gcc -arch x86_64
  MACOSARCH = -mmacosx-version-min=10.5
  KVM      = 1
  LMS      = 0
  HOST     = darwin
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

# ARMv7 hardfloat - Bootlin armv7-eabihf glibc 2.31 (pinned), not the old
# Linaro-branded toolchain (long discontinued) or apt (GLIBC_2.34 floor). See
# meshagent-archid-glibc-floor.md. binutils 2.33.1 handles modern hardening.
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

# Native on the Pi; CROSS=1 uses the Raspberry Pi cross toolchain instead.
# apt gcc-arm-linux-gnueabihf, not HOST-gated - a real cross toolchain,
# buildable from any machine. See meshagent-archid-glibc-floor.md.
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

define ARCH_29
  ARCHNAME = osx-arm-64
  CLASS    = macos
  CC       = gcc -arch arm64
  MACOSARCH = -target arm64-apple-macos11
  KVM      = 1
  LMS      = 0
  HOST     = darwin
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

# Legacy-ABI arm64 compat target: Bootlin aarch64--glibc--stable (glibc 2.31,
# pinned) - the OpenSSL archive is now built with this exact same toolchain
# release (was apt aarch64-linux-gnu-gcc, GLIBC_2.34 floor, which made this
# target identical to mainline arm64/ARCHID 26 and defeated its purpose). See
# meshagent-archid-glibc-floor.md.
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

# musl.cc x86_64-linux-musl-cross - a standalone musl toolchain with its own
# bundled kernel-UAPI headers, not the host's musl-gcc (which has no plain
# /usr/include/asm on a glibc multiarch host and conflicts with glibc's own
# headers if you paper over that with -idirafter). Not HOST-gated - a real
# cross toolchain, buildable from any machine.
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
  LDEXTRA  = -static
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
endef

# Generic rv64gc/glibc. Also runs on T-Head C906 - rv64gc is a strict subset
# of it, so no separate vendor target is needed.
define ARCH_45
  ARCHNAME = riscv64
  CLASS    = generic
  CC       = riscv64-linux-gnu-gcc
  STRIP    = riscv64-linux-gnu-strip
  HARDEN   = basic
  TUNE     = -march=rv64gc -mabi=lp64d
  KVM      = 0
  LMS      = 0
  APTPKG   = gcc-riscv64-linux-gnu
endef

$(eval $(ARCH_$(ARCHID)))
# These goals do not need a target selected.
ifeq ($(filter $(MAKECMDGOALS),list list-archs clean cleanbin),)
$(if $(ARCHNAME),,$(error unknown or missing ARCHID '$(ARCHID)' - run 'make list'))
endif

# ARCHID 25 builds natively on the Pi unless CROSS=1 asks for the cross toolchain.
ifeq ($(ARCHID)$(CROSS),251)
CC = $(PATH_RPI)bin/arm-linux-gnueabihf-gcc --sysroot=$(PATH_RPI)arm-linux-gnueabihf/sysroot
STRIP = $(PATH_RPI)bin/arm-linux-gnueabihf-strip
HOST =
endif

# The bsd targets build natively unless CROSS=1 selects a clang cross build.
# Default SYSROOT is the same $BUILDROOT/sysroots/<os>-<rel> tree env.sh/
# fetch-toolchains.sh use (openssl/libstatic/build/) - one sysroot serves both
# the OpenSSL archive build and the agent build, override with SYSROOT= for a
# one-off tree. lld is required - GNU ld can't target BSD - GNU strip is fine.
# := so these capture HOST/BUILDROOT before the native-guard clears HOST below.
BSDHOST := $(HOST)
BSDTRIPLE := x86_64-unknown-$(BSDHOST)$(BSDREL)
BUILDROOT ?= /opt/buildroot
ifeq ($(CLASS)$(CROSS),bsd1)
SYSROOT ?= $(BUILDROOT)/sysroots/$(BSDHOST)-$(BSDREL)
CC = clang --target=$(BSDTRIPLE) --sysroot=$(SYSROOT) -fuse-ld=lld -Wno-unused-command-line-argument
HOST =
endif

# ---- derived from the stanza above -----------------------------------------
OSSLARCH ?= $(ARCHNAME)

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

# HOST names the machine a native target must be built on - those stanzas have
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
  elif [ -t 0 ]; then printf "  Fetch it now with './fetch-toolchains.sh $(FETCH)'? [Y/n] "; read -r r; \
  else r=n; echo "  (stdin is not a terminal - re-run with YES=1 to fetch without asking)"; fi; \
  case "$$r" in \
    ""|[yY]|[yY][eE][sS]) ./fetch-toolchains.sh $(FETCH) || exit 1 ;; \
    *) echo "  run: ./fetch-toolchains.sh $(FETCH)"; exit 1 ;; \
  esac; \
  command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ] || \
    { echo "  fetched, but $$cc is still not there - check the path in the ARCH_$(ARCHID) stanza"; exit 1; }; \
elif [ -n "$(APTPKG)" ]; then \
  echo "  install it with: sudo apt-get install -y $(APTPKG)"; exit 1; \
else \
  echo "  no automated source for this toolchain - see openssl/libstatic/build/README.md"; exit 1; \
fi
endef

# Three hardening flavours, kept byte-identical to what each target used before.
HARDEN ?= full
CEXTRA_full  = -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security -fstack-protector -fno-strict-aliasing
CEXTRA_basic = -D_FORTIFY_SOURCE=2 -D_NOILIBSTACKDEBUG -D_NOFSWATCHER -Wformat -Wformat-security -fno-strict-aliasing
CEXTRA_none  = -fno-strict-aliasing
CEXTRA = $(CEXTRA_$(HARDEN))$(if $(CHAINLOCK), -DILIBCHAIN_GLOBAL_LOCK,)$(if $(TUNE), $(TUNE),)

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
LDEXTRA += -lssl -lcrypto
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
STRIP += ./$(EXENAME)_$(ARCHNAME)$(EXENAME2)
SYMBOLCP = cp ./$(EXENAME)_$(ARCHNAME)$(EXENAME2) ./DEBUG_$(EXENAME)_$(ARCHNAME)$(EXENAME2)
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

.PHONY: all clean cleanbin list list-archs print-toolchain print-ossldir print-bsdrel

all: $(EXENAME)

# One line per ARCHID with its toolchain status, narrowable: make list FILTER=openwrt
list list-archs:
	@printf "%6s  %-20s %-8s %-9s %s\n" ARCHID TARGET CLASS TOOLCHAIN COMPILER
	@awk '/^define ARCH_/{id=$$2; sub(/ARCH_/,"",id); n=""; c="-"} \
	      /^  ARCHNAME/{n=$$3} /^  CLASS/{c=$$3} \
	      /^endef/{if(id!="" && n!="" && (f=="" || c==f)) print id, n, c; id=""}' \
	      f="$(FILTER)" $(firstword $(MAKEFILE_LIST)) | sort -n | \
	while read -r id n c; do \
	  i=$$($(MAKE) -s --no-print-directory ARCHID=$$id print-toolchain); \
	  cc=$${i%%|*}; r=$${i#*|}; fetch=$${r%%|*}; r=$${r#*|}; \
	  apt=$${r%%|*}; r=$${r#*|}; host=$${r%%|*}; hostok=$${r#*|}; \
	  if [ -n "$$host" ] && [ -z "$$hostok" ]; then st=n/a; how="native build - run it on $$host"; \
	  elif command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ]; then st=ready; how="$$cc"; \
	  elif [ -n "$$fetch" ]; then st=MISSING; how="./fetch-toolchains.sh $$fetch"; \
	  elif [ -n "$$apt" ]; then st=MISSING; how="apt-get install $$apt"; \
	  else st=MISSING; how="bring your own ($$cc)"; fi; \
	  printf "%6s  %-20s %-8s %-9s %s\n" "$$id" "$$n" "$$c" "$$st" "$$how"; \
	done

# Machine-readable single-target probes: the toolchain the loop above needs,
# and the openssl/libstatic/ dir this target links (openssl/.../build.sh list).
print-toolchain:
	@echo '$(CCBIN)|$(FETCH)|$(APTPKG)|$(HOST)|$(HOSTOK)'

print-ossldir:
	@echo '$(if $(filter macos,$(CLASS)),macos/$(ARCHNAME),$(if $(filter bsd,$(CLASS)),bsd/$(ARCHNAME),linux/$(OSSLARCH)))'

# The OS release a bsd target cross-builds against - CI reads this to pick the
# matching sysroot tarball, so the release lives in one place (the stanza).
print-bsdrel:
	@echo '$(BSDREL)'


$(OBJDIR)/%.o: %.c
	@mkdir -p $(@D)
	$(V)$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

-include $(shell find obj -name '*.d' 2>/dev/null)

$(EXENAME): $(OBJECTS)
ifeq ($(SKIPFLAGS), 1)
	$(V)$(CC) $^ $(LDFLAGS) -lrt -o $@
else
	$(V)$(CC) $^ $(LDFLAGS) $(ADDITIONALFLAGS) -o $@
endif
clean:
	rm -rf obj

cleanbin:
	rm -f $(EXENAME)_* DEBUG_$(EXENAME)_*

# KVM=1 sources #include <X11/...> headers for type/macro definitions only -
# every actual X11 call is dlopen()/dlsym()'d against the *target device's own*
# libX11.so/libXtst.so/etc at runtime (see linux_kvm.c) or linked at build time.
# X11 client headers are a long-stable, arch-neutral C ABI, so the host's own
# libx11-dev/libxext-dev/libxtst-dev/libxrandr-dev (fetch-toolchains.sh installs
# these) are safe to compile ANY target against - no per-arch X11 build needed.
# Cross toolchains (Bootlin/musl.cc) don't search host system paths by default,
# unlike native gcc, so this must be explicit.
KVMINC = $(if $(filter 1,$(KVM)), -idirafter /usr/include)

linux:
	$(ensure_toolchain)
	$(MAKE) EXENAME="$(EXENAME)_$(ARCHNAME)$(EXENAME2)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)" ADDITIONALFLAGS="-lrt -z noexecstack -z relro -z now" CFLAGS="-DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(ARCHID) $(CFLAGS) $(CEXTRA) $(KVMINC)" LDFLAGS="$(LINUXSSL) $(LINUXFLAGS) $(LDFLAGS) $(LDEXTRA) -ldl"
	$(SYMBOLCP)
	$(STRIP)

macos:
	$(ensure_toolchain)
	$(MAKE) $(MAKEFILE) EXENAME="$(EXENAME)_$(ARCHNAME)" ADDITIONALSOURCES="$(MACOSKVMSOURCES)" CFLAGS="$(MACOSARCH) -std=gnu99 -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(ARCHID) -D_POSIX -D_NOILIBSTACKDEBUG -D_NOHECI -DMICROSTACK_PROXY -D__APPLE__ $(CWEBLOG) -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CEXTRA)" LDFLAGS="$(MACSSL) $(MACOSFLAGS) -L. -lpthread -ldl -lz -lutil -framework IOKit -framework ApplicationServices -framework SystemConfiguration -framework CoreServices -framework CoreGraphics -framework CoreFoundation -fconstant-cfstrings $(LDFLAGS) $(LDEXTRA)"
	$(SYMBOLCP)
	$(STRIP)

freebsd:
	$(ensure_toolchain)
	$(MAKE) EXENAME="$(EXENAME)_$(ARCHNAME)$(EXENAME2)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)"  CFLAGS="-std=gnu99 -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(ARCHID) -D_POSIX -D_FREEBSD -D_NOHECI -D_NOILIBSTACKDEBUG -DMICROSTACK_PROXY -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CEXTRA)" LDFLAGS="$(BSDSSL) $(BSDFLAGS) -L. -lpthread -ldl -lz -lutil $(LDFLAGS) $(LDEXTRA)"
	$(SYMBOLCP)
	$(STRIP)

openbsd:
	$(ensure_toolchain)
	$(MAKE) EXENAME="$(EXENAME)_$(ARCHNAME)$(EXENAME2)" ADDITIONALSOURCES="$(LINUXKVMSOURCES)"  CFLAGS="-std=gnu99 -Wall -DJPEGMAXBUF=$(KVMMaxTile) -DMESH_AGENTID=$(ARCHID) -D_POSIX -D_FREEBSD -D_OPENBSD -D_NOHECI -D_NOILIBSTACKDEBUG -DMICROSTACK_PROXY -fno-strict-aliasing $(INCDIRS) $(CFLAGS) $(CEXTRA)" LDFLAGS="$(BSDSSL) $(BSDFLAGS) -L. -lpthread -lz -lutil $(LDFLAGS) $(LDEXTRA)"
	$(SYMBOLCP)
	$(STRIP)

