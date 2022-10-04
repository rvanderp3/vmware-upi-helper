
# Requirements

- DNS records for api, api-int, and *.apps which will point to the load balancer node IP referenced by terraform variable `lb_ip_address`
- ignition files are present in the `inst` folder relative to the root of this repository.
- terraform version 1.0.11
~~~
TERRAFORM_VERSION=1.0.11
curl -O https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip
~~~

# Performing an Installation

1. Run `terraform init` if you are doing this for the first time
2. Copy your install-config.yaml into `inst`
3. If you are creating a OVN hybrid cluster:
   1. Run `openshift-install create manifests --dir inst`
   2. Copy your `cluster-network-03-config.yml` into `inst/manifests/`
4. Create ignition files and place them in `inst`
   1. Run `openshift-install create ignition-configs --dir inst`
5. Copy `terraform.tfvars.example` to `terraform.tfvars`
6. Update `terraform.tfvars` with details relevant to your installation
   1. OpenShift developers can start with this [example](https://gist.githubusercontent.com/rvanderp3/ef13bd8f7432871bee4f38a60bb3b5ed/raw/d0a6acb137f500876dd22901ac6e5cbcd495aaf9/terraform.tfvars)
7. Run `terraform apply -auto-approve`
8. Run `openshift-install wait-for bootstrap-complete --dir inst`
9. Run `openshift-install wait-for install-complete --dir inst`
10. While waiting for the install to be complete, execute:
    ``oc adm certificate approve `oc get csr -o=jsonpath='{.items[*].metadata.name}'` ``
    until all workers have joined the cluster.

When finished, run `terraform destroy -auto-approve`.
