# MeshAgent Architecture Hardware Guide

This document maps each MeshAgent ARCHID to typical hardware platforms that use that architecture.

## Linux x86/x86-64 (glibc, KVM-enabled)

### ARCHID 5 — Linux x86 32-bit
- Desktop/server x86 32-bit systems (legacy, glibc 2.24)
- Older small form-factor industrial PCs
- Legacy embedded x86 systems

### ARCHID 6 — Linux x86 64-bit
- Desktop and server x86-64 systems (mainline, glibc 2.24)
- Generic Linux distributions (Debian, Ubuntu, CentOS, etc.)
- Virtual machines on x86-64 hosts

## Linux x86/x86-64 (glibc, NOKVM/headless)

### ARCHID 19 — Linux x86 32-bit NOKVM
- Headless servers and cloud VMs (32-bit, glibc 2.24)
- Containers and lightweight virtualization
- Server appliances without display/KVM support

### ARCHID 20 — Linux x86 64-bit NOKVM
- Cloud VMs and data center infrastructure (x86-64, glibc 2.24)
- Containerized deployments (Docker, Kubernetes)
- Headless server appliances

## Linux ARM 32-bit

### ARCHID 9 — Linux ARM 32-bit (armel/ARMv5, soft-float)
- Marvell Kirkwood/Orion plug computers (SheevaPlug, Dockstar)
- Early NAS systems (Synology, QNAP, Buffalo, D-Link)
- Industrial ARMv5 systems (Microchip SAM9X60, NXP i.MX28)
- Soft-float ABI (gnueabi), because these cores have no VFP unit. ARCHID 24 and 25 are the
  hard-float ARMv7/ARMv6 targets

### ARCHID 24 — Linux ARM 32-bit (ARMv7 hardfloat)
- Industrial embedded systems (2012-2016 era)
- Generic ARMv7 devices, and every Raspberry Pi from the 2 up on a 32-bit userland, including
  the Pi Zero 2 W, which is Cortex-A53 and not ARMv6 despite the name
- Embedded gateways and appliances
- Has KVM since 2026-08-31, so it is the 32-bit ARM target with remote desktop

### ARCHID 25 — Linux ARM 32-bit (ARMv6 hardfloat, ARM1176JZF-S)
- Raspberry Pi 1 A/B/B+, Pi Zero and Pi Zero W only, the ARMv6 + VFPv2 boards
- Built with -mcpu=arm1176jzf_s against an ARMv6 OpenSSL archive. Anything ARMv7 (Pi 2 and
  newer, Pi Zero 2 W) belongs to ARCHID 24: an ARMv7 binary will not start on these boards,
  which is what shipped before 2026-08-31
- glibc floor 2.28, which is Raspbian Buster. Debian is retiring ARMEL and Raspberry Pi OS
  32-bit is the last mainstream ARMv6 hardfloat build, supported to roughly 2030

## Linux ARM 64-bit

### ARCHID 26 — Linux ARM 64-bit (glibc 2.40)
- Raspberry Pi 3/4/5 (64-bit mode) on a current distribution
- Generic aarch64 Linux systems, modern userland
- ARM64 embedded development boards
- Pinned to glibc 2.40, which is the "newest/native" end of the pair. Measured 2026-08-31: the
  binary requires symbols up to GLIBC_2.38, so it runs on Ubuntu 24.04 and Debian 13 or newer,
  and will NOT start on Debian 12 (2.36), Ubuntu 22.04 (2.35) or RHEL 9 (2.34). Those userlands
  are ARCHID 32's job, which pins 2.31 and measures GLIBC_2.29

### ARCHID 32 — Linux ARM 64-bit (legacy glibc 2.31)
- Legacy aarch64 embedded systems
- Pre-OpenWRT arm64 hardware compatibility
- Older industrial arm64 appliances

## Linux MIPS/MIPSEL

### ARCHID 7 — Linux MIPSEL (MIPS32r1, static musl)
- Broadcom BMIPS3300/BMIPS4350 routers and DSL CPE (BCM47xx/BCM53xx, BCM63xx), including the
  WRT54G generation and ISP-supplied ADSL/VDSL modems
- Broadcom BMIPS5000 cable modems and set-top boxes (BCM33xx, BCM7xxx)
- Atheros AR231x/AR2315 and MIPS 4Kc devices (early 802.11g APs, MikroTik RB100-series)
- Anything pre-Release-2: the 24KC/74K SoCs in most TP-Link, Netgear and Belkin routers are
  MIPS32r2 and belong to ARCHID 28 (big-endian) or 40 (little-endian), not here
- Statically linked against musl, so no libc is needed on the device, but musl wants Linux
  2.6.39 or later - stock vendor firmware older than that needs a uClibc build instead

### ARCHID 28 — Linux MIPS 24KC (OpenWRT)
- TP-Link, Netgear, Belkin MIPS routers (24KC SoC)
- Legacy home/SMB router devices
- OpenWRT-based MIPS systems

### ARCHID 40 — Linux MIPSEL 24KC (OpenWRT)
- TP-Link, Netgear, Belkin MIPSEL routers
- Classic consumer/SMB router deployments
- OpenWRT-based MIPSEL systems

## Linux ARM 64-bit (OpenWRT)

### ARCHID 41 — Linux ARM 64-bit Cortex-A53 (OpenWRT)
- MediaTek Wi-Fi SoC routers (modern generation)
- Qualcomm-based home/SMB routers (2018+)
- Mainstream OpenWRT aarch64 systems

## Linux x86-64 (OpenWRT/musl)

### ARCHID 36 — Linux x86-64 (OpenWRT/musl)
- x86-64 mini-PCs as routers/firewalls
- OpenWRT mini-PC appliances
- OPNsense/pfSense-style x86-64 router boxes
- Enthusiast/SMB network appliances

## Linux RISC-V

### ARCHID 45 — Linux RISC-V 64-bit (T-Head Xuantie C906)
- Allwinner D1 with T-Head vendor extensions
- StarFive development boards
- T-Head Xuantie vendor SoCs
- SiFive RISC-V systems

### ARCHID 46 — Linux RISC-V 64-bit (generic rv64gc)
- Generic RISC-V 64-bit systems
- SiFive standard ISA boards
- RISC-V hyperscaler systems
- Software emulation/QEMU RISC-V

### ARCHID 47 — Linux RISC-V 32-bit (generic rv32gc)
- RISC-V 32-bit embedded systems
- Lightweight IoT RISC-V devices
- Educational/development boards

## Linux Specialty

### ARCHID 33 — Alpine Linux x86 64-bit (musl)
- Alpine Linux x86-64 systems
- Container/Docker environments using Alpine
- Lightweight Linux deployments

### ARCHID 35 — Linux ARM (Armada 370 hardfloat)
- Seagate/Western Digital NAS (2012-2015)
- Linksys/plug computer devices
- Marvell Armada 370 SoC legacy systems

### ARCHID 60 — Linux SPARC64 (SPARC V9)
- Legacy/specialist SPARC V9 systems
- Oracle/Sun SPARC servers (obsolete)
- Emulation and retrocomputing

### ARCHID 70 — Linux PowerPC64LE (POWER8)
- IBM POWER8 server systems (legacy)
- OpenPOWER initiative systems
- Specialist/datacenter PowerPC deployments

## BSD

### ARCHID 30 — FreeBSD x86 64-bit
- FreeBSD servers and workstations
- FreeBSD NAS appliances (FreeNAS/TrueNAS)
- BSD-based security appliances

### ARCHID 37 — OpenBSD x86 64-bit
- OpenBSD workstations and servers
- OpenBSD firewalls and security appliances
- Specialty BSD deployments

## macOS

### ARCHID 16 — macOS x86 64-bit
- Intel-based macOS systems (pre-2021)
- Mac minis, iMacs, MacBook Pro (Intel)
- macOS servers and workstations

### ARCHID 29 — macOS ARM 64-bit (Apple Silicon)
- Apple Silicon Macs (M1, M2, M3, M4 series)
- MacBook Air/Pro (Apple Silicon)
- Mac mini/Mac Studio (Apple Silicon)
