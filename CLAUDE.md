# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this repo is

A **bare-metal NixOS installer for machines that boot off an N-way ZFS root
mirror.** The design goal is that a dead server can be rebuilt from exactly
three things: this repo, that machine's `unique.nix`, and (if it has a data
pool) `/root/.zfs-encrypt.key`.

Supports **UEFI** (GRUB as removable: `EFI/BOOT/BOOTX64.EFI`, no NVRAM entries)
and **BIOS** (GRUB in each disk's MBR + `EF02`). One code path; the firmware is
detected at install time and recorded in `disk-layout.json`.

Not a flake, no lockfile, no CI. See `README.md` for the user-facing procedures
and `AUDIT.md` for what the previous version got wrong and why it changed.

## SAFETY

`install-me.sh`, `replace-boot-disk.sh` and `add-data-pool.sh` **destroy every
disk the operator selects** (`sgdisk --zap-all`, `wipefs -fa`,
`zpool labelclear`). Never execute them in a dev container, in CI, or on a
working machine. Static checks and evaluation only.

## Architecture: the JSON seam

The one idea worth understanding before changing anything:

```
disk-layout.json   <- generated per machine (disk by-id paths, firmware, parts)
       |  builtins.fromJSON
       v
disk-layout.nix    <- static, ships in the repo; fileSystems + GRUB + ZFS opts
```

Every machine-specific disk fact lives in `disk-layout.json`. `disk-layout.nix`
is the same file on every machine. So swapping a disk is a one-field JSON edit
plus a rebuild — never hand-edited Nix, and never a regenerated
`hardware-configuration.nix`.

`lib/common.sh` owns both sides of that seam: `write_disk_layout_json` and
`read_disk_layout`. If you change the schema, change both, plus
`disk-layout.nix`, and bump `version`.

## File map

| File | Role |
|---|---|
| `install-me.sh` | The installer. Reads hostId from `unique.nix`, sets the ISO's hostid, partitions N disks, builds the mirror, optionally creates *or imports* a data pool, writes config, runs `nixos-install`, exports the pools. `nix-shell` shebang. |
| `replace-boot-disk.sh` | Replace / `--add` / `--drop` a mirror member, then `nixos-rebuild boot --install-bootloader`. Plain `bash` shebang on purpose — a degraded machine may have no network, so it relies on tools `configuration.nix` installs. |
| `add-data-pool.sh` | Create or adopt a data pool on a running machine. Replaces the old `finish-me.sh`. Plain `bash` shebang, same reason. |
| `lib/common.sh` | All shared bash. Sourced, never executed. Prompts, disk menu, by-id resolution via udev, partitioning, JSON read/write. |
| `configuration.nix` | Shared system config, identical on every machine. No disk or bootloader content. |
| `disk-layout.nix` | Pools, `fileSystems`, GRUB, ZFS options — all derived from `disk-layout.json`. |
| `zfs-health.nix` | Weekly scrub, ZED settings, and the 15-minute health timer that catches a degraded pool or a stale boot mirror. |
| `unique.nix` | Template for the per-machine file. The real one is supplied by the operator. |
| `other/node_exporter/smart/` | Prometheus textfile collectors, wired up from `unique.nix` if wanted. |

There is deliberately **no** `configuration-bios.nix`, `finish-me.sh`, or
`finish-me-bios.sh` any more; see `AUDIT.md` §M3/§M4.

## Invariants — do not break these

- **hostId is load-bearing.** ZFS stamps it into the pool labels.
  `install-me.sh` reads it from `unique.nix` and sets the live ISO's hostid
  *before creating any pool*. That is what makes the first boot import cleanly
  with `boot.zfs.forceImportRoot = false`, and what lets a dirty pool from a
  crashed machine be imported without `-f`.
- **Never clone a partition table without randomising GUIDs.**
  `sgdisk --replicate` must always be followed by `sgdisk --randomize-guids`.
  The old installer used `sfdisk --dump | sfdisk`, which duplicates `label-id`
  and every partition `uuid`.
- **Never `mkfs` straight after partitioning.** Go through `wait_for_nodes`,
  which polls for the by-id nodes and calls `udevadm settle`.
- **Every ZFS partition stops 1 GiB short of the end of the disk**
  (`END_RESERVE_BYTES`). That slack is the only reason a slightly-smaller
  replacement disk is usable.
- **Root pool stays on `lz4`, data pool uses `zstd`.** GRUB's ZFS reader is the
  weakest link in the boot path; this is a recovery tool.
- **`/boot` mount points are stored per disk in the JSON**, not derived from
  array position, so `--drop` does not renumber and remount the survivors.
- **`nofail` on the boot mounts is intentional** and is paired with
  `zfs-health.nix`. Do not remove one without the other.

## Conventions

- Bash: `set -Eeuo pipefail` comes from `lib/common.sh`. Note that `A && B` with
  a false `A` is *exempt* from `set -e` (verified), so the `cmd && flag=1` idiom
  used throughout is safe.
- `zfs-health.nix` uses `pkgs.writeShellApplication`, which runs **shellcheck at
  build time**. A shellcheck violation there is a broken `nixos-rebuild`, not a
  warning. Build it before trusting a change (see below).
- Comments and prompts are a mix of English and Czech/Slovak. Keep a file's
  existing language rather than translating wholesale.
- Machine-specific values belong in `unique.nix` or `disk-layout.json`, never in
  `configuration.nix`.

## Validating changes

No nix toolchain is installed by default, but a standalone one can be fetched
and the whole config genuinely evaluated — do this rather than eyeballing Nix:

```sh
# shell syntax
bash -n install-me.sh replace-boot-disk.sh add-data-pool.sh lib/common.sh

# standalone nix (releases.nixos.org and channels.nixos.org are reachable;
# github.com tarballs are NOT - the session is scoped to this repo)
curl -sSL -o nix.tar.xz https://releases.nixos.org/nix/nix-2.24.10/nix-2.24.10-x86_64-linux.tar.xz
tar xf nix.tar.xz && mkdir -p /nix && cp -a nix-*/store /nix/store
export PATH=/nix/store/*-nix-2.24.10/bin:$PATH

curl -sSL -o nixexprs.tar.xz https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz
tar xf nixexprs.tar.xz
```

Then build a scratch `/etc/nixos` (a `hardware-configuration.nix` stub with
`nixpkgs.hostPlatform`, a real `unique.nix`, and a `disk-layout.json` produced by
sourcing `lib/common.sh` and calling `write_disk_layout_json`) and evaluate it
through `nixos/lib/eval-config.nix`. Check **both** `bootMode` values:

```sh
nix-instantiate --eval --strict --json -E \
  'let c = (import ./eval.nix { dir = ./.; }); in
   { fs = builtins.attrNames c.fileSystems;
     mirrors = c.boot.loader.grub.mirroredBoots;
     assertions = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions); }'

nix-instantiate -E 'let c = (import ./eval.nix { dir = ./.; }); in c.system.build.toplevel'
nix-build --no-out-link -E '...zfs-health-check...'   # runs shellcheck
```

What cannot be checked here: anything that touches real disks. Partitioning,
`zpool` behaviour, GRUB installation and actually booting need a VM with two or
three virtual disks, tested separately under UEFI and BIOS firmware. Say so
explicitly rather than implying a change is verified end to end.

## Repo etiquette

- Work on `claude/*` branches; `main` is the published state.
- No PR unless explicitly asked.
