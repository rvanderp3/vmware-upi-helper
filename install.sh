
BASE_VM=rhcos-4.7.0-fc.4-x86_64-vmware.x86_64
#BASE_VM=rhcos-4.6.8-x86_64-vmware.x86_64
RESOURCE_POOL=default
BOOTSTRAP_IP=192.168.122.200
CPU_CORES=2
DATASTORE=vanderdisk
VM_NAME=test-0
VM_NAMESERVER=192.168.1.215
VM_GATEWAY=192.168.122.1
VM_IP=192.168.122.233
VM_NETMASK=255.255.255.0
MEMORY_MB=8192
DISK_SIZE=40G
ROLE=master

function createAndConfigureVM() {
    govc vm.clone -folder=$INFRA_NAME -on=false -pool=$RESOURCE_POOL -vm $BASE_VM -c $CPU_CORES -m $MEMORY_MB -ds $DATASTORE $VM_NAME
    govc vm.disk.change -vm $VM_NAME -size=$DISK_SIZE
    govc vm.change -vm $VM_NAME -e disk.EnableUUID=TRUE \
    -e guestinfo.ignition.config.data.encoding=base64 \
    -e guestinfo.afterburn.initrd.network-kargs="ip=$VM_IP::$VM_GATEWAY:$VM_NETMASK:$VM_NAME::none:$VM_NAMESERVER" \
    -e guestinfo.ignition.config.data="$(cat $INSTALL_DIR/$ROLE.ign | base64 -w0)"    
    govc vm.power -on=true $VM_NAME
}

function setupInfraNode () {
    echo $BOOTSTRAP_IP > BOOTSTRAP_IP
    scp haproxy.service core@$INFRA_IP:.
    scp bootstrap-serv.service core@$INFRA_IP:.
    scp bootstrap-serv.sh core@$INFRA_IP:.
    scp bootstrap-serv.service core@$INFRA_IP:.
    scp haproxy-updater.sh core@$INFRA_IP:.
    scp haproxy-updater.service core@$INFRA_IP:.    
    scp BOOTSTRAP_IP core@$INFRA_IP:.

    ssh core@$INFRA_IP sudo chmod 755 haproxy-updater.sh
    ssh core@$INFRA_IP sudo chmod 755 bootstrap-serv.sh
    ssh core@$INFRA_IP sudo mv *.service /etc/systemd/system
    ssh core@$INFRA_IP "sudo semanage fcontext -a -t systemd_unit_file_t /etc/systemd/system/haproxy.service"
    ssh core@$INFRA_IP "sudo semanage fcontext -a -t systemd_unit_file_t /etc/systemd/system/haproxy-updater.service"
    ssh core@$INFRA_IP "sudo semanage fcontext -a -t systemd_unit_file_t /etc/systemd/system/bootstrap-serv.service"
    ssh core@$INFRA_IP sudo restorecon -r /etc/systemd/system
    scp $INSTALL_DIR/bootstrap.ign core@$INFRA_IP:.
    ssh core@$INFRA_IP sudo systemctl start bootstrap-serv
    ssh core@$INFRA_IP sudo systemctl start haproxy-updater
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

    export CONTROL_PLANE_NODES=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.controlPlane.replicas')
    export WORKER_NODES=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.compute[0].replicas')    
    export SSH_PUBLIC_KEY=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.sshKey')    
    export GOVC_DATACENTER=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.platform.vsphere.datacenter')
    export GOVC_DATASTORE=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.platform.vsphere.defaultDatastore')
    export GOVC_INSECURE=1
    export GOVC_USERNAME=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.platform.vsphere.username')
    export GOVC_PASSWORD=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.platform.vsphere.password')
    export GOVC_URL=$(cat $INSTALL_DIR/install-config.yaml | yq -r '.platform.vsphere.vCenter')
    export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig
    DATASTORE=$GOVC_DATASTORE

    ./openshift-install create manifests --dir=$INSTALL_DIR

    export INFRA_NAME=$(cat $INSTALL_DIR/manifests/cluster-infrastructure-02-config.yml | yq -r '.status.infrastructureName')
    rm ./$INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml

    govc folder.create /$GOVC_DATACENTER/vm/$INFRA_NAME
    ./openshift-install create ignition-configs --dir=$INSTALL_DIR
    envsubst < infra.ign > $INSTALL_DIR/infra.ign
}

function startInfraNode() {
    VM_IP=192.168.122.240
    VM_NAME=$INFRA_NAME-infra
    CPU_CORES=2
    MEMORY_MB=8192
    ROLE=infra
    DISK_SIZE=20G
    createAndConfigureVM
    sleep 60
    export INFRA_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)
    setupInfraNode
}

function startBootstrap() {
    envsubst < bootstrap-ignition-bootstrap.ign > $INSTALL_DIR/bootstrap.ign
    
    VM_IP=BOOTSTRAP_IP
    VM_NAME=$INFRA_NAME-bootstrap
    CPU_CORES=2
    MEMORY_MB=8192
    ROLE=bootstrap
    DISK_SIZE=20G
    createAndConfigureVM

    BOOTSTRAP_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)

    API_ENDPOINTS+=( "server $VM_NAME $BOOTSTRAP_IP:6443 check ")
    MCO_ENDPOINTS+=( "server $VM_NAME $BOOTSTRAP_IP:22623 check ")
    updateHaproxyBackends
}

function startMasters() {
    MASTER_INDEX=0
    while [ $MASTER_INDEX -lt $CONTROL_PLANE_NODES ]
    do    
        VM_IP=192.168.122.21$MASTER_INDEX
        VM_NAME=$INFRA_NAME-master-$MASTER_INDEX
        CPU_CORES=8
        MEMORY_MB=24000
        ROLE=master
        DISK_SIZE=120G
        createAndConfigureVM
        MASTER_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)
        API_ENDPOINTS+=( "server $VM_NAME $MASTER_IP:6443 check ")
        MCO_ENDPOINTS+=( "server $VM_NAME $MASTER_IP:22623 check ")
        INGRESS_ENDPOINTS+=( "server $VM_NAME $MASTER_IP:443 check ")
        let MASTER_INDEX++
    done
}

function startWorkers() {
    WORKER_INDEX=0
    while [ $WORKER_INDEX -lt $WORKER_NODES ]
    do    
        VM_IP=192.168.122.22$WORKER_INDEX
        VM_NAME=$INFRA_NAME-worker-$WORKER_INDEX
        CPU_CORES=4
        MEMORY_MB=16384
        ROLE=worker
        DISK_SIZE=120G
	    DATASTORE=vanderdisk
        createAndConfigureVM
        WORKER_IP=$(govc vm.info -waitip=true -json=true $VM_NAME | jq -r .VirtualMachines[0].Guest.IpAddress)
        INGRESS_ENDPOINTS+=( "server $VM_NAME $WORKER_IP:443 check ")
        let WORKER_INDEX++
    done
}


function bootstrapNewCluster() {
    # consume install-config.yaml and set things up
    prepareInstallation

    startInfraNode

    startBootstrap    

    startMasters
    
    startWorkers

    enableSingleMaster
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
    oc adm certificate approve `oc get csr -o=jsonpath='{.items[*].metadata.name}'`
}


function disableMasterSchedulable() {
    oc patch Scheduler/cluster --type merge --patch '{"spec":{"mastersSchedulable":false}}'
}

function setupRegistry() {
    oc create -f image-registry-rwo-pvc.yaml
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"pvc": {"claim": "image-registry-storage-rwo"}}}}'
}

function waitForInstallCompletion() {
    if [[ -z "$INSTALL_DIR" ]]; then
        echo Must define INSTALL_DIR
        return
    fi

    ./openshift-install wait-for bootstrap-complete --dir=$INSTALL_DIR
    govc vm.destroy $INFRA_NAME-bootstrap

    oc wait --for=condition=Available co/image-registry
    setupRegistry

    ./openshift-install wait-for install-complete --dir=$INSTALL_DIR
}

function destroyCluster() {
    govc vm.destroy $INFRA_NAME-bootstrap
    govc vm.destroy $INFRA_NAME-infra
    govc vm.destroy $INFRA_NAME-master*
    govc vm.destroy $INFRA_NAME-worker*
}
