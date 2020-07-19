#!/usr/bin/env bash
# this script setup arch like this:
# +-----------------------------------------------------------------------+ +----------------+
# | Logical volume 1      | Logical volume 2      | Logical volume 3      | | Boot partition |
# |                       |                       |                       | |                |
# | [SWAP]                | /                     | /home                 | | /boot          |
# |                       |                       |                       | |                |
# | /dev/MyVolGroup/swap  | /dev/MyVolGroup/root  | /dev/MyVolGroup/home  | |                |
# |_ _ _ _ _ _ _ _ _ _ _ _|_ _ _ _ _ _ _ _ _ _ _ _|_ _ _ _ _ _ _ _ _ _ _ _| | (may be on     |
# |                                                                       | | other device)  |
# |                         LUKS2 encrypted partition                     | |                |
# |                           /dev/disk_part2                             | |/dev/disk_part1 |
# +-----------------------------------------------------------------------+ +----------------+
set -euo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

MIRRORLIST_URL="https://www.archlinux.org/mirrorlist/?country=GB&protocol=https&use_mirror_status=on"

pacman -Sy --noconfirm pacman-contrib

echo "Updating mirror list"
curl -s "$MIRRORLIST_URL" | \
    sed -e 's/^#Server/Server/' -e '/^#/d' | \
    rankmirrors -n 5 - > /etc/pacman.d/mirrorlist

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )
unset password2
# LUKS password
luks_password=$(dialog --stdout --passwordbox "Enter encryption password" 0 0) || exit 1
clear
: ${luks_password:?"password cannot be empty"}
luks_password2=$(dialog --stdout --passwordbox "Enter encryption password again" 0 0) || exit 1
clear
[[ "$luks_password" == "$luks_password2" ]] || ( echo "Passwords did not match"; exit 1; )
unset luks_password2

### Select device to install
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")


timedatectl set-ntp true

### Setup the disk and partitions ###
swap_size=$(free --giga | awk '/Mem:/ {print $2"G"}')

parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 512MiB \
  set 1 boot on \
  mkpart primary ext4 512MiB 100%

# waiting for partition creation
sleep 3

part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_lvm="$(ls ${device}* | grep -E "^${device}p?2$")"
root_size="50G"
home_size="48%FREE"

loadkeys fr

# LUKS
printf '%s' "$luks_password" | cryptsetup -v luksFormat "$part_lvm" -d -
printf '%s' "$luks_password" | cryptsetup open "$part_lvm" cryptlvm -d -

unset luks_password

# LVM
pvcreate /dev/mapper/cryptlvm
vgcreate MyVolGroup /dev/mapper/cryptlvm
lvcreate -L "$swap_size" MyVolGroup -n swap
lvcreate -L "$root_size" MyVolGroup -n root
lvcreate -l "$home_size" MyVolGroup -n home

# format lvm volumes
mkfs.ext4 /dev/MyVolGroup/root
mkfs.ext4 /dev/MyVolGroup/home
mkswap /dev/MyVolGroup/swap

mount /dev/MyVolGroup/root /mnt
mkdir /mnt/home
mount /dev/MyVolGroup/home /mnt/home
swapon /dev/MyVolGroup/swap

# preparing boot partition
mkfs.fat -F32 "$part_boot"
mkdir /mnt/boot
mount "$part_boot" /mnt/boot

# install packages
pacstrap /mnt base base-devel linux-firmware\
    linux linux-headers \
    linux-lts linux-lts-headers \
    lvm2 \
    networkmanager \
    netctl \
    wireless_tools wpa_supplicant \
    vim \
    zsh

genfstab -U /mnt >> /mnt/etc/fstab
echo "$hostname" > /mnt/etc/hostname

# timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
arch-chroot /mnt timedatectl set-ntp true
arch-chroot /mnt hwclock --systohc

# set locales
echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen

cat >>/mnt/etc/locale.conf <<EOF
LANG=en_US.UTF-8
EOF

cat >>/mnt/etc/vconsole.conf <<EOF
KEYMAP=fr
EOF


lvm_uuid=$(blkid -s UUID -o value "$part_lvm") # show block id

hooks="HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems resume fsck)"
# add encrypt modules
sed -i "s/^HOOKS=.*/$hooks/" /mnt/etc/mkinitcpio.conf

# set root partition in boot loader /boot/loader/loader.conf
arch-chroot /mnt bootctl install
cat <<EOF >/mnt/boot/loader/loader.conf
timeout 3
default arch
arch-lts
EOF

mkdir -p /mnt/boot/loader/entries/

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title Archlinux ENCRYPTED
linux /vmlinuz-linux
initrd /initramfs-linux.img
options rw cryptdevice=UUID=$lvm_uuid:cryptlvm root=/dev/MyVolGroup/root resume=/dev/MyVolGroup/swap
EOF

cat <<EOF > /mnt/boot/loader/entries/arch-lts.conf
title Archlinux ENCRYPTED
linux /vmlinuz-linux-lts
initrd /initramfs-linux-lts.img
options rw cryptdevice=UUID=$lvm_uuid:cryptlvm root=/dev/MyVolGroup/root resume=/dev/MyVolGroup/swap
EOF

arch-chroot /mnt mkinitcpio -P

arch-chroot /mnt useradd -mU -s /usr/bin/zsh -G wheel,uucp,video,audio,storage,games,input "$user"
arch-chroot /mnt chsh -s /usr/bin/zsh
# enable network manager
arch-chroot /mnt systemctl enable NetworkManager

echo "root:$password" | chpasswd --root /mnt
echo "$user:$password" | chpasswd --root /mnt
unset password
