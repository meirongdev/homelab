resource "cloudflare_ai_gateway" "shared" {
  account_id = var.cloudflare_account_id
  id         = var.ai_gateway_id

  authentication             = var.ai_gateway_authentication
  cache_invalidate_on_update = var.ai_gateway_cache_invalidate_on_update
  cache_ttl                  = var.ai_gateway_cache_ttl
  collect_logs               = var.ai_gateway_collect_logs
  rate_limiting_interval     = var.ai_gateway_rate_limiting_interval
  rate_limiting_limit        = var.ai_gateway_rate_limiting_limit
}
