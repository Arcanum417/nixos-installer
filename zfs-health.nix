# Makes a degrading mirror visible.
#
# A mirror nobody watches is a single-disk machine with extra steps: the first
# disk fails unnoticed, the second fails months later, and the recovery plan
# never gets a chance to run. There is no MTA on these boxes, so this module
# uses three signals that need no infrastructure:
#
#   * the unit fails      -> shows up in `systemctl --failed`
#   * /run/zfs-health/alert -> printed on every interactive login
#   * optional webhook    -> put a URL in /etc/zfs-alert-url (ntfy, gotify,
#                            Slack, healthchecks.io - anything that takes POST)

{ config, lib, pkgs, ... }:

let
  m = builtins.fromJSON (builtins.readFile ./disk-layout.json);
  bootMounts = map (d: d.mountPoint) m.bootDisks;

  checkScript = pkgs.writeShellApplication {
    name = "zfs-health-check";
    runtimeInputs = with pkgs; [
      config.boot.zfs.package coreutils findutils gnugrep util-linux curl
    ];
    text = ''
      alerts=""
      note () { alerts="''${alerts}$1"$'\n'; }

      # ---- pool health -------------------------------------------------
      if ! zpool status -x | grep -q 'all pools are healthy'; then
        note "ZFS POOL NOT HEALTHY"
        note "$(zpool status -x)"
      fi

      # ---- boot mirror -------------------------------------------------
      # /boot and its fallbacks are ordinary filesystems that only nixos-rebuild
      # keeps in sync. Compare the set of filenames on each (not contents:
      # grub.cfg legitimately differs per ESP). A stale copy is missing kernels.
      ref=""; refmp=""
      for mp in ${lib.escapeShellArgs bootMounts}; do
        if ! mountpoint -q "$mp"; then
          note "BOOT MIRROR: $mp is not mounted - that disk is not receiving new generations"
          continue
        fi
        # grep -v returns 1 when it filters everything out (an ESP that is
        # still empty right after a disk swap); pipefail would abort on that.
        #
        # memtest.bin is excluded for the same reason as grub.cfg: it does not
        # arrive on every mount. It comes from boot.loader.grub.extraFiles, and
        # a freshly installed machine has it on /boot only -- confirmed by the
        # VM suite, where it was the *sole* difference between /boot and the
        # fallbacks. GRUB does not need it to boot the system, so counting it
        # made every healthy machine report "stale bootloader copy" on a
        # 15-minute timer. A check that cries wolf on a good machine is worse
        # than no check, because the one time it matters it gets ignored.
        sum=$(find "$mp" -type f -printf '%P\n' \
              | { grep -vE '^(grub/(grub\.cfg|grubenv|state)|memtest\.bin)$' || true; } \
              | sort | sha256sum | cut -d' ' -f1)
        if [ -z "$ref" ]; then
          ref=$sum; refmp=$mp
        elif [ "$sum" != "$ref" ]; then
          note "BOOT MIRROR: $mp does not match $refmp - stale bootloader copy, run nixos-rebuild boot"
        fi
      done

      # ---- report ------------------------------------------------------
      mkdir -p /run/zfs-health
      if [ -z "$alerts" ]; then
        rm -f /run/zfs-health/alert
        echo "healthy"
        exit 0
      fi

      printf '%s' "$alerts" > /run/zfs-health/alert
      printf '%s' "$alerts" >&2

      if [ -r /etc/zfs-alert-url ]; then
        url=$(cat /etc/zfs-alert-url)
        curl -fsS -m 20 --data-binary "$(cat /proc/sys/kernel/hostname): $alerts" "$url" >/dev/null \
          || echo "warning: could not reach the alert webhook" >&2
      fi
      exit 1
    '';
  };

in
{
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";      # nixpkgs default is monthly
  };

  services.zfs.trim.enable = true;

  services.zfs.zed.settings = {
    ZED_NOTIFY_VERBOSE = true;
    ZED_NOTIFY_INTERVAL_SECS = 3600;
    ZED_USE_ENCLOSURE_LEDS = true;
    ZED_SCRUB_AFTER_RESILVER = true;
  };

  systemd.services.zfs-health-check = {
    description = "Check ZFS pool health and boot mirror consistency";
    after = [ "zfs.target" "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${checkScript}/bin/zfs-health-check";
    };
  };

  systemd.timers.zfs-health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min";
      Unit = "zfs-health-check.service";
    };
  };

  environment.systemPackages = [ checkScript ];

  # Show it at login. Nobody reads the journal on a box that still boots fine.
  programs.bash.interactiveShellInit = lib.mkAfter ''
    if [ -s /run/zfs-health/alert ]; then
      printf '\033[41m ZFS HEALTH \033[0m\n'; cat /run/zfs-health/alert
    fi
  '';

  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -s /run/zfs-health/alert
      set_color --bold red; echo " ZFS HEALTH "; set_color normal
      cat /run/zfs-health/alert
    end
  '';
}
