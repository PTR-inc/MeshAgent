# MeshAgent build, table driven. The ARCHIDs live in buildscripts/targets-v3.conf, target-v3.sh
# derives the rest, fetch-deps-v3.sh installs what a row needs and check-v3.sh verifies it all.
# This file only knows how to compile and link. Use it as `make ARCHID=<id>`.
#
#   make list                  every ARCHID with its derived compiler and OpenSSL prefix
#   make ARCHID=7              build one target
#   make ARCHID=7 DEBUG=1      -O0 -g, crash handler in (glibc only), nothing stripped
#   make ARCHID=20 ASAN=1      AddressSanitizer build, the one test/test-agent.sh looks for
#   make ARCHID=7 clean        drop that target's objects
#
# One directory per row, build/<name>/ (ASAN=1 uses build/<name>_asan/), holding:
#   meshagent_<name>           the release build, stripped
#   SYMBOL_meshagent_<name>    that same binary before the strip, for symbolising its crashes
#   DEBUG_meshagent_<name>     the DEBUG=1 build, never stripped
# Only the prefix-less name is the shipped binary, which is also how test/test-agent.sh picks it out.
#
# Switches: DEBUG=1  ASAN=1 (linux glibc rows only)  KVM=0|1 (overrides the row)  OPT=-O2|-Os  V=1 (echo commands)  WEBLOG=1
#           CEXTRA=... LDEXTRA=... (appended last)  SIGN=0 (macOS: skip codesign)  SIGN_ADHOC=1  BUILDROOT=<dir>
#           MACOS_CC=xcode|zig (macOS rows on a Mac; default xcode when Apple clang is installed)
# Windows is not built here. A Mac (macOS 15+) builds every row; Linux builds every row but cannot run the Mach-O ones.

BUILDROOT ?= /opt/buildroot
export BUILDROOT

.PHONY: all list clean
ifeq ($(ARCHID),)
all list:
	@buildscripts/target-v3.sh list
clean:
	@echo "clean needs an ARCHID: make ARCHID=<id> clean"
else

# ---- the row -----------------------------------------------------------------------------------
TARGETMK := build/.target-$(ARCHID).mk
$(shell mkdir -p build && buildscripts/target-v3.sh make $(ARCHID) > $(TARGETMK) || rm -f $(TARGETMK))
ifeq ($(wildcard $(TARGETMK)),)
$(error target-v3.sh could not resolve ARCHID $(ARCHID) - run 'make list')
endif
include $(TARGETMK)

KVM ?= $(T_KVM)
OPT ?= -$(T_OPT)
CC   = $(T_CC)
LD   = $(T_LD)
# test/test-agent.sh finds an ASan agent as <dir>_asan/<binary>_asan, so both halves carry the suffix.
ASANSUF = $(if $(filter 1,$(ASAN)),_asan)
OUTDIR = build/$(T_NAME)$(ASANSUF)
OUTBIN = $(OUTDIR)/$(if $(filter 1,$(DEBUG)),DEBUG_)meshagent_$(T_NAME)$(ASANSUF)
SYMBOLBIN = $(OUTDIR)/SYMBOL_meshagent_$(T_NAME)$(ASANSUF)
# The stamp carries its binary's prefix, or a DEBUG=1 build would describe itself in the release one's.
STAMPFILE = $(OUTDIR)/$(if $(filter 1,$(DEBUG)),DEBUG_)build-stamp.txt
# A DEBUG=1 build sits next to the release one, so its objects need their own directory or the two
# would overwrite each other's and every switch between them would recompile the whole tree.
OBJDIR = $(OUTDIR)/obj$(if $(filter 1,$(DEBUG)),-debug)

ifeq ($(filter 1,$(V)),)
V := @
.SILENT:
else
V :=
endif

# ---- sources -----------------------------------------------------------------------------------
SOURCES  = microstack/ILibAsyncServerSocket.c microstack/ILibAsyncSocket.c microstack/ILibAsyncUDPSocket.c microstack/ILibParsers.c microstack/ILibMulticastSocket.c
SOURCES += microstack/ILibRemoteLogging.c microstack/ILibWebClient.c microstack/ILibWebServer.c microstack/ILibCrypto.c
SOURCES += microstack/ILibSimpleDataStore.c microstack/ILibProcessPipe.c microstack/ILibIPAddressMonitor.c
SOURCES += microstack/ILibWebRTC.c microstack/ILibWrapperWebRTC.c microscript/ILibDuktape_WebRTC.c
SOURCES += microscript/duktape.c microscript/duk_module_duktape.c microscript/ILibDuktape_DuplexStream.c microscript/ILibDuktape_Helpers.c
SOURCES += microscript/ILibDuktape_net.c microscript/ILibDuktape_ReadableStream.c microscript/ILibDuktape_WritableStream.c
SOURCES += microscript/ILibDuktapeModSearch.c microscript/ILibDuktape_SimpleDataStore.c microscript/ILibDuktape_GenericMarshal.c
SOURCES += microscript/ILibDuktape_fs.c microscript/ILibDuktape_SHA256.c microscript/ILibduktape_EventEmitter.c
SOURCES += microscript/ILibDuktape_EncryptionStream.c microscript/ILibDuktape_Polyfills.c microscript/ILibDuktape_Dgram.c
SOURCES += microscript/ILibDuktape_ScriptContainer.c microscript/ILibDuktape_MemoryStream.c microscript/ILibDuktape_NetworkMonitor.c
SOURCES += microscript/ILibDuktape_ChildProcess.c microscript/ILibDuktape_HttpStream.c microscript/ILibDuktape_Debugger.c
SOURCES += microscript/ILibDuktape_CompressedStream.c meshcore/zlib/adler32.c meshcore/zlib/deflate.c meshcore/zlib/inffast.c meshcore/zlib/inflate.c meshcore/zlib/inftrees.c meshcore/zlib/trees.c meshcore/zlib/zutil.c
SOURCES += meshcore/agentcore.c meshconsole/main.c meshcore/meshinfo.c

# The Linux KVM backends are guarded with __linux__ inside and dlopen their libraries, so the BSDs compile the same list.
KVMSOURCES_linux   = meshcore/KVM/Linux/linux_kvm.c meshcore/KVM/Linux/linux_kvm_wayland.c meshcore/KVM/Linux/linux_kvm_drm.c meshcore/KVM/Linux/linux_kvm_drm_egl.c meshcore/KVM/Linux/linux_kvm_rotated.c meshcore/KVM/Linux/linux_kvm_xkb.c meshcore/KVM/Linux/linux_events.c meshcore/KVM/Linux/linux_events_evdev.c meshcore/KVM/Linux/linux_tile.c meshcore/KVM/Linux/linux_compression.c
KVMSOURCES_freebsd = $(KVMSOURCES_linux)
KVMSOURCES_openbsd = $(KVMSOURCES_linux)
KVMSOURCES_macos   = meshcore/KVM/MacOS/mac_kvm.c meshcore/KVM/MacOS/mac_events.c meshcore/KVM/MacOS/mac_tile.c meshcore/KVM/Linux/linux_compression.c
ifeq ($(KVM),1)
SOURCES += $(KVMSOURCES_$(T_OS))
endif
OBJECTS = $(patsubst %.c,$(OBJDIR)/%.o,$(SOURCES))

# ---- flags -------------------------------------------------------------------------------------
# The per-target OpenSSL include comes first so its generated opensslconf.h is the one found.
INCDIRS = -I. -I$(T_OSSLDIR)/include -Iopenssl/$(T_OSSLVER)/include -Ilib-jpeg-turbo/includes -Imicrostack -Imicroscript -Imeshcore -Imeshconsole
DEFINES = -D_POSIX -D_FILE_OFFSET_BITS=64 -DMICROSTACK_PROXY -DMICROSTACK_TLS_DETECT -DILibChain_WATCHDOG_TIMEOUT=180000 \
          -DJPEGMAXBUF=0 -DMESH_AGENTID=$(T_SERVER) \
          -DDUK_USE_DEBUGGER_SUPPORT -DDUK_USE_INTERRUPT_COUNTER -DDUK_USE_DEBUGGER_INSPECT -DDUK_USE_DEBUGGER_PAUSE_UNCAUGHT
DEFINES_freebsd = -D_FREEBSD
DEFINES_openbsd = -D_FREEBSD -D_OPENBSD
DEFINES_macos   = -D__APPLE__
DEFINES += $(DEFINES_$(T_OS))
ifeq ($(KVM),1)
DEFINES += -D_LINKVM
endif
ifeq ($(T_LMS),0)
DEFINES += -D_NOHECI
endif
ifeq ($(WEBLOG),1)
DEFINES += -D_REMOTELOGGINGSERVER -D_REMOTELOGGING
endif
# The crash handler prints raw addresses and needs execinfo.h, so it is a DEBUG=1 aid for glibc only.
# ASAN=1 keeps it out even then, because ASan installs its own SIGSEGV handler and only one can report.
ifeq ($(DEBUG)$(T_LIBC)$(filter 1,$(ASAN)),1glibc)
DEFINES += -U_NOILIBSTACKDEBUG
else
DEFINES += -D_NOILIBSTACKDEBUG
endif

# _FORTIFY_SOURCE=3 needs glibc 2.34 headers to be more than level 2 and does nothing on musl, so glibc only.
HARDEN = -Wformat -Wformat-security -fstack-protector $(if $(filter glibc,$(T_LIBC)),-D_FORTIFY_SOURCE=3)
ifeq ($(DEBUG),1)
OPTFLAGS = -O0 -g -D_DEBUG
else
OPTFLAGS = $(OPT) -g
endif
# zig bundles a UBSan runtime and a TSan one but no ASan runtime at all, so the instrumentation is zig's
# own clang while the runtime archive is borrowed from the host's LLVM. clang 19's runtime links against
# zig 0.15.2's clang 20 instrumentation because the __asan_version_mismatch_check_v8 ABI has not moved.
ifeq ($(ASAN),1)
ifneq ($(T_OS)$(T_LIBC),linuxglibc)
$(error ASAN=1 needs a linux glibc row, not $(T_OS)/$(T_LIBC)$(if $(filter musl,$(T_LIBC)), - musl has no dlvsym and the ASan runtime's interceptors need it))
endif
ASANARCH := $(patsubst i686,i386,$(T_ARCH))
ASANRT  := $(shell clang -print-file-name=libclang_rt.asan-$(ASANARCH).a 2>/dev/null)
ASANRTS := $(shell clang -print-file-name=libclang_rt.asan_static-$(ASANARCH).a 2>/dev/null)
ifeq ($(wildcard $(ASANRT)),)
$(error ASAN=1 found no libclang_rt.asan-$(ASANARCH).a. Install the host clang and its compiler-rt (apt: clang))
endif
ASANCFLAGS = -fsanitize=address -fsanitize-recover=address -fno-omit-frame-pointer
# -lunwind is zig's own libunwind. The runtime needs _Unwind_Backtrace and zig links no unwinder by itself.
ASANLD = -Wl,--whole-archive $(ASANRT) -Wl,--no-whole-archive $(wildcard $(ASANRTS)) -lunwind
endif

CFLAGS = -std=gnu11 -Wall -fno-strict-aliasing $(OPTFLAGS) $(INCDIRS) $(DEFINES) $(HARDEN) $(T_CFLAGS)
ifeq ($(filter macos,$(T_OS)),)
CFLAGS += -ffunction-sections -fdata-sections
endif

# KVM on Linux compiles against the host's X11, EGL, wayland and libdrm headers; the libraries are dlopen'd at
# run time, never linked. A cross compiler does not search /usr/include, so the arch-neutral headers are
# staged into build/hostinc and reached with -idirafter, and libdrm's own -I comes from the host pkg-config.
HOSTINC = build/hostinc
ifeq ($(KVM)$(filter linux,$(T_OS)),1linux)
CFLAGS += -idirafter $(HOSTINC) $(shell /usr/bin/pkg-config --cflags libdrm egl glesv2 wayland-client 2>/dev/null)
STAGE_HOSTINC = mkdir -p $(HOSTINC) && ln -sfn /usr/include/X11 $(HOSTINC)/X11 \
  $(foreach d,EGL KHR GLES2,&& ln -sfn /usr/include/$(d) $(HOSTINC)/$(d)) \
  $(foreach f,$(notdir $(wildcard /usr/include/wayland-*.h)) xf86drm.h xf86drmMode.h,&& ln -sfn /usr/include/$(f) $(HOSTINC)/$(f))
else
STAGE_HOSTINC = :
endif
CFLAGS += $(ASANCFLAGS) $(CEXTRA)

# ---- link --------------------------------------------------------------------------------------
# -lpthread is repeated after -lcrypto because static link order matters (glibc 2.24 needs pthread_atfork after libcrypto).
SSLLIBS = -L$(T_OSSLDIR)/lib -lssl -lcrypto -lpthread
# 8 MB thread stack pinned: musl reads it from PT_GNU_STACK, which zig and gcc fill in differently.
LDFLAGS_linux   = $(SSLLIBS) $(T_JPEG) -lpthread -lutil -lm -ldl -lrt $(if $(filter static,$(T_LINK)),-static) \
                  -Wl,--gc-sections -Wl,-z,stack-size=8388608 -z noexecstack -z relro -z now
LDFLAGS_freebsd = $(SSLLIBS) $(T_JPEG) -lpthread -lutil -lm -ldl -Wl,--gc-sections -z noexecstack -z relro -z now
LDFLAGS_openbsd = $(SSLLIBS) $(T_JPEG) -lpthread -lutil -lm -Wl,--gc-sections -z noexecstack -z relro -z now
# LTO codegen happens at link, so the macOS optimisation flags are repeated there. -dead_strip is the -gc-sections of ld64.
# LTO only with Apple's toolchain (MACOS_CC=xcode): zig objects are not bitcode for the linker that follows them.
MACOSOPT = -O3 $(if $(filter xcode,$(T_MACOSCC)),-flto)
# No -lz anywhere: the agent compiles meshcore/zlib itself, and zig does not search the SDK for libz.tbd.
LDFLAGS_macos   = -mmacosx-version-min=$(T_OSVER) $(SSLLIBS) $(T_JPEG) -lpthread -framework IOKit -framework ApplicationServices -framework SystemConfiguration -framework CoreServices -framework CoreGraphics -framework CoreFoundation -framework Security -Wl,-dead_strip $(MACOSOPT)
ifeq ($(T_OS),macos)
CFLAGS += -mmacosx-version-min=$(T_OSVER) -fstack-protector-strong $(MACOSOPT)
endif
LDFLAGS = $(LDFLAGS_$(T_OS)) $(ASANLD) $(T_LDEXTRA) $(LDEXTRA)

# ---- rules -------------------------------------------------------------------------------------
all: $(OUTBIN)

# Only regenerate the commit header when the commit changed, or every parse would rebuild everything that includes it.
GITHASH := $(shell git log -1 --format=%H 2>/dev/null)
ifneq ($(GITHASH),)
ifneq ($(shell grep -qs '"$(GITHASH)"' microscript/ILibDuktape_Commit.h && echo uptodate),uptodate)
$(shell { echo "// This file is auto-generated, any edits may be overwritten"; \
  echo "#define SOURCE_COMMIT_DATE \"$$(git log -1 --format=%cI)\""; \
  echo "#define SOURCE_COMMIT_HASH_SHORT \"$$(git rev-parse --short=12 HEAD)\""; \
  echo "#define SOURCE_COMMIT_FILEVERSION $$(git log -1 --date=format:'%y,%m,%d,%H%M' --format=%cd)"; \
  echo "#define SOURCE_COMMIT_HASH \"$(GITHASH)\""; } > microscript/ILibDuktape_Commit.h)
endif
endif

# Objects depend on the exact compile line, so a flag change recompiles instead of linking stale objects.
FLAGSTAMP = $(OBJDIR)/.cflags
$(shell mkdir -p $(OBJDIR); printf '%s\n' '$(CC) $(CFLAGS)' | cmp -s - $(FLAGSTAMP) 2>/dev/null || printf '%s\n' '$(CC) $(CFLAGS)' > $(FLAGSTAMP))

$(OBJDIR)/%.o: %.c $(FLAGSTAMP)
	@mkdir -p $(@D)
	$(V)$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

# zlib and Duktape are vendored upstream code kept as it ships, so their warnings are silenced here rather
# than patched away: zlib's 80 K&R definitions, and three in Duktape's amalgamation. The zlib spelling is
# clang's, and the one gcc row (sparc64) would otherwise report it as an unknown option.
$(OBJDIR)/meshcore/zlib/%.o: CFLAGS += $(if $(findstring gcc,$(T_CCBIN)),,-Wno-deprecated-non-prototype)
$(OBJDIR)/microscript/duktape.o: CFLAGS += -Wno-unused-but-set-variable -Wno-pointer-sign -Wno-unused-variable

-include $(shell find $(OBJDIR) -name '*.d' 2>/dev/null)

define ensure_toolchain
	@cc='$(T_CCBIN)'; if ! { command -v "$$cc" >/dev/null 2>&1 || [ -x "$$cc" ]; }; then \
	  echo "ARCHID=$(ARCHID) ($(T_NAME)): compiler '$$cc' not found (BUILDROOT=$(BUILDROOT))"; exit 1; fi; \
	if [ '$(T_LDBIN)' != '$(T_CCBIN)' ] && ! command -v '$(T_LDBIN)' >/dev/null 2>&1; then \
	  echo "ARCHID=$(ARCHID) ($(T_NAME)): linker driver '$(T_LDBIN)' not found"; exit 1; fi; \
	case '$(T_LD)' in *-fuse-ld=lld*) command -v ld64.lld >/dev/null 2>&1 || ls /usr/lib/llvm-*/bin/ld64.lld >/dev/null 2>&1 || \
	  { echo "ARCHID=$(ARCHID) ($(T_NAME)): the macOS cross link needs the host's lld package (ld64.lld)"; exit 1; } ;; esac; \
	[ -n '$(filter 1,$(DEBUG) $(ASAN))' ] || command -v '$(T_STRIPBIN)' >/dev/null 2>&1 || { echo "ARCHID=$(ARCHID) ($(T_NAME)): '$(T_STRIPBIN)' not found (apt/brew: llvm)"; exit 1; }; \
	if [ -n '$(T_SYSROOT)' ] && [ ! -f '$(T_SYSROOT)/usr/lib/libc.so' ]; then echo "ARCHID=$(ARCHID): sysroot $(T_SYSROOT) missing or empty - buildscripts/fetch-deps-v3.sh $(T_OS)"; exit 1; fi; \
	if [ ! -d '$(T_OSSLDIR)/lib' ]; then echo "ARCHID=$(ARCHID): OpenSSL prefix $(T_OSSLDIR) not installed - openssl/build/build.sh $(T_OSSL)"; exit 1; fi; \
	if [ '$(KVM)$(T_OS)' = 1linux ] && ! /usr/bin/pkg-config --exists libdrm egl glesv2 wayland-client 2>/dev/null; then \
	  echo "ARCHID=$(ARCHID): KVM needs libdrm-dev libegl-dev libgles-dev libwayland-dev pkg-config on the host"; exit 1; fi
endef

# The strip step keeps the unstripped copy as SYMBOL_ for symbolising crashes; DEBUG=1 and ASAN=1 keep
# the symbols in place, an ASan report resolves to file and line only while they are still there.
ifneq ($(filter 1,$(DEBUG) $(ASAN)),)
STRIPSTEP = :
else
STRIPSTEP = cp "$(OUTBIN)" "$(SYMBOLBIN)" && $(T_STRIP) "$(OUTBIN)" && echo "strip   $(OUTBIN)  (symbols kept in $(SYMBOLBIN))"
endif
# Apple Silicon refuses a binary whose signature strip invalidated, so macOS re-signs (buildscripts/sign-v3.sh).
ifeq ($(T_OS)$(filter 0,$(SIGN)),macos)
SIGNSTEP = buildscripts/sign-v3.sh "$(OUTBIN)"
else
SIGNSTEP = :
endif

$(OUTBIN): $(OBJECTS) $(wildcard $(T_OSSLDIR)/lib/libcrypto.a $(T_OSSLDIR)/lib/libssl.a) $(T_JPEG)
	@echo "link    $@  (ARCHID $(ARCHID), $(T_NAME), $(T_OS) $(T_ARCH) $(T_LIBCLABEL))"
	$(V)$(LD) $(OBJECTS) $(LDFLAGS) -o $@
	$(V)$(STRIPSTEP)
	$(V)$(SIGNSTEP)
	$(V){ echo "archid: $(ARCHID)"; echo "name: $(T_NAME)"; echo "server_archid: $(T_SERVER)"; echo "cc: $(CC)"; echo "ld: $(LD)"; \
	      echo "cc_version: $$( { $(T_CCBIN) --version 2>/dev/null || $(T_CCBIN) version 2>/dev/null; } | head -1)"; \
	      echo "cflags: $(CFLAGS)"; echo "ldflags: $(LDFLAGS)"; echo "openssl: $(T_OSSLDIR)"; echo "jpeg: $(T_JPEG)"; \
	      echo "kvm: $(KVM)  lms: $(T_LMS)  debug: $(DEBUG)  asan: $(ASAN)"; \
	      echo "git_rev: $$(git rev-parse --short HEAD 2>/dev/null)$$(git diff --quiet 2>/dev/null || echo '-dirty')"; \
	      echo "built_at: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "size: $$(wc -c < $@)"; } > $(STAMPFILE)

# The toolchain check and the header staging run before any object is compiled.
$(OBJECTS): | prepare
prepare:
	$(ensure_toolchain)
	$(V)$(STAGE_HOSTINC)
.PHONY: prepare

list:
	@buildscripts/target-v3.sh list

clean:
	rm -rf $(OBJDIR)
endif
