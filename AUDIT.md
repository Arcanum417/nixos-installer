# Audit — nixos-installer

Review of the installer **as it stood at commit `72c70c7`**, before the rewrite.
Kept as the record of what was wrong and why the current design looks the way it
does. `README.md` describes the current tool; `CLAUDE.md` describes its
architecture.

NixOS behaviour claims below were checked against the actual nixpkgs sources
(`nixos-25.05`: `tasks/filesystems/zfs.nix`, `system/boot/loader/grub/grub.nix`,
`install-grub.pl`) and `dosfstools`/`libfdisk` sources, not from memory.

## Status

| | Finding | Resolution |
|---|---|---|
| C1 | Degraded mirror is silent | **Fixed** — `zfs-health.nix`: weekly scrub, ZED settings, 15-min timer checking `zpool status -x` + boot-mirror consistency; fails the unit, writes `/run/zfs-health/alert` (shown at login), POSTs to `/etc/zfs-alert-url` |
| C2 | `boot.zfs.devNodes = "/dev/"` | **Fixed** — `/dev/disk/by-id` in `disk-layout.nix` |
| C3 | `/boot` mirror drifts silently | **Fixed** — `nofail` kept, but the health check compares the file set on every boot mount and reports a stale copy |
| C4 | ZFS partition fills the disk | **Fixed** — every ZFS partition stops 1 GiB short (`END_RESERVE_BYTES`), sized off the smallest selected disk |
| C5 | Pool carries the live ISO's hostid | **Fixed** — `install-me.sh` reads `networking.hostId` from `unique.nix` and sets the ISO's hostid before creating any pool; pools are exported at the end |
| H1 | `sfdisk --dump \| sfdisk` clones GPT GUIDs | **Fixed** — each disk is partitioned independently at install; `replace-boot-disk.sh` uses `sgdisk --replicate` followed by `--randomize-guids` |
| H2 | `mkfs.vfat` races udev | **Fixed** — `wait_for_nodes` polls for the by-id nodes with `udevadm settle` before any `mkfs` |
| H3 | ESP on the FAT16/FAT32 boundary | **Fixed** — ESP is 2 GiB and `mkfs.vfat -F 32` is explicit |
| H4 | Same disk selectable twice | **Fixed** — `select_disks` excludes already-chosen disks, the live medium, and current pool members; `assert_disks_free` refuses a disk an imported pool is using |
| H5 | by-id guessed from `lsblk` columns | **Fixed** — `by_id_path` asks udev (`udevadm info --query=symlink`) and ranks model_serial names above `wwn`/`eui`; a disk with no stable by-id is marked unusable |
| M1 | Data key on the unencrypted root pool | **Documented, not changed** — the threat model (safe disk RMA, not theft) is now stated in `README.md`. The key *is* now actually copied into the installed system, which the old script only warned about. |
| M2 | Data pool never imported at boot | **Fixed** — `disk-layout.nix` emits `boot.zfs.extraPools` and `fileSystems` entries for every legacy-mountpoint dataset |
| M3 | `finish-me-bios.sh` a byte-identical copy | **Fixed** — both deleted; `add-data-pool.sh` replaces them and works on a running machine |
| M4 | Nothing selected the BIOS config | **Fixed** — one `configuration.nix`; firmware lives in `disk-layout.json` |
| M5 | Disk serials hardcoded in a shared file | **Fixed** — the only place disk IDs appear is the generated `disk-layout.json` |
| M6 | The two configs had diverged | **Fixed** — there is only one now; `stateVersion` comes from the installing release and is `mkDefault` so `unique.nix` can pin it |
| M7 | No verification of the pool | **Fixed** — the installer asserts `mirror-0`, checks every ZFS partition is byte-identical, prints `zpool status` and requires confirmation |
| S1 | No pinning | **Not done** — still not a flake. This remains the biggest structural gap; see `README.md` "Known limits". |
| S2 | Installer could not finish alone | **Fixed** — `install-me.sh` runs end to end; the data pool is create / import / skip |
| S3 | Missing datasets and pool guards | **Partly** — `zroot/reserved` (2 GiB `refreservation`) and `autoexpand=on` added; `/var/log` deliberately left alone |
| S4 | Firewall off for everyone | **Softened** — `lib.mkDefault false`, so a machine can turn it on from `unique.nix` |
| S5 | No README | **Fixed** — `README.md`, including the disk-replacement procedure (scripted and manual) |

Two findings were added during the rewrite and are worth keeping in mind:

- **BIOS + dead disk + GRUB version bump.** `install-grub.pl` only re-runs
  `grub-install` when something differs (version, devices, `--install-bootloader`),
  and it `die`s if a configured device is gone. So a degraded BIOS machine
  rebuilds fine day to day but fails on the next big upgrade. Hence
  `replace-boot-disk.sh --drop`.
- **`/boot` fills up.** `copyKernels` is forced on whenever `/boot` is a separate
  filesystem, and nothing bounded the number of generations. Now `/boot` is
  2 GiB and `configurationLimit = 15`.

---

## The original findings

---

## Direct answer: is the root pool reliably redundant?

**The pool geometry is correct.** `zpool create ... zroot mirror
$DISK1-part1 $DISK2-part1` is a genuine 2-way mirror with matching partition
sizes, `ashift=12`, and stable `/dev/disk/by-id/` paths at creation time. ZFS
will self-heal, and losing one disk does not lose data.

**The operational story around it is not redundant.** Five things break the
"one disk dies, I keep running / I recover" promise:

1. Nothing tells you the mirror degraded (§C1).
2. `zpool status` shows `sda1`, not a serial, so you can't tell which disk to
   pull (§C2).
3. The bootloader half of the mirror silently drifts out of sync (§C3).
4. The partition fills the disk exactly, so a replacement disk that is one
   sector smaller cannot be used (§C4).
5. The first boot after install can fail to import the pool at all (§C5).

Fix those five and the answer becomes yes.

---

## Critical

### C1 — A degraded mirror is completely silent

`configuration.nix` enables `services.zfs.autoScrub` but configures no
notification path. In nixpkgs, `services.zfs.zed.enableMail` defaults to
`config.services.mail.sendmailSetuidWrapper != null` — this repo configures no
MTA, so it is **false**, and `services.zfs.zed.settings` is left empty. ZED
runs and logs to the journal, and nothing else happens.

A mirror nobody monitors is a single-disk machine with extra steps: the first
disk fails, you don't notice, the second fails months later, and the recovery
story never gets a chance to run.

Also note `services.zfs.autoScrub.interval` defaults to **`"monthly"`**, not
weekly — worth setting explicitly.

```nix
services.zfs.autoScrub.interval = "weekly";

services.zfs.zed = {
  enableMail = false;              # no MTA on these boxes
  settings = {
    ZED_NOTIFY_VERBOSE = true;
    ZED_USE_ENCLOSURE_LEDS = true;
    # point this at ntfy/gotify/healthchecks — ZED's PATH already has curl
    ZED_NOTIFY_INTERVAL_SECS = 3600;
  };
};
```

If there is no push target, at minimum add a systemd timer that fails loudly
on `zpool status -x` not returning `all pools are healthy`.

### C2 — `boot.zfs.devNodes = "/dev/"` destroys disk identification

`configuration.nix:18` sets `boot.zfs.devNodes = "/dev/"`. The nixpkgs default
is `/dev/disk/by-id`. This value is passed to `zpool import -d`, and the paths
ZFS finds there get written back into the pool config, so `zpool status` ends
up reporting `sda1` / `nvme0n1p1`.

The pool still imports and still mirrors correctly — ZFS matches vdevs by
label, not by path. But when the mirror degrades, the one thing you need is the
**serial number of the disk to physically remove**, and kernel names give you
nothing. Worse, `sda`/`sdb` can swap between boots, so a name you wrote down is
not trustworthy.

`configuration-bios.nix` already uses `/dev/disk/by-id` — the two configs have
diverged here, and the BIOS one is right.

```nix
boot.zfs.devNodes = "/dev/disk/by-id";   # or just delete the line
```

If `/dev/` was set because an import failed in the initrd, the real fix is
almost certainly C5 (hostid), not weakening the device paths.

### C3 — The `/boot` mirror drifts out of sync, silently, by design

This is the subtlest and most dangerous one.

`zroot` is mirrored by ZFS. `/boot` and `/boot-fallback` are **not** — they are
two independent vfat (UEFI) or ext4 (BIOS) filesystems, and the only thing that
keeps them identical is `nixos-rebuild` writing to both via
`boot.loader.grub.mirroredBoots`. (That part does work: `grub.nix` emits one
`install-grub.pl` invocation per `mirroredBoots` entry, each with its own
`--efi-directory` and `--removable`.)

Then `configuration.nix:57-58` marks both `nofail`:

```nix
fileSystems."/boot".options = [ "nofail" ];
fileSystems."/boot-fallback".options = [ "nofail" ];
```

The comment says *"if either of them dies, don't freak out"*. What actually
happens if one dies:

- Boot succeeds, the unmounted mount point is now an empty **directory on the
  ZFS root dataset**.
- The next `nixos-rebuild switch` writes that generation into the directory on
  ZFS. It reports success.
- Every subsequent generation exists on exactly one disk.
- The surviving disk's ESP is frozen at whatever generation was current when the
  other disk died. You find out at the worst possible moment.

There is a second-order failure too. `install-grub.pl` decides whether to copy
kernels by comparing `stat($bootPath)->dev` against `stat("/nix/store")->dev`.
When `/boot` is properly mounted they differ, so `copyKernels` is forced on.
When `/boot` is *not* mounted they are the same device, `copyKernels` stays off,
and grub.cfg is written pointing into `/nix/store` on ZFS.

`nofail` is still the right call — you do want the machine to boot. But it has
to be paired with an alarm:

```nix
systemd.services.boot-mirror-check = {
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Type = "oneshot";
  script = ''
    fail=0
    for m in /boot /boot-fallback; do
      mountpoint -q "$m" || { echo "NOT MOUNTED: $m"; fail=1; }
    done
    [ $fail = 0 ] || exit 1
    diff -r -q /boot/EFI /boot-fallback/EFI || exit 1
  '';
};
```

…plus a timer, and wire its failure into the same notification path as C1.
Also document that **replacing a disk means re-running `mkfs.vfat -F 32` on the
new ESP and then `nixos-rebuild boot`** — `zpool replace` does not do it.

### C4 — The ZFS partition consumes the disk exactly; replacement may be impossible

```sh
sgdisk -n1:0:0 -t1:BF01 $DISK1
```

`0:0` extends to the last usable sector. A "1 TB" disk from a different vendor
— or the same model with different firmware — is frequently a few MiB smaller.
`zpool replace` then fails with *"device is too small"*, and you are stuck
mid-recovery with a degraded pool and a disk you cannot use.

Leave slack. 1 GiB costs nothing and removes the entire failure class:

```sh
sgdisk -n1:0:-1G -t1:BF01 $DISK1
```

Do the same for the `zdata` pool in `finish-me.sh`, which currently uses whole
raw disks (`zpool create ... zdata mirror $DISK1 $DISK2`) and has exactly the
same problem.

### C5 — The pool's hostid comes from the live ISO; first boot can fail to import

`unique.nix:5` ships `networking.hostId = "ZmenMa"` as a placeholder. That is
not 8 hex digits, so NixOS's assertion rejects it — fine, it fails loudly.

The real problem is the one that survives fixing the placeholder. `install-me.sh`
creates `zroot` from the live ISO, which has its own (usually random) hostid,
and that hostid is stamped into the pool's labels. Nothing exports the pool
before reboot. On first boot the installed system has the hostid from
`unique.nix`, sees a pool last touched by a *different* host that never
exported it, and refuses to import.

Normally `boot.zfs.forceImportRoot = true` (the nixpkgs default) papers over
this. Commit `72c70c7` set it to **`false`** — which is the correct, safer
setting, and also exactly what turns this into a failed first boot dropping to
an initrd emergency shell.

Two fixes, do both:

1. In `install-me.sh`, set the ISO's hostid to the machine's real one *before*
   creating the pool, so the stamp is right from the start:
   ```sh
   read -rp "hostId (8 hex, must match unique.nix): " HOSTID
   zgenhostid -f "$HOSTID"          # writes /etc/hostid
   ```
   and have the script write that same value into `/mnt/etc/nixos/unique.nix`
   rather than leaving it to be hand-edited.
2. Export the pool at the end of `finish-me.sh`, after `nixos-install`:
   ```sh
   umount -R /mnt && zpool export -a
   ```

Recovery note worth putting in the README: the hostId is now part of the
recovery key material. `unique.nix` must carry the *same* hostId the pool was
built with, or a recovery install against surviving disks will not import them.

---

## High

### H1 — Cloning the partition table clones every GPT GUID

```sh
sfdisk --dump $DISK1 | sfdisk $DISK2
```

`libfdisk`'s script dump emits the `label-id` header and a `uuid=` field for
every partition (`libfdisk/src/script.c`), and the parser reads both back.
DISK2 therefore ends up with a **byte-identical disk GUID and identical
partition GUIDs** to DISK1.

Consequences: `/dev/disk/by-partuuid/<uuid>` resolves to whichever disk udev
processed last, so it is a coin flip which physical disk any PARTUUID-based
reference points at. Some firmware and some tooling also get confused by two
disks claiming the same GPT identity.

The pool itself is unaffected (ZFS uses its own labels), but this is a landmine
under everything else. `sgdisk` has a purpose-built pair for this:

```sh
sgdisk --replicate="$DISK2" "$DISK1"
sgdisk --randomize-guids "$DISK2"   # -G
```

### H2 — `mkfs.vfat` races udev; it runs *before* the `sleep 5`

```sh
sfdisk --dump $DISK1 | sfdisk $DISK2
mkfs.vfat $DISK1-part3      # <-- by-id symlink may not exist yet
mkfs.vfat $DISK2-part3
...
sleep 5                     # <-- too late to help
zpool create ...
```

`/dev/disk/by-id/*-part3` is created by udev asynchronously after the kernel
re-reads the partition table. On a fast machine, or a slow udev, `mkfs.vfat`
fails with ENOENT and `set -e` aborts the install with both disks already
wiped.

Replace the `sleep 5` with a real barrier, placed immediately after
partitioning:

```sh
partprobe "$DISK1" "$DISK2" || true
udevadm settle --timeout=30
for p in "$DISK1-part1" "$DISK1-part3" "$DISK2-part1" "$DISK2-part3"; do
  [ -e "$p" ] || { echo "missing $p"; exit 1; }
done
```

### H3 — The ESP is created exactly on the FAT16/FAT32 boundary

`sgdisk -n3:1M:+512M` produces exactly 536870912 bytes. `dosfstools`'
`establish_params()` reads:

```c
if (!size_fat && info->size >= 512 * 1024 * 1024) {
    size_fat = 32;
}
```

So it picks FAT32 — by a margin of exactly zero bytes. Any change to
alignment, sector size, or the `+512M` figure that shaves off a single sector
flips it to FAT16, and the UEFI spec requires FAT32 for the ESP on a fixed
disk. Firmware behaviour with a FAT16 ESP ranges from "works" to "disk not
listed in the boot menu".

Don't rely on a heuristic for something you can state:

```sh
mkfs.vfat -F 32 -n EFI  "$DISK1-part3"
mkfs.vfat -F 32 -n EFI2 "$DISK2-part3"
```

### H4 — Nothing stops you selecting the same disk twice

`install-me.sh` runs the same menu twice with no cross-check. Picking the same
entry for DISK1 and DISK2 gives you `sfdisk --dump $DISK1 | sfdisk $DISK1`
followed by `zpool create ... mirror $DISK1-part1 $DISK1-part1`, which fails —
after both wipes have run.

Worse, `finish-me.sh` re-runs the same menu over **all** disks including the two
that now hold your fresh `zroot`, and `sgdisk --zap-all`s them before asking
anything useful. One misread menu index destroys the install you just made.

Add, to both scripts:

```sh
[ "$DISK1" != "$DISK2" ] || { echo "DISK1 and DISK2 must differ"; exit 1; }
```

and in `finish-me.sh`, filter pool members out of the menu (or refuse any disk
that `zpool status -P zroot` mentions).

### H5 — by-id path construction is guesswork and breaks on common hardware

```sh
l=-1; by_id="";
while [ ${drive[$l]} != "disk" ]; do by_id="${drive[$l]}_$by_id"; let "l--"; done
if [ "${drive[2]}" == "sata" ]; then
    drive_by_id="/dev/disk/by-id/ata-$by_id"
else
    drive_by_id="/dev/disk/by-id/nvme-$by_id"
fi
```

This walks `lsblk` columns backwards and assumes the transport is either `sata`
or NVMe. It breaks when:

- `MODEL` or `SERIAL` is empty (common on virtio, some SAS, some USB
  enclosures) — the column walk consumes the wrong fields;
- `TRAN` is `usb`, `scsi`, `sas`, `virtio`, or empty — all get an `nvme-`
  prefix and the path does not exist;
- a model string contains characters udev escapes differently than
  `sed 's/\s\+/_/g'`.

For an installer whose whole purpose is "recover *any* machine", this is the
component most likely to fail on unfamiliar hardware. Stop deriving the path
and ask the kernel for it:

```sh
by_id_for() {   # $1 = /dev/sdX
  local link
  for link in $(udevadm info --query=symlink --name="$1"); do
    case "$link" in
      disk/by-id/nvme-eui.*|disk/by-id/wwn-*) continue ;;
      disk/by-id/*) echo "/dev/$link"; return 0 ;;
    esac
  done
  return 1
}
```

Better still, build the menu straight from `ls -l /dev/disk/by-id/` so the
operator picks a stable path rather than a name you then have to reconstruct.

---

## Medium

### M1 — The `zdata` encryption key sits unencrypted on the same machine

`finish-me.sh` creates `zdata` with
`-O keylocation=file:///root/.zfs-encrypt.key`, and `/root` lives on `zroot`,
which is **not encrypted at all**. Anyone who takes the disks gets the
ciphertext and the key in the same box.

This is fine if the threat model is "RMA a failed drive without leaking docker
volumes" — say so in the README. It is not fine if the threat model is theft.
If it is theft, either encrypt `zroot` too (with
`boot.zfs.requestEncryptionCredentials`, which defaults to `true`, prompting in
the initrd) or move the key to something not attached to the machine.

Separately: nothing in either script actually **copies the key into
`/mnt/root/`**. `finish-me.sh` only warns about it in a Slovak prompt
(*"A dej klic kde ma byt! Na dve mista actuall!"*). A fresh install will boot
with no key present. Make the script do it and verify:

```sh
install -m 0400 /root/.zfs-encrypt.key /mnt/root/.zfs-encrypt.key
```

### M2 — `zdata` is never imported at boot

`boot.zfs.extraPools` is unset (default `[]`) and no `fileSystems` entry exists
for `/mnt/docker` or `/mnt/docker_apps` — the ones in `finish-me.sh`'s header
comment and in `unique.nix` are all commented out. `docker.daemon.settings.data-root`
is commented out too.

So after the first reboot the data pool simply is not there, and docker uses
the root pool. Add:

```nix
boot.zfs.extraPools = [ "zdata" ];
fileSystems."/mnt/docker"      = { device = "zdata/docker";      fsType = "zfs"; };
fileSystems."/mnt/docker_apps" = { device = "zdata/docker_apps"; fsType = "zfs"; };
```

### M3 — `finish-me-bios.sh` is a byte-identical copy of `finish-me.sh`

`diff` reports only a missing trailing newline. Nothing in it is BIOS-specific.
Two copies of a destructive script guarantee that a fix lands in one of them.
Delete it, or make `finish-me.sh` take the boot mode as an argument.

### M4 — Nothing selects `configuration-bios.nix`

`install-me.sh` detects BIOS correctly and partitions accordingly, then does:

```sh
cp -r -f ./*.nix /mnt/etc/nixos/
```

That copies **both** configs, and `hardware-configuration.nix` imports
`./configuration.nix` — the UEFI one — regardless of `$BOOT_MODE`. A BIOS
install gets `efiSupport = true`, `efiInstallAsRemovable = true`, and
`mirroredBoots` with `devices = [ "nodev" ]`, i.e. GRUB is never written to
either MBR. It will not boot.

```sh
if [ "$BOOT_MODE" = "bios" ]; then
  install -m 0644 configuration-bios.nix /mnt/etc/nixos/configuration.nix
else
  install -m 0644 configuration.nix      /mnt/etc/nixos/configuration.nix
fi
install -m 0644 unique.nix /mnt/etc/nixos/unique.nix
```

### M5 — `configuration-bios.nix` hardcodes one machine's disk serials

```nix
mirroredBoots = [
  { devices = [ "/dev/disk/by-id/ata-INTEL_SSDSCKKF256G8H_BTLA74643DJF256J" ]; path = "/boot"; }
  { devices = [ "/dev/disk/by-id/ata-INTEL_SSDSCKKF256G8H_BTLA74711996256J" ]; path = "/boot-fallback"; }
];
```

Machine-specific values belong in `unique.nix` — that is the whole point of the
split. And on BIOS these paths are what make the boot mirror real: get them
wrong and GRUB is installed to one disk only, so the "redundant" machine has a
single point of failure in its bootloader. `install-me.sh` already knows
`$DISK1` and `$DISK2`; have it template them into `unique.nix`.

### M6 — The two configs have quietly diverged

Beyond the GRUB differences, which are intentional:

| | `configuration.nix` | `configuration-bios.nix` |
|---|---|---|
| `boot.zfs.devNodes` | `/dev/` | `/dev/disk/by-id` |
| `boot.zfs.forceImportRoot` | `false` | *(absent → `true`)* |
| `system.stateVersion` | `22.05` | `25.11` |

The ZFS settings should be identical and should live in a shared module.
`stateVersion` should not be a global constant at all — it belongs in
`unique.nix`, set to the release the machine was first installed with. A fresh
install in 2026 pinned to `22.05` inherits five years of stale stateful
defaults.

### M7 — Verify the pool before trusting it

For a script whose entire value proposition is redundancy, `install-me.sh`
never checks that it got a mirror. Two lines:

```sh
zpool status -v zroot
zpool status zroot | grep -q "mirror-0" || { echo "NOT A MIRROR"; exit 1; }
ask_question_yn "Pool looks right? <Y/n>"
```

---

## Structural

### S1 — No pinning, which undercuts the whole recovery premise

The goal is "recover any machine years later from this repo plus `unique.nix`".
But there is no flake, no `npins`, no channel pin — recovery uses whatever the
live ISO happens to point at. You will get a different nixpkgs, different
package versions, and possibly a config that no longer evaluates.

Converting to a flake with a committed `flake.lock`, one `nixosConfiguration`
per machine and `unique.nix` as the only per-host file, is the single change
that most improves the stated goal. It also makes `nixos-install --flake` a
one-liner and removes the `cp -r -f ./*.nix` step entirely.

### S2 — `install-me.sh` cannot complete an install on its own

Stage 1 stops after copying configs; `nixos-install` only lives in
`finish-me.sh`, which *mandatorily* builds a second encrypted pool. There is no
path to "two mirrored disks, no data pool", which is presumably the common case
on a laptop or a small box. Split the `zdata` step behind a prompt.

### S3 — Missing datasets and pool guards

- No dataset separation for `/var/log`, `/var/lib`, or `/tmp`, so a runaway log
  fills the pool that `/` lives on.
- No `refreservation` on `zroot`. A 100%-full ZFS pool cannot free space by
  deleting files. A 1–2 GiB reservation dataset is cheap insurance:
  ```sh
  zfs create -o refreservation=2G -o mountpoint=none zroot/reserved
  ```
- `compression=lz4` is the 2018 answer; `zstd` gives noticeably better ratios
  at similar CPU cost on anything modern.
- Consider `-o autoexpand=on` so a mirror rebuilt onto larger disks grows.

### S4 — Network posture is wide open by default

`networking.firewall.enable = false` combined with `virtualisation.docker` and
an SSH server. Key-only root login is good (`PasswordAuthentication = false`,
and NixOS's `PermitRootLogin` default of `prohibit-password` applies), but a
disabled firewall on every machine this installer touches is a policy decision
that should be opt-in per host in `unique.nix`, not baked into the shared
config.

### S5 — Housekeeping

- No `README.md`. The recovery procedure exists only in the operator's head:
  what to keep, where the key goes, what hostId means, how to replace a disk.
  Write it down — it is the artefact the whole design depends on.
- No `.gitignore`, no shellcheck, no CI. A GitHub Action running
  `shellcheck *.sh` and `nix flake check` (after S1) would catch most of §H.
- `poznamky.txt` is a raw `history` dump. Either promote the useful parts into
  the README or drop it.
- `install-me.sh` has mixed tabs and spaces in the BIOS branch.

---

## Suggested order

Superseded by the Status table at the top of this file. Everything except S1
(flake pinning) and the deliberate decisions noted there has been implemented.
