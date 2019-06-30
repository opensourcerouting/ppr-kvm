#!/usr/bin/env bash
##set -x
#
##### Configuration starts here ##########
# Source VM Template
VM_Template=debian10_template
#
# Mac Address Prefix (first 3 MAC Address Bytes)
MacPrefix="00:1C:44:"
#
# Linux config files
SysCtlFile="node-sysctl.conf"
# FRR
FRRpackage="frr_7.2-dev-20190628-00-g947fb4a43-0_amd64.deb"
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
# Check for Debian or RedHat System to pick correct VM template
if [ -f /etc/redhat-release ]; then
    HostSystem=redhat
elif [ -f /etc/debian_version ]; then
    HostSystem=debian
else
    echo "This is not a RedHat or Debian based system. Aborting"
    exit 1
fi
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
# Get VM Storage directory
VM_storage_dir=$(dirname `virsh dumpxml ${VM_Template} | grep "source file" | grep -o "'.*'" | sed "s/'//g"`)
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
    while var_exists name=${node}_if${ifnum}_phy ; do
        if=${node}_if${ifnum}_bridge
        if var_exists name=${if} ; then
            bridge=${!if}
            BridgeFound=`grep "${bridge}:" /proc/net/dev`
            if ! [ -n "${BridgeFound}" ] ; then
                echo "   $node: interface if$ifnum - Creating Bridge ${bridge}"
                sudo brctl addbr ${bridge} 2> /dev/null
            fi
            sudo ip link set ${bridge} up
            #
        fi
        ifnum=`expr $ifnum + 1`
    done
    #
    if [ "`virsh list --all | grep \ $node\ `" = "" ]; then
        sudo sh -c "pv -B 500M ${VM_Template_disk} > ${VM_storage_dir}/${node}_disk.qcow2"
        node_xml="/tmp/node_$node.xml"
        cp ${Script_Dir}/node-template-${HostSystem}.xml $node_xml
        sed -i "s|__TEMPLATENAME__|$node|g" $node_xml
        sed -i "s|__TEMPLATEDISK__|${VM_storage_dir}/${node}_disk.qcow2|g" $node_xml
        virsh define $node_xml
        rm -rf $node_xml
        # Node defined, now add interfaces
        ifnum=1
        while var_exists name=${node}_if${ifnum}_phy ; do
            bridgeVar=${node}_if${ifnum}_bridge
            if var_exists name=${bridgeVar} ; then
                nodeNrHigh=`expr ${nodeNr} / 256`
                nodeNrLow=`expr ${nodeNr} % 256`
                macaddr=${MacPrefix}`printf "%02x\n" ${nodeNrHigh}`:`printf "%02x\n" ${nodeNrLow}`:`printf "%02x\n" $ifnum`
                echo "   ${node}: Adding Interface $ifnum with MAC $macaddr, connected to ${!bridgeVar}"
                virsh attach-interface $node --model virtio \
                    --type bridge --source ${!bridgeVar} --mac $macaddr --persistent
                #
            fi
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
        ifnum=1
        while var_exists name=${node}_if${ifnum}_phy ; do
            bridgeVar=${node}_if${ifnum}_bridge
            tunnelVar=${node}_if${ifnum}_ipv6tunnel
            phy=${node}_if${ifnum}_phy
            if var_exists name=${bridgeVar} ; then
                phy=${node}_if${ifnum}_phy
                echo "# Interface ${ifnum}, connected to bridge ${!bridgeVar}" >> $iffile
                echo "auto ${!phy}" >> $iffile
                echo "iface ${!phy} inet manual" >> $iffile
                echo "  up ip link set \$IFACE up" >> $iffile
                echo "  down ip link set \$IFACE down" >> $iffile
                echo "iface ${!phy} inet6 manual" >> $iffile
                echo "#" >> $iffile
            elif var_exists name=${tunnelVar} ; then
                echo "# Interface ${ifnum} - ${tunnelVar} IPv6 Tunnel" >> $iffile
                echo "auto ${!phy}" >> $iffile
                echo "iface ${!phy} inet manual" >> $iffile
                tunnelLocalVar=${node}_if${ifnum}_local
                tunnelRemoteVar=${node}_if${ifnum}_remote
                tunnelTTLVar=${node}_if${ifnum}_ttl
                echo "  pre-up ip -6 tunnel add \$IFACE mode ${!tunnelVar} remote ${!tunnelRemoteVar} local ${!tunnelLocalVar} ttl ${!tunnelTTLVar}" >> $iffile
                echo "  post-down ip -6 tunnel del \$IFACE" >> $iffile
                echo "  up ip link set \$IFACE up" >> $iffile
                echo "  down ip link set \$IFACE down" >> $iffile
                echo "iface ${!phy} inet6 manual" >> $iffile
                echo "#" >> $iffile
            else
                phy=${node}_if${ifnum}_phy
                echo "# Loopback ${!phy}" >> $iffile
                echo "auto ${!phy}" >> $iffile
                echo "iface ${!phy} inet loopback" >> $iffile
                echo "#" >> $iffile
            fi
            ifnum=`expr $ifnum + 1`
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
        #
        isisNameVar=${node}_isis_name
        isisTypeVar=${node}_isis_type
        isisAreaVar=${node}_isis_area
        #
        # Config header first
        frrconf=/tmp/node-frrconf-$$
        echo "# FRR Config for node ${node}" > $frrconf
        echo "frr defaults traditional" >> $frrconf
        echo "hostname ${node}" >> $frrconf
        echo "log syslog informational" >> $frrconf
        echo "service integrated-vtysh-config" >> $frrconf
        echo "!" >> $frrconf
        # interface config next
        ifnum=1
        while var_exists name=${node}_if${ifnum}_phy ; do
            bridgeVar=${node}_if${ifnum}_bridge
            ipv6TunnelVar=${node}_if${ifnum}_ipv6tunnel
            phy=${node}_if${ifnum}_phy
            echo "interface ${!phy}" >> $frrconf
            if var_exists name=${bridgeVar} ; then
                echo " description Connected to KVM bridge ${!bridgeVar}" >> $frrconf
            elif var_exists name=${ipv6TunnelVar} ; then
                echo " description IPv6 Tunnel (Mode ${!ipv6TunnelVar})" >> $frrconf
            else
                echo " description Loopback" >> $frrconf
            fi
            ipv4AddrVar=${node}_if${ifnum}_ipv4
            if var_exists name=${ipv4AddrVar} ; then
                for addr in ${!ipv4AddrVar}; do
                    echo " ip address ${addr}" >> $frrconf
                done
            fi
            ipv6AddrVar=${node}_if${ifnum}_ipv6
            if var_exists name=${ipv6AddrVar} ; then
                for addr in ${!ipv6AddrVar}; do
                    echo " ipv6 address ${addr}" >> $frrconf
                done
            fi
            isisIPv4Proc=${node}_if${ifnum}_isis_ipv4
            if var_exists name=${isisIPv4Proc} ; then
                echo " ip router isis ${!isisIPv4Proc}" >> $frrconf
            fi
            isisIPv6Proc=${node}_if${ifnum}_isis_ipv6
            if var_exists name=${isisIPv6Proc} ; then
                echo " ipv6 router isis ${!isisIPv6Proc}" >> $frrconf
            fi
            echo "!" >> $frrconf
            ifnum=`expr $ifnum + 1`
        done
        # Now Add Router ISIS config
        if var_exists name=${isisNameVar} ; then
            echo "router isis ${!isisNameVar}" >> $frrconf
            if var_exists name=${isisTypeVar} ; then
                echo " is-type ${!isisTypeVar}" >> $frrconf
            fi
            echo " net ${!isisAreaVar}" >> $frrconf
            echo " redistribute ipv6 connected level-2" >> $frrconf
            echo "!" >> $frrconf
        fi
        # Now Add Static Router config
        staticnum=1
        while var_exists name=${node}_ipv6static${staticnum}_net ; do
            netvar=${node}_ipv6static${staticnum}_net
            destvar=${node}_ipv6static${staticnum}_dest
            distancevar=${node}_ipv6static${staticnum}_distance
            echo "ipv6 route ${!netvar} ${!destvar} ${!distancevar}" >> $frrconf
            staticnum=`expr $staticnum + 1`
        done
        echo "!" >> $frrconf
        # Finish config
        echo "line vty" >> $frrconf
        echo "!" >> $frrconf
        #
        # /etc/frr/vtysh.conf
        vtyshconf=/tmp/node-vtyshconf-$$
        echo "service integrated-vtysh-config" >> $vtyshconf
        #
        # /etc/runonce.d/80_frr_install.sh
        frrinstall=/tmp/node-frrinstall-$$
        echo "#!/usr/bin/env bash" > $frrinstall
        echo "#" >> $frrinstall
        echo "while [ \"\`which vtysh\`\" = \"\" ] ; do" >> $frrinstall
        echo "  yes \"\" | DEBIAN_FRONTEND=noninteractive dpkg -i /root/${FRRpackage}" >> $frrinstall
        echo "  if [ \"\`which vtysh\`\" == \"\" ] ; then sleep 5; fi" >> $frrinstall
        echo "done" >> $frrinstall
        echo "chown frr:frr /etc/frr" >> $frrinstall
        echo "chown frr:frr /etc/frr/frr.conf" >> $frrinstall
        echo "chown frr:frr /etc/frr/daemons" >> $frrinstall
        echo "chown frr:frr /etc/frr/vtysh.conf" >> $frrinstall
        echo "rm -f /root/${FRRpackage}" >> $frrinstall
        #
        # /etc/runboot.d
        startnum=1
        bootupfile=/tmp/startup-$$
        echo "#!/usr/bin/env bash" > $bootupfile
        echo "#" >> $bootupfile
        while var_exists name=${node}_start${startnum} ; do
            line=${node}_start${startnum}
            echo "${!line}" >> $bootupfile
            startnum=`expr $startnum + 1`            
        done
        #
        # /etc/runboot.d/10_tunnels.sh
        tunnelSetNum=1
        tunnelcfgfile=/tmp/tunnel-config-$$
        cp ${Script_Dir}/make_static_tunnels.sh $tunnelcfgfile
        echo "#" >> $tunnelcfgfile
        while var_exists name=${node}_tunnelset${tunnelSetNum}_count ; do
            line=${node}_tunnelset${tunnelSetNum}
            echo "#" >> $tunnelcfgfile
            echo "# Tunnel Set ${tunnelSetNum}" >> $tunnelcfgfile
            echo "#" >> $tunnelcfgfile
            numTunnelsVar=${node}_tunnelset${tunnelSetNum}_count
            startTunVar=${node}_tunnelset${tunnelSetNum}_start
            tunModeVar=${node}_tunnelset${tunnelSetNum}_mode
            tunSideVar=${node}_tunnelset${tunnelSetNum}_thisSide
            tunSourceVar=${node}_tunnelset${tunnelSetNum}_srcPrefix
            tunDestVar=${node}_tunnelset${tunnelSetNum}_dstPrefix
            tunNetVar=${node}_tunnelset${tunnelSetNum}_netPrefix
            echo "make_tunnels startTun=${!startTunVar} numTunnels=${!numTunnelsVar} tunSide=${!tunSideVar} tunMode=${!tunModeVar} tunSource=${!tunSourceVar} tunDest=${!tunDestVar} tunNet=${!tunNetVar}"  >> $tunnelcfgfile
            tunnelSetNum=`expr $tunnelSetNum + 1`            
        done
        #
        # Files prepared, now add them to new VM disks
        echo "   ${node}: Updating VM disk with configuration"
        sudo /usr/bin/guestfish \
            --rw -a ${VM_storage_dir}/${node}_disk.qcow2 -i \
            rm-rf /etc/udev/rules.d/70-persistent-net.rules : \
            upload $iffile /etc/network/interfaces : \
            upload $hostnamefile /etc/hostname : \
            upload $hostfile /etc/hosts : \
            upload ${Script_Dir}/$SysCtlFile /etc/sysctl.d/99-sysctl.conf : \
            upload ${Script_Dir}/frr/${FRRpackage} /root/${FRRpackage} : \
            mkdir /etc/frr : \
            upload $frrconf /etc/frr/frr.conf : \
            upload $vtyshconf /etc/frr/vtysh.conf : \
            upload ${Script_Dir}/frr/${FRRdaemons} /etc/frr/daemons : \
            upload $frrinstall /etc/runonce.d/80_frr_install.sh : \
            upload $tunnelcfgfile /etc/runboot.d/20_make_tunnels.sh

        rm $iffile
        rm $hostnamefile
        rm $hostfile
        rm $frrconf
        rm $vtyshconf
        rm $frrinstall
        rm $tunnelcfgfile
    fi
    virsh start $node 2> /dev/null
done

# Process external interface
for extif in ${global_phyif}; do
    echo "Processing external Interface ${extif}"
    bridgeVar=${extif}_bridge
    phyVar=${extif}_phy
    if var_exists name=${bridgeVar} ; then
        echo "   External Interface ${extif}: interface ${!phyVar} added to bridge ${!bridgeVar}"
        sudo brctl addif ${!bridgeVar} ${!phyVar} 2> /dev/null
        sudo ip link set ${!phyVar} up
    fi
done
