# Running the VM suite against a Proxmox node

The same suite as [`README.md`](README.md) — same phases, same assertions, same
expect drivers — with a Proxmox VE node standing in for local UTM.

**Why bother:** UTM on an arm64 Mac runs an x86_64 guest under TCG emulation,
and the install compiles GRUB from source (`disk-layout.nix` sets
`zfsSupport`, which is not a cached derivation). That is why a full UTM run
takes hours. An x86_64 Proxmox node runs the identical guest under KVM, so the
same work happens at near-native speed. Proxmox also gives more realistic
hardware: real OVMF and SeaBIOS, virtio-scsi, and a node that is not a laptop.

**Status: written but not yet run against a real node.** Every API call, the
serial mechanism and the disk semantics come from the Proxmox documentation and
source (see the reading list at the bottom), and the code is shellcheck-clean,
but nothing here has been executed against a live cluster. Expect to shake out
one or two things on first contact — the likely candidates are called out under
*Known uncertainties*.

## Setting it up

### 1. A scoped API token

Do not use `root@pam`. Create a token that can only touch the VMID band the
suite uses, so a bug in the harness cannot reach a production VM:

```sh
pveum user add ci@pve
pveum user token add ci@pve vmtest --privsep 1     # prints the secret ONCE

# The VMID band, not /vms. This is the real safety boundary.
for id in $(seq 9000 9099); do
  pveum acl modify "/vms/$id" --tokens 'ci@pve!vmtest' --roles PVEVMAdmin
done
pveum acl modify /storage/local     --tokens 'ci@pve!vmtest' --roles PVEDatastoreAdmin
pveum acl modify /storage/local-lvm --tokens 'ci@pve!vmtest' --roles PVEDatastoreUser
```

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

## Known uncertainties

Flagged rather than buried, since none of this has met a real node yet:

- **The exact guest `/dev/disk/by-id/` string.** `wwn-0x...` is documented, but
  the udev-derived `scsi-*` sibling is not. If a phase fails claiming a disk is
  missing, dump `ls -l /dev/disk/by-id/` from the guest and compare.
- **One client on the serial socket.** A QEMU socket chardev serves a single
  client. Do not leave a browser console open on the VM while the suite runs.
- **API tokens on the console endpoints.** Proxmox's own docs and its API schema
  disagree about whether a token may use `termproxy`/`vncwebsocket`. Moot here —
  this backend uses `ssh` + `socat` and needs no PVE ticket — but relevant if
  anyone reworks the console path.
- **`qm wait`.** There is a node-side `qm wait <vmid> --timeout N` with no REST
  equivalent; `vm_wait_stopped` polls `/status/current` instead, which works
  from off-box without root.

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
