#!/usr/bin/env bash
##set -x
#
##### Configuration starts here ##########
# Source VM Template
VM_Template=debian10_template
VM_storage_dir=/vms
#
# Mac Address Prefix (first 3 MAC Address Bytes)
MacPrefix="00:1C:44:"
#
# Linux config files
SysCtlFile="node-sysctl.conf"
# FRR
FRRpackage="frr_7.0.1-1+b1_amd64.deb"
FRRdaemons="daemons"
#
#########################################
# End config
#########################################
#
if test $# -lt 1 ; then
        echo "Need YAML Config file as argument"
        exit 1
fi
#
YAML_Configfile=$1
#
# Get Directory of this script
Script_Dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
#
# Get Source disk file from template VM
VM_Template_disk=`virsh dumpxml ${VM_Template} | grep "source file" | grep -o "'.*'" | sed "s/'//g"`
#
function parse_yaml {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}
#
var_exists() { # check if variable is set at all
    local "$@" # inject 'name' argument in local scope
    &>/dev/null declare -p "$name" # return 0 when var is present
}


# Check if template VM is turned off
#
if [ "`virsh list --state-shutoff --all | grep \ $VM_Template`" == "" ] ; then
    echo "Template VM $VM_Template not found or not turned off"
    exit 1
fi
#
# Parse Topology Configuration File
#
eval $(parse_yaml ${YAML_Configfile})
#
# Build nodes
#
nodeNr=0
for node in ${global_nodes}; do
    echo "Processing node $node"
    nodeNr=`expr ${nodeNr} + 1`
    #
    # Creating bridges as needed
    ifnum=1
    while var_exists name=${node}_if${ifnum}_bridge ; do
        if=${node}_if${ifnum}_bridge
        bridge=${!if}
        BridgeFound=`grep "${bridge}:" /proc/net/dev`
        if ! [ -n "${BridgeFound}" ] ; then
            echo "   $node: interface if$ifnum - Creating Bridge ${bridge}"
            sudo brctl addbr ${bridge} 2> /dev/null
        fi
        sudo ip link set ${bridge} up
        #
        ifnum=`expr $ifnum + 1`
    done
    #

    if [ "`virsh list --all | grep \ $node\ `" = "" ]; then
        sudo sh -c "pv -B 500M ${VM_Template_disk} > ${VM_storage_dir}/${node}_disk.qcow2"
        node_xml="/tmp/node_$node.xml"
        cp ${Script_Dir}/node-template.xml $node_xml
        sed -i "s|__TEMPLATENAME__|$node|g" $node_xml
        sed -i "s|__TEMPLATEDISK__|${VM_storage_dir}/${node}_disk.qcow2|g" $node_xml
        virsh define $node_xml
        rm -rf $node_xml
        # Node defined, now add interfaces
        ifnum=1
        while var_exists name=${node}_if${ifnum}_bridge ; do
                if=${node}_if${ifnum}_bridge
                bridge=${!if}
                nodeNrHigh=`expr ${nodeNr} / 256`
                nodeNrLow=`expr ${nodeNr} % 256`
                macaddr=${MacPrefix}`printf "%02x\n" ${nodeNrHigh}`:`printf "%02x\n" ${nodeNrLow}`:`printf "%02x\n" $ifnum`
                echo "   ${node}: Adding Interface $ifnum with MAC $macaddr, connected to ${bridge}"
                virsh attach-interface $node --model virtio \
                    --type bridge --source $bridge --mac $macaddr --persistent
                #
                ifnum=`expr $ifnum + 1`
        done
        # Interfaces added. Now adjust VM config
        # 
        # Hostname
        # /etc/hostname
        hostnamefile=/tmp/node-hostnamefile-$$
        echo "$node" > $hostnamefile
        #
        # /etc/network/interfaces
        iffile=/tmp/node-if-$$
        echo "# The loopback network interface" > $iffile
        echo "auto lo" >> $iffile
        echo "iface lo inet loopback" >> $iffile
        echo "#" >> $iffile
        ifnum=1
        ensnum=2
        while var_exists name=${node}_if${ifnum}_bridge ; do
            if=${node}_if${ifnum}_bridge
            bridge=${!if}
            echo "# Interface $ifnum, connected to bridge $bridge" >> $iffile
            echo "auto ens${ensnum}" >> $iffile
            echo "iface ens${ensnum} inet manual" >> $iffile
            echo "  up ip link set \$IFACE up" >> $iffile
            echo "  down ip link set \$IFACE down" >> $iffile
            echo "iface ens${ensnum} inet6 manual" >> $iffile
            echo "#" >> $iffile
            ifnum=`expr $ifnum + 1`
            ensnum=`expr $ensnum + 1`
        done
        #
        # /etc/hosts
        hostfile=/tmp/node-hostfile-$$
        echo "127.0.0.1 $node localhost.localdomain localhost" > $hostfile
        echo "::1             localhost6.localdomain6 localhost6 ip6-localhost ip6-loopback" >> $hostfile
        echo "fe00::0       ip6-localnet" >> $hostfile
        echo "ff00::0       ip6-mcastprefix" >> $hostfile
        echo "ff02::1       ip6-allnodes" >> $hostfile
        echo "ff02::2       ip6-allrouters" >> $hostfile
        #
        # /etc/frr/frr.conf
        frrconf=/tmp/node-frrconf-$$
        echo "# FRR Config for node ${node}" > $frrconf
        echo "frr defaults traditional" >> $frrconf
        echo "hostname ${node}" >> $frrconf
        echo "log syslog informational" >> $frrconf
        echo "service integrated-vtysh-config" >> $frrconf
        echo "!" >> $frrconf
        ifnum=1
        ensnum=2
        while var_exists name=${node}_if${ifnum}_bridge ; do
            if=${node}_if${ifnum}_bridge
            bridge=${!if}
            echo "interface ens${ensnum}" >> $frrconf
            echo " description Connected to KVM bridge ${bridge}" >> $frrconf
            if var_exists name=${node}_if${ifnum}_ipv4 ; then
                ip=${node}_if${ifnum}_ipv4
                addr=${!ip}
                echo " ip address ${addr}" >> $frrconf
            fi
            if var_exists name=${node}_if${ifnum}_ipv6 ; then
                ip=${node}_if${ifnum}_ipv6
                addr=${!ip}
                echo " ipv6 address ${addr}" >> $frrconf
            fi
            echo "!" >> $frrconf
            ifnum=`expr $ifnum + 1`
            ensnum=`expr $ensnum + 1`
        done
        echo "line vty" >> $frrconf
        echo "!" >> $frrconf
        #
        # /etc/frr/vtysh.conf
        vtyshconf=/tmp/node-vtyshconf-$$
        echo "service integrated-vtysh-config" >> $vtyshconf
        #
        # /etc/runonce.d/80_frr_install.sh
        frrinstall=/tmp/node-frrinstall-$$
        echo "yes \"\" | DEBIAN_FRONTEND=noninteractive dpkg -i /root/${FRRpackage}" >> $frrinstall
        echo "rm -f /root/${FRRpackage}" >> $frrinstall
        echo "chown frr:frr /etc/frr/frr.conf" >> $frrinstall
        echo "chown frr:frr /etc/frr/daemons" >> $frrinstall
        echo "chown frr:frr /etc/frr/vtysh.conf" >> $frrinstall
        #
        # Files prepared, now add them to new VM disks
        echo "   ${node}: Updating VM disk with configuration"
        sudo /usr/bin/guestfish \
            --rw -a ${VM_storage_dir}/${node}_disk.qcow2 -i \
            rm-rf /etc/udev/rules.d/70-persistent-net.rules : \
            upload $iffile /etc/network/interfaces : \
            upload $hostnamefile /etc/hostname : \
            upload $hostfile /etc/hosts : \
            upload $SysCtlFile /etc/sysctl.d/99-sysctl.conf : \
            upload ${Script_Dir}/frr/${FRRpackage} /root/${FRRpackage} : \
            mkdir /etc/frr : \
            upload $frrconf /etc/frr/frr.conf : \
            upload $vtyshconf /etc/frr/vtysh.conf : \
            upload ${Script_Dir}/frr/${FRRdaemons} /etc/frr/daemons : \
            upload $frrinstall /etc/runonce.d/80_frr_install.sh

        rm $iffile
        rm $hostnamefile
        rm $hostfile
        rm $frrconf
        rm $vtyshconf
        rm $frrinstall
    fi
    virsh start $node 2> /dev/null
done
