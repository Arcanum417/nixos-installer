# VM suite: status and findings

Status of `tests/vm-boot.sh` as committed. Written so the next person does not
repeat the dead ends — most of the work here was finding out which of the
obvious approaches UTM actually supports.

**Host these results come from:** macOS 25.6 (Darwin), arm64, UTM 4.7.5,
NixOS `nixos-25.05` minimal ISO (x86_64), guest emulated under QEMU TCG.

## Where it stands

A full `uefi` run has been executed. Results, verbatim:

```
assets
  ok   installer ISO cached (1.7G)
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
  FAIL uefi: GRUB is at the removable path
  ok   uefi: boots with the first mirror member pulled
  ok   uefi: pool notices the missing disk
  ok   uefi: pool is DEGRADED but usable
  ok   uefi: root still mounted from the pool
  ok   uefi: a missing /boot did not block startup (nofail)
  FAIL uefi: zfs-health-check reports the degradation
```

**The thing this suite exists to prove works.** A machine installed onto a
3-way ZFS root mirror boots, and it still boots with the first mirror member --
the one whose ESP is mounted at `/boot` -- pulled, coming up DEGRADED but
usable with `/` intact.

Both failures were faults in the harness, not the installer, and both are fixed
in the committed code but **have not yet been re-verified by a run**:

- *GRUB is at the removable path* -- the probe looked only under `/boot`. See
  the section below: that mount had failed, so it read an empty directory. It
  now checks every ESP. Note this assertion was *passing* before the transcript
  parser was fixed, because the greedy match was matching the echoed command
  text rather than its output. A false pass.
- *zfs-health-check reports the degradation* -- the probe discarded the output.
  It built `$( cmd 2>/dev/null | tr ... )` while callers passed
  `zfs-health-check || true`, which the shell parses as
  `cmd || { true | tr ... }`: a command exiting non-zero has its stdout thrown
  away. A health check exits non-zero exactly when it has something to report,
  so that probe was guaranteed blank in the one case it exists for. Now
  `{ cmd ; } 2>&1`.

### Not yet established

- **`replace`.** Root cause found and fixed; the fix is **not yet verified by
  a run** because each attempt costs hours.

  The phase reached a shell, sent its command, and the script never produced a
  line. The cause is that `configuration.nix` sets

  ```nix
  users.users.root.shell = pkgs.fish;
  ```

  and **fish does not accept `$?`** -- it rejects the expression and tells you
  to use `$status`. So `... | replace-boot-disk.sh; echo REPLACE-EXIT=$?` was
  typed, submitted, and discarded by fish before the script ever ran. That is
  exactly what the console showed: a command sitting on the prompt line and no
  output. It also explains why the install phase was never affected -- that
  runs on the ISO, under bash.

  The command is now wrapped in `bash -c` so the pipeline, the quoting and
  `$?` all mean what the script expects.

  Two earlier theories in this file were wrong and are worth naming so they
  are not retried: a trailing `\r` being eaten by fish's prompt redraw, and
  the command being too long to submit. Neither was it. What isolated the real
  cause was the readiness handshake -- once the shell provably echoed a token
  back, "the shell is not listening" was ruled out and only "the shell
  rejected the command" was left.

  The lesson for anyone extending this suite: **the installer environment is
  bash, the installed system is fish.** Anything sent to the installed system
  should go through `bash -c`.

- **The whole `bios` matrix.** Never run.
- **A clean re-run of `uefi`** with the two harness fixes in place.

## A VM-environment limitation worth knowing

On the first boot after install, `/boot` did not mount:

```
DEPEND] Dependency failed for /boot.
DEPEND] Dependency failed for File System …/nvme-QEMU_NVMe_Ctrl_disk0_1-part1.
```

Note the `_1`. udev appended a disambiguation suffix to that disk's by-id name
when the installer recorded it, and the suffix did not come back the same way
on the next boot, so the path in `disk-layout.json` no longer existed. That is
QEMU's NVMe naming in this emulator, not a fault in the installer -- but it
does mean **this suite cannot validate by-id stability across reboots**, which
is worth remembering before trusting it on that point.

Two useful things fell out of it anyway:

- **`nofail` demonstrably works.** A mirror member's ESP failed to mount and
  the machine still booted to a shell with the pool ONLINE, which is exactly
  what `nofail` plus `zfs-health.nix` are there for.
- **It exposed a weak assertion.** The removable-EFI check originally looked
  only under `/boot`, so with that mount missing it read an empty directory.
  Worse, before the transcript parser was fixed it *passed anyway*, because the
  greedy match was matching the echoed command text `ls
  /boot/EFI/BOOT/BOOTX64.EFI` rather than the command's output -- a false pass.
  It now checks every ESP, which is the actual invariant.

## Two real defects these tests found

**`set_hostid` could not run on a NixOS ISO.** `/etc/hostid` there is a symlink
into `/etc/static`, which lives in the read-only `/nix/store`, so both branches
of `set_hostid` were writing *through* it and dying with `fopen: Read-only file
system`. Since the hostId must be stamped into the pool labels before any pool
exists, the installer could not get past its first step on the medium it is
designed for. Nothing short of a real ISO boot reproduces this.

**`utm_reload` hung indefinitely.** `osascript -e 'tell application "UTM" to
quit'` has no timeout, so with UTM busy the harness deadlocked on its own
AppleScript call and phases sat for tens of minutes without starting. This is
what made runs look like a slow emulator rather than a stuck harness. Signals
instead; `utm_reload` now returns in 1.5s.

## How long a run takes, and what was done about it

The guest is x86_64 on an arm64 host, so QEMU emulates. Three things were
measured and changed:

- **Documentation is not in the binary cache.** The NixOS manual and the man
  cache are generated per configuration, so they were the only large
  derivations being *compiled* inside the emulator. Disabled in the fixture.
- **The channel copy is the single slowest step, and reverted.** Skipping it
  with `--no-channel-copy` broke the `replace` phase outright:
  `replace-boot-disk.sh` ends in `nixos-rebuild boot --install-bootloader`,
  which without a channel dies with `error: file 'nixpkgs/nixos' was not found
  in the Nix search path`. A self-inflicted failure from optimising the install
  without thinking about what the later phases need. The hook stays in
  `install-me.sh`; the suite does not use it.
- **More vCPUs do not help.** See the note in `lib-utm.sh`: the guest workload
  is serial, so multi-threaded TCG has nothing to spread.

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

## Four expect traps, all of which look like a hung guest

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
