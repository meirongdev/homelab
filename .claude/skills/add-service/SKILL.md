---
name: add-service
description: Add a new service to the homelab. Creates the K8s manifest, gateway HTTPRoute, homepage entry, and Cloudflare tunnel DNS rule. Use when the user wants to deploy a new application or self-hosted service.
argument-hint: [service-name]
allowed-tools: Read, Edit, Write, Glob, Grep, Bash(kubectl *), Bash(cd /Users/matthew/projects/homelab/cloudflare/terraform && just *), Bash(cd /Users/matthew/projects/homelab && git *)
---

## Add New Homelab Service: $ARGUMENTS

This homelab uses **ArgoCD GitOps**: once changes are pushed to `main`, ArgoCD auto-deploys within 3 minutes. No manual `kubectl apply` needed for service manifests.

### Step 1 — Gather information

Ask the user (or infer from context) the following:

| Field | Example |
|-------|---------|
| Service name (lowercase, hyphenated) | `my-app` |
| Subdomain | `myapp` → `myapp.meirong.dev` |
| Docker image | `ghcr.io/author/my-app:latest` |
| Container port | `8080` |
| Service port (usually 80) | `80` |
| Namespace | `personal-services` (default) |
| Homepage section (个人服务 / 监控 / 基础设施) | `个人服务` |
| Homepage description (Chinese preferred) | `我的应用` |
| Homepage icon (from walkxcode/dashboard-icons) | `my-app.png` |
| Needs persistent storage? | yes/no |
| Needs external secrets? | yes/no |

### Step 2 — Create `manifests/<service-name>.yaml`

Use this template (adjust ports and add storage/env as needed):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  namespace: <namespace>
  labels:
    app: <service-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
        - name: <service-name>
          image: <image>
          ports:
            - containerPort: <container-port>
---
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  selector:
    app: <service-name>
  ports:
    - protocol: TCP
      port: <service-port>
      targetPort: <container-port>
```

If persistent storage is needed, add a PVC with `storageClassName: nfs-client`.
If the PVC holds important data (e.g. media libraries), add `argocd.argoproj.io/sync-options: Prune=false` annotation to protect it from accidental deletion.

### Step 3 — Add HTTPRoute to `manifests/gateway.yaml`

Append at the end of the file. Always include all explicit fields to prevent ArgoCD OutOfSync drift:

```yaml
---
# HTTPRoute: <subdomain>.meirong.dev -> <service-name>
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: homelab-gateway
      namespace: kube-system
      port: 8000
  hostnames:
    - "<subdomain>.meirong.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: <service-name>
          port: <service-port>
          weight: 1
```

**Important**: if the namespace is new (not `personal-services`, `monitoring`, `homepage`, `vault`, or `argocd`), also prepend a ReferenceGrant:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-<namespace>
  namespace: <namespace>
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: <namespace>
  to:
    - group: ""
      kind: Service
```

### Step 4 — Register with ArgoCD Application

Open `argocd/applications/personal-services.yaml` and add the new filename to the `include` list:

```yaml
directory:
  include: "{calibre-web.yaml,it-tools.yaml,...,<service-name>.yaml}"
```

If the service belongs to a different logical group (e.g. infrastructure), add it to the appropriate Application instead, or create a new one.

### Step 5 — Add service to homepage in `manifests/homepage.yaml`

Find the correct section under `services.yaml:` in the ConfigMap and add:

```yaml
        - <Display Name>:
            icon: <icon>.png
            href: https://<subdomain>.meirong.dev
            description: <Chinese description>
            kubernetes:
              namespace: <namespace>
              container: <service-name>
              label_selector: app=<service-name>
```

### Step 6 — Add Cloudflare tunnel rule in `cloudflare/terraform/terraform.tfvars`

Add to the `ingress_rules` map:

```hcl
  "<subdomain>" = { service = "http://traefik.kube-system.svc:80" }
```

### Step 7 — Commit and push (triggers ArgoCD auto-deploy)

```bash
cd /Users/matthew/projects/homelab
git add manifests/<service-name>.yaml manifests/gateway.yaml manifests/homepage.yaml argocd/applications/personal-services.yaml
git commit -m "feat: add <service-name> service"
git push origin main
```

ArgoCD will automatically sync within ~3 minutes. The `personal-services` and `gateway` Applications handle deployment — no manual `kubectl apply` needed.

### Step 8 — Apply Cloudflare DNS

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform && just plan
```

Show the plan output and ask the user to confirm before running `just apply`.

### Step 9 — Verify

```bash
kubectl get pods -n <namespace> -l app=<service-name>
kubectl rollout status deployment/<service-name> -n <namespace>
```

Or check ArgoCD UI at `https://argocd.meirong.dev` — the Application should show `Synced + Healthy`.

Confirm the pod is Running and report the final URL: `https://<subdomain>.meirong.dev`
