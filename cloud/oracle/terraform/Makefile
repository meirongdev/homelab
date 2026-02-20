.PHONY: init plan apply import

init:
	terraform init

plan:
	terraform plan

apply:
	terraform apply

# Import existing OCI resources into Terraform state.
# Usage: make import VCN_ID=ocid1... IGW_ID=ocid1... RT_ID=ocid1... SL_ID=ocid1... SUBNET_ID=ocid1... INSTANCE_ID=ocid1...
import:
	@echo "Importing OCI resources into Terraform state..."
	terraform import oci_core_vcn.main $(VCN_ID)
	terraform import oci_core_internet_gateway.main $(IGW_ID)
	terraform import oci_core_route_table.public $(RT_ID)
	terraform import oci_core_security_list.main $(SL_ID)
	terraform import oci_core_subnet.public $(SUBNET_ID)
	terraform import oci_core_instance.k3s $(INSTANCE_ID)
	@echo "Import complete. Run 'make plan' to review any drift."
