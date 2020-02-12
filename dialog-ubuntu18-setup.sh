#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Ubuntu 18 LTS with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power sysle
Next, connect via SSH to console, download and run the script 
Answer script questions, upon the succesfull run the script will automaticall reboot
in case of failure check for the errors inside script logs within "/tmp/zfs-hetzner-vm" temp folder
end_header_info

set -o errexit
set -o pipefail
set -o nounset

# Variables set during execution
v_bpool_name=
v_bpool_tweaks=              # see defaults below for format
v_rpool_name=
v_rpool_tweaks=              # see defaults below for format
declare -a v_selected_disks  # (/dev/by-id/disk_id, ...)
v_swap_size=                 # integer
v_free_tail_space=           # integer
v_hostname=
v_zfs_arc_max_mb=
v_root_password=

v_suitable_disks=()          # (/dev/by-id/disk_id, ...); scope: find_suitable_disks -> select_disk

# Constants
c_deb_packages_repo=http://mirror.hetzner.de/ubuntu/packages
c_deb_security_repo=http://mirror.hetzner.de/ubuntu/security

c_default_zfs_arc_max_mb=250
c_default_bpool_tweaks="-o ashift=12"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_default_hostname=terem
c_zfs_mount_dir=/mnt
c_log_dir=$(dirname "$(mktemp)")/zfs-hetzner-vm
c_install_log=$c_log_dir/install.log
c_lsb_release_log=$c_log_dir/lsb_release.log
c_disks_log=$c_log_dir/disks.log
c_zfs_module_version_log=$c_log_dir/updated_module_versions.log

function activate_debug {
  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

# shellcheck disable=SC2120 # allow parameters passing even if no calls pass any
function print_step_info_header {
  echo -n "
###############################################################################
# ${FUNCNAME[1]}"

  [[ "${1:-}" != "" ]] && echo -n " $1" || true

  echo "
###############################################################################
"
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

function display_intro_banner {
  print_step_info_header

  local dialog_message='Hello!
This script will prepare the ZFS pools, then install and configure minimal Ubuntu 18 LTS with ZFS root on Hetzner hosting VPS instance
The script with minimal changes may be used on any other hosting provider supporting KVM virtualization and offering Debian-based rescue system.
In order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running.
'
  dialog --ascii-lines --msgbox "$dialog_message" 30 100
}

function store_os_distro_information {
  print_step_info_header

  lsb_release --all > "$c_lsb_release_log"
}

function check_prerequisites {
  print_step_info_header
  if [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  fi
  if ! dpkg-query -l dialog1 &> /dev/null; then
    apt install --yes dialog
  fi  
}


function find_suitable_disks {
  print_step_info_header

  udevadm trigger

  # shellcheck disable=SC2012 
  ls -l /dev/disk/by-id | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"

  local candidate_disk_ids
  local mounted_devices

  candidate_disk_ids=$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi)-.+' -not -regex '.+-part[0-9]+$' | sort)
  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"

  while read -r disk_id || [[ -n "$disk_id" ]]; do
    local device_info
    local block_device_name

    device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"
    block_device_basename="$(basename "$(readlink -f "$disk_id")")"

    # It's unclear if it's possible to establish with certainty what is an internal disk:
    #
    # - there is no (obvious) spec around
    # - pretty much everything has `DEVTYPE=disk`, e.g. LUKS devices
    # - ID_TYPE is optional
    #
    # Therefore, it's probably best to rely on the id name, and just filter out optical devices.
    #
    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^$block_device_basename\$" <<< "$mounted_devices"; then
        v_suitable_disks+=("$disk_id")
      fi
    fi

    cat >> "$c_disks_log" << LOG

## DEVICE: $disk_id ################################

$(udevadm info --query=property "$(readlink -f "$disk_id")")

LOG

  done < <(echo -n "$candidate_disk_ids")

  if [[ ${#v_suitable_disks[@]} -eq 0 ]]; then
    local dialog_message='No suitable disks have been found!

If you think this is a bug, please open an issue on https://github.com/andrey42/zfs-hetzner-vm/issues, and attach the file `'"$c_disks_log"'`.
'
    dialog --ascii-lines --msgbox "$dialog_message" 30 100

    exit 1
  fi

  print_variables v_suitable_disks
}

function select_disks {
  print_step_info_header

  while true; do
    local menu_entries_option=()

    if [[ ${#v_suitable_disks[@]} -eq 1 ]]; then
      local disk_selection_status=ON
    else
      local disk_selection_status=OFF
    fi

    for disk_id in "${v_suitable_disks[@]}"; do
      menu_entries_option+=("$disk_id" "($block_device_basename)" "$disk_selection_status")
    done

    local dialog_message="Select the ZFS devices (multiple selections will be in mirror).

Devices with mounted partitions, cdroms, and removable devices are not displayed!
"
    mapfile -t v_selected_disks < <(dialog --ascii-lines --separate-output --checklist "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)

    if [[ ${#v_selected_disks[@]} -gt 0 ]]; then
      break
    fi
  done

  print_variables v_selected_disks
}

function ask_swap_size {
  print_step_info_header

  local swap_size_invalid_message=

  while [[ ! $v_swap_size =~ ^[0-9]+$ ]]; do
    v_swap_size=$(dialog --ascii-lines --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap):" 30 100 2 3>&1 1>&2 2>&3)

    swap_size_invalid_message="Invalid swap size! "
  done

  print_variables v_swap_size
}

function ask_free_tail_space {
  print_step_info_header

  local tail_space_invalid_message=

  while [[ ! $v_free_tail_space =~ ^[0-9]+$ ]]; do
    v_free_tail_space=$(dialog --ascii-lines --inputbox "${tail_space_invalid_message}Enter the space to leave at the end of each disk (0 for none):" 30 100 0 3>&1 1>&2 2>&3)

    tail_space_invalid_message="Invalid size! "
  done

  print_variables v_free_tail_space
}

function ask_zfs_arc_max_size {
  print_step_info_header

  local zfs_arc_max_invalid_message=

  while [[ ! $v_zfs_arc_max_mb =~ ^[0-9]+$ ]]; do
    v_zfs_arc_max_mb=$(dialog --ascii-lines --inputbox "${zfs_arc_max_invalid_message}Enter ZFS ARC cache max size in Mb (minimum 64Mb, enter 0 for ZFS default value, the default will take up to 50% of memory):" 30 100 "$c_default_zfs_arc_max_mb" 3>&1 1>&2 2>&3)

    zfs_arc_max_invalid_message="Invalid size! "
  done

  print_variables v_zfs_arc_max_mb
}


function ask_pool_names {
  print_step_info_header

  local bpool_name_invalid_message=

  while [[ ! $v_bpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_bpool_name=$(dialog --ascii-lines --inputbox "${bpool_name_invalid_message}Insert the name for the boot pool" 30 100 bpool 3>&1 1>&2 2>&3)

    bpool_name_invalid_message="Invalid pool name! "
  done
  local rpool_name_invalid_message=

  while [[ ! $v_rpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_rpool_name=$(dialog --ascii-lines --inputbox "${rpool_name_invalid_message}Insert the name for the root pool" 30 100 rpool 3>&1 1>&2 2>&3)

    rpool_name_invalid_message="Invalid pool name! "
  done

  print_variables v_bpool_name v_rpool_name
}

function ask_pool_tweaks {
  print_step_info_header

  v_bpool_tweaks=$(dialog --ascii-lines --inputbox "Insert the tweaks for the boot pool" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)
  v_rpool_tweaks=$(dialog --ascii-lines --inputbox "Insert the tweaks for the root pool" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)

  print_variables v_bpool_tweaks v_rpool_tweaks
}


function ask_root_password {
  print_step_info_header

  set +x
  local password_invalid_message=
  local password_repeat=-

  while [[ "$v_root_password" != "$password_repeat" || "$v_root_password" == "" ]]; do
    v_root_password=$(dialog --ascii-lines --passwordbox "${password_invalid_message}Please enter the root account password (can't be empty):" 30 100 3>&1 1>&2 2>&3)
    password_repeat=$(dialog --ascii-lines --passwordbox "Please repeat the password:" 30 100 3>&1 1>&2 2>&3)

    password_invalid_message="Passphrase empty, or not matching! "
  done
  set -x
}

function prepare_disks {
  print_step_info_header

  # PARTITIONS #########################

  if [[ $v_free_tail_space -eq 0 ]]; then
    local tail_space_parameter=0
  else
    local tail_space_parameter="-${v_free_tail_space}G"
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    wipefs --all "$selected_disk"
    sgdisk -a1 -n1:24K:+1000K            -t1:EF02 "$selected_disk"
    sgdisk -n2:0:+512M                   -t2:BF01 "$selected_disk" # Boot pool
    sgdisk -n3:0:"$tail_space_parameter" -t3:BF01 "$selected_disk" # Root pool
  done

  udevadm settle

  # POOL OPTIONS #######################

  local rpool_disks_partitions=()
  local bpool_disks_partitions=()

  for selected_disk in "${v_selected_disks[@]}"; do
    rpool_disks_partitions+=("${selected_disk}-part3")
    bpool_disks_partitions+=("${selected_disk}-part2")
  done

  if [[ ${#v_selected_disks[@]} -gt 1 ]]; then
    local pools_mirror_option=mirror
  else
    local pools_mirror_option=
  fi                           

  # POOLS #####################
  # See https://github.com/zfsonlinux/zfs/wiki/Ubuntu-18.04-Root-on-ZFS for the details.

  zpool create \
    $v_rpool_tweaks \
    -O canmount=off -O mountpoint=/ -R "$c_zfs_mount_dir" -f \
    "$v_rpool_name" $pools_mirror_option "${rpool_disks_partitions[@]}"

  zpool create \
    $v_bpool_tweaks \
    -O canmount=off -O mountpoint=/boot -R "$c_zfs_mount_dir" -f \
    "$v_bpool_name" $pools_mirror_option "${bpool_disks_partitions[@]}"

  udevadm settle

  # ZFS DATASETS #########################
  zfs create -o canmount=off -o mountpoint=none "$v_rpool_name/ROOT"
  zfs create -o canmount=off -o mountpoint=none "$v_bpool_name/BOOT"
 
  zfs create -o canmount=noauto -o mountpoint=/ $v_rpool_name/ROOT/ubuntu
  zfs mount rpool/ROOT/ubuntu
 
  zfs create -o canmount=noauto -o mountpoint=/boot $v_bpool_name/BOOT/ubuntu
  zfs mount $v_bpool_name/BOOT/ubuntu
 
  zfs create                                 $v_rpool_name/home
  zfs create -o mountpoint=/root             $v_rpool_name/home/root
  zfs create -o canmount=off                 $v_rpool_name/var
  zfs create -o canmount=off                 $v_rpool_name/var/lib
  zfs create                                 $v_rpool_name/var/log
  zfs create                                 $v_rpool_name/var/spool
 
  zfs create -o com.sun:auto-snapshot=false  $v_rpool_name/var/cache
  zfs create -o com.sun:auto-snapshot=false  $v_rpool_name/var/tmp
  chmod 1777 $c_zfs_mount_dir/var/tmp
 
  zfs create                                 $v_rpool_name/srv
 
  zfs create -o canmount=off                 $v_rpool_name/usr
  zfs create                                 $v_rpool_name/usr/local
 
  zfs create                                 $v_rpool_name/var/mail
 
  zfs create -o com.sun:auto-snapshot=false  $v_rpool_name/tmp
  chmod 1777 $c_zfs_mount_dir/tmp

  # SWAP ###############################

  if [[ $v_swap_size -gt 0 ]]; then
    zfs create \
      -V "${v_swap_size}G" -b "$(getconf PAGESIZE)" \
      -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
      "$v_rpool_name/swap"

    udevadm settle
 
    mkswap -f "/dev/zvol/$v_rpool_name/swap"
  fi

}

function chroot_execute {
  chroot $c_zfs_mount_dir bash -c "$1"
}

function check_prerequisites {
  print_step_info_header

  if [[ ! -r /root/.ssh/authorized_keys ]]; then
    echo "SSH pubkey file is absent, please add it to the rescue system setting, then reboot into rescue system and run the script"
    exit 1
  elif [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  fi
}

function install_zfs_on_rescue_system {
  print_step_info_header

  for kver in $(ls /lib/modules/ -1 | grep -v "$(uname -r)"); do 
    #apt purge --yes "linux-headers-$kver"
    apt purge --yes "linux-image-$kver"  
  done
  echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

  apt update
  apt install --yes -t buster-backports libelf-dev zfs-dkms 
  modprobe zfs
  zfs --version
}

function initial_load_zed_cache {
  print_step_info_header

  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/$v_rpool_name"
  #chroot_execute "ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

  chroot_execute "zed -F &"

  local success=0
  
  if [[ ! -e $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name ]] || [[ -e $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name && (( $(ls -l $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name 2> /dev/null | cut -d ' ' -f 5) == 0 )) ]]; then
    chroot_execute "zfs set canmount=noauto $v_rpool_name"

    SECONDS=0

    while (( SECONDS++ <= 120 )); do
      if [[ -e $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name ]] && (( "$(ls -l $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name | cut -d ' ' -f 5)" > 0 )); then
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

  sed -Ei 's|$c_zfs_mount_dir/?|/|g' $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name
}

function unmount_and_export_fs {
  print_step_info_header

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  local SECONDS=0
  local zpools_exported=99

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

function ask_hostname {
  print_step_info_header

  local hostname_invalid_message=

  while [[ ! $v_hostname =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_hostname=$(dialog --ascii-lines --inputbox "${hostname_invalid_message}Set the host name" 30 100 "$c_default_hostname" 3>&1 1>&2 2>&3)

    hostname_invalid_message="Invalid host name! "
  done

  print_variables v_hostname
}

function setup_network {
  print_step_info_header

  chroot_execute "apt --yes purge netplan.io"
  chroot_execute "apt install --yes ifupdown"
  echo "$v_hostname" > $c_zfs_mount_dir/etc/hostname

  cat > $c_zfs_mount_dir/etc/hosts <<CONF
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

#cat > "$c_zfs_mount_dir/etc/netplan/01-netcfg.yml" <<CONF
#network:
#  version: 2
#  renderer: networkd
#  ethernets:
#    ens3:
#      dhcp4: yes
#      dhcp6: no
#      addresses:
#        - ${ip6addr_prefix}:1/64
#      gateway6: fe80::1
#CONF

  cat > "$c_zfs_mount_dir/etc/network/interfaces" <<CONF
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


  mkdir -p $c_zfs_mount_dir/etc/cloud/cloud.cfg.d/
  cat > "$c_zfs_mount_dir/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" <<CONF
network:
  config: disabled
CONF

  rm -rf $c_zfs_mount_dir/etc/network/interfaces.d/50-cloud-init.cfg

  cp /etc/resolv.conf $c_zfs_mount_dir/etc/resolv.conf

}

function setup_initial_system {
  print_step_info_header

  debootstrap --arch=amd64 --include=ubuntu-minimal bionic $c_zfs_mount_dir $c_deb_packages_repo

  zfs set devices=off $v_rpool_name

  for virtual_fs_dir in proc sys dev; do
    mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  cat > $c_zfs_mount_dir/etc/apt/sources.list <<CONF
deb [arch=i386,amd64] $c_deb_packages_repo bionic main restricted
deb [arch=i386,amd64] $c_deb_packages_repo bionic-updates main restricted
deb [arch=i386,amd64] $c_deb_packages_repo bionic-backports main restricted
deb [arch=i386,amd64] $c_deb_packages_repo bionic universe
deb [arch=i386,amd64] $c_deb_security_repo bionic-security main restricted
CONF

  chroot_execute "apt update"

}

function setup_locale {
  print_step_info_header

  chroot_execute "apt install --yes -qq locales debconf-i18n apt-utils"
  sed -i 's/# en_US.UTF-8/en_US.UTF-8/' $c_zfs_mount_dir/etc/locale.gen
  sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' $c_zfs_mount_dir/etc/locale.gen
  sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' $c_zfs_mount_dir/etc/locale.gen
  sed -i 's/# de_AT.UTF-8/de_AT.UTF-8/' $c_zfs_mount_dir/etc/locale.gen
  sed -i 's/# de_DE.UTF-8/de_DE.UTF-8/' $c_zfs_mount_dir/etc/locale.gen

  #chroot_execute "locale-gen"
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
grub-pc grub-pc/install_devices_empty   boolean true
CONF'

  chroot_execute "dpkg-reconfigure locales -f noninteractive"
  echo -e "LC_ALL=en_US.UTF-8\nLANG=en_US.UTF-8\n" >> $c_zfs_mount_dir/etc/environment
  chroot_execute "apt install -qq --yes keyboard-configuration console-setup"
  chroot_execute "dpkg-reconfigure keyboard-configuration -f noninteractive"
  chroot_execute "dpkg-reconfigure console-setup -f noninteractive"
  chroot_execute "setupcon"

  chroot_execute "rm -f /etc/localtime /etc/timezone"
  chroot_execute "dpkg-reconfigure tzdata -f noninteractive "

}

function install_kernel_and_aux_packages {
  print_step_info_header

  chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes linux-headers-virtual-hwe-18.04 linux-image-virtual-hwe-18.04 linux-image-extra-virtual-hwe-18.04"
  chroot_execute "apt install --yes man wget curl software-properties-common nano htop openssh-server net-tools"
}

function install_zfs_packages {
  print_step_info_header

  chroot_execute "wget -O - https://andrey42.github.io/zfs-ubuntu/apt_pub.gpg | apt-key add -"
  chroot_execute "add-apt-repository 'deb https://andrey42.github.io/zfs-ubuntu/public bionic zfs-backports-experimental'"
  chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
  chroot_execute "apt install --yes zfs-initramfs zfs-dkms zfsutils-linux"

  chroot_execute "cat > /etc/systemd/system/zfs-import-bpool.service <<UNIT
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c '[ -f /etc/zfs/zpool.cache ] && mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache || true'
ExecStart=/sbin/zpool import -N -o cachefile=none $v_bpool_name
ExecStartPost=/bin/sh -c '[ -f /etc/zfs/preboot_zpool.cache ] && mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache || true'

[Install]
WantedBy=zfs-import.target
UNIT"

  chroot_execute "systemctl enable zfs-import-bpool.service"

  chroot_execute "cp /usr/share/systemd/tmp.mount /etc/systemd/system/"
  chroot_execute "systemctl enable tmp.mount"

  [[ $v_zfs_arc_max_mb -gt 0 ]] && chroot_execute "echo options zfs zfs_arc_max=$((v_zfs_arc_max_mb * 1024 * 1024)) >> /etc/modprobe.d/zfs.conf" || true  

}

function setup_openssh {
  print_step_info_header

  mkdir -p $c_zfs_mount_dir/root/.ssh/
  cp /root/.ssh/authorized_keys $c_zfs_mount_dir/root/.ssh/authorized_keys
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' $c_zfs_mount_dir/etc/ssh/sshd_config
  sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' $c_zfs_mount_dir/etc/ssh/sshd_config
  chroot_execute "rm /etc/ssh/ssh_host_*"
  chroot_execute "dpkg-reconfigure openssh-server -f noninteractive"

}

function setup_grub {
  print_step_info_header

  chroot_execute "echo 'grub-pc grub-pc/install_devices_empty   boolean true' | debconf-set-selections"
  chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes grub-pc"
  chroot_execute "grub-install ${v_selected_disks[0]}"

  chroot_execute "sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub"
  chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=$v_rpool_name/ROOT/ubuntu\"|g'  /etc/default/grub"

  chroot_execute "sed -i 's/quiet//g' /etc/default/grub"
  chroot_execute "sed -i 's/splash//g' /etc/default/grub"
  chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'   >> /etc/default/grub"
}

function clone_mbr_partition {
  print_step_info_header

  for ((i = 1; i < ${#v_selected_disks[@]}; i++)); do
    dd if="${v_selected_disks[0]}-part1" of="${v_selected_disks[i]}-part1"
  done
}


function setup_dropbear {
  print_step_info_header

  chroot_execute "apt install --yes --no-install-recommends dropbear-initramfs"

  cp /root/.ssh/authorized_keys $c_zfs_mount_dir/etc/dropbear-initramfs/authorized_keys

  cp $c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key $c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key_temp
  chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_rsa_key_temp"
  chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key_temp /etc/dropbear-initramfs/dropbear_rsa_host_key"
  rm -rf $c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key_temp

#cp $c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key $c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key_temp
#chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_ecdsa_key_temp"
#chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_ecdsa_key_temp /etc/dropbear-initramfs/dropbear_ecdsa_host_key"
#chroot_execute "rm -rf /etc/ssh/ssh_host_ecdsa_key_temp"
#rm -rf $c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key_temp
  rm -rf $c_zfs_mount_dir/etc/dropbear-initramfs/dropbear_ecdsa_host_key

}

function upgrade_system_packages {
  print_step_info_header
  chroot_execute "apt upgrade --yes"
  chroot_execute "update-initramfs -u -k all"
  chroot_execute "update-grub"
}

function setup_zfs_mountpoints {
  print_step_info_header
  chroot_execute "zfs set mountpoint=legacy $v_bpool_name/BOOT/ubuntu"
  chroot_execute "echo $v_bpool_name/BOOT/ubuntu /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0 > /etc/fstab"
  chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/log"
  chroot_execute "echo $v_rpool_name/var/log /var/log zfs nodev,relatime 0 0 >> /etc/fstab"
  chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/spool"
  chroot_execute "echo $v_rpool_name/var/spool /var/spool zfs nodev,relatime 0 0 >> /etc/fstab"
  chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/tmp"
  chroot_execute "echo $v_rpool_name/var/tmp /var/tmp zfs nodev,relatime 0 0 >> /etc/fstab"
  chroot_execute "zfs set mountpoint=legacy $v_rpool_name/tmp"
  chroot_execute "echo $v_rpool_name/tmp /tmp zfs nodev,relatime 0 0 >> /etc/fstab"
}

function configure_remaining_settings {
  print_step_info_header

  chroot_execute "echo root:$(printf "%q" "$v_root_password") | chpasswd"

  cat > $c_zfs_mount_dir/root/.bashrc <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF

  [[ $v_swap_size -gt 0 ]] && chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab" || true
  chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"
}

######################## main block ####################
export LC_ALL=en_US.UTF-8

check_prerequisites

display_intro_banner

activate_debug

find_suitable_disks

select_disks

ask_swap_size

ask_free_tail_space

ask_pool_names

ask_pool_tweaks

ask_zfs_arc_max_size

ask_root_password

ask_hostname

clear 

install_zfs_on_rescue_system

prepare_disks

setup_initial_system

setup_locale 

install_kernel_and_aux_packages

setup_network

install_zfs_packages

setup_openssh

setup_grub

clone_mbr_partition

setup_dropbear

initial_load_zed_cache

#upgrade_system_packages

setup_zfs_mountpoints

configure_remaining_settings

unmount_and_export_fs

echo "======== setup complete, ready to reboot ==============="
reboot