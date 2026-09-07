# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this repo is

A **hand-rolled NixOS bare-metal installer for two-disk mirrored machines.**

The stated goal: recover *any* machine from a NixOS live ISO, given only
(a) this repo, (b) a per-machine `unique.nix`, and (c) the ZFS encryption key
for the data pool. Everything else is rebuilt from scratch.

It is **not** a flake, **not** a NixOS module, and has **no** CI, tests, or
lockfile. It is a pile of bash + `.nix` files copied verbatim into
`/mnt/etc/nixos/` during installation.

## SAFETY — read before running anything

`install-me.sh`, `finish-me.sh`, and `finish-me-bios.sh` **destroy every
partition on the two disks the operator selects** (`sgdisk --zap-all`,
`wipefs -fa`, `dd`). They are meant to run as root from a NixOS live ISO
against blank hardware.

**Never execute them in a dev container, a CI job, or on a working machine.**
Static checks only. In this environment the only tool available is
`bash -n <script>` (no `nix`, no `shellcheck`, no `sgdisk`, no `zpool`).

## File map

| File | Role |
|---|---|
| `install-me.sh` | **Stage 1.** Detects UEFI vs BIOS, prompts for DISK1/DISK2, partitions both, creates the `zroot` mirror + datasets, mounts `/mnt`, runs `nixos-generate-config`, copies `./*.nix` into `/mnt/etc/nixos/`. Does **not** run `nixos-install`. |
| `finish-me.sh` | **Stage 2.** Prompts for two *more* disks, wipes them, creates the encrypted `zdata` mirror (`docker`, `docker_apps`), regenerates hardware config, runs `nixos-install`. Marked `#edit me` — expected to be hand-edited per machine. |
| `finish-me-bios.sh` | **Byte-identical duplicate of `finish-me.sh`** (only the trailing newline differs). Nothing in it is BIOS-specific. |
| `configuration.nix` | Shared system config, **UEFI variant**. GRUB EFI + `efiInstallAsRemovable` + `mirroredBoots` over `/boot` and `/boot-fallback`. Imports `hardware-configuration.nix` and `unique.nix`. |
| `configuration-bios.nix` | **BIOS variant.** GRUB i386-pc, `zfsSupport`, `copyKernels`. Currently contains **hardcoded Intel SSD serials** for one specific machine. Nothing selects it automatically — the operator must rename it over `configuration.nix`. |
| `unique.nix` | **The per-machine file.** Hostname, `networking.hostId`, GPU drivers, docker networking, NFS mounts, node_exporter timers. This is the file the recovery story says you keep around. Ships with placeholders (`lehostname`, `ZmenMa`). |
| `poznamky.txt` | Raw `history` dump from the original manual install. Scratch notes, not executable. |
| `other/node_exporter/smart/` | `smartmon.sh`, `nvme_metrics.sh` — Prometheus textfile-collector scripts, referenced by the commented-out systemd timers in `unique.nix`. |

## Install flow

```
NixOS live ISO, root shell
  └─ ./install-me.sh          # partitions + zroot mirror + copies configs
  └─ (hand-edit /mnt/etc/nixos/unique.nix: hostName, hostId)
  └─ ./finish-me.sh           # zdata mirror + nixos-install
  └─ reboot
```

Both scripts are `nix-shell` shebang scripts (`-p bash gptfdisk`).

## Disk & pool layout

**UEFI** (per disk, table cloned DISK1 → DISK2 with `sfdisk --dump | sfdisk`):

| Part | Type | Size | Contents |
|---|---|---|---|
| 3 | `EF00` | 512 MiB | ESP, vfat, mounted `/boot` (DISK1) and `/boot-fallback` (DISK2) |
| 1 | `BF01` | rest | `zroot` mirror member |

**BIOS:**

| Part | Type | Size | Contents |
|---|---|---|---|
| 2 | `EF02` | 2 MiB | BIOS boot partition (no filesystem) |
| 3 | `8300` | 512 MiB | ext4, `/boot` (DISK1) / `/boot-fallback` (DISK2) |
| 1 | `BF01` | rest | `zroot` mirror member |

**Pools:**

```
zroot            mirror DISK1-part1 DISK2-part1   (unencrypted)
  zroot/root          -> /        mountpoint=legacy
  zroot/root/nix      -> /nix
  zroot/root/home     -> /home

zdata            mirror DISK3 DISK4 (whole disks, encrypted, raw keyfile)
  zdata/docker        -> /mnt/docker
  zdata/docker_apps   -> /mnt/docker_apps
```

Pool properties used throughout: `ashift=12`, `atime=off`, `compression=lz4`,
`acltype=posixacl`, `xattr=sa`, `mountpoint=none` at pool level with
`mountpoint=legacy` on every dataset (so `fileSystems.*` in Nix owns mounting).

`zdata` uses `-O encryption=on -O keyformat=raw
-O keylocation=file:///root/.zfs-encrypt.key`. The key must exist **both** in
the live ISO's `/root/` and in `/mnt/root/` before `nixos-install` — the
scripts do not copy it; see the Slovak prompt in `finish-me.sh`.

## Boot redundancy model

Redundancy is **two independent mechanisms**, and only the first is automatic:

1. **`zroot` is a real ZFS mirror.** Self-healing, scrubbed weekly by
   `services.zfs.autoScrub`.
2. **`/boot` and `/boot-fallback` are two unrelated filesystems**, kept in sync
   *only* by `nixos-rebuild` writing to both via `boot.loader.grub.mirroredBoots`.
   Both are marked `nofail`, so a rebuild with one of them unmounted succeeds
   silently and leaves that disk stale. There is no health check for this.

On UEFI, `efiInstallAsRemovable = true` + `canTouchEfiVariables = false` means
GRUB is written to `EFI/BOOT/BOOTX64.EFI` on *both* ESPs with no NVRAM entries,
so either disk boots standalone. (Verified: `grub.nix` emits one
`install-grub.pl` invocation per `mirroredBoots` entry, each with its own
`--efi-directory` and `--removable`.)

## Conventions

- Comments and prompts are in **Czech/Slovak**, mixed with English. Keep the
  existing language in a file rather than translating it wholesale.
- `#edit me` / `#UPRAV SI SCRIPT!` mark the spots the operator is expected to
  hand-edit before running. Treat them as intentional, not as TODOs to remove.
- Indentation is inconsistent (mixed tabs and spaces, notably in `install-me.sh`
  BIOS branch and `configuration-bios.nix`). Match the surrounding block.
- **Machine-specific values belong in `unique.nix`**, not in `configuration*.nix`.
  `configuration-bios.nix` currently violates this.
- `system.stateVersion` is currently different between the two configs
  (`22.05` UEFI, `25.11` BIOS). Do not "unify" this without asking — it changes
  stateful defaults.

## Known problems

There is a full audit in **`AUDIT.md`**, ordered by severity. Read it before
changing the partitioning or pool-creation code. The short version:

- `sfdisk --dump DISK1 | sfdisk DISK2` clones the GPT **disk GUID and every
  partition GUID**, giving both disks identical `PARTUUID`s.
- `mkfs.vfat` runs before udev has created the `-part3` by-id symlinks
  (the `sleep 5` is *after* it).
- Nothing prevents selecting the same disk as both DISK1 and DISK2.
- The by-id path is guessed from `lsblk` column positions and assumes
  `ata-` or `nvme-`; USB / virtio / SAS / blank-MODEL disks break it.
- `boot.zfs.devNodes = "/dev/"` (UEFI config) makes `zpool status` report
  `sda1`/`nvme0n1p1` instead of stable by-id names — bad when you need to
  identify which physical disk to pull.
- The `zdata` key lives on the *unencrypted* `zroot`, on the same machine.
- `zdata` is never imported at boot (`boot.zfs.extraPools` is unset and no
  `fileSystems` entry exists for it).

## Validating changes here

No nix toolchain in this environment. What you can do:

```sh
bash -n install-me.sh finish-me.sh finish-me-bios.sh   # syntax only
```

For real validation the change has to be tried on a VM with two virtual disks
(UEFI and BIOS firmware separately). Say so explicitly rather than claiming a
change is verified.

## Repo etiquette

- Branch: work happens on `claude/*` branches, `main` is the published state.
- No PR unless explicitly asked.
