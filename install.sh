# BASE_VM=rhcos-4.7.0-x86_64-vmware.x86_64
# WINDOWS_TEMPLATE=windows-golden-images/windows-server-2004-template
# WIN_WORKER_NODES=2
# INFRA_VM_NAMESERVER=192.168.1.215
# INFRA_VM_GATEWAY=192.168.2.1
# export INFRA_VM_IP=192.168.2.240
# INFRA_VM_NETMASK=255.255.255.0

if [ -z "$SSH_PUBLIC_KEY" ]; then
    export SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
fi

if [ -z "$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK" ]; then
    SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK="yes"
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
    VM_NAME=$1;ROLE=$2;CPU_CORES=$3;MEMORY_MB=$4;DATASTORE=$5;DISK_SIZE=$6;NETWORK=$7;TEMPLATE=$8

    if [ ! -z "$DRS_CLUSTER_NAME" ]; then
        RESOURCE_POOL="-cluster $DRS_CLUSTER_NAME"
    fi

    if [ ! -z "$VM_RESOURCE_POOL" ]; then
        RESOURCE_POOL="-pool $VM_RESOURCE_POOL"
    fi

    if [ -z "$RESOURCE_POOL" ]; then
        echo Using the default resource pool
    fi
    echo Creating machine with govc vm.clone -net="$GOVC_NETWORK" -folder=$INFRA_NAME -on=false $RESOURCE_POOL -vm $TEMPLATE -c $CPU_CORES -m $MEMORY_MB $VM_NAME
    govc vm.clone -net="$GOVC_NETWORK" -folder=$INFRA_NAME -on=false $RESOURCE_POOL -vm $TEMPLATE -c $CPU_CORES -m $MEMORY_MB -ds $DATASTORE $VM_NAME
    echo Provisioning disk with size "$DISK_SIZE"GB
    govc vm.disk.change -vm $VM_NAME -size="$DISK_SIZE"GB
    govc vm.change -vm $VM_NAME -e disk.EnableUUID=TRUE

    if [ "$ROLE" != "winworker" ]; then
        govc vm.change -vm $VM_NAME -e guestinfo.hostname=$VM_NAME \
        -e guestinfo.ignition.config.data.encoding=base64 \
        -e guestinfo.afterburn.initrd.network-kargs="ip=$NETWORK" \
        -e guestinfo.ignition.config.data="$(cat $INSTALL_DIR/$ROLE.ign | base64 -w0)"
    fi
    govc vm.power -on=true $VM_NAME
}

function setupInfraNode () {
    rm -rf igntmp
    mkdir igntmp
    envsubst < cluster-infra-dns.conf > igntmp/cluster-infra-dns.conf
    envsubst < infra-ignition.yaml > igntmp/infra-ignition.yaml
    cp $INSTALL_DIR/auth/kubeconfig ./igntmp
    cp $INSTALL_DIR/bootstrap.ign ./igntmp
    podman run -i -v $(pwd):/files:Z --rm quay.io/coreos/butane:release -d /files --pretty  --strict < igntmp/infra-ignition.yaml > $INSTALL_DIR/infra.ign
    startInfraNode
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
    envsubst < install-config.yaml > $INSTALL_DIR/install-config.yaml
    cp $INSTALL_DIR/install-config.yaml $INSTALL_DIR/install-config_preserve.yaml

    export SSH_PUBLIC_KEY="$(getInstallConfigParam .sshKey)"
    export GOVC_DATACENTER="$(getInstallConfigParam  .platform.vsphere.datacenter)"
    export GOVC_DATASTORE="$(getInstallConfigParam .platform.vsphere.defaultDatastore)"
    export GOVC_INSECURE=1
    export GOVC_USERNAME="$(getInstallConfigParam .platform.vsphere.username)"
    export GOVC_PASSWORD="$(getInstallConfigParam .platform.vsphere.password)"
    export GOVC_URL="$(getInstallConfigParam .platform.vsphere.vCenter)"
    export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig
    export CLUSTER_NAME="$(getInstallConfigParam .metadata.name)"
    export DRS_CLUSTER_NAME="$(getInstallConfigParam .platform.vsphere.cluster)"
    export VM_RESOURCE_POOL="$(getInstallConfigParam .platform.vsphere.resourcePool)"
    export BASE_DOMAIN="$(getInstallConfigParam .baseDomain)"
    export GOVC_NETWORK="$(getInstallConfigParam .platform.vsphere.network)"

    ./openshift-install create manifests --dir=$INSTALL_DIR
    rm -f $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-*.yaml $INSTALL_DIR/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

    export INFRA_NAME=$(cat $INSTALL_DIR/manifests/cluster-infrastructure-02-config.yml | yq -r '.status.infrastructureName')
    rm ./$INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml

    govc folder.create /$GOVC_DATACENTER/vm/$INFRA_NAME
    ./openshift-install create ignition-configs --dir=$INSTALL_DIR
}

function startInfraNode() {
    if [ "$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK" == "no" ]; then
        echo "WARNING!!! SSH host key checking is disabled for the infra node"
    fi

    createAndConfigureVM $INFRA_NAME-infra infra 2 2048 $GOVC_DATASTORE 20 "$INFRA_VM_IP::$INFRA_VM_GATEWAY:$INFRA_VM_NETMASK:$INFRA_NAME-infra::none:$INFRA_VM_NAMESERVER"

    sleep 60
    INFRA_IP=
    while [ -z $INFRA_IP ]; do
        echo Waiting for infra node to get an IP address
        INFRA_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)
    done
    scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK $INSTALL_DIR/bootstrap.ign core@$INFRA_IP:.
}

function startBootstrap() {
    envsubst < bootstrap-ignition-bootstrap.ign > $INSTALL_DIR/bootstrap.ign
    VM_NAME=$INFRA_NAME-bootstrap
    createAndConfigureVM $VM_NAME bootstrap 2 8192 $GOVC_DATASTORE 40 "dhcp nameserver=$INFRA_VM_IP"
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
        createAndConfigureVM $VM_NAME master $CPU_CORES $MEMORY_MB $GOVC_DATASTORE $DISK_SIZE "dhcp nameserver=$INFRA_VM_IP" $BASE_VM &
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
        createAndConfigureVM $VM_NAME worker $CPU_CORES $MEMORY_MB $GOVC_DATASTORE $DISK_SIZE "dhcp nameserver=$INFRA_VM_IP" $BASE_VM &
        let WORKER_INDEX++
    done
}

function startWindowsWorkers() {
    WIN_WORKER_INDEX=0
    CPU_CORES=4
    MEMORY_MB=16384
    DISK_SIZE=128
    while [ $WIN_WORKER_INDEX -lt $WIN_WORKER_NODES ]
    do
        VM_NAME=$INFRA_NAME-winworker-$WORKER_INDEX
        ROLE=worker
        createAndConfigureVM $VM_NAME winworker $CPU_CORES $MEMORY_MB $GOVC_DATASTORE $DISK_SIZE "" $WINDOWS_TEMPLATE &
        let WIN_WORKER_INDEX++
    done
}

function bootstrapNewCluster() {
    # consume install-config.yaml and set things up
    prepareInstallation
    setupInfraNode
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
    while [ 1 ]; do
	    oc wait --for=condition=Available co/cloud-credential
	    if [ $? -ne 0 ]; then
		    echo "Waiting for operators ... will try again in 60 seconds"
		    sleep 60
	    else
		    break
	    fi
    done
    oc --type=merge patch etcd cluster -p='{"spec":{"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}'
    oc patch authentication.operator.openshift.io/cluster --type=merge -p='{"spec":{"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableOAuthServer": true}}}'
}

function restartWorkers() {
    govc vm.power -off=true $INFRA_NAME-worker*
    govc vm.power -on=true $INFRA_NAME-worker*
}

function restartMasters() {
    govc vm.power -off=true $INFRA_NAME-master*
    govc vm.power -on=true $INFRA_NAME-master*
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
    while [ 1 ]; do
	    oc wait --for=condition=Available co/cloud-credential
	    if [ $? -ne 0 ]; then
		    echo "Waiting for image registry ... will try again in 60 seconds"
		    sleep 60
	    else
		    break
	    fi
    done
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
