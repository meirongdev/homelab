# Homelab Project TODO

## Phase 1: Foundation ✅

- [x] Terraform setup for VM provisioning
- [x] Ansible playbooks for K3s installation
- [x] Helm-based application deployment
- [x] Observability stack (Prometheus, Grafana, Loki, Tempo)

## Phase 2: Security & GitOps ✅

- [x] Deploy HashiCorp Vault to Kubernetes (Helm, `vault` namespace)
- [x] Initialize and unseal Vault (`just vault-init`, `just vault-unseal`)
- [x] Configure Kubernetes authentication for ESO
- [x] Install External Secrets Operator
- [x] Create ClusterSecretStore (`vault-backend`)
- [x] Migrate all app secrets to Vault (Grafana, Cloudflare, Postgres, Stirling-PDF, GitHub)
- [x] GitOps with ArgoCD (auto-sync + selfHeal for all managed apps)
- [x] ArgoCD Image Updater — automated `it-tools` image tracking via GHCR

## Phase 3: Advanced Features 📋 (Planned)

- [ ] Dynamic database credentials (Vault dynamic secrets for PostgreSQL)
- [ ] Automatic certificate management (cert-manager + Vault PKI)
- [ ] Secret rotation automation
- [ ] Audit logging and monitoring
- [ ] Backup and disaster recovery (Velero)

## Phase 4: Production Readiness 🎯 (Future)

- [ ] High availability for all components
- [ ] Disaster recovery runbooks
- [ ] Performance optimization

## Nice-to-Have 💡

- [x] GitOps with ArgoCD
- [x] CI/CD — ArgoCD Image Updater for automated image deployments
- [ ] Service mesh (Istio or Linkerd)
- [ ] Monitoring alerts and notifications (Alertmanager)
- [ ] Custom Grafana dashboards
