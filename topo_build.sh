#!/usr/bin/env bash
##set -x
#
##### Configuration starts here ##########
# Source VM Template (VLC Template is optional, but will speed up repeated deployment)
VM_Template=debian10_template
VM_Template_with_VLC=debian10_vlc_template
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
# Update file cache first
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
${DIR}/update_cache.py
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
if var_exists name=VM_Template_with_VLC ; then
    if [ "`virsh list --state-shutoff --all | grep \ $VM_Template_with_VLC`" == "" ] ; then
        echo "Template VM $VM_Template not found or not turned off"
        exit 1
    fi
fi
#
# Get Source disk file from template VM
VM_Template_disk=`virsh dumpxml ${VM_Template} | grep "source file" | grep -o "'.*'" | sed "s/'//g"`
if var_exists name=VM_Template_with_VLC ; then
    VM_Template_VLC_disk=`virsh dumpxml ${VM_Template_with_VLC} | grep "source file" | grep -o "'.*'" | sed "s/'//g"`
else
    # no VLC template - use normal template and let VLC install itself during boot of VM
    VM_Template_VLC_disk=${VM_Template_disk}
fi
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
    # Wipe previous config staging directory and recreate it
    rm -rf config_${node}
    install -d -m755 config_${node}/root/extras
    #
    # By default, run FRR unless disabled
    frrInstall="true"
    frrVar=${node}_frr
    if var_exists name=${frrVar} ; then
        if [ "${!frrVar}" == "false" ] ; then
            frrInstall="false"
        fi
    fi
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
            # Video Server / Client use template with VLC pre-installed if it exists
            if var_exists name=${node}_video ; then
                echo "Using Video Template ${VM_Template_VLC_disk}"
                sudo sh -c "pv -B 500M ${VM_Template_VLC_disk} > ${VM_storage_dir}/${node}_disk.qcow2"
            else
                echo "Using Template ${VM_Template_disk}"
                sudo sh -c "pv -B 500M ${VM_Template_disk} > ${VM_storage_dir}/${node}_disk.qcow2"
            fi
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
                        echo "  dns-nameserver ${!if_ipv4gw}" >> $iffile
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
        #
        # Add PPR Paths
        pprsetcnt=1
        while var_exists name=${node}_pprset${pprsetcnt}_group ; do
            pprGroupVar=${node}_pprset${pprsetcnt}_group
            pprIDbaseVar=${node}_pprset${pprsetcnt}_id
            pprPrefixBaseVar=${node}_pprset${pprsetcnt}_id_prefix
            pprIDstartVar=${node}_pprset${pprsetcnt}_id_start
            pprRepeatVar=${node}_pprset${pprsetcnt}_repeat
            nextPPR=$(printf '%d' "0x${!pprIDstartVar}")
            pprRepeat=${!pprRepeatVar}
            echo "ppr group ${!pprGroupVar}" >> $frrconf
            while [ $pprRepeat -gt 0 ] ; do
                pprcnt=1
                while var_exists name=${node}_pprset${pprsetcnt}_ppr${pprcnt} ; do
                    nextPPRhex=$(printf '%x' $nextPPR)
                    echo " ppr ipv6 ${!pprIDbaseVar}${nextPPRhex}/128 prefix ${!pprPrefixBaseVar}${nextPPRhex}/128" >> $frrconf
                    pprVar=${node}_pprset${pprsetcnt}_ppr${pprcnt}
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
                    nextPPR=`expr $nextPPR + 1`
                    pprcnt=`expr $pprcnt + 1`
                done
                pprRepeat=`expr $pprRepeat - 1`
            done
            pprsetcnt=`expr $pprsetcnt + 1`
        done
        echo "!" >> $frrconf
        #
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
            pprsetcnt=1
            while var_exists name=${node}_pprset${pprsetcnt}_group ; do
                pprGroupVar=${node}_pprset${pprsetcnt}_group
                echo " ppr advertise ${!pprGroupVar}" >> $frrconf
                pprsetcnt=`expr $pprsetcnt + 1`
            done
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
        frrsetup=/tmp/node-frrsetup-$$
        echo "#!/usr/bin/env bash" > $frrsetup
        echo "#" >> $frrsetup
        if [ "${frrInstall}" == "false" ] ; then
            echo "# FRR not installed on this node" >> $frrsetup
            echo "rm -rf /etc/frr" >> $frrsetup
        else
            # Run FRR on this node
            install -D -m644 ${Script_Dir}/cache/${FRRpackage} config_${node}/root/extras/${FRRpackage}
            install -D -m644 ${Script_Dir}/cache/${FRRsysrepo} config_${node}/root/extras/${FRRsysrepo}
            echo "while [ \"\`which vtysh\`\" = \"\" ] ; do" >> $frrsetup
            echo "  yes \"\" | DEBIAN_FRONTEND=noninteractive dpkg -i /root/extras/${FRRpackage}" >> $frrsetup
            echo "  if [ \"\`which vtysh\`\" == \"\" ] ; then sleep 5; fi" >> $frrsetup
            echo "done" >> $frrsetup
            echo "chown frr:frr /etc/frr" >> $frrsetup
            echo "chown frr:frr /etc/frr/frr.conf" >> $frrsetup
            echo "chown frr:frr /etc/frr/daemons" >> $frrsetup
            echo "chown frr:frr /etc/frr/vtysh.conf" >> $frrsetup
            echo "rm -f /root/extras/${FRRpackage}" >> $frrsetup
            echo "while [ ! -f '/usr/lib/x86_64-linux-gnu/frr/modules/sysrepo.so' ] ; do" >> $frrsetup
            echo "  yes \"\" | DEBIAN_FRONTEND=noninteractive dpkg -i /root/extras/${FRRsysrepo}" >> $frrsetup
            echo "  if [ ! -f '/usr/lib/x86_64-linux-gnu/frr/modules/sysrepo.so' ] ; then sleep 5; fi" >> $frrsetup
            echo "done" >> $frrsetup
            echo "rm -f /root/extras/${FRRsysrepo}" >> $frrsetup
            sysrepo_enable_var=${node}_service_sysrepod
            if [ "${!sysrepo_enable_var}" = "true" ]; then
                echo "sysrepoctl --install --yang /usr/share/yang/frr-interface.yang" >> $frrsetup
                echo "sysrepoctl --install --yang /usr/share/yang/frr-isisd.yang" >> $frrsetup
                echo "sysrepoctl --install --yang /usr/share/yang/frr-ppr.yang" >> $frrsetup
                install -D -m644 ${Script_Dir}/extras/sysrepod.service config_${node}/root/extras/
                echo "cp /root/extras/sysrepod.service /lib/systemd/system/" >> $frrsetup
                echo "/usr/bin/systemctl enable sysrepod.service" >> $frrsetup
                echo "/usr/bin/systemctl start sysrepod.service" >> $frrsetup
                netopeer2server_enable_var=${node}_service_netopeer2server
                if [ "${!netopeer2server_enable_var}" = "true" ]; then
                    install -D -m644 ${Script_Dir}/extras/netopeer2-server.service config_${node}/root/extras/
                    echo "cp /root/extras/netopeer2-server.service /lib/systemd/system/" >> $frrsetup
                    echo "/usr/bin/systemctl enable netopeer2-server.service" >> $frrsetup
                    echo "/usr/bin/systemctl start netopeer2-server.service" >> $frrsetup
                fi
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
        # /etc/runonce.d/10_extra_install.sh
        extrasinstall=/tmp/node-extrasinstall-$$
        echo "#!/usr/bin/env bash" > $extrasinstall
        #
        # UDP Ping Servers
        #
        udpServerStartVar=${node}_udpecho_server_startport
        if var_exists name=${udpServerStartVar} ; then
            echo "#" >> $extrasinstall
            echo "# UDP Echo Servers" >> $extrasinstall
            udpServerCountVar=${node}_udpecho_server_count
            install -D -m644 ${Script_Dir}/extras/udp6-echo@.service config_${node}/root/extras/udp6-echo@.service
            echo "mv /root/extras/udp6-echo@.service /lib/systemd/system/" >> $extrasinstall
            udpServerEnd=`expr ${!udpServerStartVar} + ${!udpServerCountVar} - 1`
            for (( i=${!udpServerStartVar}; i<=${udpServerEnd}; i++)) ; do
                echo "#   - Echo Server at port ${i}" >> $extrasinstall
                echo "systemctl enable udp6-echo@${i}.service" >> $extrasinstall
                echo "systemctl start udp6-echo@${i}.service" >> $extrasinstall
            done
        fi
        #
        # UDP Ping Clients
        #
        udpClient=1
        while var_exists name=${node}_udpecho_client${udpClient} ; do
            udpClientNameVar=${node}_udpecho_client${udpClient}
            udpClientDestVar=${node}_udpecho_client${udpClient}_dest
            udpClientStartVar=${node}_udpecho_client${udpClient}_startport
            udpClientCountVar=${node}_udpecho_client${udpClient}_count
            echo "#" >> $extrasinstall
            echo "# UDP Echo Servers" >> $extrasinstall
            udpClientEnd=`expr ${!udpClientStartVar} + ${!udpClientCountVar} - 1`
            for (( i=${!udpClientStartVar}; i<=${udpClientEnd}; i++)) ; do
                udpclient=config_${node}/root/extras/udpping_${!udpClientNameVar}_${i}.sh
                get_if_v6addr ${!udpClientDestVar}
                ipv6Addr=`echo $ipv6Addr | cut -f1 -d"/"`
                echo "/usr/local/bin/udpping.py ${ipv6Addr} ${i}" >> $udpclient
            done
            if [ $udpClient == 1 ] ; then
                # Only need to do this once for all UDP clients - do it for first one
                echo "chmod 755 /root/extras/udpping*" >> $extrasinstall
                echo "mv /root/extras/udpping* /home/ppr-lab/" >> $extrasinstall
                echo "chown ppr-lab:ppr-lab /home/ppr-lab/udpping*" >> $extrasinstall
            fi
            udpClient=`expr $udpClient + 1`            
        done
        #
        # Video Server / Client processing
        if var_exists name=${node}_video ; then
            echo "#" >> $extrasinstall
            echo "dpkg -l | grep vlc > /dev/null" >> $extrasinstall
            echo "if [ \$? != 0 ]; then" >> $extrasinstall
            echo "   # Video Server/Client - install VLC (but ignore errors if offline)" >> $extrasinstall
            echo "   echo ''" >> $extrasinstall
            echo "   echo 'Installing VLC - Please wait'" >> $extrasinstall
            echo "   echo ''" >> $extrasinstall
            echo "   /usr/bin/apt-get install -y vlc >/dev/null 2> /dev/null | true" >> $extrasinstall
            echo "fi" >> $extrasinstall
            echo "#" >> $extrasinstall
            #
            # Video Servers
            #
            videoServerNum=1
            while var_exists name=${node}_video_server_movie${videoServerNum} ; do
                movieVar=${node}_video_server_movie${videoServerNum}
                movieDestVar=${node}_video_server_movie${videoServerNum}_dest
                moviePortVar=${node}_video_server_movie${videoServerNum}_port
                install -D -m644 ${Script_Dir}/cache/${!movieVar} config_${node}/root/extras/
                movieServer=config_${node}/root/extras/movie_to_port${!moviePortVar}.sh
                get_if_v6addr ${!movieDestVar}
                ipv6Addr=`echo $ipv6Addr | cut -f1 -d"/"`
                echo "# Stream Movie ${videoServerNum}" > $movieServer
                echo "#" >> $movieServer
                echo "# Movie: ${!movieVar}" >> $movieServer
                echo "# Send to ${!movieDestVar} at ${ipv6Addr}, Port ${!moviePortVar}" >> $movieServer
                echo "#" >> $movieServer
                echo "cvlc -A alsa,none /home/ppr-lab/movies/${!movieDestVar} --noaudio --loop --sout udp://[${ipv6Addr}]:${!moviePortVar}" >> $movieServer
                movieServer=config_${node}/root/extras/movie_${!movieDestVar}_port${!moviePortVar}.service
                echo "[Unit]" > $movieServer
                echo "Description=Movie to ${!movieDestVar} at ${ipv6Addr} Port ${!moviePortVar}" >> $movieServer
                echo "After=network.target" >> $movieServer
                echo "#" >> $movieServer
                echo "[Service]" >> $movieServer
                echo "Type=exec" >> $movieServer
                echo "KillMode=process" >> $movieServer
                echo "User=ppr-lab" >> $movieServer
                echo "ExecStart=/usr/bin/cvlc -A alsa,none ~ppr-lab/movies/${!movieVar} --noaudio --loop --sout udp://[${ipv6Addr}]:${!moviePortVar}" >> $movieServer
                echo "#" >> $movieServer
                echo "[Install]" >> $movieServer
                echo "WantedBy=multi-user.target" >> $movieServer
                #
                if [ $videoServerNum == 1 ] ; then
                    # Only need this once for all movies
                    echo "# Video Servers" >> $extrasinstall
                    echo "#" >> $extrasinstall
                    echo "# Move Videos to ppr-lab user" >> $extrasinstall
                    echo "install -d -m755 -o ppr-lab -g ppr-lab ~ppr-lab/movies" >> $extrasinstall
                    echo "mv /root/extras/*.mp4 ~ppr-lab/movies/" >> $extrasinstall
                    echo "chown ppr-lab:ppr-lab ~ppr-lab/movies/*" >> $extrasinstall
                    echo "mv /root/extras/movie*.sh ~ppr-lab/" >> $extrasinstall
                    echo "chown ppr-lab:ppr-lab ~ppr-lab/movie*.sh" >> $extrasinstall
                    echo "chmod 755 ~ppr-lab/movie*.sh" >> $extrasinstall
                    echo "#" >> $extrasinstall
                fi
                echo "mv /root/extras/movie_${!movieDestVar}_port${!moviePortVar}.service /lib/systemd/system/" >> $extrasinstall
                echo "systemctl enable movie_${!movieDestVar}_port${!moviePortVar}.service" >> $extrasinstall
                echo "systemctl start movie_${!movieDestVar}_port${!moviePortVar}.service" >> $extrasinstall
                videoServerNum=`expr $videoServerNum + 1`
            done
            # Video Clients
            #
            videoClientNum=1
            while var_exists name=${node}_video_clientport${videoClientNum} ; do
                moviePortVar=${node}_video_clientport${videoClientNum}
                movieClient=config_${node}/root/extras/vlc_play_port${!moviePortVar}.sh
                echo "vlc udp://@:${!moviePortVar}" > $movieClient
                if [ $videoClientNum == 1 ] ; then
                    # Only need this once for all movies
                    echo "# Video Client Scripts" >> $extrasinstall
                    echo "#" >> $extrasinstall
                    echo "# Move Videos to ppr-lab user" >> $extrasinstall
                    echo "install -D -m755 -o ppr-lab -g ppr-lab /root/extras/vlc_play*.sh ~ppr-lab/" >> $extrasinstall
                    echo "rm /root/extras/vlc_play*.sh" >> $extrasinstall
                fi
                videoClientNum=`expr $videoClientNum + 1`
            done
        fi
        #
        #
        if $nodeExtern ; then
            echo "   ${node}: Creating config_${node} directory with configuration for node"
            install -D -m644 $iffile config_${node}/etc/network/interfaces
            install -D -m644 $hostnamefile config_${node}/etc/hostname
            install -D -m644 $hostfile config_${node}/etc/hosts
            install -D -m644 ${Script_Dir}/modules.conf config_${node}/etc/modules-load.d/modules.conf
            install -D -m644 ${Script_Dir}/$SysCtlFile config_${node}/etc/sysctl.d/99-sysctl.conf
            install -D -m644 $frrconf config_${node}/etc/frr/frr.conf
            install -D -m644 $vtyshconf config_${node}/etc/frr/vtysh.conf
            install -D -m644 ${daemoncfgfile} config_${node}/etc/frr/daemons
            install -D -m755 ${Script_Dir}/rc.local config_${node}/etc/rc.local
            install -D -m755 $frrsetup config_${node}/etc/runonce.d/80_frr_install.sh
            install -D -m755 $tunnelcfgfile config_${node}/etc/runboot.d/20_make_tunnels.sh
            install -D -m755 $extrasinstall extrasinstall/10_extra_install.sh
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
                mkdir /etc/frr : \
                upload $frrconf /etc/frr/frr.conf : \
                upload $vtyshconf /etc/frr/vtysh.conf : \
                upload ${daemoncfgfile} /etc/frr/daemons : \
                upload $frrsetup /etc/runonce.d/80_frr_install.sh : \
                upload $tunnelcfgfile /etc/runboot.d/20_make_tunnels.sh : \
                mkdir /root/extras : \
                copy-in config_${node}/root/extras /root/ : \
                upload $extrasinstall /etc/runonce.d/10_extra_install.sh
            #
            # Delete config dir for VM nodes - no need to keep it around
            rm -rf config_${node}
        fi
        rm $iffile
        rm $hostnamefile
        rm $hostfile
        rm $frrconf
        rm $vtyshconf
        rm $frrsetup
        rm $tunnelcfgfile
        rm $daemoncfgfile
        rm $extrasinstall
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
