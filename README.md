Setting up a UPI installation can be a somewhat tedious effort.  This intent of this project is to share some scripting developed to 
make some of this easier.  It is recognized that there is terraform which meets a similar need.  The reason this was done was the desire
to interact with specific portions of the installation process.

# Requirements

- An `install-config.yaml` which is preconfigured for a vmware install.  This process will extract credentials from `install-config.yaml`
- `openshift-install` must be in the current directory
- DNS records for api, api-int, and *.apps which will point to the infrastructure node that is created as part of this process

# Networking

Networking is currently static IP based and hard coded.  There is no reason DHCP couldn't be used, however.  




