# PPR Lab VM/Physical Node Setup

This document describes the steps to setup a template VM with Debian 10 (or similar a physical node) to be used by the PPR Lab

It is assumed that the KVM Server is already installed as described in the _PPR Lab KVM Server (Hypervisor) Setup_ document

# Setup Debian 10 VM

- Install Server only (to keep it small)
- Single interface, connected to default virbr0 (default NAT network)
- Configure for serial console
- name the VM `debian10-template`
- Assign 4 cores and 4GB RAM to the VM (2 cores/2GB ok for small setups)

## Serial console configuration for Debian 10
Quick notes to configure Debian 10 for serial console

#### Edit /etc/default/grub
```
# If you change this file, run 'update-grub' afterwards to update
# /boot/grub/grub.cfg.
# For full documentation of the options in this file, see:
#   info -f grub -n 'Simple configuration'

GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"

# Uncomment to enable BadRAM filtering, modify to suit your needs
# This works with Linux (no patch required) and with any kernel that obtains
# the memory map information from GRUB (GNU Mach, kernel of FreeBSD ...)
#GRUB_BADRAM="0x01234567,0xfefefefe,0x89abcdef,0xefefefef"

# Uncomment to disable graphical terminal (grub-pc only)
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=0 --parity=no --stop=1"

# The resolution used on graphical terminal
# note that you can use only modes which your graphic card supports via VBE
# you can see them in real GRUB with the command `vbeinfo'
#GRUB_GFXMODE=640x480

# Uncomment if you don't want GRUB to pass "root=UUID=xxx" parameter to Linux
#GRUB_DISABLE_LINUX_UUID=true

# Uncomment to disable generation of recovery mode menu entries
#GRUB_DISABLE_RECOVERY="true"

# Uncomment to get a beep at grub start
#GRUB_INIT_TUNE="480 440 1"
```

#### Re-Run grub
```
update-grub2
```

#### Test by connecting from hypervisor to console
```
virsh console debian10-template
```

# Install required packages
```
apt-get install libc-ares2 gnupg iperf tcpdump iptraf-ng \
 nftables libyang0.16 libyang-dev git cmake \
 build-essential bison flex libpcre3-dev libev-dev \
 libavl-dev libprotobuf-c-dev protobuf-c-compiler \
 libcmocka0 libcmocka-dev doxygen libssl-dev libssl-dev \
 libssh-dev resolvconf python3-ncclient socat
```

## Install sysrepo
Sysrepo is a requirement for the temporary FRR package used for this lab, which includes the sysrepo plugin
```
git clone https://github.com/sysrepo/sysrepo.git
cd sysrepo/
mkdir build; cd build
cmake -DCMAKE_BUILD_TYPE=Release -DGEN_LANGUAGE_BINDINGS=OFF .. && make
make install
```

## Install libnetconf2
libnetconf2 is needed in combincation with sysrepo
```
git clone https://github.com/CESNET/libnetconf2.git
cd libnetconf2/
mkdir build; cd build
cmake -DCMAKE_BUILD_TYPE=Release -DGEN_LANGUAGE_BINDINGS=OFF .. && make
make install
```

## Install udpping
`udpping` is based on the project https://github.com/wangyu-/UDPping. The only change in the here included version is to show the port in the response.

- copy `extras/udpping.py` from this repo to the VM into
`/usr/local/bin/udpping.py` 
- mark it executable (`chmod 755 /usr/local/bin/udpping.py`)

## Set password to root and allow SSH login
netconf client (client - on the netconf control VM, not the part included in the router VMs) uses old SSH libraries and can't use public key SSH. As such, we need to set a root password and allow SSH login as root with password (and disable strict host key checking as VMs change)

`passwd root` (and set a password)

**This might be a security hole and is NOT needed if you don't intend to send configurations from the YANG client**

### Change SSH config for root pw login and disable strict host checks 

```
sed -i 's/#   StrictHostKeyChecking ask/   StrictHostKeyChecking no/g' /etc/ssh/ssh_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
```

**This might be a security hole and is NOT needed if you don't intend to send configurations from the YANG client**

## Setup scripts for runonce and runboot
The Script uses some rc.local started script to do certain configuration at the first (runonce) and every further (runboot) bootup of the VM. These are used for iptables setup, package installation etc.

### Create new /etc/rc.local
Use the following script as /etc/rc.local 
```
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

hwclock --systohc

for file in /etc/runonce.d/*
do
    if [ ! -f "$file" ]
    then
        continue
    fi
    chmod 755 "$file"
    su - root -c "$file" | tee /var/log/${file##*/}.log
    mv "$file" /etc/runonce.d/ran/
    logger -t runonce -p local3.info "$file"
done

for file in /etc/runboot.d/*
do
    if [ ! -f "$file" ]
    then
        continue
    fi
    chmod 755 "$file"
    su - root -c "$file" | tee /var/log/${file##*/}.log
    logger -t runboot -p local3.info "$file"
done

exit 0
```
#### Create directories for runonce/runboot files
```
mkdir /etc/runonce.d
mkdir /etc/runonce.d/ran
mkdir /etc/runboot.d
```

#### Set protection of the files/directories
```
chown root:root /etc/rc.local
chmod 755 /etc/rc.local
chown -R root:root /etc/runonce.d
chown -R root:root /etc/runboot.d
```

###### tags: `PPR` `Documentation`
