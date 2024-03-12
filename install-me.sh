#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash gptfdisk

#run as root pls

# Defining some helper variables (these will be used in later code
# blocks as well, so make sure to use the same terminal session or
# redefine them later)

# BASH error handling:
#   exit on command failure
set -e
#   keep track of the last executed command
trap 'LAST_COMMAND=$CURRENT_COMMAND; CURRENT_COMMAND=$BASH_COMMAND' DEBUG
#   on error: print the failed command
trap 'ERROR_CODE=$?; FAILED_COMMAND=$LAST_COMMAND; tput setaf 1; echo "ERROR: command \"$FAILED_COMMAND\" failed with exit code $ERROR_CODE"; put sgr0;' ERR INT TERM

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


# Dynamic Menu Function
createmenu () {
    select selected_option; do # in "$@" is the default
        if [ 1 -le "$REPLY" ] && [ "$REPLY" -le $(($#)) ]; then
            break;
        else
            echo "Please make a vaild selection (1-$#)."
        fi
    done
}

declare -a drives=();
# Load Menu by Line of Returned Command
mapfile -t drives < <(lsblk --nodeps -o "NAME,SIZE,TRAN,TYPE,MODEL,SERIAL" | grep "disk");
# Display Menu and Prompt for Input
echo "Available Drives (Please select one to be DISK1):";
createmenu "${drives[@]}"
# Split Selected Option into Array and Display
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

echo "Drive Id: ${drive[0]}";
echo $by_id;
echo "Size: ${drive[1]}";
echo "Model Serial: ${drive[4]} ${drive[5]} ${drive[6]}";
echo "Path: $drive_by_id";

DISK1=$drive_by_id

declare -a drives=();
# Load Menu by Line of Returned Command
mapfile -t drives < <(lsblk --nodeps -o "NAME,SIZE,TRAN,TYPE,MODEL,SERIAL" | grep "disk");
# Display Menu and Prompt for Input
echo "Available Drives (Please select one to be DISK2):";
createmenu "${drives[@]}"
# Split Selected Option into Array and Display
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

echo "Drive Id: ${drive[0]}";
echo $by_id;
echo "Size: ${drive[1]}";
echo "Model Serial: ${drive[4]} ${drive[5]} ${drive[6]}";
echo "Path: $drive_by_id";

DISK2=$drive_by_id

echo "DISK1=$DISK1"
echo "DISK2=$DISK2"


ask_question_yn "Continue? Destructive <Y/n>"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

sgdisk --zap-all $DISK1
sgdisk --zap-all $DISK2

wipefs -fa $DISK1
wipefs -fa $DISK2

dd if=/dev/zero of=$DISK1  bs=512  count=1
dd if=/dev/zero of=$DISK2  bs=512  count=1

# Creating partitions
# This creates the ESP / Boot partition at the beginning of the drive
# but numbered as the third partition:
sgdisk -n3:1M:+512M -t3:EF00 $DISK1

# This create the storage partition numbered as the
# first partition:
sgdisk -n1:0:0 -t1:BF01 $DISK1

# Clone the partitions to the second drive:
sfdisk --dump $DISK1 | sfdisk $DISK2

sleep 5

zpool create -f -O mountpoint=none -O atime=off -o ashift=12 -O acltype=posixacl -O xattr=sa -O compression=lz4 zroot mirror $DISK1-part1 $DISK2-part1

zfs create -o mountpoint=legacy zroot/root      # For /
zfs create -o mountpoint=legacy zroot/root/home # For /home
zfs create -o mountpoint=legacy zroot/root/nix  # For /nix

mkfs.vfat $DISK1-part3
mkfs.vfat $DISK2-part3

mount -t zfs zroot/root /mnt

# Create directories to mount file systems on
mkdir /mnt/{nix,home,boot,boot-fallback}

# Mount the rest of the ZFS file systems
mount -t zfs zroot/root/nix /mnt/nix
mount -t zfs zroot/root/home /mnt/home

# Mount both of the ESP's
mount $DISK1-part3 /mnt/boot
mount $DISK2-part3 /mnt/boot-fallback

nixos-generate-config --root /mnt

ask_question_yn "Overwrite default NIXOS config? Destructive <Y/n>"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

cp -r -f ./*.nix /mnt/etc/nixos/
#udelej si co potrebujes uprav finish-me.sh a spusti ten
