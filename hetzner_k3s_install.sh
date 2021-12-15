#!/bin/bash
# download 
# curl -sfL -o hetzner_k3s_install.sh https://raw.githubusercontent.com/willyhun/zfs-hetzner-vm/headless/hetzner_k3s_install.s
# execute:
# bash  hetzner_k3s_install.sh
# first time install:
# bash  hetzner_k3s_install.sh first
 

# prepare environment
DATADRIVE="rpool/data"

# install git
apt-get -y install git

echo "Preparing ${DATADRIVE}/rancherinstall install env:"
mkdir -p /rancherstorage
mkdir -p /rancherinstall
mkdir -p /var/lib/kubelet
mkdir -p /var/lib/rancher
mkdir -p /etc/rancher

# prepare empty install env
zfs create ${DATADRIVE}/rancherinstall -s -V 10GB && sleep 2 && mkfs.ext4 -q -L rancherinstall /dev/zvol/${DATADRIVE}/rancherinstall

mount -L rancherinstall /rancherinstall
mkdir -p /rancherinstall/etc
mkdir -p /rancherinstall/rancher
mkdir -p /rancherinstall/kubelet

mount -o bind /rancherinstall/rancher /var/lib/rancher
mount -o bind /rancherinstall/kubelet /var/lib/kubelet
mount -o bind /rancherinstall/etc     /etc/rancher

# debug
echo "Checking the mounted environment:"
mount | grep rancher 
mount | grep kubelet

echo "Please press an enter if the above is fine, if not, please Ctrl+C, and clean up manually!"
read 

# k3s install
echo "Installing k3s:"  

curl -sfL https://get.k3s.io | sh -s - --disable traefik --disable servicelb
# set the KUBECONFIG value                                                                                                                                                
cat <<CONF >> .bashrc
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"  
CONF

# helm install
echo "Installing helm:"
curl -fsL  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add metallb https://metallb.github.io/metallb
helm repo add jetstack https://charts.jetstack.io

# krew install
echo "Installing krew:"
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
# set the KUBECONFIG value                                                                                                                                                
cat <<CONF >> .bashrc
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
CONF

# stop installed k3s
echo "Stopping the installed K3S"
systemctl stop k3s
k3s-killall.sh 

# only on first run copy to the permanent storage
if [ "first" = "$1" ] ; then
 echo "This is the first run, we create the permanent storage volume, and copy over the installed k3s: "
 zfs create ${DATADRIVE}/rancherstorage -s -V 100GB && sleep 2 && mkfs.ext4 -q -L rancherstorage /dev/zvol/${DATADRIVE}/rancherstorage
 mount -L rancherstorage /rancherstorage
 rsync -avHp /rancherinstall/* /rancherstorage/
 umount /rancherstorage
fi

# stop and remove all install env settings
echo "Umount, remove, cleanup the installing environment:"
umount /etc/rancher
umount /var/lib/kubelet
umount /var/lib/rancher
umount /rancherinstall
rm -fr /rancherinstall 
rm -fr /run/k3s/*
rm -fr /run/flannel/*

zfs destroy ${DATADRIVE}/rancherinstall

# config the permament storage mount
echo "Prepare fstab:"
cat <<CONF >> /etc/fstab
LABEL=rancherstorage /rancherstorage ext4  defaults,x-systemd.requires=zfs-volumes.target 0  0
/rancherstorage/etc /etc/rancher ext4  defaults,bind,x-systemd.requires=zfs-volumes.target 0  0
/rancherstorage/kubelet /var/lib/kubelet ext4  defaults,bind,x-systemd.requires=zfs-volumes.target 0  0
/rancherstorage/rancher /var/lib/rancher ext4  defaults,bind,x-systemd.requires=zfs-volumes.target 0  0
CONF

echo "Mount the permanent storage, start k3s with the permanent env:"
mount -a 
# start the system
systemctl start k3s 

# hint for the cleanup
# systemctl stop k3s
# k3s-killall.sh
# umount /var/lib/rancher
# umount roor/lib/kubelet
# umount /etc/rancher
# umount /rancherstorage
# k3s-uninstall.sh