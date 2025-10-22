# Init
init: create-tfvars
	terraform init
# Plan: image download
create-tfvars:
	cp terraform.tfvars.example terraform.tfvars
plan-image:
	terraform plan -out=image.plan -target=proxmox_virtual_environment_download_file.ubuntu_cloud_image
# Apply: image download
apply-image: plan-image
	terraform apply "image.plan"
# Plan: VM creation
plan-vm:
	terraform plan -out=vm.plan -target=proxmox_virtual_environment_vm.ubuntu_vm
# Apply: VM creation
apply-vm: plan-vm
	terraform apply "vm.plan"
# Destroy - destroy all resources
destroy:
	terraform destroy
# Clean - remove local terraform files
clean:
	rm -rf .terraform/
	rm -f .terraform.lock.hcl
	rm -f *.tfstate*
	rm -f *.plan

# destry vm only
destroy-vm:
	terraform destroy -target=proxmox_virtual_environment_vm.ubuntu_vm
# destroy image only
destroy-image:
	terraform destroy -target=proxmox_virtual_environment_download_file.ubuntu_cloud_image