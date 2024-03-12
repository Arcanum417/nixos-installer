# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).


#Tento config chce jeste jinej, jinak je k hovnu
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./unique.nix
    ];

  # ZFS boot settings.
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev/";

  # ZFS maintenance settings.
  services.zfs.trim.enable = true;
  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.pools = [ ];

  nixpkgs.config.allowUnfree = true;
  
  #Grub EFI vec je rozbita, musis jet AsRemovable
  boot.loader.efi.canTouchEfiVariables = false;

  # This is the regular setup for grub on UEFI which manages /boot
  # automatically.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    memtest86.enable = true;
    efiInstallAsRemovable = true;

    # This will mirror all UEFI files, kernels, grub menus and things
    # needed to boot to the other drive.
    mirroredBoots = [
      {
        devices = [ "nodev" ];

        path = "/boot-fallback";
      }
      {
        devices = [ "nodev" ];
        path = "/boot";

      }
    ];
  };
  
  #if either of them dies, don't freak out
  fileSystems."/boot".options = [ "nofail" ];
  fileSystems."/boot-fallback".options = [ "nofail" ];

  # Set your time zone.
  time.timeZone = "Europe/Bratislava";

  #Firmware upgrade service
  services.fwupd.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
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

  users.users.root.openssh.authorizedKeys.keys=
  [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsfYLiUwcli/1ZcHW9J9Xr540h7U2CFqQcaEOBnoB7R lubos@DESKTOP-GMED186"
  ];
  users.users.root.shell=pkgs.fish;

  virtualisation.docker.enable = true;
  virtualisation.docker.enableOnBoot = true;

  #don't cleanup tmp
  environment.etc."tmpfiles.d/tmp.conf".text = "";
  
  #X11 forwarding
  programs.ssh.forwardX11 = true;
  programs.ssh.setXAuthLocation = true;

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings.X11Forwarding = true;
    settings.PasswordAuthentication = false; # default true
  #  permitRootLogin = "yes";
  #  challengeResponseAuthentication = false;
  };

  # Disable the firewall altogether.
  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.05"; # Did you read the comment?

}