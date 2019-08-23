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
FRRpackage="frr_7.2-dev-20190720-00-ga89793d6e-0_amd64.deb"
FRRsysrepo="frr-sysrepo_7.2-dev-20190720-00-ga89793d6e-0_amd64.deb"
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

function get_lo_v6addr {
    local node=$1
    ifnum=1
    ipv6Loopback=""
    while var_exists name=${node}_if${ifnum}_phy ; do
        bridgeVar=${node}_if${ifnum}_bridge
        ipv6TunnelVar=${node}_if${ifnum}_ipv6tunnel
        phy=${node}_if${ifnum}_phy
        if var_exists name=${bridgeVar} ; then
            continue
        elif var_exists name=${ipv6TunnelVar} ; then
            continue
        else
            # Found Loopback - get IPv6
            ipv6AddrVar=${node}_if${ifnum}_ipv6
            if var_exists name=${ipv6AddrVar} ; then
                for addr in ${!ipv6AddrVar}; do
                    ipv6Loopback=${addr}
                    break
                done
            fi
            break
        fi
    done
}

function get_if_v6addr {
    local inpStr=$1

    if var_exists name=${inpStr}_ipv6 ; then
        ipv6AddrVar=${inpStr}_ipv6
        ipv6Addr=${!ipv6AddrVar}
    fi
}

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
    nodeNr=`expr ${nodeNr} + 1`
    #
    # Check for external node
    nodeExtern=false
    if var_exists name=${node}_external ; then
        ext_name=${node}_external
        nodeExtern=${!extVar}
    fi
    if $nodeExtern ; then
        echo "Processing physical node $node"
    else
        echo "Processing virtual node $node"
    fi
    #
    # By default, no BGP or ISIS protocol daemon
    daemon_isisd="no"
    daemon_bgpd="no"
    #
    if ! $nodeExtern ; then
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
    fi
    #
    if [ "`virsh list --all | grep \ $node\ `" = "" ]; then
        if ! $nodeExtern ; then
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
            if var_exists name=${node}_dhcpif ; then
                nodeNrHigh=`expr ${nodeNr} / 256`
                nodeNrLow=`expr ${nodeNr} % 256`
                macaddr=${MacPrefix}`printf "%02x\n" ${nodeNrHigh}`:`printf "%02x\n" ${nodeNrLow}`:`printf "%02x\n" $ifnum`
                echo "   ${node}: Adding DHCP Interface $ifnum with MAC $macaddr, connected to virbr0"
                virsh attach-interface $node --model virtio \
                    --type bridge --source virbr0 --mac $macaddr --persistent
            fi
        fi
        # Interfaces added. Now adjust node config
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
                vrfVar=${node}_if${ifnum}_vrf
                if $nodeExtern ; then
                    if var_exists name=${vrfVar} ; then
                        echo "# Interface ${ifnum} - VRF ${!vrfVar}" >> $iffile
                    else
                        echo "# Interface ${ifnum}" >> $iffile
                    fi
                else
                    if var_exists name=${vrfVar} ; then
                        echo "# Interface ${ifnum} - VRF ${!vrfVar}, connected to bridge ${!bridgeVar}" >> $iffile
                    else
                        echo "# Interface ${ifnum}, connected to bridge ${!bridgeVar}" >> $iffile
                    fi
                fi
                echo "auto ${!phy}" >> $iffile
                frr_enable_var=${node}_if${ifnum}_frr
                if_ipv4=${node}_if${ifnum}_ipv4
                if [ "${!frr_enable_var}" = "false" ] && [ "${!if_ipv4}" != "" ] ; then
                    echo "iface ${!phy} inet static" >> $iffile
                    echo "# Manual IPv4 Interface outside FRR" >> $iffile
                    echo "  address ${!if_ipv4}" >> $iffile
                    if_ipv4gw=${node}_if${ifnum}_ipv4gw
                    if [ "${!if_ipv4gw}" != "" ] ; then
                        echo "  gateway ${!if_ipv4gw}" >> $iffile
                        echo "  nameserver ${!if_ipv4gw}" >> $iffile
                    fi
                else
                    echo "iface ${!phy} inet manual" >> $iffile
                    echo "  up ip link set \$IFACE up" >> $iffile
                    if var_exists name=${vrfVar} ; then
                        echo "  up ip link add name ${!vrfVar} type vrf table `expr 10 + ${ifnum}`" >> $iffile
                        echo "  up ip link set ${!vrfVar} up" >> $iffile
                        echo "  up ip link set \$IFACE master ${!vrfVar}" >> $iffile
                    fi
                    echo "  down ip link set \$IFACE down" >> $iffile
                    if var_exists name=${vrfVar} ; then
                        echo "  down ip link delete name ${!vrfVar}" >> $iffile
                    fi
                fi
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
        if var_exists name=${node}_dhcpif ; then
            dhcpifVar=${node}_dhcpif
            echo "# Primary Mgmt (DHCP) Interface ${!dhcpifVar}" >> $iffile
            echo "allow-hotplug ${!dhcpifVar}" >> $iffile
            echo "iface ${!dhcpifVar} inet dhcp" >> $iffile
            echo "#" >> $iffile
        fi
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
        # Config header first
        frrconf=/tmp/node-frrconf-$$
        echo "# FRR Config for node ${node}" > $frrconf
        echo "frr defaults traditional" >> $frrconf
        echo "hostname ${node}" >> $frrconf
        echo "log syslog informational" >> $frrconf
        echo "service integrated-vtysh-config" >> $frrconf
        echo "!" >> $frrconf
        echo "debug isis ppr" >> $frrconf
        echo "!" >> $frrconf
        # Now Add Static Router config
        staticnum=1
        while var_exists name=${node}_ipv6static${staticnum}_net ; do
            netvar=${node}_ipv6static${staticnum}_net
            destvar=${node}_ipv6static${staticnum}_dest
            distancevar=${node}_ipv6static${staticnum}_distance
            if var_exists name=${node}_ipv6static${staticnum}_vrf ; then
                vrfvar=${node}_ipv6static${staticnum}_vrf
                echo "vrf ${!vrfvar}" >> $frrconf
                echo " ipv6 route ${!netvar} ${!destvar} ${!distancevar}" >> $frrconf
                echo " exit-vrf" >> $frrconf
            else
                echo "ipv6 route ${!netvar} ${!destvar} ${!distancevar}" >> $frrconf
            fi
            staticnum=`expr $staticnum + 1`
        done
        echo "!" >> $frrconf
        # interface config next
        ifnum=1
        while var_exists name=${node}_if${ifnum}_phy ; do
            frr_enable_var=${node}_if${ifnum}_frr
            if [ "${!frr_enable_var}" != "false" ] ; then
                bridgeVar=${node}_if${ifnum}_bridge
                ipv6TunnelVar=${node}_if${ifnum}_ipv6tunnel
                phy=${node}_if${ifnum}_phy
                if var_exists name=${node}_if${ifnum}_vrf ; then
                    vrfvar=${node}_if${ifnum}_vrf
                    echo "interface ${!phy} vrf ${!vrfvar}" >> $frrconf
                else
                    echo "interface ${!phy}" >> $frrconf
                fi
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
                isisNet=${node}_if${ifnum}_isis_network
                if var_exists name=${isisNet} ; then
                    echo " isis network ${!isisNet}" >> $frrconf
                fi
                echo "!" >> $frrconf
            fi
            ifnum=`expr $ifnum + 1`
        done
        # Now Add Route BGP config
        if var_exists name=${node}_bgp_as ; then
            daemon_bgpd="yes"
            bgpASVar=${node}_bgp_as
            echo "router bgp ${!bgpASVar}" >> $frrconf
            routerIDVar=${node}_bgp_id
            echo " bgp router-id ${!routerIDVar}" >> $frrconf
            neighborCount=1
            while var_exists name=${node}_bgp_neighbor${neighborCount}_as ; do
                neighborASvar=${node}_bgp_neighbor${neighborCount}_as
                neighborIPvar=${node}_bgp_neighbor${neighborCount}_ip
                echo " neighbor ${!neighborIPvar} remote-as ${!neighborASvar}" >> $frrconf
                echo " neighbor ${!neighborIPvar} update-source lo" >> $frrconf
                neighborCount=`expr $neighborCount + 1`
            done
            echo "!" >> $frrconf
            neighborCount=1
            while var_exists name=${node}_bgp_neighbor${neighborCount}_as ; do
                neighborAddrFamVar=${node}_bgp_neighbor${neighborCount}_addrfamily
                if var_exists name=${neighborAddrFamVar} ; then
                    neighborIPvar=${node}_bgp_neighbor${neighborCount}_ip
                    echo " address-family ${!neighborAddrFamVar}" >> $frrconf
                    echo "  neighbor ${!neighborIPvar} activate" >> $frrconf
                    echo " exit-address-family" >> $frrconf
                fi
                neighborCount=`expr $neighborCount + 1`
            done
            echo "!" >> $frrconf
            vrfCount=1
            while var_exists name=${node}_bgp_vrf${vrfCount}_name ; do
                vrfNameVar=${node}_bgp_vrf${vrfCount}_name
                vrfLabelVar=${node}_bgp_vrf${vrfCount}_label
                vrfRDVar=${node}_bgp_vrf${vrfCount}_rd
                echo "router bgp ${!bgpASVar} vrf ${!vrfNameVar}" >> $frrconf
                echo " !" >> $frrconf
                echo " address-family ipv6 unicast" >> $frrconf
                echo "  redistribute static" >> $frrconf
                echo "  label vpn export ${!vrfLabelVar}" >> $frrconf
                echo "  rd vpn export ${!vrfRDVar}" >> $frrconf
                echo "  rt vpn both ${!vrfRDVar}" >> $frrconf
                echo "  export vpn" >> $frrconf
                echo "  import vpn" >> $frrconf
                echo " exit-address-family" >> $frrconf
                echo "!" >> $frrconf
                vrfCount=`expr $vrfCount + 1`
            done
        fi
        echo "!" >> $frrconf
        # Now Add PPR config
        tunnelSetNum=1
        echo "ppr group PPRLAB" >> $frrconf
        while var_exists name=${node}_tunnelset${tunnelSetNum}_count ; do
            line=${node}_tunnelset${tunnelSetNum}
            numTunnelsVar=${node}_tunnelset${tunnelSetNum}_count
            startTunVar=${node}_tunnelset${tunnelSetNum}_start
            tunModeVar=${node}_tunnelset${tunnelSetNum}_mode
            tunSideVar=${node}_tunnelset${tunnelSetNum}_thisSide
            tunNetVar=${node}_tunnelset${tunnelSetNum}_netPrefix
            if [ "${!tunSideVar}" = "Dest" ] ; then
                tunThisSideVar=${node}_tunnelset${tunnelSetNum}_dstPrefix
                tunOtherSideVar=${node}_tunnelset${tunnelSetNum}_srcPrefix
            else
                tunThisSideVar=${node}_tunnelset${tunnelSetNum}_srcPrefix
                tunOtherSideVar=${node}_tunnelset${tunnelSetNum}_dstPrefix
            fi                    
            for((i=1; i<=${!numTunnelsVar}; i++)) ; do
                dec=`expr ${!startTunVar} + $i`
                hex=$(printf '%x' $dec)
                echo " ppr ipv6 ${!tunThisSideVar}::${hex}/128 prefix ${!tunOtherSideVar}::${hex}/128" >> $frrconf
                pprVar=${node}_ppr${i}
                for step in ${!pprVar}; do
                    if [[ $step =~ "_" ]] ; then
                        get_if_v6addr ${step}
                        echo "  pde ipv6-interface ${ipv6Addr}"  >> $frrconf
                    else
                        get_lo_v6addr ${step}
                        echo "  pde ipv6-node ${ipv6Loopback}"  >> $frrconf
                    fi
                done
                echo "  exit" >> $frrconf
            done
            tunnelSetNum=`expr $tunnelSetNum + 1`            
        done
        echo "!" >> $frrconf
        # Now Add Router ISIS config
        isisNameVar=${node}_isis_name
        isisTypeVar=${node}_isis_type
        isisAreaVar=${node}_isis_area
        if var_exists name=${isisNameVar} ; then
            daemon_isisd="yes"
            #
            echo "router isis ${!isisNameVar}" >> $frrconf
            if var_exists name=${isisTypeVar} ; then
                echo " is-type ${!isisTypeVar}" >> $frrconf
            fi
            echo " net ${!isisAreaVar}" >> $frrconf
            if [ "${global_redistributeHostRoutes}" = "true" ]; then
                echo " redistribute ipv6 static level-1" >> $frrconf
            fi
            echo " topology ipv6-unicast" >> $frrconf
            echo " ppr on" >> $frrconf
            echo " ppr advertise PPRLAB" >> $frrconf
            echo "!" >> $frrconf
        fi
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
        echo "while [ ! -f '/usr/lib/x86_64-linux-gnu/frr/modules/sysrepo.so' ] ; do" >> $frrinstall
        echo "  yes \"\" | DEBIAN_FRONTEND=noninteractive dpkg -i /root/${FRRsysrepo}" >> $frrinstall
        echo "  if [ ! -f '/usr/lib/x86_64-linux-gnu/frr/modules/sysrepo.so' ] ; then sleep 5; fi" >> $frrinstall
        echo "done" >> $frrinstall
        echo "rm -f /root/${FRRsysrepo}" >> $frrinstall
        sysrepo_enable_var=${node}_service_sysrepod
        if [ "${!sysrepo_enable_var}" = "true" ]; then
            echo "sysrepoctl --install --yang /usr/share/yang/frr-interface.yang" >> $frrinstall
            echo "sysrepoctl --install --yang /usr/share/yang/frr-isisd.yang" >> $frrinstall
            echo "sysrepoctl --install --yang /usr/share/yang/frr-ppr.yang" >> $frrinstall
            echo "/usr/bin/systemctl enable sysrepod.service" >> $frrinstall
            echo "/usr/bin/systemctl start sysrepod.service" >> $frrinstall
            netopeer2server_enable_var=${node}_service_netopeer2server
            if [ "${!netopeer2server_enable_var}" = "true" ]; then
                echo "/usr/bin/systemctl enable netopeer2-server.service" >> $frrinstall
                echo "/usr/bin/systemctl start netopeer2-server.service" >> $frrinstall
            fi
        fi
        #
        # /etc/runboot.d/20_make_tunnels.sh
        tunnelSetNum=1
        tunnelcfgfile=/tmp/tunnel-config-$$
        cp ${Script_Dir}/make_static_tunnels.sh $tunnelcfgfile
        # Look for a VRF in config - only support 1 VRF right now (first one)
        unset ifVRF
        ifnum=1
        while var_exists name=${node}_if${ifnum}_phy ; do
            vrfVar=${node}_if${ifnum}_vrf
            if var_exists name=${vrfVar} ; then
                ifVRF=${!vrfVar}
                break
            fi
            ifnum=`expr $ifnum + 1`
        done
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
            if var_exists name=ifVRF ; then
                echo "make_tunnels startTun=${!startTunVar} numTunnels=${!numTunnelsVar} tunSide=${!tunSideVar} tunMode=${!tunModeVar} tunSource=${!tunSourceVar} tunDest=${!tunDestVar} tunNet=${!tunNetVar} ifVRF=${ifVRF}"  >> $tunnelcfgfile
            else
                echo "make_tunnels startTun=${!startTunVar} numTunnels=${!numTunnelsVar} tunSide=${!tunSideVar} tunMode=${!tunModeVar} tunSource=${!tunSourceVar} tunDest=${!tunDestVar} tunNet=${!tunNetVar}"  >> $tunnelcfgfile
            fi
            tunnelSetNum=`expr $tunnelSetNum + 1`            
        done
        #
        # /etc/frr/daemons file
        daemoncfgfile=/tmp/daemons-$$
        cp ${Script_Dir}/frr/${FRRdaemons} ${daemoncfgfile}
        sed -i "s/isisd=.*/isisd=${daemon_isisd}/g" ${daemoncfgfile}
        sed -i "s/bgpd=.*/bgpd=${daemon_bgpd}/g" ${daemoncfgfile}
        #
        if $nodeExtern ; then
            echo "   ${node}: Creating config_${node} directory with configuration for node"
            rm -rf config_${node}
            install -D -m644 $iffile config_${node}/etc/network/interfaces
            install -D -m644 $hostnamefile config_${node}/etc/hostname
            install -D -m644 $hostfile config_${node}/etc/hosts
            install -D -m644 ${Script_Dir}/modules.conf config_${node}/etc/modules-load.d/modules.conf
            install -D -m644 ${Script_Dir}/$SysCtlFile config_${node}/etc/sysctl.d/99-sysctl.conf
            install -D -m644 ${Script_Dir}/frr/${FRRpackage} config_${node}/root/${FRRpackage}
            install -D -m644 $frrconf config_${node}/etc/frr/frr.conf
            install -D -m644 $vtyshconf config_${node}/etc/frr/vtysh.conf
            install -D -m644 ${daemoncfgfile} config_${node}/etc/frr/daemons
            install -D -m755 ${Script_Dir}/rc.local config_${node}/etc/rc.local
            install -D -m755 $frrinstall config_${node}/etc/runonce.d/80_frr_install.sh
            install -D -m755 $tunnelcfgfile config_${node}/etc/runboot.d/20_make_tunnels.sh
        else
            # Files prepared, now add them to new VM disks
            echo "   ${node}: Updating VM disk with configuration"
            sudo /usr/bin/guestfish \
                --rw -a ${VM_storage_dir}/${node}_disk.qcow2 -i \
                rm-rf /etc/udev/rules.d/70-persistent-net.rules : \
                upload $iffile /etc/network/interfaces : \
                upload $hostnamefile /etc/hostname : \
                upload $hostfile /etc/hosts : \
                upload ${Script_Dir}/modules.conf /etc/modules-load.d/modules.conf : \
                upload ${Script_Dir}/$SysCtlFile /etc/sysctl.d/99-sysctl.conf : \
                upload ${Script_Dir}/frr/${FRRpackage} /root/${FRRpackage} : \
                upload ${Script_Dir}/frr/${FRRsysrepo} /root/${FRRsysrepo} : \
                mkdir /etc/frr : \
                upload $frrconf /etc/frr/frr.conf : \
                upload $vtyshconf /etc/frr/vtysh.conf : \
                upload ${daemoncfgfile} /etc/frr/daemons : \
                upload $frrinstall /etc/runonce.d/80_frr_install.sh : \
                upload $tunnelcfgfile /etc/runboot.d/20_make_tunnels.sh
        fi
        rm $iffile
        rm $hostnamefile
        rm $hostfile
        rm $frrconf
        rm $vtyshconf
        rm $frrinstall
        rm $tunnelcfgfile
        rm $daemoncfgfile
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
