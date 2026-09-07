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

**Run the suite. Do not eyeball Nix.**

```sh
bash tests/run-all.sh
```

Suites are `tests/lint.sh`, `tests/lib-unit.sh`, `tests/disk-integration.sh`
(root + loop devices) and `tests/nix-eval.sh` (the 8-cell firmware × width ×
data-pool matrix, plus `system.build.toplevel` and building the health-check
derivation). A suite exits **77** when its environment is missing, which
`run-all.sh` reports as skipped. All four run in CI.

`tests/vm-boot.sh` is the fifth suite and does **not** run in CI — it needs
macOS and UTM, and CI is Linux. It boots the thing: a real install onto a real
mirror, then the same VM booted again with a disk pulled and again after a
replacement is resilvered, across both firmware modes. It is opt-in
(`VM_TESTS=1 bash tests/run-all.sh`, or run it directly) because the guest is
x86_64 on an arm64 host, so QEMU is emulating and a full run takes hours. See
`tests/vm/README.md`.

Nothing is installed by default here, but everything can be fetched — GitHub
tarballs are blocked (the session is scoped to this repo) while
`releases.nixos.org`, `channels.nixos.org` and `cache.nixos.org` are reachable:

```sh
curl -sSL -o nix.tar.xz https://releases.nixos.org/nix/nix-2.24.10/nix-2.24.10-x86_64-linux.tar.xz
tar xf nix.tar.xz && mkdir -p /nix && cp -a nix-*/store /nix/store
export PATH=/nix/store/*-nix-2.24.10/bin:$PATH
mkdir -p /tmp/nixconf && printf 'build-users-group =\nsandbox = false\n' > /tmp/nixconf/nix.conf
export NIX_CONF_DIR=/tmp/nixconf

curl -sSL -o nixexprs.tar.xz https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz
tar xf nixexprs.tar.xz && export NIXPKGS=$PWD/nixos-25.05.*

# shellcheck, sgdisk, mkfs.vfat for the lint and disk suites
nix-build --no-out-link "$NIXPKGS" -A shellcheck -A gptfdisk -A dosfstools -A util-linux
```

When adding behaviour, add a check. The suite has already caught two real
defects: the ESP `grep -v` aborting under `pipefail` on an empty filesystem,
and `select_disks` renumbering its menu between picks (which, in a script that
runs `sgdisk --zap-all` on your choice, wipes the wrong disk).

Booting used to be out of reach; `tests/vm-boot.sh` now covers it, one VM per
firmware mode: GRUB landing correctly, the removable path being found on a
surviving disk after the first is pulled, the machine coming up degraded with
`/boot` missing, and a replacement disk resilvering back to healthy.

What remains out of reach: real hardware. The guest is emulated, so firmware
quirks, NVMe/SATA controller behaviour, and anything timing-dependent on a
physical machine are still untested. The data pool is also not covered by the
VM suite — `install-me.sh` is driven with the "skip" option, so encrypted-pool
creation and import are still evaluation-only. Say so plainly instead of
implying end-to-end coverage.

## Repo etiquette

- Work on `claude/*` branches; `main` is the published state.
- No PR unless explicitly asked.
