#!/bin/sh

KEYMAP="pl"
TIMEZONE="Europe/Warsaw"
LANG="en_US.UTF-8"
DISK="$1"
ROOT_PASS="$2"
EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"
HOSTNAME="kubopc"

if [ -z "$DISK" || -z "$ROOT_PASS" ] ; then
    echo "Usage: $0 /dev/DRIVE ROOT_PASS"
    exit 1
fi

echo "Setting up keymap..."
loadkeys "$KEYMAP"

echo "Setting up system clock..."
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true

echo "Setting up system drive..."
# wipefs -af "$DISK"

sfdisk -w always -W always "$DISK" <<EOF
label: gpt

$EFI_PART : size=1024M, type=U
$SWAP_PART: size=8192M, type=S
$LVM_PART : type=L
EOF

partprobe "$DISK"
sleep 2

mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
mkfs.btrfs "$ROOT_PART"

echo "Creating btrfs subvolumes..."
mount "$ROOT_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@.snapshots

umount /mnt

echo "Mounting rootfs..."
mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt

mkdir -p /mnt/{var/log,var/cache/pacman/pkg,boot/efi}

mount --mkdir -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
mount --mkdir -o noatime,compress=zstd,subvol=@.snapshots "$ROOT_PART" /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log "$ROOT_PART" /mnt/var/log
mount -o noatime,compress=zstd,subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg

mount "$EFI_PART" /mnt/boot/efi
swapon "$SWAP_PART"

echo "Installing essential software..."
pacstrap -K /mnt base linux linux-firmware grub efibootmgr btrfs-progs git python3 curl networkmanager

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Writiing install-chrooted.sh to /mnt/root..."
echo "#!/bin/sh

echo \"Setting time & locale...\"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen
echo \"LANG=${LANG}\" >> /etc/locale.conf
echo \"KEYMAP=${KEYMAP}\" >> /etc/vconsole.conf

echo \"Setting hostname...\"
echo \"${HOSTNAME}\" >> /etc/hostname

echo \"Enabling networkmanager...\"
systemctl enable NetworkManager.service

echo \"Setting root password...\"
echo \"${ROOT_PASS}\" | passwd root --stdin

echo \"Configuring boot loader...\"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

exit" >/mnt/root/install-chrooted.sh
chmod 755 /mnt/root/install-chrooted.sh

echo "Chrooting into rootfs..."
arch-chroot /mnt /bin/sh /root/install-chrooted.sh

echo "Removing install-chrooted.sh..."
rm -rf /mnt/root/install-chrooted.sh

echo "Unmounting rootfs..."
umount -R /mnt
