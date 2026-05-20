# ── locals.tf ─────────────────────────────────────────────────────────────────
locals {
  common_tags = {
    project     = "payment-service"
    environment = var.environment
    managed_by  = "terraform"
    owner       = "platform-engineering"
  }
}


# ── outputs.tf ────────────────────────────────────────────────────────────────
output "aks_cluster_name" {
  description = "AKS cluster name — use in Jenkins: az aks get-credentials"
  value       = azurerm_kubernetes_cluster.main.name
}

output "aks_resource_group" {
  description = "Resource group containing the AKS cluster"
  value       = azurerm_resource_group.main.name
}

output "acr_login_server" {
  description = "ACR login server URL — prefix for all image tags"
  value       = azurerm_container_registry.main.login_server
}

output "acr_name" {
  description = "ACR registry name"
  value       = azurerm_container_registry.main.name
}

output "kube_config" {
  description = "Raw kubeconfig for the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true   # masked in logs; retrieve with: terraform output -raw kube_config
}

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for linking additional diagnostic settings"
  value       = azurerm_log_analytics_workspace.main.id
}
