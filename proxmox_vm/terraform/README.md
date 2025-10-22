## Functionality

- [ ] download img
- [ ] init vm

## Reference

- [bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md)

## Usage

### Install terraform

Install by source code

```bash
apt install golang
git clone https://github.com/hashicorp/terraform
cd terraform
go install
# move terraform binary to where is included in $PATH
mv $GOPATH/bin/terraform /usr/local/bin/
#  install the autocomplete package.
terraform -install-autocomplete
```

## Environment Varibles

```properties
PROXMOX_VE_USERNAME=xxx@pam
PROXMOX_VE_PASSWORD=your password
PROXMOX_VE_ENDPOINT=https://youripordomain:8006
```

## Init terraform project

```bash
make init
```

Modify the `terraform.tfvars` if in need

## Image

```bash
make plan-image
make apply-image
make destry-image
```

## Create VM

```bash
make plan-vm
make apply-vm
make destroy-vm
```
