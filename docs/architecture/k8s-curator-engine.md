# K8s-Curator-Engine (v2026.1) Design Document

## 1. Project Definition
**K8s-Curator-Engine** is a highly customized information aggregation and curation system running in a Kubernetes environment. It aims to solve the "information overload" problem through a pipeline of "Machine Ingestion + Human Curation + Automated Distribution", enabling precise delivery of high-quality technical news.

## 2. System Architecture
The system uses a layered, decoupled design, communicating via standard protocols (RSS/API/Webhook):

1.  **Ingestion Layer**:
    *   **RSSHub**: Responsible for converting non-standard web pages (GitHub, Blogs, Security Bulletins) into standard RSS feeds.
    *   **Redis**: Caching layer for RSSHub to prevent rate limiting and improve performance.
2.  **Storage & Curation Layer**:
    *   **Miniflux**: Serves as the data center and human review backend. Users mark content for distribution by "Starring" items.
    *   **PostgreSQL**: Persistent database for Miniflux.
3.  **Orchestration & Logic Layer**:
    *   **n8n**: The automation engine. It periodically polls the Miniflux API, fetches starred items, sanitizes the data, and executes multi-platform distribution.
4.  **Distribution Layer**:
    *   **Telegram Channel**: Sends MarkdownV2 formatted messages via the Bot API.
    *   **Discord Server**: Sends Rich Embed formatted messages via Webhooks.

## 3. Kubernetes Infrastructure Specification

### 3.1 Multi-Cluster Architecture
The system leverages a **dual-cluster** topology for resilience and separation of concerns:

| Cluster | Role | Location |
|---------|------|----------|
| `oracle-k3s` | **Workload cluster** — runs all rss-system pods | Oracle Cloud ARM VM (Ampere A1) |
| `k3s-homelab` | **Shared services** — provides HashiCorp Vault | Local Proxmox |

**Cross-cluster communication** is handled exclusively via **Tailscale** (WireGuard mesh VPN):
*   `oracle-k3s` node Tailscale IP: `100.107.166.37`
*   `k3s-homelab` node (k8s-node) Tailscale IP: `100.107.254.112`
*   Vault is accessed from `oracle-k3s` pods via `http://100.107.254.112:31144` (NodePort)

This ensures the rss-system remains operational even if the homelab has network issues (the only dependency is Vault token refresh, which is cached).

### 3.2 Workload Specification
The system is deployed in the `oracle-k3s` cluster:

*   **Namespace**: `rss-system`
*   **Workloads**:
    *   `rsshub`: Deployment (Port 1200) + Service + Redis (Cache) + Browserless (headless Chrome)
    *   `miniflux`: Deployment (Port 8080) + Service + PostgreSQL
    *   `n8n`: Deployment (Port 5678) + Service (Persistent volume at `/home/node/.n8n`)
*   **Persistence**:
    *   `PersistentVolumeClaim` (PVC) using the `local-path` storage class for PostgreSQL and n8n.
*   **Ingress**:
    *   Gateway API `HTTPRoute` routing `rss.meirong.dev` to the Miniflux service.
    *   Independent Cloudflare Tunnel (`cloudflared`) for `oracle-k3s` to route `rss.meirong.dev`.
*   **Secret Management**:
    *   External Secrets Operator (ESO) installed in `oracle-k3s`.
    *   `ClusterSecretStore` pointing to Vault in `k3s-homelab` via Tailscale.
    *   Vault token stored as `vault-token` Secret in `rss-system` namespace.
    *   All sensitive tokens (DB passwords, admin credentials) fetched from Vault path `secret/homelab/miniflux`.

### 3.3 Oracle Cloud K3s Network Notes
The Oracle Cloud VM uses `firewalld` (nftables-based) which requires explicit trust for k3s pod/service CIDRs. Without this, pod egress to external IPs is blocked by the default `reject with icmpx admin-prohibited` rule in the `filter_FORWARD` chain.

**Required firewalld configuration:**
```bash
sudo firewall-cmd --permanent --zone=trusted --add-source=10.52.0.0/16  # Pod CIDR
sudo firewall-cmd --permanent --zone=trusted --add-source=10.53.0.0/16  # Service CIDR
sudo firewall-cmd --permanent --zone=trusted --add-interface=cni0        # CNI bridge
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel.1   # Flannel VXLAN
sudo firewall-cmd --reload
```

**CoreDNS** must be configured to forward to `8.8.8.8` instead of `/etc/resolv.conf`, because the default Oracle DNS (`169.254.169.254`) is a link-local metadata service unreachable from inside pods.

## 4. Automation Logic Specification (n8n)

### 4.1 Trigger Strategy
*   **Mode**: Pull Mode (Cron).
*   **Frequency**: Every 15 minutes.
*   **API Endpoint**: Miniflux API `/v1/entries?starred=true&status=unread`.

### 4.2 Data Sanitization & Escaping
Telegram's MarkdownV2 is highly sensitive to special characters. The logic layer must escape the following characters before sending to Telegram:
`_`, `*`, `[`, `]`, `(`, `)`, `~`, `` ` ``, `>`, `#`, `+`, `-`, `=`, `|`, `{`, `}`, `.`, `!`

**JavaScript Escaping Function (for n8n Code Node):**
```javascript
function escapeTelegramMarkdownV2(text) {
  if (!text) return '';
  const specialChars = ['_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!'];
  let escapedText = text;
  specialChars.forEach(char => {
    // Use regex to globally replace the character with its escaped version
    const regex = new RegExp('\\' + char, 'g');
    escapedText = escapedText.replace(regex, '\\' + char);
  });
  return escapedText;
}

// Example usage in n8n:
for (const item of $input.all()) {
  item.json.escapedTitle = escapeTelegramMarkdownV2(item.json.title);
  item.json.escapedUrl = escapeTelegramMarkdownV2(item.json.url);
  // Add more fields as needed
}
return $input.all();
```

### 4.3 State Loop Closure
After a successful push task, n8n must initiate a reverse callback to the Miniflux API to change the entry's status from `unread` to `read` to prevent duplicate pushes.
*   **API Endpoint**: `PUT /v1/entries`
*   **Payload**: `{"entry_ids": [ID], "status": "read"}`

### 4.4 Telegram Message Template
```markdown
*📰 \[Tech News\]* {escapedTitle}

*Source:* {escapedFeedTitle}
*Link:* [Read More]({escapedUrl})

\#TechNews \#Curated
```

## 5. Execution Plan

### Phase 1: Oracle K3s Node Preparation
1.  **Firewalld Configuration**: Add k3s pod/service CIDRs (`10.52.0.0/16`, `10.53.0.0/16`) and interfaces (`cni0`, `flannel.1`) to firewalld trusted zone.
2.  **CoreDNS Fix**: Patch CoreDNS ConfigMap to forward to `8.8.8.8 8.8.4.4` instead of `/etc/resolv.conf`.

### Phase 2: Secret Management
1.  **Install ESO**: Deploy External Secrets Operator via Helm in `oracle-k3s`.
2.  **Vault Token**: Create `vault-token` Secret in `rss-system` namespace.
3.  **ClusterSecretStore**: Deploy `vault-store.yaml` pointing to Vault via Tailscale IP (`http://100.107.254.112:31144`).
4.  **Vault Secrets**: Inject credentials into Vault:
    ```bash
    vault kv put secret/homelab/miniflux \
      db_password="<password>" \
      database_url="postgres://miniflux:<password>@miniflux-db.rss-system.svc.cluster.local:5432/miniflux?sslmode=disable" \
      admin_username="admin" \
      admin_password="<password>"
    ```

### Phase 3: Kubernetes Manifests
1.  **Create manifests** in `k8s/helm/manifests/rss-system/`:
    *   `namespace.yaml` — Namespace definition
    *   `vault-store.yaml` — ClusterSecretStore for Vault via Tailscale
    *   `secrets.yaml` — ExternalSecret definitions
    *   `miniflux.yaml` — Miniflux + PostgreSQL (Deployment, Service, PVC)
    *   `rsshub.yaml` — RSSHub + Redis + Browserless (Deployment, Service)
    *   `n8n.yaml` — n8n automation engine (Deployment, Service, PVC)
    *   `kustomization.yaml` — Kustomize entrypoint
2.  **Apply**: `kubectl apply -k k8s/helm/manifests/rss-system/`

### Phase 4: Ingress & Networking
1.  **Cloudflare Tunnel**: Deploy an independent `cloudflared` tunnel in `oracle-k3s` (separate from the homelab tunnel).
2.  **Terraform**: Update `cloudflare/terraform/` to configure `rss.meirong.dev` DNS pointing to the Oracle tunnel.
3.  **Gateway API**: Add `HTTPRoute` for `rss.meirong.dev` → `miniflux:8080`.

### Phase 5: Automation Setup
1.  **n8n Workflow**: Import the workflow JSON into the deployed n8n instance.
2.  **Credentials**: Configure Miniflux API, Telegram Bot, and Discord Webhook credentials in n8n.

### Phase 6: GitOps (Optional)
1.  **ArgoCD Application**: Create `argocd/applications/rss-system.yaml` for continuous deployment.

## 6. n8n Workflow JSON Definition
*(Save this as a `.json` file and import into n8n)*

```json
{
  "name": "K8s-Curator-Engine",
  "nodes": [
    {
      "parameters": {
        "rule": {
          "interval": [
            {
              "field": "minutes",
              "minutesInterval": 15
            }
          ]
        }
      },
      "name": "Schedule Trigger",
      "type": "n8n-nodes-base.scheduleTrigger",
      "typeVersion": 1.1,
      "position": [0, 0]
    },
    {
      "parameters": {
        "method": "GET",
        "url": "http://miniflux.rss-system.svc.cluster.local:8080/v1/entries?starred=true&status=unread",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "minifluxApi",
        "options": {}
      },
      "name": "Fetch Starred Entries",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.1,
      "position": [200, 0]
    },
    {
      "parameters": {
        "fieldToSplitOut": "entries",
        "options": {}
      },
      "name": "Item Lists",
      "type": "n8n-nodes-base.itemLists",
      "typeVersion": 3,
      "position": [400, 0]
    },
    {
      "parameters": {
        "jsCode": "function escapeTelegramMarkdownV2(text) {\n  if (!text) return '';\n  const specialChars = ['_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!'];\n  let escapedText = text;\n  specialChars.forEach(char => {\n    const regex = new RegExp('\\\\' + char, 'g');\n    escapedText = escapedText.replace(regex, '\\\\' + char);\n  });\n  return escapedText;\n}\n\nfor (const item of $input.all()) {\n  item.json.escapedTitle = escapeTelegramMarkdownV2(item.json.title);\n  item.json.escapedUrl = escapeTelegramMarkdownV2(item.json.url);\n  item.json.escapedFeedTitle = escapeTelegramMarkdownV2(item.json.feed.title);\n}\nreturn $input.all();"
      },
      "name": "Sanitize Data",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [600, 0]
    },
    {
      "parameters": {
        "chatId": "YOUR_TELEGRAM_CHAT_ID",
        "text": "=*📰 \\[Tech News\\]* {{$json.escapedTitle}}\n\n*Source:* {{$json.escapedFeedTitle}}\n*Link:* [Read More]({{$json.escapedUrl}})\n\n\\#TechNews \\#Curated",
        "parseMode": "MarkdownV2",
        "additionalFields": {}
      },
      "name": "Send to Telegram",
      "type": "n8n-nodes-base.telegram",
      "typeVersion": 1.1,
      "position": [800, -100]
    },
    {
      "parameters": {
        "webhookUri": "YOUR_DISCORD_WEBHOOK_URL",
        "text": "New Tech News!",
        "embeds": {
          "embedsValues": [
            {
              "title": "={{$json.title}}",
              "url": "={{$json.url}}",
              "description": "={{$json.feed.title}}",
              "color": "#0099ff"
            }
          ]
        }
      },
      "name": "Send to Discord",
      "type": "n8n-nodes-base.discord",
      "typeVersion": 2,
      "position": [800, 100]
    },
    {
      "parameters": {
        "method": "PUT",
        "url": "http://miniflux.rss-system.svc.cluster.local:8080/v1/entries",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "minifluxApi",
        "sendBody": true,
        "bodyParameters": {
          "parameters": [
            {
              "name": "entry_ids",
              "value": "={{[$json.id]}}"
            },
            {
              "name": "status",
              "value": "read"
            }
          ]
        },
        "options": {}
      },
      "name": "Mark as Read",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.1,
      "position": [1000, 0]
    }
  ],
  "connections": {
    "Schedule Trigger": {
      "main": [
        [
          {
            "node": "Fetch Starred Entries",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Fetch Starred Entries": {
      "main": [
        [
          {
            "node": "Item Lists",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Item Lists": {
      "main": [
        [
          {
            "node": "Sanitize Data",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Sanitize Data": {
      "main": [
        [
          {
            "node": "Send to Telegram",
            "type": "main",
            "index": 0
          },
          {
            "node": "Send to Discord",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Send to Telegram": {
      "main": [
        [
          {
            "node": "Mark as Read",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Send to Discord": {
      "main": [
        [
          {
            "node": "Mark as Read",
            "type": "main",
            "index": 0
          }
        ]
      ]
    }
  }
}
```

## 7. Future Roadmap
*   Integrate Ollama node in n8n for localized AI summary generation.
*   Add Prometheus monitoring for push success rates.
