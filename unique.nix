{ config, pkgs, ... }:

{
  networking.hostName = "lehostname"; # Define your hostname.
  networking.hostId = "ZmenMa"; #tr -dc 0-9a-f < /dev/urandom | head -c 8
  
  # NVIDIA drivers are unfree.
  #nixpkgs.config.allowUnfree = true;

  #services.xserver.videoDrivers = [ "nvidia" ];
  #hardware.opengl.enable = true;

  # Optionally, you may need to select the appropriate driver version for your specific GPU.
  #hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  
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

#hardware.enableAllFirmware = true;

#  networking.interfaces.enp7s0f1.mtu = 9000;

#  networking.dhcpcd.extraConfig = ''
#
#    interface enp0s31f6
#    metric 1
#
#    interface enp7s0f1
#    metric 1000
#  '';

  #Mount NFS share  

#  fileSystems."/mnt/remotenfs" = {
#    device = "192.168.55.31:/storage";
#    fsType = "nfs";
#        options = [ "x-systemd.automount" "noauto" "nofail"];
#  };

  #Monitorovanie pre prometheus node exporter

#  systemd.services.smart-exporter= {
#    serviceConfig.Type = "oneshot";
#    path = with pkgs; [ bash smartmontools gawk ];
#    script = ''
#      /bin/sh -c '/mnt/docker_apps/node_exporter/smart/smartmon.sh > /mnt/docker_apps/node_exporter/smart/smart_metrics.prom'
#    '';
#  };
#  systemd.timers.smart-exporter = {
#    wantedBy = [ "timers.target" ];
#    partOf = [ "smart-exporter.service" ];
#    timerConfig = {
#      OnCalendar = "*:0/1";
#      Unit = "smart-exporter.service";
#    };
#  };
#
#  systemd.services.nvme-exporter= {
#    serviceConfig.Type = "oneshot";
#    path = with pkgs; [ bash smartmontools gawk nvme-cli jq ];
#    script = ''
#      /bin/sh -c '/mnt/docker_apps/node_exporter/smart/nvme_metrics.sh > /mnt/docker_apps/node_exporter/smart/nvme_metrics.prom'
#    '';
#  };
#  systemd.timers.nvme-exporter = {
#    wantedBy = [ "timers.target" ];
#    partOf = [ "nvme-exporter.service" ];
#    timerConfig = {
#      OnCalendar = "*:0/1";
#      Unit = "nvme-exporter.service";
#    };
#  };

}