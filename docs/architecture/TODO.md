# Homelab Project TODO

## Phase 1: Foundation ✅

- [x] Terraform setup for VM provisioning (Proxmox)
- [x] Ansible playbooks for K3s installation (On-prem)
- [x] Helm-based application deployment
- [x] Observability stack (Prometheus, Grafana, Loki, Tempo)
- [x] OTel Collector DaemonSet — 替换 Promtail，OTLP HTTP → Loki 3.x
- [x] Grafana Loki Dashboards — Overview / Pod Browser / Errors / Cluster Search（GitOps via ArgoCD）
- [x] log-exporter sidecar pattern — 支持文件日志应用（Calibre-Web 已实施）
- [x] **Cloud Foundation**: Oracle Cloud Free Tier K3s Cluster (Terraform + Ansible)

## Phase 2: Security & GitOps ✅

- [x] Deploy HashiCorp Vault to Kubernetes (Helm, `vault` namespace)
- [x] Initialize and unseal Vault (`just vault-init`, `just vault-unseal`)
- [x] Configure Kubernetes authentication for ESO
- [x] Install External Secrets Operator (ESO)
- [x] Create ClusterSecretStore (`vault-backend`)
- [x] Migrate all app secrets to Vault (Grafana, Cloudflare, Postgres, Stirling-PDF, GitHub)
- [x] GitOps with ArgoCD (auto-sync + selfHeal for all managed apps)
- [x] ArgoCD Image Updater — automated `it-tools` image tracking via GHCR

## Phase 3: Multi-Cloud & Security 📋 (In Progress)

- [ ] **Multi-Cluster ArgoCD**: Manage Oracle Cloud resources from local ArgoCD
- [ ] **Cert-Manager**: Automatic certificate management (cert-manager + Vault PKI or Cloudflare DNS)
- [ ] **Vault Dynamic Secrets**: Dynamic database credentials for PostgreSQL
- [ ] **Secret Rotation**: Automate rotation for sensitive keys (Cloudflare, etc.)
- [ ] **VPC Peering/VPN**: Securely connect On-prem K3s with Oracle OCI K3s (Tailscale/Wireguard)

## Phase 4: Reliability & Maintenance 📋 (Planned)

- [x] **Uptime Kuma**: Deploy external health monitoring (status.meirong.dev) — with PostSync provisioner and public status page
- [ ] **Kopia Automation**: Scheduled backups via K8s CronJob to offsite storage
- [ ] **Loki Retention**: Configure log retention and compaction policies
- [ ] **Alerting**: Alertmanager integration with Discord/Slack
- [ ] **Disaster Recovery**: Velero backup and recovery runbooks

---

## 🚀 Task Roadmap (Ordered by Difficulty)

### 🟢 Low Difficulty (Easy Wins)
- [x] **Uptime Kuma**: Deploy for external service health monitoring.
- [ ] **Homepage Integration**: Add health checks for `it-tools`, `stirling-pdf`, `squoosh`, `kopia` in `manifests/homepage.yaml`.
- [ ] **Oracle Metrics**: Run `ansible/playbooks/install-node-exporter.yaml` on Oracle node.
- [ ] **Grafana Housekeeping**: Remove any remaining Promtail/Old Dashboards.

### 🟡 Medium Difficulty (Configuration Focused)
- [ ] **Alertmanager Config**: Set up basic alerting rules and notification webhooks.
- [ ] **Kopia Scheduled Jobs**: Refactor `kopia.yaml` to use CronJobs for automated backups.
- [ ] **Cert-Manager Setup**: Install cert-manager and configure Let's Encrypt with Cloudflare DNS-01 challenge.
- [ ] **ArgoCD App-of-Apps**: Refactor Application manifests into a cleaner hierarchy.

### 🔴 High Difficulty (Complex Systems)
- [ ] **Vault Dynamic Postgres**: Implement Vault's Database secret engine for dynamic SQL users.
- [ ] **Hybrid Cloud Networking**: Establish a secure tunnel (e.g., Tailscale Subnet Router) between local and OCI networks.
- [ ] **Multi-Cluster ArgoCD**: Add Oracle Cluster as a managed destination in local ArgoCD.

## Phase 5: Production Readiness 🎯 (Future)

- [ ] High availability for all components (Vault HA, Postgres HA)
- [ ] Performance optimization & Resource Quotas
- [ ] Audit logging for Vault and K8s API
