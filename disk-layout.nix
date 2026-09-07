# Everything about this machine's disks, derived from ./disk-layout.json.
#
# The JSON is written by install-me.sh and rewritten by replace-boot-disk.sh.
# This file is static and ships in the repo, so swapping a disk means editing
# one JSON field and rebuilding - never hand-editing Nix.
#
#   {
#     "bootMode": "uefi" | "bios",
#     "rootPool": "zroot",
#     "stateVersion": "25.05",
#     "bootDisks": [ { "id": "/dev/disk/by-id/...",
#                      "bootPart": 1, "zfsPart": 2, "mountPoint": "/boot" } ],
#     "dataPool": null | { "name": "zdata", "keyFile": "/root/.zfs-encrypt.key",
#                          "datasets": [ { "dataset": "...", "mountPoint": "..." } ] }
#   }

{ lib, ... }:

let
  m = builtins.fromJSON (builtins.readFile ./disk-layout.json);

  uefi = m.bootMode == "uefi";

  bootDevice = d: "${d.id}-part${toString d.bootPart}";

  # nofail so a dead disk does not wedge the boot. The cost of nofail is that
  # a rebuild with a boot mirror member unmounted silently writes that
  # generation to a directory on the root pool instead - zfs-health.nix exists
  # to catch exactly that.
  bootOptions =
    [ "nofail" "x-systemd.device-timeout=5s" ]
    ++ lib.optionals uefi [ "umask=0077" ];

  rootFilesystems = {
    "/"     = { device = "${m.rootPool}/root";      fsType = "zfs"; };
    "/nix"  = { device = "${m.rootPool}/root/nix";  fsType = "zfs"; };
    "/home" = { device = "${m.rootPool}/root/home"; fsType = "zfs"; };
  };

  bootFilesystems = lib.listToAttrs (map (d:
    lib.nameValuePair d.mountPoint {
      device  = bootDevice d;
      fsType  = if uefi then "vfat" else "ext4";
      options = bootOptions;
    }) m.bootDisks);

  hasData = m.dataPool != null;

  dataFilesystems = lib.optionalAttrs hasData (lib.listToAttrs (map (ds:
    lib.nameValuePair ds.mountPoint {
      device = ds.dataset;
      fsType = "zfs";
    }) m.dataPool.datasets));

in
{
  fileSystems = rootFilesystems // bootFilesystems // dataFilesystems;

  # ---------------------------------------------------------------- ZFS ----

  boot.supportedFilesystems = [ "zfs" ];

  # by-id, not /dev/. `zpool status` has to name the disk you physically pull.
  boot.zfs.devNodes = "/dev/disk/by-id";

  # Never force-import the root pool. install-me.sh stamps the pool with the
  # hostId from unique.nix and exports it cleanly, so a legitimate boot never
  # needs -f; if an import does fail, that is a fact worth stopping for.
  boot.zfs.forceImportRoot = false;

  boot.zfs.extraPools = lib.optional hasData m.dataPool.name;

  # Datasets on the data pool carry keylocation=file://<keyFile>; the import
  # service loads them from the running root at boot.
  boot.zfs.requestEncryptionCredentials = true;

  # --------------------------------------------------------------- GRUB ----

  boot.loader.efi.canTouchEfiVariables = false;

  boot.loader.grub = {
    enable = true;
    zfsSupport = true;

    # /boot is a separate filesystem from /nix, so kernels have to be copied
    # into it. install-grub.pl infers this anyway; being explicit means a
    # broken mount cannot silently flip it off.
    copyKernels = true;

    # A 2 GiB /boot holds roughly this many kernel+initrd pairs. Without a
    # limit /boot fills up and the machine stops being able to install a new
    # generation.
    configurationLimit = 15;

    memtest86.enable = true;

    efiSupport = uefi;
    # Removable install: EFI/BOOT/BOOTX64.EFI on every ESP, no NVRAM entries,
    # so any surviving disk boots on its own in any machine.
    efiInstallAsRemovable = uefi;

    # One entry per disk. On UEFI the target is the ESP mounted at path; on
    # BIOS it is the disk's MBR plus its EF02 partition, which is why the BIOS
    # path needs real by-id device paths here.
    mirroredBoots = map (d: {
      path = d.mountPoint;
      devices = if uefi then [ "nodev" ] else [ d.id ];
    }) m.bootDisks;
  };

  # Set from the release that installed the machine. Override in unique.nix if
  # this machine was originally installed on an older NixOS.
  system.stateVersion = lib.mkDefault m.stateVersion;
}
