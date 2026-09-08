# VM boot tests

The other four suites cannot boot a machine. `tests/nix-eval.sh` proves the
configuration evaluates and `tests/disk-integration.sh` proves the partitioning
is correct, but neither proves that a machine built this way actually starts.
GRUB landing in the right place, firmware finding the removable path on a
surviving disk, and the pool importing with `boot.zfs.forceImportRoot = false`
are all boot-time facts. This suite is the only thing in the repo that checks
them.

It runs on macOS against UTM, which is why it is not in CI: the GitHub runners
are Linux and cannot usefully nest a hypervisor. CI covers what CI can cover;
this covers the rest.

## What it asserts

Four phases per firmware mode, run against one VM that is installed once and
then progressively broken:

| Phase | What it proves |
|---|---|
| `install` | `install-me.sh` completes unattended on an N-way mirror; the hostId is set *before* any pool exists; the pool really is a `mirror-0`; the pools are exported so the first boot imports cleanly. |
| `boot` | The installed system boots off the mirror to a shell. Hostname and hostId survived, the root pool is `ONLINE`, `/` is the ZFS dataset, `disk-layout.json` matches the firmware, and (UEFI) GRUB is at `EFI/BOOT/BOOTX64.EFI`. |
| `degraded` | With the **first** mirror member pulled — in UEFI mode that is the disk whose ESP is mounted at `/boot` — the machine still boots. The pool reports `DEGRADED`, `/` is still mounted, the missing `/boot` did not block startup (this is what `nofail` is for), and `zfs-health-check` notices. |
| `replace` | `/etc/nixos/replace-boot-disk.sh` partitions a blank replacement, randomises its GUIDs, resilvers, and reinstalls the bootloader; the pool returns to healthy. |

Both `uefi` and `bios` run the whole set. That matters: `BOOTX64.EFI` and the
`EF02` BIOS boot partition are the two halves of the repo's boot support, and
they share one code path that only diverges on `detect_boot_mode`.

## Requirements

macOS with [UTM](https://mac.getutm.app) installed at `/Applications/UTM.app`.
Almost everything else the suite uses — `expect`, `nc`, `jq`, `plutil`,
`mkfile`, `hdiutil`, `bsdtar`, `osascript`, `curl` — ships with macOS, and UTM
itself needs no configuration.

The one exception is **`xorriso`**, which the suite needs to repack the
installer ISO (see *How it works*). Without it the `install` phase reports
itself as skipped rather than passing:

```sh
nix-shell -p xorriso        # then run the suite from inside that shell
```

The suite downloads the NixOS minimal ISO once into
`~/.cache/nixos-installer-vm/` (about 1.7 GB), repacks it once alongside, and
reuses both forever after.

## Running it

```sh
bash tests/vm-boot.sh                 # both firmware modes, all four phases
bash tests/vm-boot.sh uefi            # one firmware mode
bash tests/vm-boot.sh bios install    # a single phase
VM_KEEP=1 bash tests/vm-boot.sh uefi  # leave the VM behind to inspect
```

Phases are **sequential and stateful** — `boot` needs the disks `install` left,
`degraded` needs a system to degrade. Running one in isolation only works if a
previous run left the VM in place (`VM_KEEP=1`).

Useful knobs: `DISK_GB` (default 8), `NDISKS` (default 3), `VM_MEM_MB` (4096),
`VM_CORES` (4), `NIXOS_CHANNEL` (`nixos-25.05`).

### Budget the time

The guest is x86_64 and this is very likely an arm64 Mac, so QEMU runs in **TCG
emulation with no hardware acceleration**. That is deliberate: an aarch64 guest
would run at near-native speed but could not test the BIOS path at all (there
is no CSM on aarch64) and would exercise `BOOTAA64.EFI` rather than the
`BOOTX64.EFI` these machines actually use. Fidelity was worth the wall-clock.

Expect **hours, not minutes**, for a full run — `nixos-install` is building and
activating a system closure under emulation. This is a release gate you run
deliberately, not something to put in a pre-commit hook.

What actually helps is giving the guest less to **build**. The fixture disables
the NixOS manual and the man cache, which are generated per configuration and
so are the only large derivations never available from the binary cache — with
them on, the run spends a long stretch compiling inside an emulator; with them
off it is dominated by downloads instead.

Two things to know before trying to tune this further:

- **Sample the right process, the right way.** `QEMUHelper` is a wrapper and
  reads ~0% CPU; the emulator is `QEMULauncher`. And use `top -l 2` rather than
  `ps -o %cpu`, which on macOS is a decaying average since process start and
  swings wildly enough to make a busy guest look idle.
- **Long silences are normal.** `copying channel...` and the closure copy print
  nothing for a long time while working, so a static transcript is not a hang.

Whether UTM's `ForceMulticore` helps is unmeasured; the harness leaves it off
with 4 vCPUs because that is the configuration installs have completed on.

## When something fails

Every phase writes a full serial console transcript to `tests/vm/logs/`:

```
tests/vm/logs/uefi-install.log
tests/vm/logs/uefi-boot.log
tests/vm/logs/uefi-degraded.log
tests/vm/logs/uefi-replace.log
```

The expect drivers print a single `FAILED: <reason>` line on the way out, and
the suite quotes it. The transcript above that line is the guest's own output,
so a `FATAL` from `lib/common.sh` appears verbatim.

To watch a run live, or to poke at a VM left behind by `VM_KEEP=1`:

```sh
/Applications/UTM.app/Contents/MacOS/utmctl list
nc 127.0.0.1 4410            # uefi console (bios is 4411)
```

Test VMs are all named `nixinst-test-*`. The suite only ever deletes bundles
matching that prefix, so a VM of your own can never be removed by a failed run
or a stray cleanup.

## How it works

UTM's AppleScript interface can create a VM and size its drives but silently
ignores `source:` on a removable drive, so it cannot insert an ISO. A `.utm`
bundle, though, is just a directory holding `config.plist` and a `Data/` folder
of disk images. So `lib-utm.sh` writes the whole bundle itself (`jq` to build
the config as JSON, `plutil` to convert it to a plist) and hands the finished
thing to UTM. That is also what makes the failure scenarios cheap: pulling a
disk is a rewrite of the `Drive` array, not a UI gesture.

`QEMU.UEFIBoot` in that plist is the entire difference between the two firmware
modes. Disk images are sparse (`mkfile -n`), so a three-disk 8 GiB VM costs
kilobytes until the guest writes to it.

UTM keeps VM configuration in memory from launch, so **every bundle rewrite is
followed by `utm_reload`** — quitting and relaunching UTM — before the VM
starts. Without it, UTM boots the configuration it already had.

The guest is driven entirely over a TCP serial console — no SSH, no guest
agent, no guest networking. `lib-assets.sh` generates the test `unique.nix`
with `console=ttyS0` and `services.getty.autologinUser = "root"`, so reaching a
shell *is* the boot assertion. The repo itself reaches the guest as a second
ISO built with `hdiutil`, which avoids depending on a 9p driver or a git remote.

Getting the *installer* onto that console needs one more step, and it is the
reason `xorriso` is required. The stock NixOS ISO's default GRUB entry sets no
`console=`, and serial is offered only from a submenu that cannot be selected:
OVMF mirrors GRUB's output to the serial port, but GRUB never acts on serial
input, so the countdown always expires into the non-serial default. So the
suite repacks the ISO — `-boot_image any replay` preserves the El Torito setup
so it stays bootable in both firmware modes — replacing `grub.cfg` and
`isolinux.cfg` with versions that add `terminal_input serial`,
`console=ttyS0,115200n8` on every kernel line, and a shorter timeout.
`tests/vm/RESULTS.md` records the approaches that were tried and rejected.

One consequence worth knowing when reading a transcript: UTM drops the serial
TCP client when the guest reinitialises the UART, which GRUB does on its way to
the kernel. That is one expected disconnect per boot, and every expect driver
reconnects through it rather than failing.

The `unique.nix` the tests generate is the only thing that differs from a real
install. It adds the serial console and autologin, disables DHCP so a booted
machine does not sit waiting on a NIC the test never uses, and turns off the
NixOS manual and the man cache — those are generated per configuration rather
than fetched from the binary cache, so under emulation they are built from
source and dominate the run, while affecting nothing this suite asserts.
Everything else — `configuration.nix`, `disk-layout.nix`, `zfs-health.nix`, the
installer itself — is exactly what ships.
