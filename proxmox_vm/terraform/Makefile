# Init
init: create-tfvars
	terraform init

# Create tfvars from example if it doesn't exist
create-tfvars:
	@if [ ! -f terraform.tfvars ]; then \
		echo "Creating terraform.tfvars from example..."; \
		cp terraform.tfvars.example terraform.tfvars; \
	else \
		echo "terraform.tfvars already exists."; \
	fi

# Plan all changes
plan:
	terraform plan -out=terraform.plan

# Apply all changes
apply: plan
	terraform apply "terraform.plan"

# Destroy all resources
destroy:
	terraform destroy -auto-approve

# Clean - remove local terraform files
clean:
	rm -rf .terraform/
	rm -f .terraform.lock.hcl
	rm -f *.tfstate*
	rm -f *.plan

# --- Granular Commands ---

# Plan: VM creation
plan-vm:
	terraform plan -out=vm.plan -target=proxmox_virtual_environment_vm.ubuntu_vm
# Apply: VM creation
apply-vm: plan-vm
	terraform apply "vm.plan"

# destry vm only
destroy-vm:
	terraform destroy -target=proxmox_virtual_environment_vm.ubuntu_vm
