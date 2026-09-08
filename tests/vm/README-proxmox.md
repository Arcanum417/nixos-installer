# Running the VM suite against a Proxmox node

The same suite as [`README.md`](README.md) — same phases, same assertions, same
expect drivers — with a Proxmox VE node standing in for local UTM.

**Why bother:** UTM on an arm64 Mac runs an x86_64 guest under TCG emulation,
and the install compiles GRUB from source (`disk-layout.nix` sets
`zfsSupport`, which is not a cached derivation). That is why a full UTM run
takes hours. An x86_64 Proxmox node runs the identical guest under KVM, so the
same work happens at near-native speed. Proxmox also gives more realistic
hardware: real OVMF and SeaBIOS, virtio-scsi, and a node that is not a laptop.

**Status: verified.** A full run — both firmware modes, all four phases —
passes against a live PVE 8.2.5 node: **73 checks, 0 failed, 1 skipped** (the
skip is structural: BIOS has no ESP). `RESULTS.md` carries the verbatim output
and the bugs first contact turned up.

**It takes about an hour**, both modes end to end, against most of a day on
UTM. Measured per phase on a node with `/dev/kvm`:

| Phase | uefi | bios |
|---|---|---|
| `install` | ~9 min | ~3.5 min |
| `boot` | ~2.5 min | ~2.5 min |
| `degraded` | ~5.5 min | ~6.5 min |
| `replace` | ~15 min | ~15 min |

The install is quicker in BIOS mode because the two firmware modes build
different GRUB derivations and the shared parts of the closure are already in
the node's store by then.

## Setting it up

### 1. A scoped API token

Do not use `root@pam`. Create a token that can only touch the VMID band the
suite uses, so a bug in the harness cannot reach a production VM:

```sh
pveum user add ci@pve
pveum user token add ci@pve vmtest --privsep 1     # prints the secret ONCE

# Grant to BOTH the token and the user. See the note below -- this is the one
# step that is easy to get wrong and produces a token that silently sees
# nothing at all.
for who in "--tokens ci@pve!vmtest" "--users ci@pve"; do
  # The VMID band, not /vms. This is the real safety boundary.
  for id in $(seq 9000 9099); do
    # shellcheck disable=SC2086
    pveum acl modify "/vms/$id" $who --roles PVEVMAdmin
  done
  # Whichever storage actually holds the disks and the ISOs -- run the
  # preflight to find its name; it may be one storage for both.
  # shellcheck disable=SC2086
  pveum acl modify /storage/local-btrfs $who --roles PVEDatastoreAdmin
done
```

**`--privsep 1` intersects the token's rights with the user's, and a freshly
created user has none.** Granting only the token therefore yields a token with
no effective privileges — and the failure is quiet rather than a 403: the
storage endpoints return `{"data":[]}`, so it looks like the node has no
storage rather than like a permissions problem. Grant both, or create the token
with `--privsep 0` and grant the user only.

`PVEDatastoreAdmin` is needed on the storage that holds the ISOs, because
uploading one requires `Datastore.AllocateTemplate`. If disks and ISOs live on
different storages, the disk one can be the weaker `PVEDatastoreUser`
(`Datastore.AllocateSpace` + `Datastore.Audit`).

Write the header to a file rather than passing it on a command line, where it
would be world-readable in `ps`:

```sh
umask 077
echo 'Authorization: PVEAPIToken=ci@pve!vmtest=PASTE-THE-UUID-HERE' > ~/.pve-token
```

### 2. SSH to the node

Needed for exactly one thing: the serial console. Key-based, no passphrase
prompt, and `socat` present on the node (`apt install socat`).

```sh
ssh-copy-id root@pve1
ssh -T root@pve1 'command -v socat'
```

### 3. Point the suite at it

```sh
export PVE_HOST=pve1.example.lan
export PVE_NODE=pve1                 # the node name inside the cluster
export PVE_TOKEN_FILE=~/.pve-token
export PVE_STORAGE=local-lvm         # where VM disks go
export PVE_ISO_STORAGE=local         # must have "iso" in its content types
export PVE_BRIDGE=vmbr0
# export PVE_INSECURE=1              # self-signed cert on the node
# export PVE_SSH=root@10.0.0.5       # if ssh goes somewhere else than PVE_HOST

bash tests/vm-boot.sh                # both firmware modes, all four phases
```

Setting `PVE_HOST` selects this backend automatically; `VM_BACKEND=proxmox`
forces it and `VM_BACKEND=utm` forces local UTM. The suite prints which one it
chose as its first line. A backend that cannot run reports itself as skipped
(exit 77) rather than failing.

`xorriso` is still needed on the *machine running the suite*, to repack the
installer ISO with a serial console — `nix-shell -p xorriso`.

### Which storage to use

Don't guess — `proxmox-preflight.sh` prints every storage on the node with its
type and content types, and then names the ones actually usable for VM disks
and for ISOs. Pick from that list.

Any storage carrying `images` works for `PVE_STORAGE`, and any carrying `iso`
works for `PVE_ISO_STORAGE`. They can be the same storage if it does both. A
default Proxmox install gives you `local-lvm` (LVM-thin: `images rootdir`) and
`local` (directory: `iso vztmpl backup images ...`), which is why those are the
defaults here — but a node with BTRFS, ZFS or NFS storage may be arranged
differently.

**If your VM disks live on BTRFS, one thing matters.** Proxmox's BTRFS
documentation warns:

> BTRFS will honor the O_DIRECT flag when opening files, meaning VMs should not
> use cache mode `none`, otherwise there will be checksum errors.

Both `none` and `directsync` use `O_DIRECT`, so both are unusable there. This
backend therefore sets `cache=writeback` on every disk explicitly rather than
inheriting a default — safe on every storage type, and ZFS in the guest is
crash-consistent, which is what the pull-a-disk phases depend on. Override with
`PVE_DISK_CACHE` if you have a reason, but do not set it to `none` or
`directsync` on BTRFS.

## What differs from the UTM backend

Only this file and `lib-proxmox.sh`. The phases, assertions, probes and expect
drivers are shared, which is the point of the thirteen-function contract
documented at the top of `lib-utm.sh`.

| | UTM | Proxmox |
|---|---|---|
| VM identity | `.utm` bundle name | VMID, derived from the name (9001 uefi, 9002 bios) |
| Config changes | rewrite `config.plist`, then restart UTM | one API call, applied immediately |
| `utm_reload` | quit and relaunch UTM | **no-op** |
| Serial console | TCP port UTM listens on | unix socket on the node, reached over `ssh` + `socat` |
| Firmware switch | `QEMU.UEFIBoot` boolean | `bios=ovmf` + an `efidisk0`, or `bios=seabios` |
| "Pull a disk" | drop it from the `Drive` array | `delete=scsiN`, volume survives as `unused0` |
| Guest disk naming | QEMU's own NVMe serials | explicit `wwn=` per disk |
| Cleanup guard | name prefix | VMID band **and** tag, both re-read from the node |
| Speed | TCG, hours | KVM, near-native |

### Three decisions worth knowing

**Secure Boot is deliberately off.** The EFI disk is created with
`pre-enrolled-keys=0`. With Microsoft's keys enrolled, OVMF refuses the
unsigned GRUB this repo installs, and the failure looks like a mysterious boot
failure rather than a policy decision. `efitype=4m` is the current format; `2m`
exists only for backward compatibility.

**Disks carry an explicit `wwn=`.** `install-me.sh` records
`/dev/disk/by-id/...` paths into `disk-layout.json` and `disk-layout.nix`
consumes them verbatim, so the guest-visible name has to be predictable.
`wwn-0x<16 hex>` is a documented, stable path with no vendor or product prefix.
A `serial=` is set too, but only because it is what a human reads in `lsblk`:
the `scsi-*` path udev derives from it is generated guest-side and is not
something Proxmox documents. Given this repo's history — a whole class of bug
came from two by-id spellings of one NVMe disk — depending on the documented
form is the right call.

**Detach is not delete.** Pulling a disk uses `delete=scsiN`, which removes the
config entry and leaves the volume as `unused0`. `unlink --force` would destroy
it, and then the replace phase would have nothing to put back. Reattaching
finds the volume among the `unused[n]` entries rather than allocating a fresh
one, so the "put the disk back" path really does return the same disk.

## Safety

The suite talks to a machine that may host real VMs, so:

- **VMID band.** Everything lives in `[PVE_VMID_BASE, +100)`, default
  9000–9099. Anything outside it is refused.
- **Tag.** VMs are created with `tags=ci-vmtest`, and destroy requires the tag
  to be present in the config it reads back from the node. Tags are advisory
  metadata in Proxmox, so this is a second check, never the only one.
- **A scoped token is the real boundary.** The two checks above live in the same
  script that does the destroying; an ACL on `/vms/9000..9099` does not. Scope
  the token.
- Set `protection: 1` on VMs you care about. It blocks remove operations at the
  hypervisor. Leave it off the test VMs or cleanup cannot work.

## What first contact settled

These were listed as uncertainties before the backend had met a real node.
Resolved by observation:

- **The guest's `/dev/disk/by-id/` name is `scsi-3<wwn>`.** Setting `wwn=` on
  each drive produces `/dev/disk/by-id/scsi-35000c50000ff0001-part2` and
  friends inside the guest — udev's SCSI form built from the WWN, stable across
  reboots and across the detach/reattach the degraded and replace phases do.
  That is what `disk-layout.json` records and `disk-layout.nix` consumes.
- **One client on the serial socket is a real constraint.** It behaved exactly
  as documented. Do not leave a browser console open on the VM while the suite
  runs.
- **A privsep token can read its own task status.** The harness polls task
  UPIDs constantly and never needed `Sys.Audit`.

Two things still worth knowing:

- **Destroying a VM removes its VM-specific permissions.** This is why the
  token is granted on a pool rather than per-VMID; see `PVE_POOL` in
  `lib-proxmox.sh`. Granting per-VMID works exactly once.
- **`qm wait`.** There is a node-side `qm wait <vmid> --timeout N` with no REST
  equivalent; `vm_wait_stopped` polls `/status/current` instead, which works
  from off-box without root.

## Bugs this backend had, and what found them

Every one was in the harness rather than the installer, and none was visible to
shellcheck or to reading the code:

1. `local vmid; vmid=$(...) upid` parses as "run the command `upid`".
2. `net0=virtio,bridge=...` is config-file syntax the API rejects; it wants
   `model=virtio`.
3. Destroying a VM removed the per-VMID ACL, so cleanup deleted the harness's
   own access: the first run worked and every later one returned 403.
4. `env(...)` inside a Tcl proc does not see the global `env` array, so every
   run silently fell back to `nc` — which meant attaching to whatever happened
   to be on that TCP port rather than to the guest.
5. `spawn` swallowed `-o BatchMode=yes` as an abbreviation of its own `-open`
   flag. Hence the helper script: a single path with no dashes in it.
6. A boot order naming a disk that does not exist yet makes Proxmox store an
   *empty* order, and OVMF then drops to the UEFI Shell.
7. The probes raced their own output, so a value could be scored empty on a
   healthy pool. Fixed with a per-probe sentinel.
8. `eval spawn [split $cmd]` left `spawn_id` holding the command string minus
   its first eight characters.

The last two only appear on a fast guest: UTM's emulation was slow enough to
hide both. That is worth remembering — a slower environment does not simply
take longer, it hides a category of bug.

## Reading list

- [API viewer](https://pve.proxmox.com/pve-docs/api-viewer/index.html) — the
  generated schema, and the authority on parameter names
- [`qm.conf(5)`](https://pve.proxmox.com/pve-docs/qm.conf.5.html) — `bios`,
  `efidisk0`, `serial[n]`, `scsi[n]` including `serial=`/`wwn=`
- [Proxmox VE API wiki](https://pve.proxmox.com/wiki/Proxmox_VE_API) — token
  format, and why tokens need no CSRF token
- [`pveum`](https://pve.proxmox.com/pve-docs/pveum-plain.html) — token creation
  and ACL scoping
- [Serial Terminal wiki](https://pve.proxmox.com/wiki/Serial_Terminal) — the
  guest side of a serial console
