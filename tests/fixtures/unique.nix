# A realistic per-machine file, modelled on a live host, used by the Nix
# evaluation tests. Deliberately has no fetchTarball import so the tests do not
# need network access to anything but the nixpkgs channel.
{ config, pkgs, ... }:

{
  networking.hostName = "sm2-box";
  networking.hostId = "37f2fb23";

  virtualisation.docker.storageDriver = "zfs";
  virtualisation.docker.daemon.settings = {
    data-root = "/mnt/docker";
    ipv6 = false;
    bip = "10.141.0.1/24";
    default-address-pools = [
      { base = "10.142.0.0/16"; "size" = 24; }
      { base = "10.143.0.0/16"; "size" = 24; }
    ];
  };

  hardware.enableAllFirmware = true;

  networking.interfaces.enp130s0f0.mtu = 9000;
  networking.interfaces.enp130s0f1.mtu = 9000;

  networking.dhcpcd.extraConfig = ''
    interface enp3s0f1
    metric 1

    interface enp130s0f0
    metric 1000
  '';

  fileSystems."/mnt/remotenfs" = {
    device = "192.168.55.31:/storage";
    fsType = "nfs";
    options = [ "x-systemd.automount" "noauto" "nofail" ];
  };

  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /mnt/shares 192.168.35.0/24(rw,async,crossmnt,fsid=0) 192.168.55.0/24(rw,async,crossmnt,fsid=0)
  '';

  services.openssh.settings.X11Forwarding = true;
  programs.ssh.forwardX11 = true;
  programs.ssh.setXAuthLocation = true;

  environment.etc."zfs-alert-url".text = "https://ntfy.sh/test-topic";
}
