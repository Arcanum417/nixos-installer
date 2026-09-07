# VM suite: status and findings

Status of `tests/vm-boot.sh` as committed. Written so the next person does not
repeat the dead ends — most of the work here was finding out which of the
obvious approaches UTM actually supports.

**Host these results come from:** macOS 25.6 (Darwin), arm64, UTM 4.7.5,
NixOS `nixos-25.05` minimal ISO (x86_64), guest emulated under QEMU TCG.

## Where it stands

The harness is complete and its host-side machinery is verified. **A full green
end-to-end run has not been completed**, because a single `nixos-install` under
TCG emulation runs for hours and the full matrix is two firmware modes × four
phases. Do not read this suite as "passing" until someone runs it to completion
and updates this file.

| Component | Status |
|---|---|
| `.utm` bundle generation (drives, firmware, serial, sparse images) | verified working |
| Firmware switching (`QEMU.UEFIBoot`) | verified — `efi_vars.fd` present only for UEFI |
| Disk add / remove / blank between phases | verified working |
| VM lifecycle (start, confirmed stop, destroy by prefix) | verified working |
| Repo ISO built with `hdiutil` | verified working |
| Installer ISO repacked for serial (`xorriso`) | verified working |
| Guest reaches a serial console the harness can drive | verified — a UEFI VM booted from the repacked ISO to a login prompt on the TCP serial port |
| `install` → `boot` → `degraded` → `replace` end to end | **not yet run to completion** |

The last verified step is the one that matters most for trusting the rest: a
three-disk UEFI VM booted the repacked ISO and presented a login prompt on
`127.0.0.1:4417`, which is the console `install.expect` drives. Everything from
that point on is the installer's own prompt sequence, which is exercised but
not yet observed to completion.

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

(A fourth trap was mine, not UTM's: `spawn` inside a Tcl proc sets a *local*
`spawn_id`, so the caller ends up with no connection. Spawn at top level.)

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
