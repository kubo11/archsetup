#!/bin/sh

KEYMAP="pl"
TIMEZONE="Europe/Warsaw"
DISK="$1"
EFI="${DISK}1"
SWAP="${DISK}2"
ROOT="${DISK}3"
HOSTNAME="kubopc"

if [ -z "$DISK" ] ; then
    echo "Usage: $0 /dev/DRIVE"
    exit 1
fi

echo "Setting up keymap..."
loadkeys "$KEYMAP"

echo "Setting up system clock..."
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true

echo "Setting up system drive..."
wipefs -a "$DISK"
sfdisk "$DISK" <<EOF
label: gpt

${DISK}p1 : size=1024M, type=U

${DISK}p2 : size=4096M, type=S

${DISK}p3 : type=L
EOF

partprobe "$DISK"
sleep 2

mkfs.fat -F32 "$EFI"
mkswap "$SWAP"
mkfs.ext4 "$ROOT"

echo "Mounting rootfs..."
mount "$ROOT" /mnt
mount --mkdir "$EFI" /mnt/boot
swapon "$SWAP"

echo "Installing essential software..."
pacstrap -K /mnt base linux linux-firmware grub efibootmgr

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Writiing install-chrooted.sh to /mnt/root..."
echo "#!/bin/sh

echo \"Setting time & locale...\"
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
hwclock --systohc
locale-gen
echo \"LANG=en_US.UTF-8\" >> /etc/locale.conf
echo \"KEYMAP=${KEYMAP}\" >> /etc/vconsole.conf

echo \"Setting hostname...\"
echo \"${HOSTNAME}\" >> /etc/hostname

echo \"Setting password...\"
passwd

echo \"Configuring boot loader...\"
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

exit" >/mnt/root/install-chrooted.sh
chmod 755 /mnt/root/install-chrooted.sh

echo "Chrooting into rootfs..."
arch-chroot /mnt /bin/sh /root/install-chrooted.sh

echo "Unmounting rootfs..."
umount -R /mnt
