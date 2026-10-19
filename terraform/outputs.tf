# Inputs echoed back for the scripts in ../scripts.
output "tenant_id" {
  value = var.tenant_id
}

output "workspace_url" {
  value = trimsuffix(var.workspace_url, "/")
}

output "lakebase_endpoint" {
  value = var.lakebase_endpoint
}

output "lakebase_database" {
  value = var.lakebase_database
}

output "apim_gateway_url" {
  description = "APIM gateway base URL."
  value       = azurerm_api_management.this.gateway_url
}

output "apim_subscription_key" {
  description = "Subscription key for /lakebase and /lakebase-s."
  value       = local.keyed_apis ? azurerm_api_management_subscription.this[0].primary_key : ""
  sensitive   = true
}

output "apim_mi_client_id" {
  description = "Shared MI's client ID = its Postgres role name (/lakebase and /lakebase-s)."
  value       = local.shared_mi ? azurerm_user_assigned_identity.this["apim"].client_id : ""
}

output "tenant_mi_client_ids" {
  description = "Tenant MIs' client IDs = their Postgres role names (/lakebase-t)."
  value       = { for t in local.tenants : t => azurerm_user_assigned_identity.this["tenant-${t}"].client_id }
}

output "gateway_app_id" {
  description = "Gateway app registration's client ID. Client tokens use scope api://<this>/.default."
  value       = local.tenant_rls ? azuread_application.gateway[0].client_id : ""
}

output "client_app_ids" {
  description = "Sample client apps' client IDs."
  value       = { for t in local.tenants : t => azuread_application.client[t].client_id }
}

output "client_secrets" {
  description = "Sample client apps' secrets (for testing)."
  value       = { for t in local.tenants : t => azuread_application_password.client[t].value }
  sensitive   = true
}

output "apis" {
  description = "Paths of the deployed APIs on the gateway."
  value = concat(
    var.enable_mi_api ? ["lakebase"] : [],
    local.tenant_rls ? ["lakebase-t"] : [],
    local.secret_api ? ["lakebase-s"] : [],
  )
}
