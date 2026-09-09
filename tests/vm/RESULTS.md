# VM suite: status and findings

Status of `tests/vm-boot.sh` as committed. Written so the next person does not
repeat the dead ends — most of the work here was finding out which of the
obvious approaches UTM actually supports.

**Host these results come from:** macOS 25.6 (Darwin), arm64, UTM 4.7.5,
NixOS `nixos-25.05` minimal ISO (x86_64), guest emulated under QEMU TCG.

## Where it stands

**Green. 71 checks, 0 failed, 1 skipped** — both firmware modes, all four
phases, one clean run. Verbatim:

```
assets
  ok   installer ISO cached (1.7G)
  ok   generated configuration evaluates
  ok   repo ISO built
  ok   installer ISO repacked with a serial console as the default entry
uefi
  ok   uefi: guest serial port opens
  ok   uefi: install-me.sh completes on a 3-disk mirror
  ok   uefi: hostid was set before any pool existed
  ok   uefi: pool is a mirror
  ok   uefi: pools exported for a clean first import
  ok   uefi: installed system boots off the mirror
  ok   uefi: hostname from unique.nix
  ok   uefi: hostid survived the install
  ok   uefi: root pool is ONLINE
  ok   uefi: pool reports healthy
  ok   uefi: root is the zfs dataset
  ok   uefi: layout json matches the firmware
  ok   uefi: layout json records 3 disks
  ok   uefi: systemd reports the system running
  ok   uefi: no failed units
  ok   uefi: zfs-health-check reports healthy
  ok   uefi: no vdev is DEGRADED
  ok   uefi: every mirror member's boot partition is mounted
  ok   uefi: root pool imported without a force flag
  ok   uefi: GRUB is at the removable path
  ok   uefi: boots with the first mirror member pulled
  ok   uefi: pool notices the missing disk
  ok   uefi: pool is DEGRADED but usable
  ok   uefi: root still mounted from the pool
  ok   uefi: a missing /boot did not block startup (nofail)
  ok   uefi: zfs-health-check reports the degradation
  ok   uefi: replace-boot-disk.sh resilvers onto a new disk
  ok   uefi: GUIDs randomised on the replacement
  ok   uefi: bootloader reinstalled onto the new disk
  ok   uefi: pool healthy again after resilver
  ok   uefi: layout json now names the new disk
  ok   uefi: pool is ONLINE again, not just not-failing
  ok   uefi: no vdev left DEGRADED after the resilver
  ok   uefi: hostid unchanged by the replace
bios
  ok   bios: guest serial port opens
  ok   bios: install-me.sh completes on a 3-disk mirror
  ok   bios: hostid was set before any pool existed
  ok   bios: pool is a mirror
  ok   bios: pools exported for a clean first import
  ok   bios: installed system boots off the mirror
  ok   bios: hostname from unique.nix
  ok   bios: hostid survived the install
  ok   bios: root pool is ONLINE
  ok   bios: pool reports healthy
  ok   bios: root is the zfs dataset
  ok   bios: layout json matches the firmware
  ok   bios: layout json records 3 disks
  ok   bios: systemd reports the system running
  ok   bios: no failed units
  ok   bios: zfs-health-check reports healthy
  ok   bios: no vdev is DEGRADED
  ok   bios: every mirror member's boot partition is mounted
  ok   bios: root pool imported without a force flag
  skip bios: removable EFI path (BIOS mode has no ESP)
  ok   bios: boots with the first mirror member pulled
  ok   bios: pool notices the missing disk
  ok   bios: pool is DEGRADED but usable
  ok   bios: root still mounted from the pool
  ok   bios: a missing /boot did not block startup (nofail)
  ok   bios: zfs-health-check reports the degradation
  ok   bios: replace-boot-disk.sh resilvers onto a new disk
  ok   bios: GUIDs randomised on the replacement
  ok   bios: bootloader reinstalled onto the new disk
  ok   bios: pool healthy again after resilver
  ok   bios: layout json now names the new disk
  ok   bios: pool is ONLINE again, not just not-failing
  ok   bios: no vdev left DEGRADED after the resilver
  ok   bios: hostid unchanged by the replace
vm-boot: 71 checks, 0 failed, 1 skipped
```

The single skip is structural: BIOS mode has no ESP, so there is no removable
EFI path to check.

**What this establishes.** A machine installed onto a 3-way ZFS root mirror
boots, in both UEFI and BIOS mode. It comes up with the pool ONLINE, systemd at
`running` with no failed units, every mirror member's boot partition mounted,
the root pool imported with no force flag on the kernel command line, and the
health check quiet. Pull the first mirror member — in UEFI mode that is the
disk whose ESP is mounted at `/boot` — and it still boots: DEGRADED, `/`
intact, `nofail` keeping the missing `/boot` from blocking startup, and
`zfs-health-check` reporting the degradation. Then `replace-boot-disk.sh`
partitions a blank replacement, randomises its GUIDs, resilvers, reinstalls the
bootloader on every member, and the pool returns to fully ONLINE with the
hostId undisturbed.

Getting here took several runs, and the failures along the way were worth more
than the green: three real defects, listed below.

### Still not established

None of these are failures; they are the honest edges of what this suite
covers.

- **Widening and narrowing a mirror.** The VM suite drives
  `replace-boot-disk.sh` on its default replace path only; `--add` and `--drop`
  are covered by neither the VM suite nor the unit tests.
- **The data pool, and `add-data-pool.sh` entirely.** `install-me.sh` is driven
  with the data pool skipped, so encrypted-pool creation, import and the
  `/root/.zfs-encrypt.key` handling are evaluation-only, and
  `add-data-pool.sh` is never executed by any suite.
- **Resilvering onto a genuinely smaller disk.** `disk-integration.sh` proves
  the 1 GiB of end slack exists and that a smaller disk is rejected where it
  should be, but the VM replace hands over a disk of identical size, so the
  slack has never actually been used for what it is for.
- **by-id stability across reboots.** The by-id defect below was found here, so
  the mechanism is understood, but a test that installs, reboots several times
  and asserts the recorded paths still resolve has not been written.
- **The UTM backend since the Proxmox work.** The expect drivers are shared,
  and they changed a lot while the Proxmox backend was being built: per-probe
  end markers, a rewritten `enter_bash`, `spawn` without `eval`, and a tunable
  keystroke pace. UTM keeps its slower default and nothing in those changes is
  backend-specific, but its last green run predates all of them, so treat the
  71-check result above as unverified against current HEAD until someone spends
  the hours to re-run it.
- **Real hardware.** The guest is emulated. Firmware quirks, real controller
  behaviour and anything timing-dependent are out of reach by construction.

## The same suite on Proxmox

Both backends are green. On a Proxmox VE 8.2.5 node with `/dev/kvm`, both
firmware modes run **in parallel** and pass: **75 checks, 0 failed, 1 skipped,
16m22s wall clock** for the pair.

```
assets
  ok   installer ISO cached (1.7G)
  ok   generated configuration evaluates
  ok   repo ISO built
  ok   installer ISO repacked with a serial console as the default entry
uefi
  ok   uefi: guest serial port opens
  ok   uefi: install-me.sh completes on a 3-disk mirror
  ok   uefi: hostid was set before any pool existed
  ok   uefi: pool is a mirror
  ok   uefi: pools exported for a clean first import
  ok   uefi: installed system boots off the mirror
  ok   uefi: hostname from unique.nix
  ok   uefi: hostid survived the install
  ok   uefi: root pool is ONLINE
  ok   uefi: pool reports healthy
  ok   uefi: root is the zfs dataset
  ok   uefi: layout json matches the firmware
  ok   uefi: layout json records 3 disks
  ok   uefi: systemd reports the system running
  ok   uefi: no failed units
  ok   uefi: zfs-health-check reports healthy
  ok   uefi: no vdev is DEGRADED
  ok   uefi: every mirror member's boot partition is mounted
  ok   uefi: root pool imported without a force flag
  ok   uefi: GRUB is at the removable path
  ok   uefi: boots with the first mirror member pulled
  ok   uefi: pool notices the missing disk
  ok   uefi: pool is DEGRADED but usable
  ok   uefi: root still mounted from the pool
  ok   uefi: a missing /boot did not block startup (nofail)
  ok   uefi: zfs-health-check reports the degradation
  ok   uefi: replace-boot-disk.sh resilvers onto a new disk
  ok   uefi: GUIDs randomised on the replacement
  ok   uefi: bootloader reinstalled onto the new disk
  ok   uefi: pool healthy again after resilver
  ok   uefi: layout json now names the new disk
  ok   uefi: pool is ONLINE again, not just not-failing
  ok   uefi: no vdev left DEGRADED after the resilver
  ok   uefi: hostid unchanged by the replace
  uefi/install       5m27s
  uefi/boot          0m55s
  uefi/degraded      4m34s
  uefi/replace       4m15s
  total             15m11s
vm-boot: 38 checks, 0 failed, 0 skipped
  ok   installer ISO cached (1.7G)
  ok   generated configuration evaluates
  ok   repo ISO built
  ok   installer ISO repacked with a serial console as the default entry
bios
  ok   bios: guest serial port opens
  ok   bios: install-me.sh completes on a 3-disk mirror
  ok   bios: hostid was set before any pool existed
  ok   bios: pool is a mirror
  ok   bios: pools exported for a clean first import
  ok   bios: installed system boots off the mirror
  ok   bios: hostname from unique.nix
  ok   bios: hostid survived the install
  ok   bios: root pool is ONLINE
  ok   bios: pool reports healthy
  ok   bios: root is the zfs dataset
  ok   bios: layout json matches the firmware
  ok   bios: layout json records 3 disks
  ok   bios: systemd reports the system running
  ok   bios: no failed units
  ok   bios: zfs-health-check reports healthy
  ok   bios: no vdev is DEGRADED
  ok   bios: every mirror member's boot partition is mounted
  ok   bios: root pool imported without a force flag
  skip bios: removable EFI path (BIOS mode has no ESP)
  ok   bios: boots with the first mirror member pulled
  ok   bios: pool notices the missing disk
  ok   bios: pool is DEGRADED but usable
  ok   bios: root still mounted from the pool
  ok   bios: a missing /boot did not block startup (nofail)
  ok   bios: zfs-health-check reports the degradation
  ok   bios: replace-boot-disk.sh resilvers onto a new disk
  ok   bios: GUIDs randomised on the replacement
  ok   bios: bootloader reinstalled onto the new disk
  ok   bios: pool healthy again after resilver
  ok   bios: layout json now names the new disk
  ok   bios: pool is ONLINE again, not just not-failing
  ok   bios: no vdev left DEGRADED after the resilver
  ok   bios: hostid unchanged by the replace
  bios/install       3m10s
  bios/boot          0m55s
  bios/degraded      3m57s
  bios/replace       4m28s
  total             12m30s
vm-boot: 37 checks, 0 failed, 1 skipped
```

### Where the hour went

The first working Proxmox run took about an hour for both modes. It now takes
about sixteen minutes. Only one of the five changes was a tuning knob; the rest
were bugs:

| Change | Effect |
|---|---|
| The resilver wait grepped for a pattern that never matched | replace 15m -> 5m |
| The backend was still asking for 4 vCPUs | install 9m -> 5m26s |
| The two firmware modes run in parallel | ~38m -> ~18m |
| `enter_bash` waited for a prompt that could not appear | boot 3m -> ~2m |
| Keystroke pacing tuned for emulation, not KVM | boot 2m -> 0m51s |

The resilver loop polled for `scan:.*resilvered`, but a scrubbed pool reports
`scan: scrub repaired 0B` on that line, so it ran its full ceiling of 120 x
`sleep 5` after a resilver that finishes in seconds. `enter_bash` waited for a
prompt that only exists *after* the command that sets it, so every attempt
burned a 30s timeout. And the drivers typed at 33 characters a second -- right
for fish redrawing over an emulated line, four and a half seconds per probe on
a KVM guest talking to bash.

### Sizing was tested and the intuition was wrong

More vCPUs and more memory both make it slower, measured by timing the install
phase alone on a 32-thread node:

| vCPUs | RAM | install |
|---|---|---|
| **8** | **8 GiB** | **5m26s** |
| 8 | 16 GiB | 5m41s |
| 16 | 8 GiB | 5m54s |
| 16 | 16 GiB | 6m08s |
| 24 | 8 GiB | 6m29s |

The guest confirms it received what it was given (`CPUS=24 MEM=8087816` appears
in its own transcript), so this is scheduling contention on a host that is also
running other guests, not nix ignoring the cores. Scaling the VM to a fraction
of the host would make the suite slower, not faster.

The network is not the constraint either: the node pulls from the binary cache
at 9.4 MB/s, so ~734 store paths are one to two minutes of an otherwise
CPU-bound phase.

### What parallelism exposed

Running the modes at once did more than halve the clock -- it applied enough
timing pressure to surface three bugs that sequential runs had been masking,
and one that was actively dangerous:

- **A finished mode destroyed its sibling's VM.** `vm_destroy_all` removes
  every test VM and each mode's cleanup trap called it, so bios finishing 90
  seconds early took uefi's VM down mid-replace. It presented as the console
  dropping 41 times, which is why it was twice misdiagnosed as a timing race;
  the Proxmox task log settled it (`qmdestroy 9001` at 02:38:50, uefi still
  using that socket at 02:40:11). **Read the hypervisor's own task history
  before theorising about the guest.**
- **A fixed 300s shutdown budget.** Under load the degraded phase ran 337s, so
  `vm_wait_stopped` gave up and the next phase started a VM that was still
  stopping.
- **`vm_start` believed a "running" VM that was shutting down**, and treated
  the start task finishing as the guest being up.

### Optimisations considered and rejected

Recorded so they are not re-attempted:

- **More vCPUs or memory.** Tested and monotonically worse; the table above has
  the numbers. The guest transcript proves it received what it was given, so
  this is host scheduler contention, not nix declining the cores. Scaling the
  VM to a fraction of the host would make the suite slower.
- **A local binary cache on the node.** The node pulls from cache.nixos.org at
  9.4 MB/s, so the install's ~734 store paths are one to two minutes of a phase
  dominated by compiling GRUB. A cache would be a second-order win and means
  running and maintaining another service on someone's hypervisor.
- **Sharing the GRUB build between firmware modes.** They are different
  derivations -- `efiSupport` differs -- so there is nothing to share.
- **Shortening the degraded phase.** It is ~4m against ~1m for a healthy boot,
  and the extra time is the guest importing a pool with a missing member. That
  is the behaviour under test, not harness overhead: the boot mounts already
  carry `x-systemd.device-timeout=5s` and the log shows the device job
  honouring it.

## The `_1` suffix: retracted, and what it really was

On the first boot after an early install, `/boot` did not mount:

```
DEPEND] Dependency failed for /boot.
DEPEND] Dependency failed for File System …/nvme-QEMU_NVMe_Ctrl_disk0_1-part1.
```

An earlier version of this file called that `_1` suffix "QEMU's NVMe naming in
this emulator, not a fault in the installer". **That was wrong**, and the
correction is the most valuable thing this suite has produced. See the defects
section below: the suffix is how udev names the namespace-scoped by-id link,
every NVMe disk has one alongside the device-level link, and the installer was
picking between the two nondeterministically.

Do not dismiss a `_1` as emulator noise. It is reproducible on real NVMe
hardware and it had a real consequence.

Two useful things fell out of the incident anyway:

- **`nofail` demonstrably works.** A mirror member's ESP failed to mount and
  the machine still booted to a shell with the pool ONLINE, which is exactly
  what `nofail` plus `zfs-health.nix` are there for.
- **It exposed a weak assertion.** The removable-EFI check originally looked
  only under `/boot`, so with that mount missing it read an empty directory.
  Worse, before the transcript parser was fixed it *passed anyway*, because the
  greedy match was matching the echoed command text `ls
  /boot/EFI/BOOT/BOOTX64.EFI` rather than the command's output -- a false pass.
  It now checks every ESP, which is the actual invariant.

## The real defects these tests found

**`set_hostid` could not run on a NixOS ISO.** `/etc/hostid` there is a symlink
into `/etc/static`, which lives in the read-only `/nix/store`, so both branches
of `set_hostid` were writing *through* it and dying with `fopen: Read-only file
system`. Since the hostId must be stamped into the pool labels before any pool
exists, the installer could not get past its first step on the medium it is
designed for. Nothing short of a real ISO boot reproduces this.

**A live mirror member was offered as a replacement disk.** This is the serious
one, because `replace-boot-disk.sh` runs `sgdisk --zap-all` on the answer.

An NVMe disk carries two by-id links of equal rank: the device-level
`nvme-MODEL_SERIAL` and the namespace-scoped `nvme-MODEL_SERIAL_1`, both
pointing at the same device. `by_id_path` ranked them equally and kept
whichever `udevadm` happened to list first — and `udevadm` promises no order.
So the pool was recorded as `nvme-QEMU_NVMe_Ctrl_disk2` at install time while a
later scan returned `nvme-QEMU_NVMe_Ctrl_disk2_1` for that same disk.
`select_disks` then decided "already spoken for" by string equality, did not
match, and listed a live mirror member as a candidate. Only
`assert_disks_free`, which compares *resolved* devices rather than names,
stopped it.

The nondeterminism is visible in the results: the same commit failed this way
under `uefi` and passed under `bios`, because the two runs got the two links in
different orders.

Fixed at both layers — `by_id_path` breaks equal-rank ties deterministically,
and `select_disks` compares disks with a `same_disk` helper that resolves both
paths. Both are covered in `tests/nix-eval.sh`'s sibling suite
`tests/lib-unit.sh`, including both `udevadm` orderings, since this reproduces
with a fake `udevadm` and needs no VM at all. That is the pattern to follow:
**once a VM finds something, push the regression test down into CI.**

**Every healthy machine reported a stale bootloader copy.** `zfs-health.nix`
compares the set of filenames on each boot mount, and a freshly installed
machine failed that comparison immediately, on a 15-minute timer:

```
BOOT MIRROR: /boot-fallback-1 does not match /boot - stale bootloader copy
```

A `bootdiff` probe was added rather than guessing, and the difference turned out
to be a single file:

```
339d338
< memtest.bin
```

`memtest.bin` comes from `boot.loader.grub.extraFiles` (enabled by
`memtest86.enable` in `disk-layout.nix`) and a fresh install leaves it on
`/boot` only. GRUB does not need it to boot anything, so counting it achieved
nothing except to make a good machine cry wolf — and a check that fires on a
healthy machine is ignored on the one occasion it is right. Excluded, for the
same reason `grub.cfg` and `grubenv` already were.

Worth recording what this was *not*, because the first hypothesis was that the
installer left the fallback ESPs incomplete. It does not:
`nixpkgs`' `grub.nix` runs `install-grub.pl` once per `mirroredBoots` entry with
its own `bootPath`, so every ESP gets its own `grub/`, `kernels/` and `EFI/`.
Reading that source settled the question before the VM data arrived and agreed
with it.

**`utm_reload` hung indefinitely.** `osascript -e 'tell application "UTM" to
quit'` has no timeout, so with UTM busy the harness deadlocked on its own
AppleScript call and phases sat for tens of minutes without starting. This is
what made runs look like a slow emulator rather than a stuck harness. Signals
instead; `utm_reload` now returns in 1.5s.

## How long a run takes, and what was done about it

The guest is x86_64 on an arm64 host, so QEMU emulates. What was measured:

- **The install compiles GRUB from source, and that dominates.** This is the
  answer to "why does a run take so long", and it is not the harness's doing.
  `disk-layout.nix` sets `boot.loader.grub.zfsSupport = true` — GRUB has to
  read the pool to boot a ZFS root — which produces a derivation the binary
  cache does not carry. So GRUB 2.12 is built inside the emulator, once per
  firmware mode (the UEFI and BIOS builds differ in `efiSupport`, so they
  cannot share). Installing this repo does this on real hardware too; it just
  takes minutes there. Nothing can remove it.
- **Documentation is not in the binary cache.** The NixOS manual and the man
  cache are generated per configuration, so they were the other large
  derivations being *compiled* inside the emulator. Disabled in the fixture.
- **The channel copy is the single slowest step, and reverted.** Skipping it
  with `--no-channel-copy` broke the `replace` phase outright:
  `replace-boot-disk.sh` ends in `nixos-rebuild boot --install-bootloader`,
  which without a channel dies with `error: file 'nixpkgs/nixos' was not found
  in the Nix search path`. A self-inflicted failure from optimising the install
  without thinking about what the later phases need. The hook stays in
  `install-me.sh`; the suite does not use it.
- **vCPUs: 8, and the earlier claim here was wrong.** This file used to say
  "more vCPUs do not help, the guest workload is serial". The GRUB build is not
  serial: at 4 vCPUs, `QEMULauncher` measured ~400% — all four threads
  saturated — on an 18-core host (12 performance) that was otherwise idle, so
  the count was raised to 8. `nix` defaults `cores = 0`, so `make -j` follows
  the vCPU count on its own and needs no installer flag, and `ForceMulticore`
  is not the lever since the threads were already saturated without it.

  Stated honestly: the effect of 8 vCPUs on the *sequential* stages
  (partitioning, pool creation, the channel copy) is **unmeasured**. It is
  justified by the compile alone.

Even so, an install is hours of wall clock, and the remaining phases and the
bios matrix are hours more. Treat this as an overnight release gate.

Two measurement traps worth knowing, both of which sent this investigation
down a blind alley: `QEMUHelper` is a wrapper that always reads ~0% CPU (the
emulator is `QEMULauncher`), and `ps -o %cpu` on macOS is a decaying average
since process start. Use `top -l 2`. A silent transcript is also not a hang --
the closure copy and the build phase print nothing for long stretches.

## What does not work in UTM, and why

Three approaches were tried before the current one. Each is documented in the
code at the point where it matters, but collected here:

**1. `utmctl` / AppleScript cannot attach an ISO.** `make new virtual machine`
accepts a full configuration and will create the CD *device*, but it silently
ignores `source:` on a removable drive — the drive appears with `ImageName`
unset. Hence the harness writes the `.utm` bundle itself (`jq` → `plutil`).
AppleScript also collides on `serial ports`, which must be written as the raw
four-char code `«class SrPt»`; the bundle avoids that entirely.

**2. QEMU direct kernel boot is impossible through UTM.**
`QEMU.AdditionalArguments` is a flat array of strings and UTM splits every
entry on whitespace when building argv, so `-append "init=… root=… console=…"`
arrives as several arguments and QEMU treats the tail as disk images:

```
qemu-x86_64-softmmu: root=LABEL=nixos-minimal-25.05-x86_64:
  Could not open 'root=LABEL=nixos-minimal-25.05-x86_64': No such file or directory
```

Plain, double-quoted and backslash-escaped forms all fail identically.

**3. The stock ISO's bootloader cannot be driven over serial.** OVMF *does*
mirror output to the serial port and the GRUB menu renders there perfectly.
But GRUB never acts on serial input: keystrokes are echoed into the output
stream (visible as `Press 't' to use the text boot menu on this**t** console`
and `GNU GRUB  ve**c**rsion 2.12`), the countdown still expires, and the
default entry — which sets no `console=` — boots anyway. The stock ISO offers
serial only from a submenu that therefore cannot be reached.

### What does work

Repacking the ISO. `xorriso -boot_image any replay` copies the El Torito boot
setup verbatim, so the image stays bootable in both BIOS and UEFI mode, while
`EFI/BOOT/grub.cfg` and `isolinux/isolinux.cfg` are replaced with versions that

- put GRUB itself on the serial port **and give it `terminal_input serial`**,
  which is what the stock image is missing,
- add `console=ttyS0,115200n8` to every kernel line, and
- shorten the boot timeout.

The BIOS side needed less: `isolinux.cfg` already opens with `SERIAL 0 115200`,
so only the `APPEND` lines needed the console argument.

## Two traps that cost real time

Both are now handled in `lib-utm.sh`, and both fail in the same misleading way
— a console that simply never says anything, which is indistinguishable from a
hung guest at emulation speed.

**UTM caches VM configuration in memory.** It reads every bundle in its
Documents folder at launch and does not re-read it. Editing a `config.plist`
behind its back does nothing — a VM kept booting with `-kernel` arguments that
had already been removed from its plist. Every bundle rewrite must be followed
by `utm_reload` (quit and relaunch UTM) before the VM is started. Note also
that AppleScript `import` is *not* the fix: it copies the bundle and leaves two
VMs registered under the same name.

**`utmctl start` on a running VM is a silent no-op.** Skipping the wait for
`stopped` means the next phase attaches to the *previous* boot.

**`nc -z` as a readiness probe breaks the session.** UTM's serial `TcpServer`
serves one client, and the probe consumes it; the connection that matters then
gets an immediate EOF. `vm_serial_ready` checks for a LISTEN socket with `lsof`
instead and never connects.

**`utmctl stop` can wedge.** A stuck VM answers `stop --force` with
`OSStatus error -1712` (AppleEvent timed out) and stays `started` forever.
`vm_kill` therefore falls back to killing the QEMU process by bundle path.

## The installer runs bash; the installed system runs fish

`configuration.nix` sets `users.users.root.shell = pkgs.fish`, and that split
accounts for a whole class of failures where the guest looked hung or a probe
looked empty. Two distinct problems, found in that order:

**fish rejects `$?`.** `... | replace-boot-disk.sh; echo R-EXIT=$?` was typed,
submitted, and thrown away by fish before the script ever ran — fish wants
`$status`. The console showed a command sitting on the prompt line and no
output. The install phase was never affected because that runs on the ISO,
under bash.

**fish repaints the line as characters arrive.** Syntax highlighting and
autosuggestions redraw the input line on every keystroke, and over a slow
emulated serial console that turned `echo PROBE:...` into `eecho PROBE:...`,
which fish then reported through its command-not-found handler. The probe never
ran, and the transcript scraper picked a redraw fragment instead of a value —
so **every probe in the boot and degraded phases came back empty while the boot
itself passed**. Eleven assertions failed for that one reason, and the same
commit passed all of them under `bios` once the fix was in.

The fix for both is to stop scripting into an interactive shell. The drivers
land in fish first — which still proves the login shell works, and is worth
keeping — then `exec bash --noprofile --norc` with a fixed one-line prompt, and
readline's line editing and bracketed paste turned off. No repainting, no
autosuggestion, no command-not-found, no `$?`-versus-`$status`.

Two earlier theories in this file were wrong and are named so they are not
retried: a trailing `\r` being eaten by the prompt redraw, and the command
being too long to submit. What isolated the real cause was the readiness
handshake — once the shell provably echoed a token back, "the shell is not
listening" was ruled out and only "the shell mangled the command" was left.

## expect traps, all of which look like a hung guest

These cost more time than anything on the UTM side, so they are worth naming.

**`spawn` inside a Tcl proc sets a *local* `spawn_id`** unless the proc
declares it global — the caller is left with no connection at all.

**`close` with nothing spawned closes expect's own stdout.** The first
`serial_connect` call did this, which silently destroyed the script's output.
Guard it with a `connected` flag.

**`log_file` records only the spawned process's I/O, not `send_user`.** Every
`FAILED:` line was going to stdout and never reaching the transcript the suite
greps — so a failed phase reported "see the log" and the log said nothing.
`bail` now writes with both `send_user` and `send_log`.

**Comments inside an `expect {}` block are patterns, not comments.** Tcl does
not treat `#` specially in a pattern list, so every `# ...` line was a live
pattern matching stray output. Both blocks were rewritten with the commentary
moved above them.

**`send` on a dropped connection raises, it does not return an error.** UTM
drops the serial TCP client whenever the guest reinitialises the UART, which
the `expect {}` blocks all handle with an `eof` branch — but `wait_shell_ready`,
`enter_bash` and `probe` called `send` directly. A drop landing inside the
handshake produced

```
send: spawn id exp6 not open
    while executing
"send -s "echo $tok""
    (procedure "wait_shell_ready" line 5)
```

which killed a phase that had booted perfectly well, and skipped the two phases
after it. Every direct `send` is now wrapped in `catch` with a reconnect.

**Do not bail on a marker before the line carrying it has arrived.** The
replace driver matched `FATAL` and exited immediately, cutting the connection
mid-line, so the transcript ended at `` FATAL  /d`` — the first two characters
of `/dev/disk/by-id/... is in use by imported pool`. The reason *is* the value
of the failure; the driver now drains the rest of the line before reporting.

## The one that actually blocked the run

Synchronising on an echoed marker does not work on this console. The driver
would send `echo QUIET-OK`, the transcript would show `QUIET-OK` arriving —
proving expect had *read* it — and the matching `expect` would sit there until
it timed out. Raising `match_max`, throttling the send, and reconnecting all
failed to change it.

Synchronising on the shell prompt regex works, and it is what the driver does
now:

```tcl
proc wait_prompt {code msg} {
    expect {
        -re {root@nixos:[^\r\n]*\]#} { }
        eof     { reconnect_or_bail; send -s "\r"; exp_continue }
        timeout { bail $code $msg }
    }
}
```

Note the prompt pattern itself: the real prompt is
`[\033]0;root@nixos: ~\007root@nixos:~]#`, so an intuitive `\[root@nixos` never
matches — the `[` is followed by an escape sequence, not by the username. For
the same reason a `{[#$] $}` prompt wait never fires: the line ends with
`$ \033[0m `, not with `$ `.

## Finishing the run

```sh
nix-shell -p xorriso
bash tests/vm-boot.sh                  # hours; both modes, all phases
bash tests/vm-boot.sh uefi install     # or one phase at a time
```

Phases are stateful, so a partial run needs `VM_KEEP=1` to leave the VM in
place for the next phase. Transcripts land in `tests/vm/logs/`.

When a full run completes, replace the status table above with what it actually
reported. If it fails, the transcript plus the `FAILED:` line the expect driver
prints is the whole story.

## The rule that made this suite worth its runtime

Every defect above was found by a booted VM and then **pushed down into CI**:
the hostId symlink problem is guarded by `tests/lint.sh` and the ISO's own
behaviour, and the by-id defect has unit tests in `tests/lib-unit.sh` covering
both `udevadm` orderings with a fake `udevadm` and no VM at all.

Do the same with anything found here. A VM run is the only way to *discover*
this class of bug and the worst possible way to *regression-test* it — hours
versus a second or two. The VM suite should keep only what genuinely needs
firmware, a bootloader and an initrd.
