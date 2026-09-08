#!/usr/bin/env bash
# Checks everything the Proxmox backend needs, without creating a VM.
#
#   bash tests/vm/proxmox-preflight.sh
#
# Every check that can fail prints what to do about it. Exits 0 when a real run
# has a chance of working, 1 otherwise. Reads configuration the same way the
# suite does, so a pass here means the suite sees the same thing.
#
# It deliberately stops short of creating anything. The point is to separate
# "cannot reach the node" from "the suite has a bug", which are otherwise easy
# to confuse an hour into a run.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
# shellcheck source=../assert.sh
source "$ROOT/tests/assert.sh"
set +e

# Optional env file, so nothing secret has to live in a shell history.
PVE_ENV=${PVE_ENV:-$HOME/.config/nixos-installer-vm/proxmox.env}
if [[ -r $PVE_ENV ]]; then
    # shellcheck disable=SC1090
    source "$PVE_ENV"
    echo "config: $PVE_ENV"
else
    echo "config: none at $PVE_ENV (using the environment)"
fi

# shellcheck source=lib-proxmox.sh
source "$HERE/lib-proxmox.sh"

section "local tools"
for c in curl jq ssh expect xorriso; do
    if command -v "$c" >/dev/null; then _pass "$c present"
    elif [[ $c == xorriso ]]; then
        skip "xorriso present" "needed to repack the installer ISO: nix-shell -p xorriso"
    else
        _fail "$c present" "install $c"
    fi
done

section "configuration"
for v in PVE_HOST PVE_NODE PVE_TOKEN_FILE; do
    if [[ -n ${!v-} ]]; then _pass "$v is set (${!v})"
    else _fail "$v is set" "export $v=... or put it in $PVE_ENV"; fi
done
_pass "storage for disks: $PVE_STORAGE"
_pass "storage for ISOs:  $PVE_ISO_STORAGE"
_pass "bridge:            $PVE_BRIDGE"
_pass "disk cache mode:   $PVE_DISK_CACHE"
_pass "VMID band:         $PVE_VMID_BASE-$(( PVE_VMID_BASE + PVE_VMID_SPAN - 1 )) (tag $PVE_TAG)"

if [[ -z ${PVE_HOST-} || -z ${PVE_NODE-} || -z ${PVE_TOKEN_FILE-} ]]; then
    summary "proxmox-preflight"; exit 1
fi

section "token file"
if [[ -r $PVE_TOKEN_FILE ]]; then
    _pass "readable: $PVE_TOKEN_FILE"
    perm=$(stat -f '%Lp' "$PVE_TOKEN_FILE" 2>/dev/null || stat -c '%a' "$PVE_TOKEN_FILE" 2>/dev/null)
    case $perm in
        600|400) _pass "permissions are $perm" ;;
        *) skip "permissions are tight" "$perm -- it holds a credential, consider chmod 600" ;;
    esac
    # Shape only. The secret itself is never echoed.
    if grep -qE '^Authorization: PVEAPIToken=[^!]+![^=]+=[0-9a-fA-F-]+[[:space:]]*$' "$PVE_TOKEN_FILE"; then
        _pass "contents look like a PVEAPIToken header"
    else
        _fail "contents look like a PVEAPIToken header" \
              "expected one line: Authorization: PVEAPIToken=USER@REALM!TOKENID=UUID"
    fi
else
    _fail "readable: $PVE_TOKEN_FILE" "create it, see tests/vm/README-proxmox.md"
    summary "proxmox-preflight"; exit 1
fi

section "API"
if ver=$(_pve_get version 2>&1); then
    _pass "authenticated: PVE $(jq -r '.data.version // "?"' <<<"$ver" 2>/dev/null)"
else
    _fail "authenticated" "$(head -c 300 <<<"$ver")
  If this is a TLS complaint, the node has a self-signed cert: export PVE_INSECURE=1"
    summary "proxmox-preflight"; exit 1
fi

if nodes=$(_pve_get nodes 2>/dev/null); then
    if jq -e --arg n "$PVE_NODE" '.data | any(.node == $n)' <<<"$nodes" >/dev/null; then
        _pass "node '$PVE_NODE' exists"
    else
        _fail "node '$PVE_NODE' exists" \
              "known nodes: $(jq -r '.data | map(.node) | join(", ")' <<<"$nodes")"
    fi
fi

# What is actually on this node, rather than what the defaults assume. Printed
# in full because picking PVE_STORAGE and PVE_ISO_STORAGE correctly is easier
# from a list than from guesswork -- and because a BTRFS storage needs one
# extra thing (see the cache note below).
section "storage inventory on $PVE_NODE"
if inv=$(_pve_get "nodes/$PVE_NODE/storage" 2>/dev/null); then
    while IFS=$'\t' read -r st ty content active; do
        [[ -n $st ]] || continue
        note=""
        [[ $ty == btrfs ]] && note="  <- BTRFS: needs cache!=none (PVE_DISK_CACHE=$PVE_DISK_CACHE handles it)"
        [[ $active == 1 ]] || note="  <- INACTIVE"
        printf '       %-16s %-10s %s%s\n' "$st" "$ty" "$content" "$note"
    done < <(jq -r '.data[] | [.storage, .type, .content, (.active|tostring)] | @tsv' <<<"$inv")
    _pass "listed $(jq -r '.data|length' <<<"$inv") storage(s)"

    # Suggest, rather than silently accept a default that does not fit.
    cand_img=$(jq -r '.data[] | select(.active == 1 and (.content | contains("images"))) | .storage' <<<"$inv" | paste -sd' ' -)
    cand_iso=$(jq -r '.data[] | select(.active == 1 and (.content | contains("iso")))    | .storage' <<<"$inv" | paste -sd' ' -)
    [[ -n $cand_img ]] && echo "       usable for VM disks (PVE_STORAGE):     $cand_img"
    [[ -n $cand_iso ]] && echo "       usable for ISOs     (PVE_ISO_STORAGE): $cand_iso"
fi

section "storage"
for pair in "$PVE_STORAGE:images" "$PVE_ISO_STORAGE:iso"; do
    st=${pair%%:*}; want=${pair##*:}
    if got=$(_pve_get "nodes/$PVE_NODE/storage" 2>/dev/null \
             | jq -r --arg s "$st" '.data[] | select(.storage == $s) | .content'); then
        if [[ -z $got ]]; then
            _fail "storage '$st' is available on $PVE_NODE" \
                  "not present; available: $(_pve_get "nodes/$PVE_NODE/storage" | jq -r '.data|map(.storage)|join(", ")')"
        elif [[ $got == *"$want"* ]]; then
            _pass "storage '$st' accepts $want"
        else
            _fail "storage '$st' accepts $want" "its content types are: $got"
        fi
    fi
done

# A token that can see nothing looks identical to an empty node, and the
# storage endpoints return {"data":[]} rather than 403. Without this check the
# "VMID band is free" section below reports every VMID free -- a false pass on
# a safety check, which is the worst kind. Verified against a real node, where
# a --privsep token with no matching *user* ACL behaved exactly this way.
section "the token can actually see things"
if _pve_get "nodes/$PVE_NODE/qemu" >/dev/null 2>&1; then
    _pass "can enumerate VMs on $PVE_NODE"
else
    _fail "can enumerate VMs on $PVE_NODE" \
          "the token cannot list VMs. With --privsep 1 the token's rights are
  intersected with the USER's, and a fresh user has none -- grant the same ACLs
  to --users ci@pve as to --tokens ci@pve!vmtest. See README-proxmox.md."
fi
if [[ $(_pve_get "nodes/$PVE_NODE/storage" | jq -r '.data | length') -gt 0 ]]; then
    _pass "can see at least one storage"
else
    _fail "can see at least one storage" \
          "zero storages visible. This is a permissions symptom, not an empty node:
  grant Datastore privileges to both the token and the user (see above)."
fi

section "VMID band is free"
for off in 1 2; do
    vmid=$(( PVE_VMID_BASE + off ))
    if cfg=$(_pve_get "nodes/$PVE_NODE/qemu/$vmid/config" 2>/dev/null); then
        tags=$(jq -r '.data.tags // ""' <<<"$cfg")
        case ",$tags," in
            *",$PVE_TAG,"*) _pass "$vmid exists and is one of ours (tag $PVE_TAG)" ;;
            *) _fail "$vmid is free or ours" \
                     "VM $vmid exists WITHOUT the '$PVE_TAG' tag -- the suite will refuse to touch it.
  Move it, or point the suite elsewhere with PVE_VMID_BASE." ;;
        esac
    else
        # Only meaningful given the visibility check above passed; a blind
        # token cannot distinguish "absent" from "not allowed to look".
        _pass "$vmid is free"
    fi
done

section "ssh to the node (for the serial console)"
dest=$(_pve_ssh)
if ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$dest" true 2>/dev/null; then
    _pass "ssh $dest works without a prompt"
    if ssh -T -o BatchMode=yes "$dest" 'command -v socat' >/dev/null 2>&1; then
        _pass "socat present on the node"
    else
        _fail "socat present on the node" "apt install socat -- the serial console goes through it"
    fi
    if ssh -T -o BatchMode=yes "$dest" 'test -d /var/run/qemu-server' 2>/dev/null; then
        _pass "/var/run/qemu-server exists (where the console sockets appear)"
    else
        skip "/var/run/qemu-server exists" "created when a VM first starts; not an error on an idle node"
    fi
else
    _fail "ssh $dest works without a prompt" \
          "ssh-copy-id $dest, and check BatchMode works (no passphrase prompt).
  Override the destination with PVE_SSH if it differs from PVE_HOST."
fi

section "KVM (the reason to use this backend)"
if kvm=$(ssh -T -o BatchMode=yes "$dest" 'test -e /dev/kvm && echo yes || echo no' 2>/dev/null); then
    if [[ $kvm == yes ]]; then
        arch=$(ssh -T -o BatchMode=yes "$dest" 'uname -m' 2>/dev/null)
        if [[ $arch == x86_64 ]]; then
            _pass "node is x86_64 with /dev/kvm -- the guest will be accelerated"
        else
            skip "node is x86_64" "node reports '$arch'; an x86_64 guest there would be emulated, like UTM"
        fi
    else
        skip "/dev/kvm on the node" "no KVM: the guest will be emulated and slow"
    fi
fi

summary "proxmox-preflight"
