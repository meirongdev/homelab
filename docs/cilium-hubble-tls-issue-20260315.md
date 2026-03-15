# Cilium Hubble Relay TLS Certificate Issue

**Date:** 2026-03-15  
**Cluster:** oracle-k3s  
**Cilium Version:** v1.19.1

## Problem Summary

Hubble Relay showing 1 error in cilium status.

## Root Cause

**Persisted bad Helm value + missing/reused Hubble TLS secrets**

The original symptom was a Hubble Relay TLS name mismatch:

Error message:
  x509: certificate is valid for *.default.hubble-grpc.cilium.io, 
  not hubble-peer.oracle-k3s.hubble-grpc.cilium.io

### Why This Happens

1. The cluster is configured with `cluster.name=oracle-k3s`, so Relay expects `hubble-peer.oracle-k3s.hubble-grpc.cilium.io`.
2. A previous manual `helm upgrade --set hubble.tls.auto.method=cronjob` persisted a bad user value in the Helm release.
3. The Cilium chart only supports `hubble.tls.auto.method=cronJob` (capital `J`). With the wrong casing, the chart still renders workloads that mount `hubble-server-certs` / `hubble-relay-client-certs`, but it does **not** render the cert-generation Job/CronJob that should create those secrets.
4. Depending on what was already in-cluster, this leads to either:
   - stale certificates minted for the old/default cluster name being reused, causing the x509 SAN mismatch, or
   - missing secrets entirely, leaving `hubble-relay` stuck in `ContainerCreating` with `MountVolume.SetUp failed ... secret "hubble-relay-client-certs" not found`.

### Permanent Repository Fix

The repo now prevents this in future installs/reinstalls by:

1. Explicitly pinning `hubble.tls.auto.method: cronJob` in both Cilium values files.
2. Adding `--reset-values` to the `deploy-cilium` automation so stale ad-hoc `helm --set` values cannot survive future upgrades.
3. Deleting `hubble-server-certs` and `hubble-relay-client-certs` before each Cilium deploy so certgen always re-issues them for the current cluster identity.
4. Verifying the secrets and `hubble-relay` rollout as part of the automation instead of silently assuming TLS bootstrapped correctly.

## Evidence from Sysdump

### Hubble Relay Logs
File: logs-hubble-relay-77b64b488c-zkwnl-hubble-relay-20260315-142037.log

Error:
  transport: authentication handshake failed: tls: failed to verify certificate: 
  x509: certificate is valid for *.default.hubble-grpc.cilium.io, 
  not hubble-peer.oracle-k3s.hubble-grpc.cilium.io

### Helm Values
File: cilium-helm-values-20260315-142037.yaml

  cluster:
    name: oracle-k3s

### Hubble Relay Configuration
- Peer Target: hubble-peer.kube-system.svc.cluster.local.:443
- Cluster Name: oracle-k3s
- TLS Enabled: Yes

## Solution Options

### Option 1: Re-run the fixed automation (Recommended)

  cd cloud/oracle
  just deploy-cilium

This now:
- deletes stale Hubble cert secrets,
- upgrades Cilium with `--reset-values`,
- uses `hubble.tls.auto.method=cronJob`,
- waits for `hubble-relay`,
- and runs `cilium status --brief`.

### Option 2: Use Cilium CLI to Re-enable Hubble

  cilium hubble disable
  cilium hubble enable --relay --ui

### Option 3: Manual break-glass secret regeneration

Only needed if the fixed automation cannot recreate the secrets.

  kubectl delete secret hubble-relay-client-certs -n kube-system --ignore-not-found
  kubectl delete secret hubble-server-certs -n kube-system --ignore-not-found

  helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --kube-context oracle-k3s \
    --values cloud/oracle/values/cilium-values.yaml \
    --reset-values \
    --wait \
    --timeout 10m
## Manual Certificate Generation (Last Resort)

  # Create certificate directory
  mkdir -p /tmp/hubble-certs

  # Generate CA
  openssl genrsa -out /tmp/hubble-certs/ca.key 2048
  openssl req -new -x509 -days 3650 -key /tmp/hubble-certs/ca.key -out /tmp/hubble-certs/ca.crt -subj "/CN=cilium-ca"

  # Generate server certificate with SAN
  openssl genrsa -out /tmp/hubble-certs/server.key 2048
  
  # Create SAN config file
  cat > /tmp/hubble-certs/san.cnf << 'EOF'
  [req]
  distinguished_name = req_distinguished_name
  req_extensions = v3_req
  [req_distinguished_name]
  [v3_req]
  subjectAltName = @alt_names
  [alt_names]
  DNS.1 = *.default.hubble-grpc.cilium.io
  DNS.2 = *.oracle-k3s.hubble-grpc.cilium.io
  DNS.3 = hubble-peer.oracle-k3s.hubble-grpc.cilium.io
  DNS.4 = hubble-peer.kube-system.svc.cluster.local
  EOF

  openssl req -new -key /tmp/hubble-certs/server.key -out /tmp/hubble-certs/server.csr -subj "/CN=*.oracle-k3s.hubble-grpc.cilium.io" -config /tmp/hubble-certs/san.cnf
  openssl x509 -req -days 3650 -in /tmp/hubble-certs/server.csr -CA /tmp/hubble-certs/ca.crt -CAkey /tmp/hubble-certs/ca.key -CAcreateserial -out /tmp/hubble-certs/server.crt -extensions v3_req -extfile /tmp/hubble-certs/san.cnf

  # Generate client certificate for Hubble Relay
  openssl genrsa -out /tmp/hubble-certs/client.key 2048
  openssl req -new -key /tmp/hubble-certs/client.key -out /tmp/hubble-certs/client.csr -subj "/CN=*.oracle-k3s.hubble-grpc.cilium.io"
  openssl x509 -req -days 3650 -in /tmp/hubble-certs/client.csr -CA /tmp/hubble-certs/ca.crt -CAkey /tmp/hubble-certs/ca.key -CAcreateserial -out /tmp/hubble-certs/client.crt

  # Create Kubernetes secrets
  kubectl create secret generic hubble-server-certs -n kube-system --from-file=/tmp/hubble-certs/ca.crt --from-file=/tmp/hubble-certs/server.crt --from-file=/tmp/hubble-certs/server.key
  kubectl create secret generic hubble-relay-client-certs -n kube-system --from-file=/tmp/hubble-certs/ca.crt --from-file=/tmp/hubble-certs/client.crt --from-file=/tmp/hubble-certs/client.key

  # Restart Hubble Relay
  kubectl rollout restart deployment hubble-relay -n kube-system

## Verification

After applying the fix, verify:

  cilium status
  kubectl logs -n kube-system -l k8s-app=hubble-relay --tail=20
  hubble status

## Related Files in Sysdump

- logs-hubble-relay-77b64b488c-zkwnl-hubble-relay-20260315-142037.log - Hubble Relay error logs
- cilium-helm-values-20260315-142037.yaml - Helm configuration showing cluster name
- hubble-relay-configmap-20260315-142037.yaml - Hubble Relay configuration
- hubble-relay-deployment-20260315-142037.yaml - Hubble Relay deployment spec
- cilium-configmap-20260315-142037.yaml - Cilium agent configuration

## Prevention

To prevent this issue in future deployments:

1. Never use ad-hoc `helm --set hubble.tls.auto.method=cronjob`; the only valid CronJob mode string is `cronJob`.
2. Always deploy Cilium through the repo automation so `--reset-values` clears stale Helm release state.
3. Re-issue Hubble TLS secrets whenever re-installing/upgrading Cilium across cluster-name changes or partial rebuilds.
4. Fail the bootstrap if `hubble-relay` does not roll out cleanly.

## References

- Cilium Hubble TLS Documentation: https://docs.cilium.io/en/stable/observability/hubble/#tls-configuration
- Cilium CLI GitHub: https://github.com/cilium/cilium-cli
- Hubble Architecture: https://docs.cilium.io/en/stable/observability/architecture/
