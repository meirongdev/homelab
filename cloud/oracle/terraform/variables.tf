# --- OCI Provider Credentials ---

variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID"
  type        = string
}

variable "fingerprint" {
  description = "OCI API key fingerprint"
  type        = string
}

variable "private_key_path" {
  description = "Path to OCI API private key file (e.g., ~/.oci/oci_api_key.pem)"
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g., ap-osaka-1, ap-sydney-1, us-ashburn-1)"
  type        = string
}

# --- Compartment & Availability ---

variable "compartment_ocid" {
  description = "OCI compartment OCID (use tenancy OCID for root compartment)"
  type        = string
}

variable "availability_domain" {
  description = "OCI availability domain name (e.g., lFTz:AP-OSAKA-1-AD-1). Get from OCI Console."
  type        = string
}

# --- Network Configuration ---

variable "vcn_display_name" {
  description = "Display name for the VCN"
  type        = string
  default     = "k3s-vcn"
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN (must match existing VCN if importing)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_display_name" {
  description = "Display name for the public subnet"
  type        = string
  default     = "k3s-public-subnet"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet (must match existing subnet if importing)"
  type        = string
  default     = "10.0.1.0/24"
}

# --- Instance Configuration ---

variable "instance_display_name" {
  description = "Display name for the K3s compute instance"
  type        = string
  default     = "oracle-k3s"
}

variable "instance_hostname" {
  description = "Hostname label for the instance (used for OCI internal DNS)"
  type        = string
  default     = "oracle-k3s"
}

variable "instance_image_ocid" {
  description = "OCID of the Ubuntu 24.04 ARM image. Find at: OCI Console > Compute > Images (Platform Images, filter: Canonical Ubuntu 24.04, ARM)."
  type        = string
}

variable "ocpus" {
  description = "Number of OCPUs for VM.Standard.A1.Flex (Free Tier max: 4)"
  type        = number
  default     = 4
}

variable "memory_gb" {
  description = "Memory in GB for VM.Standard.A1.Flex (Free Tier max: 24)"
  type        = number
  default     = 24
}

variable "boot_volume_size_gb" {
  description = "Boot volume size in GB (Free Tier max: 200)"
  type        = number
  default     = 200
}

variable "ssh_public_key" {
  description = "SSH public key content for instance access (e.g., contents of ~/.ssh/vgio.pub)"
  type        = string
  sensitive   = true
}
