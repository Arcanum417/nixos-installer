# nixos-installer

[![ci](https://github.com/Arcanum417/nixos-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/Arcanum417/nixos-installer/actions/workflows/ci.yml)

Bare-metal NixOS installer for machines that boot off an **N-way ZFS root
mirror**, built so a dead server can be rebuilt from three things:

1. this repo
2. that machine's `unique.nix` (hostname + **hostId**)
3. `/root/.zfs-encrypt.key`, if the machine has a data pool

Nothing else. No flake lock, no backups of `/etc`, no notes.

Works on **UEFI** (GRUB installed as removable: `EFI/BOOT/BOOTX64.EFI`, no NVRAM
entries) and on **BIOS** (GRUB in each disk's MBR + `EF02` partition). The
installer detects which and writes the right config.

---

## Recovery kit

| | |
|---|---|
| `unique.nix` | hostname and `networking.hostId`. **The hostId is stamped into the ZFS pool labels.** Recover with the wrong one and the pool will not import. Keep it with the machine forever. |
| `/root/.zfs-encrypt.key` | raw 32-byte key for the encrypted data pool. Only needed if the machine has one. Without it the data pool is gone. |
| this repo | everything else |

---

## Installing (new machine, or rebuilding a dead one)

Boot a ZFS-capable NixOS live ISO, become root, put `unique.nix` and (if
needed) the key in place, then:

```sh
git clone <this repo> && cd nixos-installer
cp /path/to/sm2-box-unique.nix ./unique.nix
cp /path/to/zfs-encrypt.key /root/.zfs-encrypt.key   # only if you use a data pool
./install-me.sh
```

`install-me.sh` walks through, in order:

1. reads hostname + hostId from `unique.nix` and **sets the live ISO's hostid to
   match** — this is what makes the pool importable on first boot, and what
   lets a pool from a crashed machine be imported without `-f`
2. lists disks (by-id, resolved from udev, live medium excluded and flagged)
3. you pick **2 or more identical disks** for the root mirror — pick 3 and any
   two may die
4. partitions each disk **independently** (own random GPT GUIDs), leaving 1 GiB
   of slack at the end of every ZFS partition
5. creates the mirror, the datasets, and a 2 GiB `reserved` refreservation
6. data pool: create a new encrypted one, **import an existing one** (the
   normal case when only the boot disks died), or skip
7. `nixos-generate-config --no-filesystems`, then writes
   `configuration.nix`, `disk-layout.nix`, `zfs-health.nix`, `unique.nix` and
   the generated `disk-layout.json`
8. `nixos-install` (prompts for a root password — set one, you will want console
   access when something goes wrong)
9. unmounts and **exports** the pools, so the first boot imports cleanly

It also copies `replace-boot-disk.sh`, `add-data-pool.sh` and `lib/common.sh`
into `/etc/nixos/`, so a future disk swap does not need the ISO.

### Mixed-size disks

The installer refuses disks of different sizes for the root mirror — a mirror
you cannot rebuild from a spare is not much of a mirror. To override:

```sh
ALLOW_MIXED_SIZE=1 ./install-me.sh
```

Every partition is then sized to the smallest disk, so the members stay
interchangeable.

---

## Replacing a failed disk

On the affected machine:

```sh
sudo /etc/nixos/replace-boot-disk.sh
```

It shows each mirror member and its state, pre-selects the one that is not
`ONLINE`, asks for the replacement disk, and then:

- copies the surviving disk's partition table with `sgdisk --replicate`, then
  `sgdisk --randomize-guids` so the new disk gets its own GPT identity
- makes a fresh ESP (`mkfs.vfat -F 32`) or `/boot` (`mkfs.ext4`)
- `zpool replace` — falling back to picking the vdev by GUID if the dead disk's
  path is gone from `zpool status`
- clears any junk that accumulated in the mount point while the disk was
  missing (those files were on the root pool, not on any disk)
- mounts the new boot filesystem, rewrites `disk-layout.json`, and runs
  `nixos-rebuild boot --install-bootloader` so the bootloader lands on the new
  disk too

Other modes:

```sh
sudo /etc/nixos/replace-boot-disk.sh --add     # widen the mirror with another disk
sudo /etc/nixos/replace-boot-disk.sh --drop    # forget a dead disk, no replacement yet
```

Use `--drop` if a disk died and you do not have a spare **and** the machine is
BIOS: `grub-install` runs against every configured device whenever the GRUB
version changes, so a missing device will fail your next big upgrade. Dropping
it keeps the machine rebuildable until the replacement arrives.

From a live ISO instead (pool imported at `/mnt`):

```sh
./replace-boot-disk.sh --layout /mnt/etc/nixos/disk-layout.json
# then, in the target system:
nixos-enter --root /mnt -c 'nixos-rebuild boot --install-bootloader'
```

### Doing it by hand

If the script cannot run:

```sh
NEW=/dev/disk/by-id/ata-NEW_DISK
OLD=/dev/disk/by-id/ata-DEAD_DISK
HEALTHY=/dev/disk/by-id/ata-SURVIVOR

sgdisk --zap-all "$NEW"
sgdisk --replicate="$NEW" "$HEALTHY"    # copy the table
sgdisk --randomize-guids "$NEW"         # ...but not its identity
udevadm settle

mkfs.vfat -F 32 -n ESP1 "$NEW-part1"    # UEFI  (BIOS: mkfs.ext4 -L boot1 "$NEW-part2")

zpool replace zroot "$OLD-part2" "$NEW-part2"   # UEFI part numbers
# if the dead path is gone from `zpool status`, find its GUID:
#   zpool status -Pg zroot
#   zpool replace zroot <guid> "$NEW-part2"

mount "$NEW-part1" /boot-fallback-1
# edit /etc/nixos/disk-layout.json: swap the dead disk's "id" for the new one
nixos-rebuild boot --install-bootloader

watch -n5 zpool status zroot            # wait for the resilver
```

The pool is redundant again only when the resilver finishes.

---

## How the redundancy actually works

Two mechanisms, and they fail in different ways.

**The pool.** A real `mirror` vdev across N partitions. ZFS self-heals, scrubs
weekly, and survives N-1 disk failures. This part takes care of itself.

**The bootloader.** `/boot` and each `/boot-fallback-N` are *ordinary,
independent filesystems* — vfat on UEFI, ext4 on BIOS. ZFS does not mirror them.
The only thing that keeps them identical is `nixos-rebuild` writing to all of
them via `boot.loader.grub.mirroredBoots`.

They are mounted `nofail`, so the machine still boots with a disk missing. The
price is that a `nixos-rebuild` with one of them unmounted **succeeds silently**
and writes that generation into an empty directory on the root pool instead. The
surviving disk's `/boot` then freezes at whatever generation was current when
the other disk died, and you find out at the worst possible time.

`zfs-health.nix` exists for exactly this. Every 15 minutes it checks:

- `zpool status -x` says all pools are healthy
- every configured boot mount is actually mounted
- every boot mount holds the same set of files (filenames, not contents —
  `grub.cfg` legitimately differs per ESP)

On a problem it fails the unit (`systemctl --failed`), writes
`/run/zfs-health/alert` which is printed on every interactive login, and POSTs
to the URL in `/etc/zfs-alert-url` if you set one:

```nix
# unique.nix
environment.etc."zfs-alert-url".text = "https://ntfy.sh/my-secret-topic";
```

Run it on demand with `zfs-health-check`.

> Worth testing once, on new hardware: pull a disk and confirm the machine still
> boots. On UEFI this relies on the firmware trying `\EFI\BOOT\BOOTX64.EFI` on
> the remaining disk, which nearly all firmware does, but "nearly" is why you
> test it before you need it.

---

## Layout

Every root-mirror disk is partitioned identically.

**UEFI**

| # | Type | Size | Contents |
|---|---|---|---|
| 1 | `EF00` | 2 GiB | ESP, FAT32, mounted `/boot`, `/boot-fallback-1`, … |
| 2 | `BF01` | rest − 1 GiB | mirror member |

**BIOS**

| # | Type | Size | Contents |
|---|---|---|---|
| 1 | `EF02` | 2 MiB | BIOS boot partition, no filesystem |
| 2 | `8300` | 2 GiB | ext4, mounted `/boot`, `/boot-fallback-1`, … |
| 3 | `BF01` | rest − 1 GiB | mirror member |

The 1 GiB of end slack is what makes a slightly-smaller replacement disk usable.
The 2 GiB `/boot` holds `configurationLimit = 15` generations of kernel+initrd.

**Pools**

```
zroot                       mirror over every disk's ZFS partition, lz4
  zroot/root       -> /
  zroot/root/nix   -> /nix
  zroot/root/home  -> /home
  zroot/reserved      refreservation=2G, never mounted

zdata (optional)            whole disks, mirror if 2+, zstd, encrypted
  zdata/docker      -> /mnt/docker
  zdata/docker_apps -> /mnt/docker_apps
```

`zroot` uses **lz4, not zstd**, on purpose: GRUB's ZFS reader is the weakest
link in the boot path and this is a recovery tool. `zdata` uses zstd — no
bootloader ever reads it.

`zroot/reserved` exists because a 100%-full ZFS pool cannot free space by
deleting files.

---

## Files

| File | What it is |
|---|---|
| `install-me.sh` | the installer |
| `replace-boot-disk.sh` | replace / add / drop a mirror member |
| `add-data-pool.sh` | create or adopt a data pool on a running machine |
| `lib/common.sh` | shared bash helpers, sourced by all three |
| `configuration.nix` | shared system config, identical on every machine |
| `disk-layout.nix` | pools, `fileSystems`, GRUB — reads `disk-layout.json` |
| `disk-layout.json` | **generated per machine**, the only place disk IDs live |
| `zfs-health.nix` | scrub, ZED, degraded-mirror and stale-boot alerting |
| `unique.nix` | template for the per-machine file |
| `other/node_exporter/` | Prometheus textfile collectors for SMART/NVMe |
| `tests/` | the test suite (see below) |
| `AUDIT.md` | review of the previous version and why it changed |

`disk-layout.json` is the whole machine-specific disk story, and it is read by
Nix with `builtins.fromJSON`. Swapping a disk is a one-field edit plus a
rebuild — never hand-edited Nix.

---

## Tests

```sh
bash tests/run-all.sh          # runs whatever this machine can; skips the rest
```

Four suites, **334 checks**, run in CI on every push
(`.github/workflows/ci.yml`). The GitHub runner can load the ZFS module, so the
mirror lifecycle is exercised for real there, not skipped:

| Suite | What it covers | Needs |
|---|---|---|
| `tests/lint.sh` | `bash -n` and shellcheck on every script, `nix-instantiate --parse` on every Nix file, plus repo invariants: the on-machine scripts must not need `nix-shell`, and no disk IDs may appear in tracked Nix | shellcheck, nix |
| `tests/lib-unit.sh` | `lib/common.sh` in isolation: `disk-layout.json` round trip, `--drop` not renumbering survivors, `nix_attr` parsing, hostId byte order and validation, `by_id_path` preference order (faked udev), and `select_disks` — minimum of 2, stable numbering, toggling, live-medium and no-by-id exclusion | jq |
| `tests/disk-integration.sh` | the real partitioning code against **loop devices**: UEFI and BIOS layouts, partition types and sizes, all ZFS partitions byte-identical, the 1 GiB end slack, **every GPT disk and partition GUID distinct**, the ESP really being FAT32, and `--replicate` + `--randomize-guids` copying the layout but not the identity. Then creates a 3-way ZFS mirror, degrades it, replaces the member and waits for the resilver | root, loop devices, gdisk, dosfstools, a zfs kernel module |
| `tests/nix-eval.sh` | the whole config evaluated through `nixos/lib/eval-config.nix` across **firmware × mirror width × data pool** (8 combinations), asserting no failed assertions and checking `mirroredBoots`, `fileSystems`, `efiInstallAsRemovable`, `devNodes`, `extraPools` and the `unique.nix` wiring. Instantiates `system.build.toplevel` for both firmwares and builds the health-check derivation (which is what runs shellcheck on it) | nix, nixpkgs |

The ZFS section of `disk-integration.sh` reports itself as **skipped**, not passed,
when no zfs kernel module is available.

### Booting it: `tests/vm-boot.sh`

A fifth suite covers the one thing the four above cannot — actually starting a
machine. It runs on **macOS with UTM** and so is not in CI (the runners are
Linux). One VM per firmware mode is installed, then progressively broken:

| Phase | What it proves |
|---|---|
| `install` | `install-me.sh` runs unattended to completion on a 3-way mirror; hostId set before any pool exists; the pool really is `mirror-0`; pools exported for a clean first import |
| `boot` | the installed system boots off the mirror to a shell — hostname and hostId intact, pool `ONLINE`, `/` on the ZFS dataset, `disk-layout.json` matching the firmware, and GRUB at `EFI/BOOT/BOOTX64.EFI` |
| `degraded` | with the **first** disk pulled — the one whose ESP is `/boot` — it still boots: pool `DEGRADED`, `/` mounted, `nofail` keeping the missing `/boot` from blocking startup, `zfs-health-check` noticing |
| `replace` | `replace-boot-disk.sh` partitions a blank replacement, randomises its GUIDs, resilvers, reinstalls the bootloader, and the pool returns to healthy |

```sh
bash tests/vm-boot.sh          # both firmware modes; takes hours
```

The guest is x86_64 because `BOOTX64.EFI` and the `EF02` BIOS boot partition
are x86-only — an aarch64 guest is far faster but cannot test the BIOS path at
all. On an arm64 Mac that means TCG emulation, so this is a release gate, not a
routine run. Setup, knobs and troubleshooting: **[`tests/vm/README.md`](tests/vm/README.md)**.

## Known limits

- **Not a flake.** Recovery uses whatever nixpkgs the live ISO carries, so a
  rebuild years later will not be bit-identical. Converting to a flake with a
  committed `flake.lock` is the obvious next step.
- **BIOS + dead disk + GRUB version bump** fails `grub-install`. Use `--drop`.
- **The data-pool key lives on the unencrypted root pool.** That protects you
  when you RMA a data disk; it does not protect you against someone taking the
  whole machine. If that is the threat model, encrypt `zroot` too
  (`boot.zfs.requestEncryptionCredentials` prompts in the initrd).
- **`ALLOW_MIXED_SIZE=1` is not tested as thoroughly** as the identical-disk
  path. Prefer identical disks.
- **The data pool is not covered by the VM suite.** `tests/vm-boot.sh` drives
  `install-me.sh` with the "skip" option, so creating and importing an
  encrypted `zdata` is still only evaluated, never booted.
- Nothing here is verified on **real hardware** from this repo alone.
  `tests/vm-boot.sh` boots an emulated machine per firmware mode, which catches
  bootloader and pool-import mistakes but not firmware quirks, controller
  behaviour, or anything timing-dependent. Test a new machine type before
  trusting it with a rebuild you need.
