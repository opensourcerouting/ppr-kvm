# PPR Lab KVM Server Installation

**Please note:** This document refers to KVM server (hypervisor) and NOT the VM or physical boxes for the network.

# Supported systems for KVM Server

**Only Ubuntu 18.04LTS Server is fully supported.** CentOS 7 is partially working as well, but very limited testing is done (and no install instructions are provided)

Other Debian based systems (ie Debian 10 or Ubuntu 16.04 will not work because of version and confiuration changes in the KVM packages)

**Please note:** This refers to KVM server (hypervisor) in this document and NOT the VM or physical boxes for the network.

# Required packages to be installed

```
sudo apt-get install linux-generic-hwe-18.04
sudo apt-get install qemu-kvm libvirt-clients libvirt-daemon \
 libguestfs-tools virt-goodies virtinst libosinfo-bin git pv \
 install bridge-utils bash sudo
``` 

# Setup KVM

## Create Networks for VMs

### default Network

The `default` network is usually created during the KVM install and gives DHCP and NAT access to any VM to outside world.
For the PPR-Lab the VMs have usually no connection to this network (except the template VM to allow installation of additional packages and updates)

Verify that the default network exists:

```
# virsh net-list
 Name                 State      Autostart     Persistent
----------------------------------------------------------
 default              active     yes           yes
```

If the network already exists, is active and marked for autostart, then skip the following steps

#### Create the default-network
```
echo "<network>
  <name>default</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
" > net-default.xml
virsh define net-default.xml
```

#### Start default-network
```
virsh net-start default
```

#### Mark default network for autostart on boot
```
virsh net-autostart default
```

### mgmt Network

The `mgmt` network is used by the VMs to talk to the netconf server. 

Most topologies have a IPv4 direct connection to this network, to allow the netconf server to access them. 

(However, in general only VMs or physical hosts which need netconf connection actually need the connection. but for simplicity, the setup creates a connection for each host)

#### Create the mgmt-network
```
echo "<network>
  <name>mgmt</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr1' stp='on' delay='0'/>
  <ip address='192.168.124.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.124.2' end='192.168.124.99'/>
    </dhcp>
  </ip>
</network>
" > net-default.xml
virsh define net-default.xml
```

#### Start mgmt-network
```
virsh net-start mgmt
```

#### Mark default network for autostart on boot
```
virsh net-autostart mgmt
```

## Create Storage pool for VMs

The storage pool for the lab is just a directory which contains all the container files for the disks. For this setup we create and use a top-level `/vms` directory for it.

### VM Pool `/vms`

#### Create XML file and create pool
```
virsh pool-create-as vms --target /vms --type dir
virsh pool-dumpxml vms > vms_pool.xml
virsh pool-destroy vms
virsh pool-define vms_pool.xml
```

#### Start pool
```
virsh pool-start vms
```

#### Mark pool autostarted
```
virsh pool-autostart vms
```

# Create normal User

Create normal user for work and add it to sudo. This documentation assumes the user is called `ppr-lab`.

## Allow our normal user to use KVM

Create `libvirt` group:

```
sudo groupadd --system libvirt
```

Add our previously create user to the group

```
sudo usermod -a -G libvirt ppr-lab
```

Logout and back in with the ppr-lab user to get the group added. 
