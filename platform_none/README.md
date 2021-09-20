# Requirements

- An `install-config.yaml` which is preconfigured for a vmware install and is present in the current directory.  This process will extract credentials from `install-config.yaml`
- `openshift-install` must be in the current directory
- DNS records for api, api-int, and *.apps which will point to the infrastructure node that is created as part of this process

## Required Environment Variables

Update `env.sh` with the required environment variables.

# Networking

All created nodes, except for the infra node, use DHCP to obtain their network configuration.

# Configuring Machines

Machines are configured with specific resources in a manner similar to an IPI installation:

~~~
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 2
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master  
  replicas: 3
platform:
  none: {}
~~~

# Running an install

## Running 

## Running each step individually

At this time, the install is run piece by piece:

~~~
source install-lib.sh

# Directory which will contain installation artifacts.  This directory must not exist periof to running `prepareInstallation`
export INSTALL_DIR=the-install-dir

# Ingest install-config.yaml and create environment variables
prepareInstallation

# Installs and creates an infrastructure node for haproxy and the bootstrap server
setupInfraNode

# Creates and starts the bootstrap node
startBootstrap

# Creates and starts the master node(s) based on the number of replicas in `install-config.yaml`
startMasters


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

# Public SSH Key

The environment variable `SSH_PUBLIC_KEY` defines the public key to be used in the infra node ignition as well as `install-config.yaml`.   If the `SSH_PUBLIC_KEY` is not defined, the public key in `~/.ssh/id_rsa.pub` is read and `SSH_PUBLIC_KEY` is set to the content of the key.  To include the key in your `install-config.yaml`, include this definition:

~~~
sshKey: |
  $SSH_PUBLIC_KEY
~~~


# Host key checking for the infra node

As a convenience, the variable `SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK=no` can be defined which disables host-key checking only for the infra node.  This can be
helpful when it is required to spin up new clusters regularly from the same host.


# Installing OKD

fcos does not include `oc`(required by the infra node) and VMware does not seem to report the IP address of the nodes consistently.  The steps in this project will roughly work with an OKD installation, but will require manual intervention in the `setupInfraNode` and `startBootstrap`.

~~~
setupInfraNode

# Wait for infra node to start and CTRL+C to exit setupInfraNode. Then scp the bootstrap ignition to the infra node
INFRA_IP=172.16.y.x
scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK $INSTALL_DIR/bootstrap.ign core@$INFRA_IP:.

# Copy oc to the infra node - the haproxy configuration service requires this to detect nodes.  Otherwise, once the bootstrap API
# drops, the API will no longer be reachable.
scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK path/to/oc core@$INFRA_IP:.
ssh -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK core@$INFRA_IP "mv oc /usr/local/bin"

startBootstrap

# Wait for the bootstrap node to start and CTRL+C to exit startBootstrap. Then scp the bootstrap IP to the infra node
echo 172.16.y.z > BOOTSTRAP_IP
scp -o StrictHostKeyChecking=$SSH_ENFORCE_INFRA_NODE_HOST_KEY_CHECK BOOTSTRAP_IP core@$INFRA_IP:.
~~