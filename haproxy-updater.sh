#!/bin/sh

function buildBackend() {
    NAME=$1
    PORT=$2
    TARGETS=$3

    echo "backend $NAME" >> temp_cfg
    for TARGET in $TARGETS; do
        echo "    server $TARGET $TARGET:$PORT check" >> temp_cfg
    done
    echo "" >> temp_cfg
}

export KUBECONFIG=/home/core/kubeconfig
sudo mkdir -p /etc/haproxy

# haproxy/dnsmasq reconcilation loop
while [ 1 ]; do

rm temp_cfg

EMPTY_CONTROL_PLANE=0

# Build control plane targets
NODE_IPS=$(oc get nodes -l node-role.kubernetes.io/master -o=json | jq -r '.items[].status.addresses[] | select(.type=="ExternalIP") | .address')

if [ -z $NODE_IPS ]; then
    EMPTY_CONTROL_PLANE=1
fi

if [ -f BOOTSTRAP_IP ]; then
NODE_IPS="$NODE_IPS $(cat BOOTSTRAP_IP)"
fi

buildBackend "machine-config-server" 22623 "$NODE_IPS"
buildBackend "api-server" 6443 "$NODE_IPS"

# Build compute targets
NODE_IPS=$(oc get nodes -l node-role.kubernetes.io/worker -o=json | jq -r '.items[].status.addresses[] | select(.type=="ExternalIP") | .address')

buildBackend "router-http" 80 "$NODE_IPS"
buildBackend "router-https" 443 "$NODE_IPS"

APPLY=0
if [ ! -f "active_cfg" ]; then
    echo Loading initial configuration
    cp temp_cfg active_cfg
    APPLY=1
elif cmp -s "temp_cfg" "active_cfg"; then
    echo Configuration matches, no updates    
else
    if [ $EMPTY_CONTROL_PLANE -eq 0 ]; then
        echo Configuration is updated, applying update
        cp temp_cfg active_cfg    
        APPLY=1
    else 
        echo "No control plane nodes were found.  Not applying this change as it could break the API."
    fi
fi

if [ $APPLY -eq 1 ]; then
    cat haproxy.tmp active_cfg >> /tmp/haproxy.conf
    sudo mv /tmp/haproxy.conf /etc/haproxy/haproxy.conf
    echo Restarting haproxy
    sudo systemctl restart haproxy
    sudo systemctl status haproxy
fi
sleep 10

done
