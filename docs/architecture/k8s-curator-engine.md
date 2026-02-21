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
The system is deployed in the Oracle Cloud K3s cluster with the following specifications:

*   **Namespace**: `rss-system`
*   **Workloads**:
    *   `rsshub`: Deployment (Port 1200) + Service + Redis (Cache)
    *   `miniflux`: Deployment (Port 8080) + Service + PostgreSQL
    *   `n8n`: Deployment (Port 5678) + Service (Persistent volume at `/home/node/.n8n`)
*   **Persistence**:
    *   `PersistentVolumeClaim` (PVC) using the `local-path` storage class for PostgreSQL and n8n.
*   **Ingress**:
    *   Gateway API `HTTPRoute` routing `rss.meirong.dev` to the Miniflux service.
    *   Cloudflare Tunnel configured to route `rss.meirong.dev` to the cluster's Traefik ingress.
*   **Security**:
    *   All sensitive tokens (Telegram Bot Token, Discord Webhook, DB Passwords) are managed via External Secrets Operator (ESO) fetching from HashiCorp Vault.

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

1.  **Infrastructure as Code (Terraform)**:
    *   Update `cloudflare/terraform/variables.tf` to include `rss` in `ingress_rules`.
2.  **Kubernetes Manifests (Helm/Kustomize)**:
    *   Create `k8s/helm/manifests/rss-system/` directory.
    *   Define `namespace.yaml`.
    *   Define `miniflux.yaml` (Deployment, Service, PVC, Postgres).
    *   Define `rsshub.yaml` (Deployment, Service, Redis).
    *   Define `n8n.yaml` (Deployment, Service, PVC).
    *   Define `secrets.yaml` (ExternalSecret definitions).
3.  **Ingress Configuration**:
    *   Add `HTTPRoute` for `rss.meirong.dev` in `k8s/helm/manifests/gateway.yaml`.
4.  **GitOps Deployment**:
    *   Create `argocd/applications/rss-system.yaml` to deploy the namespace.
5.  **Vault Secrets**:
    *   Inject the required database credentials and Miniflux admin credentials into HashiCorp Vault so that ExternalSecrets could sync them.
    *   `vault kv put secret/homelab/miniflux db_password="supersecretpassword" database_url="postgres://miniflux:supersecretpassword@miniflux-db.rss-system.svc.cluster.local:5432/miniflux?sslmode=disable" admin_username="admin" admin_password="adminpassword"`
6.  **n8n Workflow Setup**:
    *   Import the workflow JSON (provided below) into the deployed n8n instance.
    *   Configure Miniflux API credentials in n8n.
    *   Configure Telegram/Discord credentials in n8n.

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
