# =============================================================================
# Cloudflare WAF & Zone Security Configuration
# Zone-level rules — apply to ALL subdomains across both tunnels (homelab + oracle-k3s)
# =============================================================================

# ---------------------------------------------------------------------------
# Zone Security Settings
# ---------------------------------------------------------------------------

# Enforce Full SSL: origin ↔ Cloudflare always encrypted (tunnels already use this)
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "ssl"
  value      = "full"
}

# Minimum TLS 1.2 — block obsolete TLS 1.0/1.1 (known vulnerabilities: BEAST, POODLE)
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# Auto-redirect HTTP → HTTPS
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "always_use_https"
  value      = "on"
}

# Security Level: medium — challenge visitors from moderately suspicious IPs
# (uses Cloudflare IP reputation database)
resource "cloudflare_zone_setting" "security_level" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "security_level"
  value      = "medium"
}

# Browser Integrity Check — block requests with missing/abnormal HTTP headers
# (common in bots and automated scanners)
resource "cloudflare_zone_setting" "browser_check" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "browser_check"
  value      = "on"
}

# Email Obfuscation — hide email addresses from scrapers in HTML responses
resource "cloudflare_zone_setting" "email_obfuscation" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "email_obfuscation"
  value      = "on"
}

# Hotlink Protection — prevent other sites from linking to your resources
resource "cloudflare_zone_setting" "hotlink_protection" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "hotlink_protection"
  value      = "on"
}

# Opportunistic Encryption — serve HTTP sites over TLS when supported
resource "cloudflare_zone_setting" "opportunistic_encryption" {
  zone_id    = data.cloudflare_zone.meirong.id
  setting_id = "opportunistic_encryption"
  value      = "on"
}

# ---------------------------------------------------------------------------
# Custom WAF Rules (Free plan: 5 rules)
# Phase: http_request_firewall_custom
# ---------------------------------------------------------------------------

resource "cloudflare_ruleset" "waf_custom_rules" {
  zone_id     = data.cloudflare_zone.meirong.id
  name        = "Custom WAF Rules"
  description = "Custom WAF rules protecting meirong.dev services"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [
    # Rule 1: Block WordPress / PHP / admin panel exploitation attempts
    # These paths are targeted by automated scanners — none of our services use them
    {
      action      = "block"
      expression  = "(http.request.uri.path contains \"/wp-\") or (http.request.uri.path contains \"/xmlrpc.php\") or (http.request.uri.path contains \"/phpmyadmin\") or (http.request.uri.path contains \"/pma\") or (http.request.uri.path contains \"/adminer\") or (http.request.uri.path contains \"/cgi-bin\") or (http.request.uri.path contains \"/wp-login\") or (http.request.uri.path contains \"/wp-cron\")"
      description = "Block WordPress/PHP/admin scanner paths"
      enabled     = true
    },

    # Rule 2: Block access to sensitive files and directories
    # Prevents leaking config files, version control data, and server info
    {
      action      = "block"
      expression  = "(http.request.uri.path contains \"/.env\") or (http.request.uri.path contains \"/.git\") or (http.request.uri.path contains \"/.svn\") or (http.request.uri.path contains \"/.htaccess\") or (http.request.uri.path contains \"/.htpasswd\") or (http.request.uri.path contains \"/.DS_Store\") or (http.request.uri.path eq \"/server-status\") or (http.request.uri.path eq \"/server-info\") or (http.request.uri.path contains \"/.well-known/security.txt\" and not http.host eq \"meirong.dev\")"
      description = "Block sensitive file and directory access"
      enabled     = true
    },

    # Rule 3: Block known vulnerability scanner user agents
    # These tools are used exclusively for malicious reconnaissance
    {
      action      = "block"
      expression  = "(http.user_agent contains \"sqlmap\") or (http.user_agent contains \"nikto\") or (http.user_agent contains \"nmap\") or (http.user_agent contains \"masscan\") or (http.user_agent contains \"dirbuster\") or (http.user_agent contains \"gobuster\") or (http.user_agent contains \"wpscan\") or (http.user_agent contains \"havij\") or (http.user_agent contains \"zmeu\") or (http.user_agent contains \"acunetix\") or (http.user_agent contains \"nessus\") or (http.user_agent contains \"qualys\")"
      description = "Block known vulnerability scanner user agents"
      enabled     = true
    },

    # Rule 4: Managed Challenge for high threat score visitors
    # Cloudflare assigns threat scores (0-100) based on IP reputation;
    # score > 14 = suspicious traffic → present a JS challenge
    {
      action      = "managed_challenge"
      expression  = "(cf.threat_score gt 14)"
      description = "Challenge visitors with high threat score"
      enabled     = true
    },

    # Rule 5: Block non-standard HTTP methods
    # Only allow methods actually used by our services (REST APIs + browser navigation)
    {
      action      = "block"
      expression  = "not http.request.method in {\"GET\" \"POST\" \"HEAD\" \"OPTIONS\" \"PUT\" \"DELETE\" \"PATCH\"}"
      description = "Block non-standard HTTP methods (TRACE, CONNECT, etc.)"
      enabled     = true
    },
  ]
}

# ---------------------------------------------------------------------------
# Rate Limiting Rules
# Phase: http_ratelimit
# ---------------------------------------------------------------------------

resource "cloudflare_ruleset" "rate_limiting" {
  zone_id     = data.cloudflare_zone.meirong.id
  name        = "Rate Limiting Rules"
  description = "Rate limiting rules for meirong.dev"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    # Rate limit authentication / login endpoints
    # Prevents brute-force login attempts across all services:
    #   auth.meirong.dev (ZITADEL), grafana.meirong.dev, vault.meirong.dev, etc.
    # Threshold: 10 requests / 10 seconds per source IP per colo → block for 10 seconds
    # Note: Free plan limits period and mitigation_timeout to 10s;
    #       Pro plan ($20/mo) allows 60s/600s for more effective brute-force protection
    {
      action      = "block"
      expression  = "(http.request.uri.path contains \"/login\") or (http.request.uri.path contains \"/oauth2\") or (http.request.uri.path contains \"/api/login\") or (http.request.uri.path contains \"/signin\") or (http.request.uri.path contains \"/v1/auth\")"
      description = "Rate limit authentication endpoints (10 req/10s per IP)"
      enabled     = true
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10
        requests_per_period = 10
        mitigation_timeout  = 10
      }
    },
  ]
}

# ---------------------------------------------------------------------------
# NOTE: Managed WAF Rulesets (Pro plan and above)
# ---------------------------------------------------------------------------
# The following managed rulesets provide additional protection but require
# Cloudflare Pro ($20/mo) or higher:
#
# 1. Cloudflare Managed Ruleset (efb7b8c949ac4650a09736fc376e9aee)
#    - Covers SQLi, XSS, RCE, LFI, and other OWASP Top 10 vulnerabilities
#    - Updated continuously by Cloudflare's threat intelligence team
#
# 2. Cloudflare OWASP Core Ruleset (4814384a9e5d4991b9815dcfc25d2f1f)
#    - Port of ModSecurity CRS — paranoia-level scoring system
#    - Detects anomalous request patterns
#
# 3. Cloudflare Leaked Credentials Detection (c2e184081120413c86c3ab7e14069605)
#    - Checks login requests against known breached credential databases
#
# To enable (Pro plan required), uncomment and add to this file:
#
# resource "cloudflare_ruleset" "managed_waf" {
#   zone_id = data.cloudflare_zone.meirong.id
#   name    = "Managed WAF Rulesets"
#   kind    = "zone"
#   phase   = "http_request_firewall_managed"
#
#   rules = [
#     {
#       action = "execute"
#       action_parameters = { id = "efb7b8c949ac4650a09736fc376e9aee" }
#       expression  = "true"
#       description = "Cloudflare Managed Ruleset"
#       enabled     = true
#     },
#     {
#       action = "execute"
#       action_parameters = { id = "4814384a9e5d4991b9815dcfc25d2f1f" }
#       expression  = "true"
#       description = "Cloudflare OWASP Core Ruleset"
#       enabled     = true
#     },
#   ]
# }
