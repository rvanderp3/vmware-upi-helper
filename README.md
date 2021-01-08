Setting up a UPI installation can be a somewhat tedious effort.  This intent of this project is to share some scripting developed to 
make some of this easier.  It is recognized that there is terraform which meets a similar need.  The reason this was done was the desire
to interact with specific portions of the installation process.

# Requirements

- An `install-config.yaml` which is preconfigured for a vmware install and is present in the current directory.  This process will extract credentials from `install-config.yaml`
- `openshift-install` must be in the current directory
- DNS records for api, api-int, and *.apps which will point to the infrastructure node that is created as part of this process

# Networking

Networking is currently static IP based and hard coded.  There is no reason DHCP couldn't be used, however.  

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

# Creates and starts the worker node(s) based on the number of replicas in `install-config.yaml`
startWorkers

# If needed, patch installation only require a single master
enableSingleMaster

# waits for the installation complete.  Will automatically tear down the bootstrap node and enable an emptyDir image registry
waitForInstallCompletion

# approves any pending CSRs.  You will need this if you are adding worker nodes
approveCSRs
~~~




