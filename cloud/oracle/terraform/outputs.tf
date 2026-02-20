output "instance_public_ip" {
  description = "Public IP address of the K3s instance"
  value       = oci_core_instance.k3s.public_ip
}

output "instance_ocid" {
  description = "OCID of the K3s instance"
  value       = oci_core_instance.k3s.id
}

output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.main.id
}

output "subnet_id" {
  description = "OCID of the public subnet"
  value       = oci_core_subnet.public.id
}
