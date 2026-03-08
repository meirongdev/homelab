# Proxmox Terraform

Provisions an Ubuntu 24.04 LTS VM on Proxmox VE using Terraform.

For the homelab K3s node, prefer Ubuntu 24.04 LTS over Ubuntu development images so Cilium runs on a stable kernel baseline.

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
mv ~/go/bin/terraform /usr/local/bin/
#  install the autocomplete package.
terraform -install-autocomplete
```

## Environment Varibles

```properties
PROXMOX_VE_USERNAME=xxx@pam
PROXMOX_VE_PASSWORD=your password
PROXMOX_VE_ENDPOINT=https://youripordomain:8006
```

## Prerequisite

- download img on proxmox server
  - We can create and destroy the VM multiple times, but the download of the image should be done only once, or else it could be limited by the network speed from the cloud image server.

```bash
wget -O /var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
```

## Init terraform project

```bash
just init
```

Modify the `terraform.tfvars` if in need

## Create VM

```bash
just apply
```

## Clean

```bash
just destroy
just clean
```
