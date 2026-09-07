#!/usr/bin/env bash
# Evaluates the real NixOS configuration across the supported matrix:
#   firmware {uefi, bios} x mirror width {2, 3} x data pool {yes, no}
#
# Needs nix and a nixpkgs. Set NIXPKGS=/path/to/nixpkgs, otherwise <nixpkgs>
# from NIX_PATH is used.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
set +e; trap - ERR
# shellcheck source=assert.sh
source "$HERE/assert.sh"

command -v nix-instantiate >/dev/null || { echo "nix-instantiate not found"; exit 77; }

if [[ -z ${NIXPKGS-} ]]; then
    NIXPKGS=$(nix-instantiate --find-file nixpkgs 2>/dev/null)
fi
[[ -n ${NIXPKGS-} && -d $NIXPKGS ]] || { echo "no nixpkgs (set NIXPKGS=/path)"; exit 77; }
echo "nixpkgs: $NIXPKGS"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cp "$ROOT"/configuration.nix "$ROOT"/disk-layout.nix "$ROOT"/zfs-health.nix "$WORK/"
cp "$HERE"/fixtures/unique.nix "$HERE"/fixtures/hardware-configuration.nix "$WORK/"

cat > "$WORK/eval.nix" <<EOF
(import $NIXPKGS/nixos/lib/eval-config.nix {
  system = "x86_64-linux";
  modules = [ ./configuration.nix ];
}).config
EOF

# layout NAME uefi|bios NDISKS data|nodata
# The globals set below are consumed by write_disk_layout_json in
# lib/common.sh, which the linter cannot see through the dynamic call.
# shellcheck disable=SC2034
layout () {
    BOOT_MODE=$2; ROOT_POOL=zroot; STATE_VERSION=25.05
    set_part_numbers "$BOOT_MODE"
    BOOT_DISKS=(); BOOT_MPS=()
    local i
    for (( i=0; i<$3; i++ )); do
        BOOT_DISKS+=("/dev/disk/by-id/ata-TESTDISK_$i")
        BOOT_MPS+=("$(boot_mount_point "$i")")
    done
    if [[ $4 == data ]]; then
        DATA_POOL_JSON='{"name":"zdata","keyFile":"/root/.zfs-encrypt.key","datasets":[
          {"dataset":"zdata/docker","mountPoint":"/mnt/docker"},
          {"dataset":"zdata/docker_apps","mountPoint":"/mnt/docker_apps"}]}'
    else
        DATA_POOL_JSON=null
    fi
    write_disk_layout_json "$WORK/disk-layout.json"
}

# query EXPR -> json on stdout
query () {
    ( cd "$WORK" && nix-instantiate --eval --strict --json -E \
        "let c = (import ./eval.nix); in $1" 2>"$WORK/err" )
}

check_matrix () { # check_matrix uefi|bios ndisks data|nodata
    local mode=$1 n=$2 data=$3 tag="$1/$2-way/$3"
    layout x "$mode" "$n" "$data"

    local out
    out=$(query '{
        fails      = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
        fs         = builtins.attrNames c.fileSystems;
        nmirrors   = builtins.length c.boot.loader.grub.mirroredBoots;
        efi        = c.boot.loader.grub.efiSupport;
        removable  = c.boot.loader.grub.efiInstallAsRemovable;
        nvram      = c.boot.loader.efi.canTouchEfiVariables;
        devs       = builtins.concatLists (map (b: b.devices) c.boot.loader.grub.mirroredBoots);
        paths      = map (b: b.path) c.boot.loader.grub.mirroredBoots;
        bootFs     = c.fileSystems."/boot".fsType;
        bootDev    = c.fileSystems."/boot".device;
        bootOpts   = c.fileSystems."/boot".options;
        rootDev    = c.fileSystems."/".device;
        devNodes   = c.boot.zfs.devNodes;
        forceRoot  = c.boot.zfs.forceImportRoot;
        extraPools = c.boot.zfs.extraPools;
        copyKern   = c.boot.loader.grub.copyKernels;
        confLimit  = c.boot.loader.grub.configurationLimit;
        scrub      = c.services.zfs.autoScrub.enable;
        stateVer   = c.system.stateVersion;
      }')
    if [[ -z $out ]]; then
        _fail "$tag evaluates" "$(tail -5 "$WORK/err")"; return
    fi
    _pass "$tag evaluates"

    j () { jq -r "$1" <<<"$out"; }
    eq "$tag: no failed assertions" "$(j '.fails|length')" "0"
    [[ $(j '.fails|length') == 0 ]] || _fail "$tag assertions" "$(j '.fails|join("; ")')"

    eq "$tag: one mirroredBoots entry per disk" "$(j .nmirrors)" "$n"
    eq "$tag: root is the zfs dataset"          "$(j .rootDev)"  "zroot/root"
    eq "$tag: devNodes is by-id"                "$(j .devNodes)" "/dev/disk/by-id"
    eq "$tag: forceImportRoot is off"           "$(j .forceRoot)" "false"
    eq "$tag: copyKernels on"                   "$(j .copyKern)" "true"
    eq "$tag: /boot bounded"                    "$(j .confLimit)" "15"
    eq "$tag: scrub enabled"                    "$(j .scrub)" "true"
    eq "$tag: stateVersion from json"           "$(j .stateVer)" "25.05"
    eq "$tag: boot mounts are nofail"           "$(j '.bootOpts|index("nofail")!=null')" "true"
    eq "$tag: /boot uses the by-id path"        "$(j .bootDev)" "/dev/disk/by-id/ata-TESTDISK_0-part${BOOTPART}"
    eq "$tag: first boot path"                  "$(j '.paths[0]')" "/boot"
    eq "$tag: boot paths are unique"            "$(j '(.paths|unique|length)')" "$n"

    if [[ $mode == uefi ]]; then
        eq "$tag: efiSupport"           "$(j .efi)"       "true"
        eq "$tag: installs as removable" "$(j .removable)" "true"
        eq "$tag: no NVRAM writes"      "$(j .nvram)"     "false"
        eq "$tag: /boot is vfat"        "$(j .bootFs)"    "vfat"
        eq "$tag: grub targets nodev"   "$(j '.devs|unique|join(",")')" "nodev"
    else
        eq "$tag: efiSupport off"       "$(j .efi)"       "false"
        eq "$tag: not removable"        "$(j .removable)" "false"
        eq "$tag: /boot is ext4"        "$(j .bootFs)"    "ext4"
        eq "$tag: grub targets real disks" "$(j '.devs|length')" "$n"
        eq "$tag: one device per disk"     "$(j '.devs|unique|length')" "$n"
    fi

    if [[ $data == data ]]; then
        eq "$tag: data pool imported at boot" "$(j '.extraPools|join(",")')" "zdata"
        eq "$tag: docker dataset mounted"     "$(j '.fs|index("/mnt/docker")!=null')" "true"
        eq "$tag: docker_apps mounted"        "$(j '.fs|index("/mnt/docker_apps")!=null')" "true"
    else
        eq "$tag: no extra pools"             "$(j '.extraPools|length')" "0"
        eq "$tag: no data mounts"             "$(j '.fs|index("/mnt/docker")')" "null"
    fi
}

section "evaluation matrix"
for mode in uefi bios; do
  for n in 2 3; do
    for data in data nodata; do
      check_matrix "$mode" "$n" "$data"
    done
  done
done

section "machine-specific wiring from unique.nix"
layout x uefi 2 data
out=$(query '{
    dockerMounts = c.systemd.services.docker.unitConfig.RequiresMountsFor or "UNSET";
    rootLogin    = c.services.openssh.settings.PermitRootLogin;
    passwordAuth = c.services.openssh.settings.PasswordAuthentication;
    hostName     = c.networking.hostName;
    hostId       = c.networking.hostId;
    healthTimer  = c.systemd.timers.zfs-health-check.timerConfig.OnUnitActiveSec;
    nfsMount     = c.fileSystems."/mnt/remotenfs".fsType;
  }')
eq "docker waits for its data-root" "$(jq -r .dockerMounts <<<"$out")" "/mnt/docker"
eq "root login is key-only"         "$(jq -r .rootLogin    <<<"$out")" "prohibit-password"
eq "no ssh passwords"               "$(jq -r .passwordAuth <<<"$out")" "false"
eq "hostName from unique.nix"       "$(jq -r .hostName     <<<"$out")" "sm2-box"
eq "hostId from unique.nix"         "$(jq -r .hostId       <<<"$out")" "37f2fb23"
eq "health timer runs every 15min"  "$(jq -r .healthTimer  <<<"$out")" "15min"
eq "unique.nix mounts still merge"  "$(jq -r .nfsMount     <<<"$out")" "nfs"

section "full system derivation"
for mode in uefi bios; do
    layout x "$mode" 3 data
    if ( cd "$WORK" && nix-instantiate --quiet -E \
            'let c = (import ./eval.nix); in c.system.build.toplevel' >/dev/null 2>"$WORK/err" ); then
        _pass "$mode: system.build.toplevel instantiates"
    else
        _fail "$mode: system.build.toplevel instantiates" "$(tail -5 "$WORK/err")"
    fi
done

section "zfs-health-check builds (this is what runs shellcheck on it)"
layout x uefi 2 data
if ( cd "$WORK" && nix-build --no-out-link -E \
        'let c = (import ./eval.nix); in builtins.head
           (builtins.filter (p: (p.name or "") == "zfs-health-check") c.environment.systemPackages)' \
        >"$WORK/built" 2>"$WORK/err" ); then
    _pass "health check derivation builds"
    script=$(cat "$WORK/built")/bin/zfs-health-check
    contains "checks both boot mounts" "$(cat "$script")" "for mp in /boot /boot-fallback-1"
    contains "guards grep -v against pipefail" "$(cat "$script")" "|| true; }"
else
    _fail "health check derivation builds" "$(tail -10 "$WORK/err")"
fi

summary "nix-eval"
