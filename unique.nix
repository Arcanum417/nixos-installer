# The one file that is different on every machine, and the one file you must
# keep. Together with this repo and (if you use a data pool) the ZFS key, it is
# the entire recovery kit.
#
# networking.hostId is not cosmetic: ZFS stamps it into the pool labels, and
# install-me.sh sets the live ISO's hostid from this file before creating any
# pool. Recover a machine with the wrong hostId and the pool will not import.
# Generate one once, then never change it:
#
#   tr -dc 0-9a-f < /dev/urandom | head -c 8

{ config, pkgs, ... }:

{
  networking.hostName = "lehostname";
  networking.hostId = "ZmenMa";      # <- 8 hex digits, see above

  # If this machine was first installed on an older NixOS, pin it here.
  # Otherwise disk-layout.json supplies the release that installed it.
  # system.stateVersion = "22.05";

  # ---------------------------------------------------------------- docker --
  # data-root on the data pool: configuration.nix adds a RequiresMountsFor on
  # whatever path you set here, so docker cannot start before it is mounted.
#  virtualisation.docker.storageDriver = "zfs";
  virtualisation.docker.daemon.settings = {
#      data-root = "/mnt/docker";
      ipv6 = false;
      bip = "10.201.0.1/24";
      default-address-pools = [
        {base = "10.202.0.0/16"; "size"= 24;}
        {base = "10.203.0.0/16"; "size"= 24;}
      ];
  };

  # ------------------------------------------------------------- hardware --
#  hardware.enableAllFirmware = true;

  # NVIDIA drivers are unfree.
#  services.xserver.videoDrivers = [ "nvidia" ];
#  hardware.opengl.enable = true;
#  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;

  # ------------------------------------------------------------ networking --
#  networking.interfaces.enp7s0f1.mtu = 9000;

#  networking.dhcpcd.extraConfig = ''
#
#    interface enp0s31f6
#    metric 1
#
#    interface enp7s0f1
#    metric 1000
#  '';

  # Turn the firewall back on for this machine (configuration.nix defaults it
  # off with mkDefault).
#  networking.firewall.enable = true;

  # ----------------------------------------------------------------- mounts --
#  fileSystems."/mnt/remotenfs" = {
#    device = "192.168.55.31:/storage";
#    fsType = "nfs";
#    options = [ "x-systemd.automount" "noauto" "nofail" ];
#  };

#  services.nfs.server.enable = true;
#  services.nfs.server.exports = ''
#    /mnt/shares 192.168.35.0/24(rw,async,crossmnt,fsid=0)
#  '';

  # ------------------------------------------------------------ monitoring --
  # Where to POST a ZFS alert (ntfy, gotify, Slack, healthchecks.io ...).
  # zfs-health.nix curls this whenever the pool degrades or a boot mirror
  # member goes stale.
#  environment.etc."zfs-alert-url".text = "https://ntfy.sh/my-secret-topic";

  # Prometheus node_exporter textfile collectors (see other/node_exporter/).
#  systemd.services.smart-exporter = {
#    serviceConfig.Type = "oneshot";
#    path = with pkgs; [ bash smartmontools gawk ];
#    script = ''
#      /bin/sh -c '/mnt/docker_apps/node_exporter/smart/smartmon.sh > /mnt/docker_apps/node_exporter/smart/smart_metrics.prom'
#    '';
#  };
#  systemd.timers.smart-exporter = {
#    wantedBy = [ "timers.target" ];
#    partOf = [ "smart-exporter.service" ];
#    timerConfig = { OnCalendar = "*:0/1"; Unit = "smart-exporter.service"; };
#  };
}
