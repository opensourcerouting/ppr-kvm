#!/usr/bin/env bash
#
var_exists() { # check if variable is set at all
    local "$@" # inject 'name' argument in local scope
    &>/dev/null declare -p "$name" # return 0 when var is present
}

make_tunnels() {
    local "$@"

    if [ "$tunSide" = "Source" ] ; then
        echo "Tunnel Source Side"
        local=$tunSource
        remote=$tunDest
        tunThisSide=1
        tunRemoteSide=2
    elif [ "$tunSide" = "Dest" ] ; then
        echo "Tunnel Destination Side"
        local=$tunDest
        remote=$tunSource
        tunThisSide=2
        tunRemoteSide=1
    else
        echo "Not a Tunnel End Host"
        return 0
    fi
    #
    if [ "${numTunnels}" -gt "0" ] ; then
        # 
        # Add PPR Loopback with IPs
        #
        LoopFound=`grep "lo-ppr:" /proc/net/dev`
        if ! [ -n "${LoopFound}" ] ; then
            ip link add name lo-ppr type dummy
            ip link set lo-ppr up
        fi
        for((i=1; i<=${numTunnels}; i++)) ; do
            hex=$(printf '%x' `expr $startTun + $i`)
            ip -6 addr add ${local}::${hex}/64 dev lo-ppr
        done
        #
        # Add Tunnels
        #
        for((i=1; i<=${numTunnels}; i++)) ; do
            dec=`expr $startTun + $i`
            hex=$(printf '%x' $dec)
            ip -6 tunnel add tun-ppr${dec} mode ${tunMode} remote ${remote}::${hex} local ${local}::${hex} ttl 64
            ip link set dev tun-ppr${dec} up
            sysctl -w net.mpls.conf.tun-ppr${dec}.input=1
            ip -6 addr add ${tunNet}:${hex}::${tunThisSide}/64 dev tun-ppr${dec}
        done
        #
        # Add ip6tables rule and routing table
        #
        # ip6tables -t mangle -A PREROUTING -i ens2 -p ipv6-icmp -j MARK --set-mark 0x1
        ip6tables -t mangle -A PREROUTING -p ipv6-icmp -j MARK --set-mark 0x1
        for((i=1; i<=${numTunnels}; i++)) ; do
            dec=`expr $startTun + $i`
            hex=$(printf '%x' $dec)
            if var_exists name=ifVRF ; then
                ip6tables -t mangle -A PREROUTING -i ${ifVRF} -p udp --sport `expr 10000 + $dec` -j MARK --set-mark 0x${hex}
                ip6tables -t mangle -A PREROUTING -i ${ifVRF} -p udp --dport `expr 10000 + $dec` -j MARK --set-mark 0x${hex}
                ip -6 rule add fwmark 0x${hex} lookup `expr 10000 + ${dec}`
                ip -6 route add default via ${tunNet}:${hex}::${tunRemoteSide} encap mpls 500 table `expr 10000 + ${dec}`
            else
                ip6tables -t mangle -A PREROUTING -i ens2 -p udp --sport `expr 10000 + $dec` -j MARK --set-mark 0x${hex}
                ip6tables -t mangle -A PREROUTING -i ens2 -p udp --dport `expr 10000 + $dec` -j MARK --set-mark 0x${hex}
                ip -6 rule add fwmark 0x${hex} lookup `expr 10000 + ${dec}`
                ip -6 route add default via ${tunNet}:${hex}::${tunRemoteSide} table `expr 10000 + ${dec}`
            fi
        done
    fi
}
#
# numTunnels=0000000000
# startTun=0
# #
# tunSide=Neither
# tunMode=ip6ip6
# tunSource=fc00:1000::
# tunDest=fc00:2000::
# tunNet=fc00:ffff:
# ifVRF=vrf-RED
#
