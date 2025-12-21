#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash gptfdisk

# Run as root please

# BASH error handling:
set -e
trap 'LAST_COMMAND=$CURRENT_COMMAND; CURRENT_COMMAND=$BASH_COMMAND' DEBUG
trap 'ERROR_CODE=$?; FAILED_COMMAND=$LAST_COMMAND; tput setaf 1; echo "ERROR: command \"$FAILED_COMMAND\" failed with exit code $ERROR_CODE"; tput sgr0;' ERR INT TERM

COLOR_RESET="\033[0m"
BLUE_BG="\033[44m"

ask_question () {
    echo -e "\n${BLUE_BG} > $1${COLOR_RESET}"
}

ask_question_yn () {
    ask_question "$1" ; read -n 1 -r
}

unmount_it () {
    if mountpoint -q "$1"; then
        umount -f "$1"
    fi
}

unmount_it /mnt/boot
unmount_it /mnt/boot-fallback
unmount_it /mnt/nix
unmount_it /mnt/home
unmount_it /mnt

# Check if system is booted in UEFI or BIOS mode
check_boot_mode () {
    if [ -d /sys/firmware/efi ]; then
        echo "System booted in UEFI mode"
        BOOT_MODE="uefi"
    else
        echo "System booted in BIOS mode"
        BOOT_MODE="bios"
    fi
}

check_boot_mode

# Dynamic Menu Function
createmenu () {
    select selected_option; do
        if [ 1 -le "$REPLY" ] && [ "$REPLY" -le $(($#)) ]; then
            break;
        else
            echo "Please make a valid selection (1-$#)."
        fi
    done
}

declare -a drives=();
mapfile -t drives < <(lsblk --nodeps -o "NAME,SIZE,TRAN,TYPE,MODEL,SERIAL" | grep "disk");

echo "Available Drives (Please select one to be DISK1):";
createmenu "${drives[@]}"
drive=($(echo "${selected_option}"));
echo "Drive Id: ${drive[0]}";

l=-1;
by_id="";
while [ ${drive[$l]} != "disk" ]; do
    by_id="${drive[$l]}_$by_id";
    let "l--"
done
by_id=${by_id::-1};

if [ "${drive[2]}" == "sata" ]; then
    drive_by_id=($(echo "/dev/disk/by-id/ata-$by_id" | sed -e 's/\s\+/_/g'));
else
    drive_by_id=($(echo "/dev/disk/by-id/nvme-$by_id" | sed -e 's/\s\+/_/g'));
fi

DISK1=$drive_by_id

declare -a drives=();
mapfile -t drives < <(lsblk --nodeps -o "NAME,SIZE,TRAN,TYPE,MODEL,SERIAL" | grep "disk");

echo "Available Drives (Please select one to be DISK2):";
createmenu "${drives[@]}"
drive=($(echo "${selected_option}"));
echo "Drive Id: ${drive[0]}";

l=-1;
by_id="";
while [ ${drive[$l]} != "disk" ]; do
    by_id="${drive[$l]}_$by_id";
    let "l--"
done
by_id=${by_id::-1};

if [ "${drive[2]}" == "sata" ]; then
    drive_by_id=($(echo "/dev/disk/by-id/ata-$by_id" | sed -e 's/\s\+/_/g'));
else
    drive_by_id=($(echo "/dev/disk/by-id/nvme-$by_id" | sed -e 's/\s\+/_/g'));
fi

DISK2=$drive_by_id

echo "DISK1=$DISK1"
echo "DISK2=$DISK2"

ask_question_yn "Continue? Destructive <Y/n>"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

# Wipe and partition disks based on boot mode
sgdisk --zap-all $DISK1
sgdisk --zap-all $DISK2

wipefs -fa $DISK1
wipefs -fa $DISK2

dd if=/dev/zero of=$DISK1 bs=512 count=1
dd if=/dev/zero of=$DISK2 bs=512 count=1

if [ "$BOOT_MODE" == "uefi" ]; then
    # UEFI Partitioning
    sgdisk -n3:1M:+512M -t3:EF00 $DISK1
    sgdisk -n1:0:0 -t1:BF01 $DISK1

    sfdisk --dump $DISK1 | sfdisk $DISK2

    mkfs.vfat $DISK1-part3
    mkfs.vfat $DISK2-part3
else
    # BIOS Partitioning (requires BIOS boot partition)
    sgdisk -n2:1M:+2M -t2:EF02 $DISK1   # BIOS boot (NO FS)
	sgdisk -n3:0:+512M -t3:8300 $DISK1  # /boot ext4
    sgdisk -n1:0:0 -t1:BF01 $DISK1       # ZFS Partition
	
    sfdisk --dump $DISK1 | sfdisk $DISK2
	
	mkfs.ext4 $DISK1-part3
    mkfs.ext4 $DISK2-part3
fi

sleep 5

zpool create -f -O mountpoint=none -O atime=off -o ashift=12 -O acltype=posixacl -O xattr=sa -O compression=lz4 zroot mirror $DISK1-part1 $DISK2-part1

zfs create -o mountpoint=legacy zroot/root      # For /
zfs create -o mountpoint=legacy zroot/root/home # For /home
zfs create -o mountpoint=legacy zroot/root/nix  # For /nix

mount -t zfs zroot/root /mnt
mkdir /mnt/{nix,home,boot,boot-fallback}

mount -t zfs zroot/root/nix /mnt/nix
mount -t zfs zroot/root/home /mnt/home

if [ "$BOOT_MODE" == "uefi" ]; then
    mount $DISK1-part3 /mnt/boot
    mount $DISK2-part3 /mnt/boot-fallback
else
    # No need to mount boot partition for BIOS mode
	mount $DISK1-part3 /mnt/boot
    mount $DISK2-part3 /mnt/boot-fallback
fi

nixos-generate-config --root /mnt

ask_question_yn "Overwrite default NIXOS config? Destructive <Y/n>"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

cp -r -f ./*.nix /mnt/etc/nixos/
#udelej si co potrebujes uprav finish-me.sh a spusti ten
