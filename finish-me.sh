#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash gptfdisk

#run as root pls a edituj tenhle script

#helpful stuff
#lsblk -o "NAME,MODEL,SERIAL,SIZE,STATE,UUID,FSTYPE,MODE,TYPE,VENDOR"
#https://github.com/JayRovacsek/nix-config/tree/main/modules/nvidia
#nixos-rebuild switch
#nixos-generate-config --root /mnt
#zpool import zroot

#  fileSystems."/mnt/docker" =
#    { device = "zdata/docker";
#      fsType = "zfs";
#    };

#  fileSystems."/mnt/docker_apps" =
#    { device = "zdata/docker_apps";
#      fsType = "zfs";
#    };

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

#edit me

dd if=/dev/zero bs=512  count=1 of=$DISK1
dd if=/dev/zero bs=512  count=1 of=$DISK2
wipefs -fa $DISK1
wipefs -fa $DISK2
sgdisk --zap-all $DISK1
sgdisk --zap-all $DISK2

ask_question_yn "Create ZFS Data pool? Destructive! UPRAV SI SCRIPT! A dej klic kde ma byt! Na dve mista actuall! Aj v Installcce aj v mnt chrootu"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

#edit me

zpool create -O mountpoint=none -O atime=off -o ashift=12 -O acltype=posixacl -O xattr=sa -O compression=lz4   -o feature@encryption=enabled -O encryption=on -O keylocation=file:///root/.zfs-encrypt.key -O keyformat=raw zdata mirror $DISK1 $DISK2
zfs create -o mountpoint=legacy zdata/docker
zfs create -o mountpoint=legacy zdata/docker_apps

mkdir /mnt/mnt
mkdir /mnt/mnt/{docker,docker_apps}

mount -t zfs zdata/docker /mnt/mnt/docker
mount -t zfs zdata/docker_apps /mnt/mnt/docker_apps

nixos-generate-config --root /mnt

ask_question_yn "Install nixos FR?"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

#nebo jenom sjet tohle
nixos-install
