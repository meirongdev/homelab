# Homelab Project TODO

## Phase 1: Foundation ✅ (Current)

- [x] Terraform setup for VM provisioning
- [x] Ansible playbooks for MicroK8s installation
- [x] Helm-based application deployment
- [x] Observability stack (Prometheus, Grafana, Loki, Tempo)
- [x] Basic secret management with `.env` files

## Phase 2: Enhanced Security 🔄 (In Progress)

- [ ] Deploy HashiCorp Vault to Kubernetes
  - [ ] Install Vault Helm chart
  - [ ] Initialize and unseal Vault
  - [ ] Configure Kubernetes authentication
  - [ ] Set up high availability (3 replicas)
  
- [ ] Integrate External Secrets Operator
  - [ ] Install External Secrets Operator
  - [ ] Create SecretStore resources
  - [ ] Migrate Grafana secrets to Vault
  - [ ] Test secret rotation
  
- [ ] Update documentation
  - [ ] Create Vault usage guide
  - [ ] Document disaster recovery procedures
  - [ ] Update README with new architecture

## Phase 3: Advanced Features 📋 (Planned)

- [ ] Dynamic database credentials
- [ ] Automatic certificate management (cert-manager + Vault PKI)
- [ ] Secret rotation automation
- [ ] Audit logging and monitoring
- [ ] Backup and disaster recovery testing

## Phase 4: Production Readiness 🎯 (Future)

- [ ] High availability for all components
- [ ] Automated backups (Velero)
- [ ] Disaster recovery runbooks
- [ ] Performance optimization
- [ ] Cost optimization

## Nice-to-Have Features 💡

- [ ] GitOps with ArgoCD or Flux
- [ ] Service mesh (Istio or Linkerd)
- [ ] CI/CD pipeline
- [ ] Monitoring alerts and notifications
- [ ] Custom Grafana dashboards

---

### 当前使用流程（Phase 1）
```bash
# 首次设置
just init
vim .env  # 设置密码

# 部署
just deploy-all

# 使用
just grafana  # 访问 Grafana
just status   # 检查状态

```

### 未来迁移到 Vault 时（Phase 2）
你的配置文件结构不需要改变，只需要：

部署 Vault
将 .env 中的值迁移到 Vault
安装 External Secrets Operator
应用会自动从 Vault 获取 secrets
关键点：应用层（Grafana、Prometheus 等）的配置完全不需要修改，它们仍然从 Kubernetes Secrets 读取，只是 Secrets 的来源从手动创建变成了 Vault 自动同步。
