#!/bin/bash

set -euo pipefail
set +x

KEYMAP="pl"
TIMEZONE="Europe/Warsaw"
LANG="en_US.UTF-8"
LANGUAGE="en_US:en:C"
TIME="en_DK.UTF-8"
DISK="$1"
BOOT_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOSTNAME="kubopc"
POSTINSTALL_WORK_DIR=/tmp/postinstall
USERNAME="kubo"

if [ -z "$DISK" ] ; then
    echo "Usage: $0 /dev/DRIVE"
    exit 1
fi

echo -n "root password: " 
read -s ROOT_PASS
echo ""

echo -n "$USERNAME password: " 
read -s USER_PASS
echo ""

echo "Setting up keymap..."
loadkeys "$KEYMAP"

echo "Setting up system clock..."
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true

echo "Setting up system drive..."
sfdisk -w always -W always "$DISK" <<EOF
label: gpt

$BOOT_PART : size=1024M, type=U
$SWAP_PART: size=8192M, type=S
$ROOT_PART : type=L
EOF

partprobe "$DISK"
sleep 2

mkfs.fat -F32 "$BOOT_PART"
mkswap "$SWAP_PART"
mkfs.btrfs "$ROOT_PART"

echo "Creating btrfs subvolumes..."
mount "$ROOT_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache

umount /mnt

echo "Mounting rootfs..."
mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt

mount --mkdir -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
mount --mkdir -o noatime,compress=zstd,subvol=@var_log "$ROOT_PART" /mnt/var/log
mount --mkdir -o noatime,compress=zstd,subvol=@var_cache "$ROOT_PART" /mnt/var/cache

mount --mkdir "$BOOT_PART" /mnt/boot
swapon "$SWAP_PART"

echo "Installing essential software..."
pacstrap -K /mnt base linux linux-firmware linux-headers efibootmgr btrfs-progs git python3 networkmanager sudo sof-firmware

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Writing install-chrooted.sh to /mnt/root..."
echo "#!/bin/bash

set -euo pipefail
set +x

echo \"Setting time & locale...\"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i '/${LANG} UTF-8/s/^#//g' /etc/locale.gen
sed -i '/${TIME} UTF-8/s/^#//g' /etc/locale.gen
locale-gen
echo \"LANG=${LANG}\" >> /etc/locale.conf
echo \"LANGUAGE=${LANGUAGE}\" >> /etc/locale.conf
echo \"LC_TIME=${TIME}\" >> /etc/locale.conf
echo \"KEYMAP=${KEYMAP}\" >> /etc/vconsole.conf

echo \"Setting hostname...\"
echo \"${HOSTNAME}\" >> /etc/hostname

echo \"Enabling networkmanager...\"
systemctl enable NetworkManager.service

echo \"Setting root password...\"
printf 'root:%s\n' \"$ROOT_PASS\" | chpasswd

echo \"Adding user $USERNAME...\"
useradd -m -G audio,wheel -s /bin/bash \"$USERNAME\" 2>/dev/null || true
echo \"Setting user $USERNAME password...\"
printf '$USERNAME:%s\n' \"\$USER_PASS\" | chpasswd

echo \"Adding wheel group to sudoers...\"
printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel

echo \"Configuring boot loader...\"
bootctl install
mkdir -p /boot/loader/entries

echo \"default arch.conf
timeout 0
console-mode max
editor no\" >/boot/loader/loader.conf

echo \"title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$(lsblk -no UUID $ROOT_PART) rootflags=subvol=@ rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 lsm=landlock,lockdown,yama,integrity,apparmor,bpf\" >/boot/loader/entries/arch.conf

exit" >/mnt/root/install-chrooted.sh
chmod 755 /mnt/root/install-chrooted.sh
unset ROOT_PASS

echo "Chrooting into rootfs..."
arch-chroot /mnt /bin/bash /root/install-chrooted.sh

echo "Removing install-chrooted.sh..."
rm -f /mnt/root/install-chrooted.sh

echo "Writing postinstall.sh to /mnt/home/$USERNAME..."
echo "#!/bin/bash

set -euo pipefail
set +x

PLAYBOOK=\"\$1\"

if [ -z \"\$PLAYBOOK\" ] ; then
    echo \"Usage: \$0 DRIVE\"
    exit 1
fi

echo \"Running \$(whoami) setup...\"

echo -n \"ssh passphrase: \" 
read -s USER_SSH_PASSPHRASE
echo \"\"

echo \"Preparing ansible temp vars...\"
tmp_vars=\"\$(mktemp)\"
chmod 600 \"\$tmp_vars\"

printf 'ssh_passphrase: \"%s\"\n' \"\$USER_SSH_PASSPHRASE\" >> \"\$tmp_vars\"

echo \"Creating work dir...\"
mkdir -p $POSTINSTALL_WORK_DIR
cd $POSTINSTALL_WORK_DIR

echo \"Creating virtual environment...\"
python3 -m venv venv
source venv/bin/activate

echo \"Installing python modules...\"
pip3 install ansible build setuptools wheel installer poetry-core

echo \"Cloning archsetup repository...\"
git clone https://github.com/kubo11/archsetup.git

cd archsetup/ansible

echo \"Running ansible...\"
ansible-playbook $PLAYBOOK.yml -K --extra-vars \"@\$temp_vars\"

echo \"Exiting virtual environment...\"
deactivate

echo \"Cleaning up...\"
unset temp_vars
unset USER_SSH_PASSPHRASE
rm -f \"\$tmp_vars\"
rm -rf /\$HOME/postinstall.sh" >/mnt/home/$USERNAME/postinstall.sh
chmod 755 /mnt/home/$USERNAME/postinstall.sh

echo "Unmounting rootfs..."
umount -R /mnt

