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

ask_question_yn "Wipe data drives FR? Destructive! UPRAV SI SCRIPT!"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

#edit me

dd if=/dev/zero bs=512  count=1 of=/dev/nvme1n1
dd if=/dev/zero bs=512  count=1 of=/dev/nvme0n1
wipefs -fa /dev/nvme1n1
wipefs -fa /dev/nvme0n1
sgdisk --zap-all /dev/nvme1n1
sgdisk --zap-all /dev/nvme0n1

ask_question_yn "Create ZFS Data pool? Destructive! UPRAV SI SCRIPT! A dej klic kde ma byt! Na dve mista actuall! Aj v Installcce aj v mnt chrootu"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

#edit me

zpool create -O mountpoint=none -O atime=off -o ashift=12 -O acltype=posixacl -O xattr=sa -O compression=lz4   -o feature@encryption=enabled -O encryption=on -O keylocation=file:///root/.zfs-encrypt.key -O keyformat=raw zdata mirror /dev/nvme1n1 /dev/nvme0n1
zfs create -o mountpoint=legacy zdata/docker
zfs create -o mountpoint=legacy zdata/docker_apps

mkdir /mnt/mnt
mkdir /mnt/mnt/{docker,docker_apps}

nixos-generate-config --root /mnt

ask_question_yn "Install nixos FR?"
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit 1
fi

#nebo jenom sjet tohle
nixos-install