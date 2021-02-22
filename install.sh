
BASE_VM=rhcos-4.7.0-fc.4-x86_64-vmware.x86_64
RESOURCE_POOL=default
DATASTORE=vanderdisk
INFRA_VM_NAMESERVER=192.168.1.215
INFRA_VM_GATEWAY=192.168.122.1
export INFRA_VM_IP=192.168.122.240
INFRA_VM_NETMASK=255.255.255.0

if [ -z "$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK" ]; then
    SSH_ENFORCE_NODE_HOST_KEY_CHECK="yes"
fi

# Creates a Virtual machine by accepting the parameters below:
# VM Name
# Role - Maps to the ignition file in $INSTALL_DIR
# CPU Cores
# Memory in MB
# Datastore
# Resource pool
# Disk size in GB
# Network kargs - $VM_IP::$VM_GATEWAY:$VM_NETMASK:$VM_NAME::none:$VM_NAMESERVER
#
# All args are required
function createAndConfigureVM() {
    VM_NAME=$1;ROLE=$2;CPU_CORES=$3;MEMORY_MB=$4;DATASTORE=$5;RESOURCE_POOL=$6;DISK_SIZE=$7;NETWORK=$8
    govc vm.clone -folder=$INFRA_NAME -on=false -pool=$RESOURCE_POOL -vm $BASE_VM -c $CPU_CORES -m $MEMORY_MB -ds $DATASTORE $VM_NAME
    govc vm.disk.change -vm $VM_NAME -size=$DISK_SIZE
    govc vm.change -vm $VM_NAME -e disk.EnableUUID=TRUE \
    -e guestinfo.hostname=$VM_NAME \
    -e guestinfo.ignition.config.data.encoding=base64 \
    -e guestinfo.afterburn.initrd.network-kargs="ip=$NETWORK" \
    -e guestinfo.ignition.config.data="$(cat $INSTALL_DIR/$ROLE.ign | base64 -w0)"    
    govc vm.power -on=true $VM_NAME
}

function setupInfraNode () {    
    envsubst < cluster-infra-dns.conf > $INSTALL_DIR/cluster-infra-dns.conf
    
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK haproxy.service core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK bootstrap-serv.service core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK bootstrap-serv.sh core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK bootstrap-serv.service core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK haproxy-updater.sh core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK haproxy.tmp core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK haproxy-updater.service core@$INFRA_VM_IP:.   
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK $INSTALL_DIR/bootstrap.ign core@$INFRA_VM_IP:. 
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK $INSTALL_DIR/cluster-infra-dns.conf core@$INFRA_IP:.    

    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo chmod 755 haproxy-updater.sh
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo chmod 755 bootstrap-serv.sh
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo mv *.service /etc/systemd/system
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo mv cluster-infra-dns.conf /etc/dnsmasq.d
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP "sudo semanage fcontext -a -t systemd_unit_file_t /etc/systemd/system/haproxy.service"
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP "sudo semanage fcontext -a -t systemd_unit_file_t /etc/systemd/system/haproxy-updater.service"
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP "sudo semanage fcontext -a -t systemd_unit_file_t /etc/systemd/system/bootstrap-serv.service"
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo restorecon -r /etc/systemd/system
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo restorecon -r /etc/dnsmasq.d
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK $INSTALL_DIR/bootstrap.ign core@$INFRA_VM_IP:.
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK $INSTALL_DIR/auth/kubeconfig core@$INFRA_VM_IP:.
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo systemctl start bootstrap-serv
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo systemctl enable haproxy-updater
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo systemctl start haproxy-updater
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo systemctl enable dnsmasq
    ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_VM_IP sudo systemctl start dnsmasq
}

function getInstallConfigParam() {
    QUERY=$1
    DEFAULT=$2    
    VALUE=$(cat $INSTALL_DIR/install-config_preserve.yaml | yq -r $QUERY)
    if [ "null" != "$VALUE" ]; then
        echo $VALUE
        return
    fi
    if [ ! -z "$DEFAULT" ]; then
        echo $DEFAULT
    fi    
}

function prepareInstallation() {
    if [[ -z "$INSTALL_DIR" ]]; then
        echo Must define INSTALL_DIR
        return
    fi    

    if [[ -d "$INSTALL_DIR" ]]; then
        echo Install dir $INSTALL_DIR already exists.  You must delete it before continuing.
        return
    fi

    mkdir $INSTALL_DIR
    cp install-config.yaml $INSTALL_DIR/
    cp install-config.yaml $INSTALL_DIR/install-config_preserve.yaml

    export SSH_PUBLIC_KEY="$(getInstallConfigParam .sshKey)"
    export GOVC_DATACENTER="$(getInstallConfigParam  .platform.vsphere.datacenter)"
    export GOVC_DATASTORE="$(getInstallConfigParam .platform.vsphere.defaultDatastore)"
    export GOVC_INSECURE=1
    export GOVC_USERNAME="$(getInstallConfigParam .platform.vsphere.username)"
    export GOVC_PASSWORD="$(getInstallConfigParam .platform.vsphere.password)"
    export GOVC_URL="$(getInstallConfigParam .platform.vsphere.vCenter)"
    export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig
    export CLUSTER_NAME="$(getInstallConfigParam .metadata.name)"
    export BASE_DOMAIN="$(getInstallConfigParam .baseDomain)"
    DATASTORE=$GOVC_DATASTORE

    ./openshift-install create manifests --dir=$INSTALL_DIR
    rm -f $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-*.yaml $INSTALL_DIR/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

    export INFRA_NAME=$(cat $INSTALL_DIR/manifests/cluster-infrastructure-02-config.yml | yq -r '.status.infrastructureName')
    rm ./$INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml

    govc folder.create /$GOVC_DATACENTER/vm/$INFRA_NAME
    ./openshift-install create ignition-configs --dir=$INSTALL_DIR
    envsubst < infra.ign > $INSTALL_DIR/infra.ign
}

function startInfraNode() {    
    if [ "$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK" == "no" ]; then
        echo "WARNING!!! SSH host key checking is disabled for the infra node"
    fi

    createAndConfigureVM $INFRA_NAME-infra infra 2 8192 $DATASTORE $RESOURCE_POOL 20G "$INFRA_VM_IP::$INFRA_VM_GATEWAY:$INFRA_VM_NETMASK:$INFRA_NAME-infra::none:$INFRA_VM_NAMESERVER"

    sleep 60
    INFRA_IP=
    while [ -z $INFRA_IP ]; do
        echo Waiting for infra node to get an IP address
        INFRA_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)
    done
    setupInfraNode
}

function startBootstrap() {
    envsubst < bootstrap-ignition-bootstrap.ign > $INSTALL_DIR/bootstrap.ign   
    VM_NAME=$INFRA_NAME-bootstrap 
    createAndConfigureVM $VM_NAME bootstrap 2 8192 $DATASTORE $RESOURCE_POOL 40G "dhcp nameserver=$INFRA_VM_IP"
    BOOTSTRAP_IP=
    while [ -z $BOOTSTRAP_IP ]; do
        echo Waiting for bootstrap node to get an IP address
        BOOTSTRAP_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)    
        if [ ! -z $BOOTSTRAP_IP ]; then
            echo $BOOTSTRAP_IP > BOOTSTRAP_IP
            scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK BOOTSTRAP_IP core@$INFRA_IP:.
        fi
    done
}

function startMasters() {
    MASTER_INDEX=0
    CPU_CORES=$(getInstallConfigParam .controlPlane.platform.vsphere.cpus 4)
    MEMORY_MB=$(getInstallConfigParam .controlPlane.platform.vsphere.memoryMB 16384)
    DISK_SIZE=$(getInstallConfigParam .controlPlane.platform.vsphere.osDisk.diskSizeGB 120)
    CONTROL_PLANE_NODES=$(getInstallConfigParam .controlPlane.replicas 3)
    while [ $MASTER_INDEX -lt $CONTROL_PLANE_NODES ]
    do    
        VM_NAME=$INFRA_NAME-master-$MASTER_INDEX
        ROLE=master
        createAndConfigureVM $VM_NAME master $CPU_CORES $MEMORY_MB $DATASTORE $RESOURCE_POOL $DISK_SIZE "dhcp nameserver=$INFRA_VM_IP"
        let MASTER_INDEX++
    done
}

function startWorkers() {
    WORKER_INDEX=0
    CPU_CORES=$(getInstallConfigParam .compute[0].platform.vsphere.cpus 2)
    MEMORY_MB=$(getInstallConfigParam .compute[0].platform.vsphere.memoryMB 8192)
    DISK_SIZE=$(getInstallConfigParam .compute[0].platform.vsphere.osDisk.diskSizeGB 120)
    WORKER_NODES=$(getInstallConfigParam .compute[0].replicas 2)

    while [ $WORKER_INDEX -lt $WORKER_NODES ]
    do    
        VM_NAME=$INFRA_NAME-worker-$WORKER_INDEX
        ROLE=worker
        createAndConfigureVM $VM_NAME worker $CPU_CORES $MEMORY_MB $DATASTORE $RESOURCE_POOL $DISK_SIZE "dhcp nameserver=$INFRA_VM_IP"
        let WORKER_INDEX++
    done
}


function bootstrapNewCluster() {
    # consume install-config.yaml and set things up
    prepareInstallation
    startInfraNode
    startBootstrap    
    startMasters    
    enableSingleMaster
    waitForBootstrapCompletion
    startWorkers
    approveCSRs &
    setupRegistry
    waitForInstallCompletion
}

function enableSingleMaster() {
    oc --type=merge patch etcd cluster -p='{"spec":{"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}'
    oc patch authentication.operator.openshift.io/cluster --type=merge -p='{"spec":{"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableOAuthServer": true}}}'
}

function restartWorkers() {
    govc vm.power -off=true $INFRA_NAME-worker*
    govc vm.power -on=true $INFRA_NAME-worker*
}

function approveCSRs() {
    while [ -z $INSTALL_FINISHED ]; do
        oc adm certificate approve `oc get csr -o=jsonpath='{.items[*].metadata.name}'` &> /dev/null
        sleep 30
    done
    unset INSTALL_FINISHED
}


function disableMasterSchedulable() {
    oc patch Scheduler/cluster --type merge --patch '{"spec":{"mastersSchedulable":false}}'
}

function setupRegistry() {
    oc wait --for=condition=Available co/image-registry
    oc create -f image-registry-rwo-pvc.yaml
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"pvc": {"claim": "image-registry-storage-rwo"}}}}'
}

function waitForBootstrapCompletion() {
    if [[ -z "$INSTALL_DIR" ]]; then
        echo Must define INSTALL_DIR
        return
    fi
    ./openshift-install wait-for bootstrap-complete --dir=$INSTALL_DIR
    govc vm.destroy $INFRA_NAME-bootstrap

}

function waitForInstallCompletion() {
    if [[ -z "$INSTALL_DIR" ]]; then
        echo Must define INSTALL_DIR
        return
    fi 
    ./openshift-install wait-for install-complete --dir=$INSTALL_DIR
    kill $(jobs -p)
}

function destroyCluster() {
    govc vm.destroy $INFRA_NAME-bootstrap
    govc vm.destroy $INFRA_NAME-infra
    govc vm.destroy $INFRA_NAME-master*
    govc vm.destroy $INFRA_NAME-worker*
}
