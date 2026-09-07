# Shared system configuration. Identical on every machine installed with this
# repo - anything machine-specific belongs in unique.nix.
#
# Disks, pools, filesystems and the bootloader live in disk-layout.nix, driven
# by the generated disk-layout.json. Pool monitoring lives in zfs-health.nix.
# There is no longer a separate BIOS variant of this file; disk-layout.json
# says which firmware the machine uses.

{ config, pkgs, lib, ... }:

{
  imports =
    [
      ./hardware-configuration.nix   # generated with --no-filesystems
      ./disk-layout.nix              # pools, fileSystems, GRUB (from disk-layout.json)
      ./zfs-health.nix               # scrub, ZED, degraded-mirror alerting
      ./unique.nix                   # this machine
    ];

  nixpkgs.config.allowUnfree = true;

  time.timeZone = lib.mkDefault "Europe/Bratislava";

  services.fwupd.enable = true;

  environment.systemPackages = with pkgs; [
      any-nix-shell
      nixpkgs-fmt
      starship
      cacert
      glances
      htop
      tmux
      rsync
      git
      jq            # disk-layout.json is read by the disk-replacement tooling
      smartmontools # identifying and checking the disk you are about to pull
      nvme-cli
      gptfdisk      # sgdisk, used by replace-boot-disk.sh
      dosfstools    # mkfs.vfat for a replacement ESP
      e2fsprogs     # mkfs.ext4 for a replacement BIOS /boot
    ];

  programs.fish = {
    enable = true;
    shellAliases = {
      ls = "ls -la";
      docker-compose = "docker compose";
    };
    interactiveShellInit = ''
      any-nix-shell fish --info-right | source
      starship init fish | source
    '';
  };

  programs.nano.syntaxHighlight = true;

  nix = {
    settings.auto-optimise-store = true;
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 90d";
    };
  };

  users.users.root.openssh.authorizedKeys.keys =
  [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsfYLiUwcli/1ZcHW9J9Xr540h7U2CFqQcaEOBnoB7R lubos@DESKTOP-GMED186"
  ];
  users.users.root.shell = pkgs.fish;

  virtualisation.docker.enable = true;
  virtualisation.docker.enableOnBoot = true;

  # If unique.nix points docker at a data-pool path, docker must not start
  # before that dataset is mounted - otherwise it quietly initialises a fresh
  # state directory on the root pool and you lose every container.
  systemd.services.docker = lib.mkIf
    (config.virtualisation.docker.enable
     && (config.virtualisation.docker.daemon.settings.data-root or null) != null)
    { unitConfig.RequiresMountsFor = config.virtualisation.docker.daemon.settings.data-root; };

  #don't cleanup tmp
  environment.etc."tmpfiles.d/tmp.conf".text = "";

  #X11 forwarding
  programs.ssh.forwardX11 = true;
  programs.ssh.setXAuthLocation = true;

  services.openssh = {
    enable = true;
    settings.X11Forwarding = true;
    settings.PasswordAuthentication = false;
    # PermitRootLogin defaults to "prohibit-password": key-only root login.
  };

  # mkDefault so a machine that wants a firewall can just set it in unique.nix.
  networking.firewall.enable = lib.mkDefault false;

  # system.stateVersion comes from disk-layout.json (the release that installed
  # the machine). Override it in unique.nix for a machine first installed on an
  # older NixOS.
}
