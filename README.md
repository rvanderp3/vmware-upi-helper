
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

1. Create ignition files and place them in `inst`
2. Copy `terraform.tfvars.example` to `terraform.tfvars`
3. Update `terraform.tfvars` with details relevant to your installation
4. Run `terraform apply`
5. Run `openshift-install wait-for bootstrap-complete --dir inst`
6. Run `openshift-install wait-for install-complete --dir inst`

When finished, run `terraform destroy`.