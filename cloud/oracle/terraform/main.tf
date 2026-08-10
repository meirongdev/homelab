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

  # 2026-08-10 删掉了三条 0.0.0.0/0 的 TCP 入站规则：80 / 443 / 6443。
  # 实测依据（`ss -tulnp` on node + `firewall-cmd --get-active-zones`）：
  #
  # · 80/443 —— **节点上根本没有进程监听这两个端口**。入口是 Cloudflare Tunnel，
  #   cloudflared 是**出站**连到 CF 边缘的；所有 DNS 记录都是
  #   `CNAME → <tunnel_id>.cfargotunnel.com` 且 proxied=true（cloudflare/terraform/main.tf:46），
  #   没有任何 A 记录指向本机公网 IP。这两条规则从来没被用过。
  #
  # · 6443 —— k3s-server 确实在 `*:6443` 上监听，但没有任何客户端走公网连它：
  #   ArgoCD 控制面 2026-08-02 起在本集群内（kubernetes.default.svc），
  #   本机 kubectl 走 Tailscale。关键是 **tailscale0 属于 firewalld 的 `trusted` zone**，
  #   完全不经 `public` 规则，所以删掉这条云侧规则不影响经 tailnet 的 API 访问；
  #   同批把 setup-k3s.yaml 的 tls-san 也收成只有 Tailscale IP。
  #
  # 保留 22/tcp：tailnet 整个挂掉时唯一的进入手段（密钥认证，无口令登录）。
  # 想连它也关掉的话，破窗改用 OCI 控制台的 Instance Console Connection（串口）。
  #
  # ⚠️ OS 层的 firewalld `public` zone 仍开着一大堆 k8s 端口
  #    （10250/2380/4240/32379/16443/25000/19001/… 多数是早期 CNI/microk8s 试验的残留）。
  #    它们目前只靠这份 Security List 挡在云边界——**这一层薄，别再往下面这个列表里加口子**。

  # Tailscale WireGuard (UDP 41641). Without this node0 never receives NAT-traversal
  # packets, so every tailnet path to it rides a DERP relay (observed 2026-07-07:
  # telemetry push + ClusterMesh VXLAN over relay "sin", 4GB+). WireGuard is
  # authenticated end-to-end; exposing the port is standard practice.
  ingress_security_rules {
    protocol  = "17"
    source    = "0.0.0.0/0"
    stateless = false
    udp_options {
      min = 41641
      max = 41641
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
