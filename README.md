# ocudu-macos-arm64

A reproducible kit for building and running the [OCUDU](https://gitlab.com/ocudu/ocudu)
gNB natively on macOS with Apple Silicon, validated with a 5G SA attach of
srsUE over a ZeroMQ virtual radio against an Open5GS 5GC, all on one machine.

OCUDU is the successor of srsRAN Project, a 5G CU/DU written for Linux. This
repository carries no OCUDU source. It carries 49 numbered patches against the
upstream tag `release_26_10` (commit `e0db566a`), the gNB and UE configuration
of the loopback test, two host-side scripts, and the Darwin facts that are not
in any manual. Clone upstream, `git am` the patches, build.

## What was validated

Platform: macOS 26 (Darwin 25.6) on Apple M-series, Apple clang 21, Homebrew,
CMake 4.4, Ninja 1.13, OCUDU 26.10.0, Open5GS v2.8.0, srsUE from srsRAN 4G.

- Build: `apps/gnb/gnb` configures and links with `-Werror` on, with the
  ZeroMQ and UHD radio plugins in the binary, against the SCTP shim
  libsctp-compat 0.4.0, mbedtls, FFTW and yaml-cpp. `gnb --version` reports
  26.10.0. The `lib/support` and gateway unit tests were built and run while
  those libraries were ported (patches 019 and 027 to 031 come from there);
  the full `tests/` tree was not built.
- NG Setup: the gNB opens a one-to-one SCTP association to the AMF through
  the shim (UDP encapsulation 9900 to 9899) and completes NG Setup in 4.5 ms.
- Registration: srsUE in NR SA mode finds the cell (band n3, ARFCN 368500,
  10 MHz), completes RACH, RRC Setup, 5G-AKA, Security Mode and Registration
  in 375 ms from Registration Request to Registration Complete; the AMF logs
  `Registration complete` for the test subscriber.
- PDU Session: the UE receives IP 10.45.0.3 from the SMF, the gNB completes
  the PDU Session Resource Setup and configures the N3 GTP-U tunnel; SMF and
  UPF log the same session.
- User plane: `run-5gsa-ocudu-ue.sh` sets the crossed host routes and pings
  both ways, UE to gateway and gateway to UE, 4 of 4 packets each way. This
  result was read from the terminal during the run; the kept logs cover the
  control plane and the GTP-U tunnel setup, not the ping output.

Nothing is transmitted at any point: both ends exchange IQ samples over TCP on
localhost. No RF hardware was used with OCUDU in this work.

The scripts in `config/` were rewritten after the validation run to take
their paths from the environment and to carry English messages. They passed
`bash -n` and the render test; the functional run was made with the
unscrubbed versions on the same tree. Logic and commands are the same.

## Quick start

### 1. Dependencies

```
brew install cmake ninja googletest yaml-cpp mbedtls fftw zeromq uhd tmux
```

Two more pieces come from companion repositories:

- [libsctp-compat-macos-arm64](https://github.com/AndreiGosman/libsctp-compat-macos-arm64)
  v0.4.0 or later: the Linux lksctp API over usrsctp with UDP encapsulation
  (RFC 6951). Install it into your prefix; OCUDU finds it through
  `pkg-config --exists sctp`. Version 0.4.0 adds what OCUDU needs beyond
  srsRAN 4G: `sctp_getaddrinfo`, `sctp_getpaddrs`/`sctp_getladdrs`, and
  `SCTP_EVENT` subscription on one-to-one sockets.
- [open5gs-macos-arm64](https://github.com/AndreiGosman/open5gs-macos-arm64):
  the 5GC. Its 5GC configuration set and `lo0-aliases-5gc.sh` are what
  `start-5gc-user.sh` starts. Render that set into `$CONFDIR/open5gs-5gc`.
- For the UE, [srsRAN-4G-macos-arm64](https://github.com/AndreiGosman/srsRAN-4G-macos-arm64)
  with its patches 027 and 028 (the NR SA fixes), installed into the same prefix.

### 2. Build OCUDU with the patches

```
export PREFIX="$HOME/ocudu-lab/local"                     # where libsctp-compat is installed
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
git clone https://github.com/AndreiGosman/ocudu-macos-arm64.git
git clone --branch release_26_10 https://gitlab.com/ocudu/ocudu.git
cd ocudu
git am ../ocudu-macos-arm64/patches/*.patch
mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_ZEROMQ=ON -DENABLE_DPDK=OFF -DENABLE_DIFI=OFF ..
ninja gnb
./apps/gnb/gnb --version
```

- `ENABLE_DIFI=OFF`: the DIFI radio plugin uses `htobe*` from glibc's
  `endian.h`; the loopback does not need it and it is left unported.
- `-Werror` stays on. Every warning Apple clang 21 raised is fixed by a
  patch, not silenced.
- After any patch that touches a CMake probe, `rm -rf build` before
  reconfiguring; CMake caches the probe results.
- The shim's `libsctp.dylib` is linked by absolute path from the prefix, so
  no `DYLD_*` variable is needed at run time. `sudo` strips them anyway.

### 3. Render the configuration

`config/gnb.yml` and `config/srsue/ue.conf` carry one placeholder,
`@LOGDIR@`, for the pcap paths.

```
export LOGDIR="$HOME/ocudu-lab/logs" CONFDIR="$HOME/ocudu-lab/config"
ocudu-macos-arm64/config/render.sh "$LOGDIR" "$CONFDIR"
```

That writes `$CONFDIR/ocudu-5gsa/gnb.yml` and `$CONFDIR/srsue/ue.conf`. The
5GC set from the open5gs kit goes to `$CONFDIR/open5gs-5gc` with that kit's
own `render.sh`.

### 4. Run the 5GC

```
sudo "$CONFDIR/open5gs-5gc/lo0-aliases-5gc.sh"                           # once per boot
PREFIX="$PREFIX" CONFDIR="$CONFDIR" LOGDIR="$LOGDIR" MONGODB="$HOME/ocudu-lab/mongodb" \
  ocudu-macos-arm64/config/start-5gc-user.sh                             # mongod + 10 NFs, no root
sudo "$PREFIX/bin/open5gs-upfd" -c "$CONFDIR/open5gs-5gc/upf.yaml"       # root: utun, own terminal
```

The subscriber is the Open5GS test subscriber (IMSI 001010000000001, the K
and OPc from the Open5GS documentation); add it with `open5gs-dbctl` as the
open5gs kit describes.

### 5. gNB alone

```
LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900 LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899 \
  ocudu/build/apps/gnb/gnb -c "$CONFDIR/ocudu-5gsa/gnb.yml"
```

Expected within a second: `"NG Setup Procedure" finished successfully` and
`Connected to AMF. Supported PLMNs: 00101`. The AMF logs `Number of gNBs is
now 1`.

### 6. Attach test

```
sudo PREFIX="$PREFIX" CONFDIR="$CONFDIR" LOGDIR="$LOGDIR" \
     GNB="$PWD/ocudu/build/apps/gnb/gnb" ocudu-macos-arm64/config/run-5gsa-ocudu-ue.sh
```

The script stops a leftover srsUE and gNB with SIGINT, restarts the gNB as
`$SUDO_USER` through the shim, waits for NG Setup, starts srsUE in a tmux
session, waits for `PDU Session Establishment successful`, sets the UPF utun
destination to the UE address, installs the crossed host routes and pings
both ways. Stop the UE with `tmux send-keys -t 5gsa-ocudu C-c`.

## The 49 patches

All are on the `darwin-arm64` lineage over `release_26_10`; the series
replays on the clean tag (84 files, 1772 insertions, 129 deletions, 7 new
files). Each commit message states the symptom, the cause and the choice
made. Grouped by what they do:

Build system (001, 002, 004, 018, 020, 023, 033, 047). CMake sees `arm64`
on Darwin where Linux says `aarch64`; `sed -i` is BSD sed; the bundled fmt
must beat the Homebrew one on the include path; GTest comes as an imported
target, not a bare `gtest` name; the SCTP include directory must propagate
to every user of `ocudu_gateway`; UHD and ZeroMQ headers are system
includes so their warnings do not trip `-Werror`; `libatomic` exists only
where it exists.

Darwin backends in `lib/support` (007 to 017, 049). `cpu_set_t`,
`sched_getcpu` and `sched_getaffinity` through a compat header; thread
affinity calls compiled out; PMULL detection through `sysctl` instead of
`getauxval`; per-thread rusage through a wrapper; the perf_event RAPL
reader Linux-only; `futex_util` on `os_sync_wait_on_address`; the pool
memory region without `MAP_HUGETLB`; `SO_BINDTODEVICE` by interface name;
`SOCK_DCCP` and `SOCK_PACKET` guarded. Two are real backends rather than
guards: 016 emulates `timerfd` with a kqueue `EVFILT_TIMER` and a pipe per
timer, so `io_timer_source` keeps reading the expiration count out of a
descriptor, and 017 adds a kqueue `io_broker` next to the epoll one, with
`EV_DISPATCH` giving the same one-shot rearm semantics the executors rely
on. 049 gives `unique_thread` an 8 MB stack: Darwin's default for secondary
threads is 512 KB, and one `fapi::dl_tti_request` on the stack is 74 KB,
so the gNB died with SIGBUS at its first slot.

SCTP gateway (020, 021, 022, 024, 025, 048). `sendmmsg`/`recvmmsg`
emulated for the UDP gateway with exact sockaddr lengths; `sctp_assoc_t`
is unsigned on the shim; endpoints resolved through `sctp_getaddrinfo`.
048 is the one to know: CMake puts libraries after objects on the link
line, and the two-level namespace binds `socket`, `bind`, `connect`,
`sendmsg` and friends to the first library that exports them, which is
libSystem. The gNB then creates a kernel socket with no SCTP behind it and
reports `Failed to create SCTP socket`. The patch passes the shim through
`target_link_options` on Apple so it comes first.

Compiler and libc differences (003, 005, 006, 026, 032, 034 to 041, 044
to 046). glibc macros that Apple's libc does not have (`M_SQRT2f32`,
`iszero`, `le16toh`, `__always_inline`, `<linux/udp.h>`); `OVERFLOW` and
`UNDERFLOW` are macros in Darwin's `math.h` and collide with radio event
names; `std::min`/`std::max` literal types on LP64 where `uint64_t` is
`unsigned long long`, not `unsigned long`; libc++'s `system_clock` counts
microseconds, so adding nanoseconds changes the `time_point` type; CLI11
without `<codecvt>`; and 032, an Apple clang 21 strictness: a `switch` on
an `enumerated<>` object inside a template is rejected, the fix switches on
its value.

Linux-only subsystems and tests (012, 019, 027 to 031, 043). The raw
socket Ethernet fronthaul and the perf_event reader build on Linux only.
Tests that need loopback aliases (`lo0` has only 127.0.0.1 by default), IPv6
SCTP, or a TCP self-connect are skipped on Darwin; the SCTP test node polls
for the peer's event instead of assuming ordering, and the simultaneous
shutdown sequence usrsctp produces is accepted.

Radio (039, 042, 046). RF plugins are loaded with the platform's shared
library suffix and without `RTLD_DEEPBIND`, which Darwin lacks.

Several of these are not Darwin-specific and are candidates for upstream:
002, 003, 018, 020, 022, 023, 024, 028, 029, 031, 032, 033, 035 to 041,
045, 046, 047. None has been submitted yet.

## Darwin behaviours to know

1. NGAP must bind to the real 127.0.0.1, never to an `lo0` alias. The
   association "succeeds" on an alias and nothing flows afterwards. OCUDU
   has the explicit key `cu_cp.amf.bind_addrs`; the shipped `gnb.yml` sets
   it.
2. One UDP encapsulation port per process. The Open5GS AMF runs native
   usrsctp on UDP 9899. The gNB's shim takes `LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900`
   and `LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899`; two processes on 9899
   fight silently.
3. ZeroMQ gains must be 0 dB or lower. OCUDU 26.10 rejects positive
   `tx_gain`/`rx_gain` for the ZMQ device with `Channel gain must be <= 0.0
   dB for ZMQ-device` and exits. The UHD examples use 75.
4. ZeroMQ is REQ/REP. Once a srsUE dies, the gNB serves no new client.
   Stop the UE first, then restart the gNB, then start the UE. SIGINT, never
   SIGKILL; the gNB writes its pcap files on a clean shutdown.
5. Under `nohup`, stdin is `/dev/null`, which kqueue refuses to register.
   The gNB logs `kevent failed with "Invalid argument"` and `Couldn't
   register stdin handler` once and runs on; interactive stdin commands are
   unavailable in that mode.
6. `Could not check scaling governor` and `Could not check DRM KMS polling`
   are the Linux `/sys` probes failing. They also appear on Linux without
   those files and are harmless.
7. Root processes. The UPF and srsUE need root for the utun; the gNB does
   not. Stop root processes with `pkill -INT -x <name>`.
8. The UPF utun has a self point-to-point destination (`10.45.0.1 -->
   10.45.0.1`). On a single host that pins the gateway address to the UPF
   utun, so a UE-to-gateway ping never crosses the radio path. Setting the
   destination to the UE address first makes the crossed host routes stick;
   `run-5gsa-ocudu-ue.sh` does it. A UE on another machine needs none of
   this.

## Layout

```
patches/                   001 to 049, git format-patch output, apply with git am
config/render.sh           render @LOGDIR@ into gnb.yml and ue.conf
config/gnb.yml             OCUDU gNB: ZeroMQ 11.52 MHz, band n3, ARFCN 368500, 10 MHz, PCI 500,
                           PLMN 001/01, TAC 7, AMF on 127.0.0.1:38412, pcap on
config/srsue/ue.conf       srsUE NR SA over ZeroMQ, matched to the cell above
config/start-5gc-user.sh   mongod and the ten non-root Open5GS 5GC NFs, idempotent
config/run-5gsa-ocudu-ue.sh  gNB restart, srsUE in tmux, crossed routes, ping both ways (sudo)
LICENSES/                  the upstream OCUDU license text
```

`gnb.yml` is the upstream `configs/gnb_rf_b210_fdd_srsUE.yml` (the `pdcch`,
`prach` and `mcs` parameters srsUE needs) with the radio switched to ZeroMQ
at 11.52 MHz, gains at 0 dB, the cell set to band n3, ARFCN 368500, 10 MHz,
PCI 500, PLMN 001/01, TAC 7, SST 1, and the AMF address and bind address on
127.0.0.1. `ue.conf` is the srsRAN 4G example with NR SA mode, the ZeroMQ
ports crossed with the gNB (UE tx 2001, rx 2000), the matching band and
ARFCN, and the Open5GS test subscriber.

## Credits and license

OCUDU is developed by Software Radio Systems and contributors and is
licensed under the BSD 3-Clause Open MPI variant license; its text is in
`LICENSES/BSD-3-Clause-Open-MPI.txt`. The patches are modifications to
OCUDU files and are offered under those same terms. The kit's own files
(this README, `NOTICE`, `config/render.sh` and the two scripts) are released
under the MIT license, see `LICENSE`. srsRAN 4G is AGPL-3.0; `ue.conf` is
derived from its example configuration. See `NOTICE` for the full
provenance.

Port and kit by Andrei Gosman.
