#!/usr/bin/env bash
##set -x
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

#
# Parse Topology Configuration File
#
eval $(parse_yaml ${YAML_Configfile})
#
# Delete nodes
#
for node in ${global_nodes}; do
    echo "Deleting node $node"
    #
    # Delete node if it exists
    if [ "`virsh list --all | grep \ $node\ `" != "" ]; then
        VM_disk=`virsh dumpxml ${node} | grep "source file" | grep -o "'.*'" | sed "s/'//g"`
        virsh destroy $node 2> /dev/null
        while [ "`virsh list --state-shutoff --all | grep \ $node`" == "" ]
        do
            sleep 1
            echo "waiting for shutdown"
        done
        virsh undefine  --remove-all-storage $node 2> /dev/null
        sleep 2
        sudo rm -f -v $VM_disk
    fi
done
#
# All nodes deleted, now delete bridges
#
for node in ${global_nodes}; do
    ifnum=1
    while var_exists name=${node}_if${ifnum}_bridge ; do
        if=${node}_if${ifnum}_bridge
        bridge=${!if}
        BridgeFound=`grep "${bridge}:" /proc/net/dev`
        if [ -n "${BridgeFound}" ] ; then
            echo "Deleting Bridge ${bridge}"
            sudo ip link set ${bridge} down 2> /dev/null
            sudo brctl delbr ${bridge} 2> /dev/null
        fi
        #
        ifnum=`expr $ifnum + 1`
    done
    #
done
