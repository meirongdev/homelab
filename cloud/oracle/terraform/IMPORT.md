# Terraform Import Guide

This document walks through importing the existing OCI resources into Terraform state.

## Step 1: Collect OCIDs from OCI Console

Open **OCI Console** and collect the following OCIDs:

| Resource | Where to find it |
|----------|-----------------|
| **Instance OCID** | Compute > Instances > oracle-k3s > Instance Information |
| **VCN OCID** | Networking > Virtual Cloud Networks > (your VCN) |
| **Subnet OCID** | Networking > Virtual Cloud Networks > (your VCN) > Subnets |
| **Internet Gateway OCID** | Networking > Virtual Cloud Networks > (your VCN) > Internet Gateways |
| **Route Table OCID** | Networking > Virtual Cloud Networks > (your VCN) > Route Tables |
| **Security List OCID** | Networking > Virtual Cloud Networks > (your VCN) > Security Lists |
| **Image OCID** | Compute > Instances > oracle-k3s > Instance Information > Image |
| **Availability Domain** | Compute > Instances > oracle-k3s > Placement > Availability Domain |

## Step 2: Fill in terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your actual values
```

## Step 3: Initialize Terraform

```bash
make init
```

## Step 4: Import all resources

```bash
make import \
  VCN_ID=ocid1.vcn.oc1... \
  IGW_ID=ocid1.internetgateway.oc1... \
  RT_ID=ocid1.routetable.oc1... \
  SL_ID=ocid1.securitylist.oc1... \
  SUBNET_ID=ocid1.subnet.oc1... \
  INSTANCE_ID=ocid1.instance.oc1...
```

## Step 5: Review drift

```bash
make plan
```

The plan will show differences between your Terraform config and the imported state.
Common expected diffs:
- `shape_config`: if instance is currently at 1 OCPU/6GB instead of 4/24
- `boot_volume_size_in_gbs`: if not yet at 200GB
- `display_name`, `dns_label`: cosmetic name differences

## Step 6: Apply to reach desired state

```bash
make apply
```

This scales the instance to 4 OCPUs / 24GB RAM and aligns all resource settings.

> **Note:** OCI can scale A1.Flex instances in-place without stopping them (usually).
> Confirm in the plan output before applying.
