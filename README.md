# zfs-hetzner-vm

Fully automatic, unattended script to install Debian 10 with ZFS root on Hetzner VPS.
__WARNING:__ all data on the disk will be destroyed.

How to use: add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power cycle
Next, connect via SSH to rescue console, download the script and run it:
````
wget https://raw.githubusercontent.com/andrey42/zfs-hetzner-vm/master/hetzner-vps-debian10-setup.sh
chmod 755 hetzner-vps-debian10-setup.sh
./hetzner-vps-debian10-setup.sh
````
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
````
screen -dmS zfs
screen -r zfs
````
To detach from screen console, hit Ctrl-d then a

