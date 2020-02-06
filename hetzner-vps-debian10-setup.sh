#!/bin/bash
: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic, unattended script to install Debian 10 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power sysle
Next, connect via SSH to console, and run the script 
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info


set -o errexit
set -o pipefail
set -o nounset

function chroot_execute {
  chroot /mnt bash -c "$1"
}


export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en

read -p "Enter desired hostname [terem]: " v_hostname
v_hostname=${v_hostname:-terem}

read -p "Enter desired ZFS ARC max cache size in bytes [250000000]: " v_zfs_arc_max
v_zfs_arc_max=${v_zfs_arc_max:-250000000}

echo "======= installing zfs on rescue system =========="
echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

apt update
apt install --yes -t buster-backports zfs-dkms
modprobe zfs
zfs --version

echo "======= partitioning the disk =========="
DISK=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-0

sgdisk --zap-all $DISK
sgdisk -a1 -n1:24K:+1000K            -t1:EF02 $DISK # MBR area
sgdisk -n2:0:+512M                   -t2:BF01 $DISK # Boot pool
sgdisk -n3:0:0                       -t3:BF01 $DISK # Root pool

udevadm settle

echo "======= create zfs pools and datasets =========="
zpool create \
  -o ashift=12 -O canmount=off -O compression=lz4 -O devices=off -f \
  -O mountpoint=/boot -R /mnt bpool "${DISK}-part2"

zpool create -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/ -f -R /mnt rpool "${DISK}-part3"

zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu

zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/ubuntu
zfs mount bpool/BOOT/ubuntu

zfs create                                 rpool/home
zfs create -o mountpoint=/root             rpool/home/root
zfs create -o canmount=off                 rpool/var
zfs create -o canmount=off                 rpool/var/lib
zfs create                                 rpool/var/log
zfs create                                 rpool/var/spool

zfs create -o com.sun:auto-snapshot=false  rpool/var/cache
zfs create -o com.sun:auto-snapshot=false  rpool/var/tmp
chmod 1777 /mnt/var/tmp

zfs create                                 rpool/srv

zfs create -o canmount=off                 rpool/usr
zfs create                                 rpool/usr/local

zfs create                                 rpool/var/mail

zfs create -o com.sun:auto-snapshot=false  rpool/tmp
chmod 1777 /mnt/tmp

echo "======= unpacking initial system image =========="
tar -zxf /root/.oldroot/nfs/install/../images/Debian-102-buster-64-minimal.tar.gz -C /mnt/

zfs set devices=off rpool

echo "======= setting up the network =========="

echo $v_hostname > /mnt/etc/hostname

cat > /mnt/etc/hosts <<CONF
127.0.1.1 terem terem
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
CONF

ip6addr_prefix=$(ip -6 a s | grep -E "inet6.+global" | sed -nE 's/.+inet6\s(([0-9a-z]{1,4}:){4,4}).+/\1/p')

cat > "/mnt/etc/network/interfaces" <<CONF
auto lo
iface lo inet loopback
iface lo inet6 loopback

auto ens3
iface ens3 inet dhcp
    dns-nameservers 213.133.98.98 213.133.99.99 213.133.100.100

# control-alias ens3
iface ens3 inet6 static
    address ${ip6addr_prefix}:1/64
    gateway fe80::1
CONF

cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "======= preparing the jail for chroot =========="
for virtual_fs_dir in proc sys dev; do
  mount --rbind "/$virtual_fs_dir" "/mnt/$virtual_fs_dir"
done

echo "======= setting apt repos =========="
### official mirror
chroot_execute 'echo "deb [arch=i386,amd64] http://deb.debian.org/debian  buster  main non-free contrib" > /etc/apt/sources.list'
chroot_execute 'echo "deb-src [arch=i386,amd64] http://deb.debian.org/debian  buster  main non-free contrib" >> /etc/apt/sources.list'
chroot_execute 'echo "deb [arch=i386,amd64] http://deb.debian.org/debian  buster-updates  main non-free contrib" >> /etc/apt/sources.list'
chroot_execute 'echo "deb-src [arch=i386,amd64] http://deb.debian.org/debian  buster-updates  main non-free contrib" >> /etc/apt/sources.list'
chroot_execute 'echo "deb [arch=i386,amd64] http://deb.debian.org/debian  buster-backports  main non-free contrib" >> /etc/apt/sources.list'
chroot_execute 'echo "deb-src [arch=i386,amd64] http://deb.debian.org/debian  buster-backports  main non-free contrib" >> /etc/apt/sources.list'
chroot_execute 'echo "deb [arch=i386,amd64] http://security.debian.org  buster/updates  main contrib non-free" >> /etc/apt/sources.list'
chroot_execute 'echo "deb-src [arch=i386,amd64] http://security.debian.org  buster/updates  main contrib non-free" >> /etc/apt/sources.list'

chroot_execute 'cat > /etc/apt/preferences.d/90_zfs <<APT
Package: libnvpair1linux libuutil1linux libzfs2linux libzpool2linux zfs-dkms zfs-initramfs zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=buster-backports
Pin-Priority: 990
APT'

chroot_execute "apt update"

echo "======= setting locale, console and language =========="
chroot_execute 'cat <<CONF | debconf-set-selections
locales locales/default_environment_locale      select  en_US.UTF-8
keyboard-configuration  keyboard-configuration/store_defaults_in_debconf_db     boolean true
keyboard-configuration  keyboard-configuration/variant  select  German
keyboard-configuration  keyboard-configuration/unsupported_layout       boolean true
keyboard-configuration  keyboard-configuration/modelcode        string  pc105
keyboard-configuration  keyboard-configuration/unsupported_config_layout        boolean true
keyboard-configuration  keyboard-configuration/layout   select  German
keyboard-configuration  keyboard-configuration/layoutcode       string  de
keyboard-configuration  keyboard-configuration/optionscode      string
keyboard-configuration  keyboard-configuration/toggle   select  No toggling
keyboard-configuration  keyboard-configuration/xkb-keymap       select  de
keyboard-configuration  keyboard-configuration/switch   select  No temporary switch
keyboard-configuration  keyboard-configuration/unsupported_config_options       boolean true
keyboard-configuration  keyboard-configuration/ctrl_alt_bksp    boolean false
keyboard-configuration  keyboard-configuration/variantcode      string
keyboard-configuration  keyboard-configuration/model    select  Generic 105-key PC (intl.)
keyboard-configuration  keyboard-configuration/altgr    select  The default for the keyboard layout
keyboard-configuration  keyboard-configuration/compose  select  No compose key
keyboard-configuration  keyboard-configuration/unsupported_options      boolean true
console-setup   console-setup/fontsize-fb47     select  8x16
console-setup   console-setup/store_defaults_in_debconf_db      boolean true
console-setup   console-setup/codeset47 select  # Latin1 and Latin5 - western Europe and Turkic languages
console-setup   console-setup/fontface47        select  Fixed
console-setup   console-setup/fontsize  string  8x16
console-setup   console-setup/charmap47 select  UTF-8
console-setup   console-setup/fontsize-text47   select  8x16
console-setup   console-setup/codesetcode       string  Lat15
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Vienna
CONF'

chroot_execute "dpkg-reconfigure locales -f noninteractive"
chroot_execute "apt install -qq --yes keyboard-configuration console-setup"
chroot_execute "dpkg-reconfigure keyboard-configuration -f noninteractive"
chroot_execute "dpkg-reconfigure console-setup -f noninteractive"

chroot_execute "rm -f /etc/localtime /etc/timezone"
chroot_execute "dpkg-reconfigure -f noninteractive tzdata"

echo "======= installing zfs packages =========="
chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
chroot_execute "apt install --yes zfs-initramfs zfs-dkms"

echo "======= installing ssh server and aux packages =========="
chroot_execute "apt install --yes openssh-server net-tools wget curl nano"

echo "======= setting credentials for root using resque system SSH key =========="
mkdir -p /mnt/root/.ssh/
cp /root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys

echo "======= setting up zfs services =========="
chroot_execute "cat > /etc/systemd/system/zfs-import-bpool.service <<UNIT
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c '[ -f /etc/zfs/zpool.cache ] && mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache || true'
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
ExecStartPost=/bin/sh -c '[ -f /etc/zfs/preboot_zpool.cache ] && mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache || true'

[Install]
WantedBy=zfs-import.target
UNIT"

chroot_execute "systemctl enable zfs-import-bpool.service"

chroot_execute "cp /usr/share/systemd/tmp.mount /etc/systemd/system/"
chroot_execute "systemctl enable tmp.mount"

echo "======= setting mountpoints =========="
chroot_execute "zfs set mountpoint=legacy bpool"
chroot_execute "echo bpool /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0 > /etc/fstab"

chroot_execute "zfs set mountpoint=legacy rpool/var/log"
chroot_execute "echo rpool/var/log /var/log zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy rpool/var/spool"
chroot_execute "echo rpool/var/spool /var/spool zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy rpool/var/tmp"
chroot_execute "echo rpool/var/tmp /var/tmp zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy rpool/tmp"
chroot_execute "echo rpool/tmp /tmp zfs nodev,relatime 0 0 >> /etc/fstab"

echo "========setting up zfs module parameters========"
echo "options zfs zfs_arc_max=$v_zfs_arc_max" >> /etc/modprobe.d/zfs.conf

echo "======= update initramfs =========="
chroot_execute "update-initramfs -u -k all"

echo "======= update openssh server host keys =========="
chroot_execute "rm /etc/ssh/ssh_host_*"
chroot_execute "dpkg-reconfigure openssh-server"

echo "======= setting up grub =========="
chroot_execute "grub-install $DISK"

chroot_execute "sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=rpool/ROOT/ubuntu\"|g'  /etc/default/grub"

chroot_execute "sed -i 's/quiet//g' /etc/default/grub"
chroot_execute "sed -i 's/splash//g' /etc/default/grub"
chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'   >> /etc/default/grub"

chroot_execute "update-grub"

echo "======= setting up zed =========="
chroot_execute "mkdir /etc/zfs/zfs-list.cache"
chroot_execute "touch /etc/zfs/zfs-list.cache/rpool"
chroot_execute "ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

echo "======= unmounting virtual filesystems from jail =========="
for virtual_fs_dir in dev sys proc; do
 umount --recursive --force --lazy "/mnt/$virtual_fs_dir"
done

echo "======= unmounting zfs pools =========="
zpool export -a 

echo "======== setup complete, rebooting ==============="
reboot
