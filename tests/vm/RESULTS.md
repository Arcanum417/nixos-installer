# VM suite: status and findings

Status of `tests/vm-boot.sh` as committed. Written so the next person does not
repeat the dead ends — most of the work here was finding out which of the
obvious approaches UTM actually supports.

**Host these results come from:** macOS 25.6 (Darwin), arm64, UTM 4.7.5,
NixOS `nixos-25.05` minimal ISO (x86_64), guest emulated under QEMU TCG.

## Where it stands

**The `install` phase passes. The `boot` phase reaches the installed system and
its facts are correct. `degraded` and `replace` have not been run to
completion, and the whole `bios` matrix is untouched.**

`install`, from a real run:

```
uefi
  ok   uefi: guest serial port opens
  ok   uefi: install-me.sh completes on a 3-disk mirror
  ok   uefi: hostid was set before any pool existed
  ok   uefi: pool is a mirror
  ok   uefi: pools exported for a clean first import
vm-boot: 8 checks, 0 failed, 0 skipped
```

`boot`, probes read off the installed system after it booted through its own
GRUB off the mirror:

```
PROBE:hostname:vmtest-box          PROBE:systemstate:running
PROBE:poolstate:zroot	ONLINE     PROBE:poolhealthy:pool 'zroot' is healthy
PROBE:rootfs:zroot/root            PROBE:layout:{"mode":"uefi","n":3}
PROBE:members_online:6             PROBE:degraded:0
```

| Component | Status |
|---|---|
| `.utm` bundle generation, firmware switching, disk add/remove/blank | verified |
| VM lifecycle (start, confirmed stop, destroy by prefix) | verified |
| Repo ISO, installer ISO repack for serial | verified |
| `install` phase | **passes, 8 checks** |
| `boot` phase | installed system boots off the mirror; probes correct |
| `degraded`, `replace` | **not yet run to completion** |
| `bios` matrix | **not yet run** |

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
- **The channel copy is the single slowest step.** `nixos-install` writes the
  whole nixpkgs channel -- tens of thousands of small files -- into a fresh ZFS
  pool. `install-me.sh` gained an opt-in `NIXOS_INSTALL_ARGS` hook so the suite
  passes `--no-channel-copy`; real installs are unchanged.
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
