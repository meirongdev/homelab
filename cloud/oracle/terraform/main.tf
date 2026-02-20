# VCN
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = var.vcn_display_name

  lifecycle {
    # dns_label is immutable — keep existing value on import
    ignore_changes = [dns_label]
  }
}

# Internet Gateway
resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "k3s-igw"
  enabled        = true
}

# Route Table (public — routes all egress via IGW)
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "k3s-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

# Security List
resource "oci_core_security_list" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "k3s-security-list"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH (port 22)
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP (port 80) — for Cloudflare Tunnel
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS (port 443)
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Kubernetes API Server (port 6443)
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # ICMP type 3 code 4 — Path MTU Discovery (required for OCI)
  ingress_security_rules {
    protocol  = "1"
    source    = "0.0.0.0/0"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# Public Subnet
resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.subnet_cidr
  display_name               = var.subnet_display_name
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.main.id]
  prohibit_public_ip_on_vnic = false

  lifecycle {
    # dns_label is immutable — keep existing value on import
    ignore_changes = [dns_label]
  }
}

# Cloud-init script (for reference; does not re-run on imported instances)
locals {
  cloud_init = <<-EOT
    #cloud-config
    package_update: true
    package_upgrade: false
    packages:
      - curl
      - git
      - nfs-common
    runcmd:
      - mkdir -p /root/.ssh
      - cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
      - chmod 700 /root/.ssh
      - chmod 600 /root/.ssh/authorized_keys
  EOT
}

# Compute Instance (VM.Standard.A1.Flex — Free Tier ARM)
resource "oci_core_instance" "k3s" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.instance_display_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = var.instance_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.public.id
    display_name           = "k3s-vnic"
    assign_public_ip       = true
    hostname_label         = var.instance_hostname
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  # Prevent boot volume deletion on instance termination
  preserve_boot_volume = true

  lifecycle {
    # Ignore metadata changes to avoid forced replacement on existing instance
    ignore_changes = [metadata, defined_tags, create_vnic_details[0].defined_tags]
  }
}
