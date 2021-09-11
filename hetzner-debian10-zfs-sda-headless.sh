#!/bin/bash


set -o errexit
set -o pipefail
set -o nounset

# Variables
v_bpool_name="bpool"
v_bpool_tweaks="-o ashift=12 -O compression=lz4"
v_rpool_name="rpool"
v_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
v_hostname="debian"
v_kernel_variant=
v_zfs_arc_max_mb=512
v_root_password="changeme"
v_encrypt_rpool="1"             # 0=false, 1=true
v_passphrase="changeme"
v_tz_area="Europe"
v_tz_city="Berlin"
v_selected_disk="/dev/sda"
v_swap_size=0

# Constants
c_deb_packages_repo=http://mirror.hetzner.de/debian/packages
c_deb_security_repo=http://mirror.hetzner.de/debian/security

c_default_zfs_arc_max_mb=250
c_default_bpool_tweaks="-o ashift=12 -O compression=lz4"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_default_hostname="debian"
c_zfs_mount_dir=/mnt
c_log_dir=$(dirname "$(mktemp)")/zfs-hetzner-vm
c_install_log=$c_log_dir/install.log
c_lsb_release_log=$c_log_dir/lsb_release.log
c_disks_log=$c_log_dir/disks.log

function activate_debug {
  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}


function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}


function store_os_distro_information {
  lsb_release --all > "$c_lsb_release_log"
}

function check_prerequisites {
  if [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  fi
  if [[ ! -r /root/.ssh/authorized_keys ]]; then
    echo "SSH pubkey file is absent, please add it to the rescue system setting, then reboot into rescue system and run the script"
    exit 1
  fi
}

function initial_load_debian_zed_cache {
  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/rpool"
  chroot_execute "ln -sf /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

  chroot_execute "zed -F &"

  local success=0

  if [[ ! -e $c_zfs_mount_dir/etc/zfs/zfs-list.cache/rpool ]] || [[ -e $c_zfs_mount_dir/etc/zfs/zfs-list.cache/rpool && (( $(ls -l /$c_zfs_mount_dir/etc/zfs/zfs-list.cache/rpool 2> /dev/null | cut -d ' ' -f 5) == 0 )) ]]; then
    chroot_execute "zfs set canmount=noauto rpool"

    SECONDS=0

    while (( SECONDS++ <= 120 )); do
      if [[ -e $c_zfs_mount_dir/etc/zfs/zfs-list.cache/rpool ]] && (( "$(ls -l $c_zfs_mount_dir/etc/zfs/zfs-list.cache/rpool | cut -d ' ' -f 5)" > 0 )); then
        success=1
        break
      else
        sleep 1
      fi
    done
  else
    success=1
  fi

  if (( success != 1 )); then
    echo "Fatal zed daemon error: the ZFS cache hasn't been updated by ZED!"
    exit 1
  fi

  chroot_execute "pkill zed"

  sed -Ei 's|/$c_zfs_mount_dir/?|/|g' $c_zfs_mount_dir/etc/zfs/zfs-list.cache/rpool
}


function determine_kernel_variant {
  if dmidecode | grep -q vServer; then
    v_kernel_variant="-cloud"
  fi
}

function chroot_execute {
  chroot $c_zfs_mount_dir bash -c "$1"
}

function unmount_and_export_fs {

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
    fi
  done

  SECONDS=0
  zpools_exported=99
  echo "===========exporting zfs pools============="
  set +e
  while (( zpools_exported == 99 )) && (( SECONDS++ <= 60 )); do
    zpool export -a 2> /dev/null
    if [[ $? == 0 ]]; then
      zpools_exported=1
      echo "all zfs pools were succesfully exported"
      break;
    else
      sleep 1
     fi
  done
  set -e
  if (( zpools_exported != 1 )); then
    echo "failed to export zfs pools"
    exit 1
  fi
}

function get_install_disk {

  local mounted_devices
  local device_info

  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"
  device_info="$(udevadm info --query=property "${v_selected_disk}")"
  
    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^${v_selected_disk}\$" <<< "$mounted_devices"; then
        v_installdisk=$(find  /dev/disk/by-id/ -exec sh -c  "readlink -nf {}  | grep -q ^${v_selected_disk}$ && echo {}" \;)
      fi
    fi
}


#################### MAIN ################################
export LC_ALL=en_US.UTF-8

check_prerequisites

activate_debug

determine_kernel_variant

get_install_disk

clear

echo "===========remove unused kernels in rescue system========="
for kver in $(find /lib/modules/* -maxdepth 0 -type d | grep -v "$(uname -r)" | cut -s -d "/" -f 4); do
  apt purge --yes "linux-headers-$kver"
  apt purge --yes "linux-image-$kver"
done

echo "======= installing zfs on rescue system =========="
  echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

  wget -O - https://terem42.github.io/zfs-debian/apt_pub.gpg | apt-key add -
  echo 'deb https://terem42.github.io/zfs-debian/public zfs-debian-experimental main' > /etc/apt/sources.list.d/zfs-experimental.list
  apt update
  apt install -t zfs-debian-experimental --yes zfs-dkms zfsutils-linux 
  apt install --yes -t buster-backports libelf-dev zfs-dkms
  modprobe zfs

echo "======= partitioning the disk =========="
  wipefs --all "$v_installdisk"
  sgdisk -a1 -n1:24K:+1000K            -t1:EF02 "$v_installdisk"
  sgdisk -n2:0:+512M                   -t2:BF01 "$v_installdisk" # Boot pool
  sgdisk -n3:0:0                       -t3:BF01 "$v_installdisk" # Root pool

udevadm settle

echo "======= create zfs pools and datasets =========="

  encryption_options=()
  
  if [[ $v_encrypt_rpool == "1" ]]; then
    encryption_options=(-O "encryption=aes-256-gcm" -O "keylocation=prompt" -O "keyformat=passphrase")
  fi

  rpool_disks_partition=("${v_installdisk}-part3")
  bpool_disks_partition=("${v_installdisk}-part2")
  

zpool create \
  $v_bpool_tweaks -O canmount=off -O devices=off \
  -O mountpoint=/boot -R $c_zfs_mount_dir -f \
  $v_bpool_name  "${bpool_disks_partition}"

echo -n "$v_passphrase" | zpool create \
  $v_rpool_tweaks \
  "${encryption_options[@]}" \
  -O mountpoint=/ -R $c_zfs_mount_dir -f \
  $v_rpool_name "${rpool_disks_partition}"

zfs create -o canmount=off -o mountpoint=none "$v_rpool_name/ROOT"
zfs create -o canmount=off -o mountpoint=none "$v_bpool_name/BOOT"

zfs create -o canmount=noauto -o mountpoint=/ "$v_rpool_name/ROOT/debian"
zfs mount "$v_rpool_name/ROOT/debian"

zfs create -o canmount=noauto -o mountpoint=/boot "$v_bpool_name/BOOT/debian"
zfs mount "$v_bpool_name/BOOT/debian"

zfs create                                 "$v_rpool_name/home"
zfs create -o mountpoint=/root             "$v_rpool_name/home/root"
zfs create -o canmount=off                 "$v_rpool_name/var"
zfs create -o canmount=off                 "$v_rpool_name/var/lib"
zfs create                                 "$v_rpool_name/var/log"
zfs create                                 "$v_rpool_name/var/spool"

zfs create -o com.sun:auto-snapshot=false  "$v_rpool_name/var/cache"
zfs create -o com.sun:auto-snapshot=false  "$v_rpool_name/var/tmp"
chmod 1777 "$c_zfs_mount_dir/var/tmp"

zfs create                                 "$v_rpool_name/srv"

zfs create -o canmount=off                 "$v_rpool_name/usr"
zfs create                                 "$v_rpool_name/usr/local"

zfs create                                 "$v_rpool_name/var/mail"

zfs create -o com.sun:auto-snapshot=false -o canmount=on -o mountpoint=/tmp "$v_rpool_name/tmp"
chmod 1777 "$c_zfs_mount_dir/tmp"

if [[ $v_swap_size -gt 0 ]]; then
  zfs create \
    -V "${v_swap_size}G" -b "$(getconf PAGESIZE)" \
    -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
    "$v_rpool_name/swap"

  udevadm settle
 
  mkswap -f "/dev/zvol/$v_rpool_name/swap"
fi

echo "======= setting up initial system packages =========="
debootstrap --arch=amd64 buster "$c_zfs_mount_dir" "$c_deb_packages_repo" 

zfs set devices=off "$v_rpool_name"

echo "======= setting up the network =========="

echo "$v_hostname" > $c_zfs_mount_dir/etc/hostname

cat > "$c_zfs_mount_dir/etc/hosts" <<CONF
127.0.1.1 ${v_hostname}
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

cat <<CONF > /mnt/etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
DHCP=ipv4
Address=${ip6addr_prefix}:1/64
Gateway=fe80::1
CONF
chroot_execute "systemctl enable systemd-networkd.service"


cp /etc/resolv.conf $c_zfs_mount_dir/etc/resolv.conf

echo "======= preparing the jail for chroot =========="
for virtual_fs_dir in proc sys dev; do
  mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
done

echo "======= setting apt repos =========="
cat > "$c_zfs_mount_dir/etc/apt/sources.list" <<CONF
deb [arch=i386,amd64] $c_deb_packages_repo buster main contrib non-free
deb [arch=i386,amd64] $c_deb_packages_repo buster-updates main contrib non-free
deb [arch=i386,amd64] $c_deb_packages_repo buster-backports main contrib non-free
deb [arch=i386,amd64] $c_deb_security_repo buster/updates main contrib non-free
CONF

chroot_execute "apt update"

echo "======= setting locale, console and language =========="
chroot_execute "apt install --yes -qq locales debconf-i18n apt-utils"
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"

chroot_execute 'cat <<CONF | debconf-set-selections
locales locales/default_environment_locale      select  en_US.UTF-8
keyboard-configuration  keyboard-configuration/store_defaults_in_debconf_db     boolean true
keyboard-configuration  keyboard-configuration/variant  select  English (US)
keyboard-configuration  keyboard-configuration/unsupported_layout       boolean true
keyboard-configuration  keyboard-configuration/modelcode        string  pc105
keyboard-configuration  keyboard-configuration/unsupported_config_layout        boolean true
keyboard-configuration  keyboard-configuration/layout   select  English (US)
keyboard-configuration  keyboard-configuration/layoutcode       string  us
keyboard-configuration  keyboard-configuration/optionscode      string
keyboard-configuration  keyboard-configuration/toggle   select  No toggling
keyboard-configuration  keyboard-configuration/xkb-keymap       select  us
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
console-setup   console-setup/fontface47        select  Fixed
console-setup   console-setup/fontsize  string  8x16
console-setup   console-setup/charmap47 select  UTF-8
console-setup   console-setup/fontsize-text47   select  8x16
console-setup   console-setup/codesetcode       string  Uni2
tzdata tzdata/Areas select "$v_tz_area"
tzdata tzdata/Zones/Europe select "$v_tz_city"
CONF'

chroot_execute "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales -f noninteractive"
echo -e "LC_ALL=en_US.UTF-8\nLANG=en_US.UTF-8\n" >> "$c_zfs_mount_dir/etc/environment"
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install -qq --yes keyboard-configuration console-setup"
chroot_execute "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure keyboard-configuration -f noninteractive"
chroot_execute "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure console-setup -f noninteractive"
chroot_execute "setupcon"

chroot_execute "rm -f /etc/localtime /etc/timezone"
chroot_execute "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure tzdata -f noninteractive "

echo "======= installing latest kernel============="
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes -t buster-backports linux-image${v_kernel_variant}-amd64 linux-headers${v_kernel_variant}-amd64"
 
echo "======= installing aux packages =========="
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes man wget curl software-properties-common nano htop gnupg"

echo "======= installing zfs packages =========="
chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'

chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes -t buster-backports zfs-initramfs zfs-dkms zfsutils-linux"

echo "======= installing OpenSSH and network tooling =========="
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes openssh-server net-tools"

echo "======= setup OpenSSH  =========="
mkdir -p "$c_zfs_mount_dir/root/.ssh/"
cp /root/.ssh/authorized_keys "$c_zfs_mount_dir/root/.ssh/authorized_keys"
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$c_zfs_mount_dir/etc/ssh/sshd_config"
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$c_zfs_mount_dir/etc/ssh/sshd_config"
chroot_execute "rm /etc/ssh/ssh_host_*"
chroot_execute "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server -f noninteractive"

echo "======= set root password =========="
chroot_execute "echo root:$(printf "%q" "$v_root_password") | chpasswd"

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
ExecStart=/sbin/zpool import -N -o cachefile=none -d /dev/disk/by-id $v_bpool_name
ExecStartPost=/bin/sh -c '[ -f /etc/zfs/preboot_zpool.cache ] && mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache || true'

[Install]
WantedBy=zfs-import.target
UNIT"

chroot_execute "systemctl enable zfs-import-bpool.service"

echo "========setting up zfs module parameters========"
chroot_execute "echo options zfs zfs_arc_max=$((v_zfs_arc_max_mb * 1024 * 1024)) >> /etc/modprobe.d/zfs.conf"

echo "======= setting up grub =========="
chroot_execute "echo 'grub-pc grub-pc/install_devices_empty   boolean true' | debconf-set-selections"
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes grub-pc"
chroot_execute "grub-install /dev/sda"

chroot_execute "sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"net.ifnames=0\"|' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=rpool/ROOT/debian\"|g' /etc/default/grub"

chroot_execute "sed -i 's/quiet//g' /etc/default/grub"
chroot_execute "sed -i 's/splash//g' /etc/default/grub"
chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'   >> /etc/default/grub"

if [[ $v_encrypt_rpool == "1" ]]; then
  echo "=========set up dropbear=============="

  chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes dropbear-initramfs"

  cp /root/.ssh/authorized_keys "$c_zfs_mount_dir/etc/dropbear-initramfs/authorized_keys"

  cp "$c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key" "$c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key_temp"
  chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_rsa_key_temp"
  chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key_temp /etc/dropbear-initramfs/dropbear_rsa_host_key"
  rm -rf "$c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key_temp"

  cp "$c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key" "$c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key_temp"
  chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_ecdsa_key_temp"
  chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_ecdsa_key_temp /etc/dropbear-initramfs/dropbear_ecdsa_host_key"
  chroot_execute "rm -rf /etc/ssh/ssh_host_ecdsa_key_temp"

  rm -rf "$c_zfs_mount_dir/etc/dropbear-initramfs/dropbear_dss_host_key"
fi 

echo "========running packages upgrade==========="
chroot_execute "DEBIAN_FRONTEND=noninteractive apt upgrade --yes"

#echo "===========add static route to initramfs via hook to add default routes due to  initramfs DHCP bug ========="
# removed

echo "======= update initramfs =========="
chroot_execute "update-initramfs -u -k all"

echo "======= update grub =========="
chroot_execute "update-grub"

echo "======= setting up zed =========="
initial_load_debian_zed_cache

echo "======= setting mountpoints =========="
chroot_execute "zfs set mountpoint=legacy $v_bpool_name/BOOT/debian"
chroot_execute "echo $v_bpool_name/BOOT/debian /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0 > /etc/fstab"

chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/log"
chroot_execute "echo $v_rpool_name/var/log /var/log zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/spool"
chroot_execute "echo $v_rpool_name/var/spool /var/spool zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/tmp"
chroot_execute "echo $v_rpool_name/var/tmp /var/tmp zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy $v_rpool_name/tmp"
chroot_execute "echo $v_rpool_name/tmp /tmp zfs nodev,relatime 0 0 >> /etc/fstab"

echo "========= add swap, if defined"
[[ $v_swap_size -gt 0 ]] && chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab" || true
chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"

echo "======= unmounting filesystems and zfs pools =========="
unmount_and_export_fs

echo "======== setup complete, rebooting ==============="
reboot
