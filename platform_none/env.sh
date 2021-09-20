# VMWare configuration
export DRS_CLUSTER_NAME="your-cluster"
export GOVC_DATACENTER="your-datacenter"
export GOVC_URL=https://vcenter-url
export GOVC_PASSWORD='your-password'
export GOVC_USERNAME='your-username'
export GOVC_DATASTORE="your-datastore"
export GOVC_NETWORK="network-segment-x"
export BASE_TEMPLATE="rhcos-48.84.202106301921-0-vmware.x86_64.ova-hw17"
 
# Network configuration
export SUBNET_PREFIX="192.168.20"
export SUBNET_NETMASK=255.255.255.0
export CONTROL_PLANE_START_IP=4
export COMPUTE_NODE_START_IP=7
export NAMESERVER=8.8.8.8
 
# WMCO configuration
export WIN_WORKER_NODES=2
export WINDOWS_TEMPLATE=template_folder/windows-template
 
# Derived configuration
export BOOTSTRAP_IP=${SUBNET_PREFIX}.3
export INFRA_VM_IP=${SUBNET_PREFIX}.2
export SUBNET_GATEWAY=${SUBNET_PREFIX}.1
export VM_RESOURCE_POOL="/${GOVC_DATACENTER}/host/${DRS_CLUSTER_NAME}/Resources"
export GOVC_INSECURE=1
