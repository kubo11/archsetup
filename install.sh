#!/bin/bash

set -euo pipefail
set +x

KEYMAP="pl"
TIMEZONE="Europe/Warsaw"
LANG="en_US.UTF-8"
LANGUAGE="en_US:en:C"
TIME="en_DK.UTF-8"
DISK="$1"
PLAYBOOK="$2"
EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"
HOSTNAME="kubopc"
POSTINSTALL_WORK_DIR=/tmp/postinstall
USERNAME="kubo"

if [ -z "$DISK" ] || [ -z "$PLAYBOOK" ] ; then
    echo "Usage: $0 /dev/DRIVE PLAYBOOK"
    exit 1
fi

url="https://github.com/kubo11/archsetup/blob/main/ansible/${PLAYBOOK}.yml"
if ! curl -L --fail --silent --output /dev/null "$url"; then
    echo "Invalid playbook name: $PLAYBOOK"
    exit 1
fi

echo -n "root password: " 
read -s ROOT_PASS
echo ""

echo "Setting up keymap..."
loadkeys "$KEYMAP"

echo "Setting up system clock..."
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true

echo "Setting up system drive..."
sfdisk -w always -W always "$DISK" <<EOF
label: gpt

$EFI_PART : size=1024M, type=U
$SWAP_PART: size=8192M, type=S
$ROOT_PART : type=L
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
pacstrap -K /mnt base linux linux-firmware grub efibootmgr btrfs-progs git python3 networkmanager sudo

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

echo \"Configuring boot loader...\"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg    

exit" >/mnt/root/install-chrooted.sh
chmod 755 /mnt/root/install-chrooted.sh
unset ROOT_PASS

echo "Chrooting into rootfs..."
arch-chroot /mnt /bin/bash /root/install-chrooted.sh

echo "Removing install-chrooted.sh..."
rm -rf /mnt/root/install-chrooted.sh

echo "Writing postinstall.sh to /mnt/root..."
echo "#!/bin/bash

set -euo pipefail
set +x

if [[ \"\$(id -u)\" -eq 0 ]]; then
    echo \"Running root setup...\"

    echo \"Adding user $USERNAME...\"
    useradd -m -G wheel -s /bin/bash \"$USERNAME\" 2>/dev/null || true

    echo \"Setting user $USERNAME password...\"
    echo -n \"$USERNAME password: \" 
    read -s USER_PASS
    echo \"\"
    printf '$USERNAME:%s\n' \"\$USER_PASS\" | chpasswd

    echo \"Adding wheel group to sudoers (passwordless)...\"
    printf '%s\n' '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel

    echo \"Saving $USERNAME become pass to temp file...\"
    tmp_vars=\"\$(mktemp)\"
    chmod 600 \"\$tmp_vars\"

    printf 'ansible_become_password: \"%s\"\n' \"\$USER_PASS\" > \"\$tmp_vars\"

    chown \"$USERNAME:$USERNAME\" \"\$tmp_vars\"
    export ANSIBLE_EXTRA_VARS_FILE=\"\$tmp_vars\"

    echo \"Moving postinstall.sh to /home/$USERNAME...\"
    mv /root/postinstall.sh /home/$USERNAME/

    echo \"Switching to user $USERNAME...\"
    exec sudo --preserve-env=ANSIBLE_EXTRA_VARS_FILE -u \"$USERNAME\" -H /home/$USERNAME/postinstall.sh \"\$@\"
fi

echo \"Running \$(whoami) setup...\"

if [[ -z \"\${ANSIBLE_EXTRA_VARS_FILE:-}\" ]]; then
    echo \"ANSIBLE_EXTRA_VARS_FILE is missing\"
    exit 1
fi

trap 'rm -f \"\$ANSIBLE_EXTRA_VARS_FILE\"' EXIT

echo \"Creating work dir...\"
mkdir -p $POSTINSTALL_WORK_DIR
cd $POSTINSTALL_WORK_DIR

echo \"Creating virtual environment...\"
python3 -m venv venv
source venv/bin/activate

echo \"Installing ansible...\"
pip3 install ansible

echo \"Cloning archsetup repository...\"
git clone https://github.com/kubo11/archsetup.git

cd archsetup/ansible

echo \"Running ansible...\"
ansible-playbook $PLAYBOOK.yml --extra-vars \"@\$ANSIBLE_EXTRA_VARS_FILE\"

echo \"Exiting virtual environment...\"
deactivate

echo \"Changing sudo to passworded...\"
sudo printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
sudo chmod 440 /etc/sudoers.d/10-wheel
sudo visudo -cf /etc/sudoers.d/10-wheel

echo \"Removing postinstall.sh from /home/$USERNAME...\"
rm -rf /home/$USERNAME/postinstall.sh" >/mnt/root/postinstall.sh
chmod 755 /mnt/root/postinstall.sh

echo "Unmounting rootfs..."
umount -R /mnt
