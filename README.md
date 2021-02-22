Setting up a UPI installation can be a somewhat tedious effort.  This intent of this project is to share some scripting developed to 
make some of this easier.  It is recognized that there is terraform which meets a similar need.  The reason this was done was the desire
to interact with specific portions of the installation process.

# Requirements

- An `install-config.yaml` which is preconfigured for a vmware install and is present in the current directory.  This process will extract credentials from `install-config.yaml`
- `openshift-install` must be in the current directory
- DNS records for api, api-int, and *.apps which will point to the infrastructure node that is created as part of this process

# Networking

All created nodes, except for the infra node, use DHCP to obtain their network configuration.  

# Configuring Machines

Machines are configured with specific resources in a manner similar to an IPI installation:

~~~
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: 
    vsphere: 
      cpus: 2
      coresPerSocket: 1
      memoryMB: 10000
      osDisk:
        diskSizeGB: 60
  replicas: 2
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    vsphere: 
      cpus: 4
      coresPerSocket: 2
      memoryMB: 16384
      osDisk:
        diskSizeGB: 60
  replicas: 1
~~~

# Running an install

At this time, the install is run piece by piece:

~~~
source install.sh

# Directory which will contain installation artifacts.  This directory must not exist periof to running `prepareInstallation`
export INSTALL_DIR=the-install-dir

# Ingest install-config.yaml and create environment variables
prepareInstallation

# Installs and creates an infrastructure node for haproxy and the bootstrap server
startInfraNode

# Creates and starts the bootstrap node
startBootstrap    

# Creates and starts the master node(s) based on the number of replicas in `install-config.yaml`
startMasters    

# Optional, if enabled enables a single master install
# enableSingleMaster

# Waits for bootstrap completion and tears down the bootstrap node after completion
waitForBootstrapCompletion

# Creates the worker nodes 
startWorkers

# Starts CSR approval process
approveCSRs &

# Setups up the image registry to be backed by a VMware volume
setupRegistry

# Waits for installation to complete and tears down the CSR approval mechanism
waitForInstallCompletion

~~~




