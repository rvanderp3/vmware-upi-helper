
# Update 
source env.sh
trap 'kill $(jobs -p)' EXIT

if [ -z "$SSH_PUBLIC_KEY" ]; then
    export SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
fi

if [ -z "$SSH_PRIVATE_KEYPATH" ]; then
    export SSH_PRIVATE_KEYPATH=~/.ssh/id_rsa
fi

if [ -z "$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK" ]; then
    SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK="yes"
fi

function GOVC_RETRY (){    
    govc $@
    while [ $? -ne 0 ]; do
        echo "retrying govc $@ in 10 seconds. check the error message from govc and ctrl+c if necessary to resolve the issue."
        sleep 10
        govc $@
    done

}

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
    echo Creating machine with govc vm.clone -net="$GOVC_NETWORK" -folder=$INFRA_NAME -on=false $RESOURCE_POOL -vm $BASE_TEMPLATE -c $CPU_CORES -m $MEMORY_MB $VM_NAME
    govc vm.clone -net="$GOVC_NETWORK" -folder=$INFRA_NAME -on=false $RESOURCE_POOL -vm $TEMPLATE -c $CPU_CORES -m $MEMORY_MB -ds $DATASTORE $VM_NAME
    echo Provisioning disk with size "$DISK_SIZE"GB
    GOVC_RETRY vm.disk.change -vm $VM_NAME -size="$DISK_SIZE"GB
    GOVC_RETRY vm.change -vm $VM_NAME -e disk.EnableUUID=TRUE

    if [ "$ROLE" != "winworker" ]; then
        echo applying network ${NETWORK}
        GOVC_RETRY vm.change -vm $VM_NAME -e guestinfo.hostname=$VM_NAME \
        -e guestinfo.ignition.config.data.encoding=base64 \
        -e guestinfo.afterburn.initrd.network-kargs="ip=$NETWORK" \
        -e guestinfo.ignition.config.data="$(cat $INSTALL_DIR/$ROLE.ign | base64 -w0)"
    fi
    GOVC_RETRY vm.power -on=true $VM_NAME
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
    VALUE=$(cat $INSTALL_DIR/install-config_preserve.yaml | yq eval $QUERY -)
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

    if [[ ! -f "./openshift-install" ]]; then
        echo "openshift-install was not found in the working directory"
        return
    fi        

    mkdir $INSTALL_DIR    
    envsubst < haproxy.tmpl > haproxy.conf
    envsubst < install-config.yaml > $INSTALL_DIR/install-config.yaml
    cp $INSTALL_DIR/install-config.yaml $INSTALL_DIR/install-config_preserve.yaml

    export SSH_PUBLIC_KEY="$(getInstallConfigParam .sshKey)"
    export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig
    export CLUSTER_NAME="$(getInstallConfigParam .metadata.name)"
    export BASE_DOMAIN="$(getInstallConfigParam .baseDomain)"    

    ./openshift-install create manifests --dir=$INSTALL_DIR
    rm -f $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-*.yaml $INSTALL_DIR/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

    export INFRA_NAME=$(cat $INSTALL_DIR/manifests/cluster-infrastructure-02-config.yml | yq eval '.status.infrastructureName' -)
    if [ -z $INFRA_NAME ]; then 
        echo "infrastructure name could not be derived.  please check above for errors as to why."
        return
    fi

    echo ${INFRA_NAME} > $INSTALL_DIR/infra_name
    rm ./$INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml

    echo applying hybrid network manifest
    cp cluster-network-03-config.yml ./$INSTALL_DIR/manifests

    govc folder.create /$GOVC_DATACENTER/vm/$INFRA_NAME
    ./openshift-install create ignition-configs --dir=$INSTALL_DIR
}

function startInfraNode() {    
    if [ "$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK" == "no" ]; then
        echo "WARNING!!! SSH host key checking is disabled for the infra node"
    fi

    createAndConfigureVM $INFRA_NAME-infra infra 2 2048 $GOVC_DATASTORE 20 "$INFRA_VM_IP::$SUBNET_GATEWAY:$SUBNET_NETMASK:$INFRA_NAME-infra::none:$NAMESERVER" $BASE_TEMPLATE

    sleep 60
    INFRA_IP=
    while [ -z $INFRA_IP ]; do
        echo "waiting for infra node to get an IP address"
        INFRA_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)
        sleep 30
    done    
    scp -i $SSH_PRIVATE_KEYPATH $INSTALL_DIR/bootstrap.ign core@$INFRA_IP:.
    if [ $? -ne 0 ]; then
        echo "an error was encountered when attempting to scp the bootstrap ignition to the infra node."
        echo "read the error carefully.  once understood, this command can be retried by running:"
        echo "scp -i $SSH_PRIVATE_KEYPATH $INSTALL_DIR/bootstrap.ign core@$INFRA_IP:."        
        echo "the private key at $SSH_PRIVATE_KEYPATH was used to establish a connection to the infra node"
        echo "once successful, run startBootstrap"
        return
    fi
}

function startBootstrap() {        
    envsubst < bootstrap-ignition-bootstrap.ign > $INSTALL_DIR/bootstrap.ign   
    VM_NAME=$INFRA_NAME-bootstrap 
    createAndConfigureVM $VM_NAME bootstrap 2 8192 $GOVC_DATASTORE 40 "$BOOTSTRAP_IP::$SUBNET_GATEWAY:$SUBNET_NETMASK:$VM_NAME::none:$INFRA_VM_IP" $BASE_TEMPLATE
}

function startControlPlaneNodes() {
    CP_INDEX=0
    CPU_CORES=$(getInstallConfigParam .controlPlane.platform.vsphere.cpus 4)
    MEMORY_MB=$(getInstallConfigParam .controlPlane.platform.vsphere.memoryMB 16384)
    DISK_SIZE=$(getInstallConfigParam .controlPlane.platform.vsphere.osDisk.diskSizeGB 120)
    CONTROL_PLANE_NODES=$(getInstallConfigParam .controlPlane.replicas 3)
    while [ $CP_INDEX -lt $CONTROL_PLANE_NODES ]
    do  
        echo creating control plane node ${CP_INDEX} of ${CONTROL_PLANE_NODES}  
        VM_NAME=$INFRA_NAME-cp-$CP_INDEX
        ROLE=master
        createAndConfigureVM $VM_NAME master $CPU_CORES $MEMORY_MB $GOVC_DATASTORE $DISK_SIZE "$SUBNET_PREFIX.$(( CONTROL_PLANE_START_IP + CP_INDEX ))::$SUBNET_GATEWAY:$SUBNET_NETMASK:$VM_NAME::none:$INFRA_VM_IP" $BASE_TEMPLATE &
        let CP_INDEX++
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
        echo creating compute node ${WORKER_INDEX} of ${CONTROL_PLANE_NODES}  
        VM_NAME=$INFRA_NAME-worker-$WORKER_INDEX
        ROLE=worker
        createAndConfigureVM $VM_NAME worker $CPU_CORES $MEMORY_MB $GOVC_DATASTORE $DISK_SIZE "$SUBNET_PREFIX.$(( COMPUTE_NODE_START_IP + WORKER_INDEX ))::$SUBNET_GATEWAY:$SUBNET_NETMASK:$VM_NAME::none:$INFRA_VM_IP" $BASE_TEMPLATE &
        let WORKER_INDEX++
    done
}

function bootstrapNewCluster() {    
    prepareInstallation
    setupInfraNode
    startBootstrap    
    startControlPlaneNodes        
    startWorkers
    approveCSRs &
    waitForBootstrapCompletion
    setupRegistry
    if [ ! -z $WIN_WORKER_NODES ]; then
        startWindowsWorkers
    fi
    waitForInstallCompletion
}

function restartWorkers() {
    govc vm.power -off=true $INFRA_NAME-worker*
    govc vm.power -on=true $INFRA_NAME-worker*
}

function restartControlPlaneNodes() {
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
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'    
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"emptyDir":{}}}}'
}

function startWindowsWorkers() {
    WIN_WORKER_INDEX=0
    CPU_CORES=4
    MEMORY_MB=16384
    DISK_SIZE=128
    while [ $WIN_WORKER_INDEX -lt $WIN_WORKER_NODES ]
    do
        VM_NAME=$INFRA_NAME-winworker-$WIN_WORKER_INDEX
        ROLE=worker
        createAndConfigureVM $VM_NAME winworker $CPU_CORES $MEMORY_MB $GOVC_DATASTORE $DISK_SIZE "" $WINDOWS_TEMPLATE &
        let WIN_WORKER_INDEX++
    done
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
    if [[ -z "$INSTALL_DIR" ]]; then
        echo Must define INSTALL_DIR
        return
    fi
    INFRA_NAME=$(cat ${INSTALL_DIR}/infra_name)
    if [[ -z "$INFRA_NAME" ]]; then
        echo "${INSTALL_DIR}/infra_name was not found.  You must manually delete the VMs associated with this cluster."
        return 1
    fi    
    rm -r ./igntmp
    echo destroying VMs associated with cluster infra ID ${INFRA_NAME}
    echo destroy bootstrap
    govc vm.destroy $INFRA_NAME-bootstrap
    echo destroy infra node
    govc vm.destroy $INFRA_NAME-infra
    echo destroy control plane nodes
    govc vm.destroy $INFRA_NAME-cp-*
    echo destroy compute nodes
    govc vm.destroy $INFRA_NAME-worker-*
    echo destroy winworkers
    govc vm.destroy $INFRA_NAME-winworker-*
}

