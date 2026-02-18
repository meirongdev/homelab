---
name: add-service
description: Add a new service to the homelab. Creates the K8s manifest, gateway HTTPRoute, homepage entry, and Cloudflare tunnel DNS rule. Use when the user wants to deploy a new application or self-hosted service.
argument-hint: [service-name]
allowed-tools: Read, Edit, Write, Glob, Grep, Bash(kubectl *), Bash(cd /Users/matthew/projects/homelab/cloudflare/terraform && just *)
---

## Add New Homelab Service: $ARGUMENTS

Follow these steps to fully integrate a new service into the homelab.

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

If persistent storage is needed, add a PVC using `storageClassName: nfs-client`.

### Step 3 — Add HTTPRoute to `manifests/gateway.yaml`

Append at the end of the file. Always include `port: 8000` in parentRefs:

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
    - name: homelab-gateway
      namespace: kube-system
      port: 8000
  hostnames:
    - "<subdomain>.meirong.dev"
  rules:
    - backendRefs:
        - name: <service-name>
          port: <service-port>
```

Note: if the namespace is new (not personal-services, monitoring, homepage, or vault), also add a ReferenceGrant for it.

### Step 4 — Add service to homepage in `manifests/homepage.yaml`

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

### Step 5 — Add Cloudflare tunnel rule in `cloudflare/terraform/terraform.tfvars`

Add to the `ingress_rules` map:

```hcl
  "<subdomain>" = { service = "http://traefik.kube-system.svc:80" }
```

### Step 6 — Apply everything

Run in order:

```bash
kubectl apply -f manifests/<service-name>.yaml
kubectl apply -f manifests/gateway.yaml
kubectl apply -f manifests/homepage.yaml
kubectl rollout restart deployment/homepage -n homepage
```

Then apply Cloudflare changes:

```bash
cd /Users/matthew/projects/homelab/cloudflare/terraform && just plan
```

Show the plan output and ask the user to confirm before running `just apply`.

### Step 7 — Verify

```bash
kubectl get pods -n <namespace> -l app=<service-name>
kubectl rollout status deployment/<service-name> -n <namespace>
```

Confirm the pod is Running and report the final URL: `https://<subdomain>.meirong.dev`
