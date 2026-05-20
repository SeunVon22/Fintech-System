# ── main.tf ───────────────────────────────────────────────────────────────────
# Provisions:
#   - Resource Group
#   - Virtual Network + Subnets (AKS, pods, services)
#   - Azure Container Registry (ACR)
#   - AKS Cluster (system + user node pools)
#   - Role assignments (AKS → ACR pull, kubelet managed identity)
#   - Log Analytics Workspace (for AKS diagnostics)
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.48"
    }
  }

  # Remote state — store in Azure Blob Storage so teams share the same state.
  # Never use local state in production; concurrent applies corrupt it.
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "moniepointtfstate"   # must be globally unique
    container_name       = "tfstate"
    key                  = "payment-service/terraform.tfstate"
    # State is locked automatically via Azure Blob lease — no DynamoDB needed
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true  # safety guard
    }
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────
data "azurerm_client_config" "current" {}

# ── Resource Group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-${var.environment}-rg"
  location = var.location

  tags = local.common_tags
}

# ── Log Analytics Workspace (AKS diagnostics & Container Insights) ────────────
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.prefix}-${var.environment}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.common_tags
}

# ── Virtual Network ───────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-${var.environment}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]

  tags = local.common_tags
}

# AKS nodes subnet
resource "azurerm_subnet" "aks_nodes" {
  name                 = "aks-nodes-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_nodes_cidr]
}

# ── Azure Container Registry ──────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                = "${var.prefix}${var.environment}acr"   # no hyphens allowed
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  admin_enabled       = false   # use managed identity, not admin credentials

  # Geo-replication available on Premium SKU — upgrade when needed
  tags = local.common_tags
}

# ── AKS Cluster ───────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-${var.environment}-aks"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "${var.prefix}-${var.environment}"
  kubernetes_version  = var.kubernetes_version

  # Use SystemAssigned managed identity — no service principal credentials to rotate
  identity {
    type = "SystemAssigned"
  }

  # ── System node pool (runs kube-system pods only) ──────────────────────────
  # Kept separate from workload nodes so system components are never evicted
  # under resource pressure from application pods.
  default_node_pool {
    name                 = "system"
    node_count           = 2
    vm_size              = var.system_node_vm_size
    vnet_subnet_id       = azurerm_subnet.aks_nodes.id
    os_disk_size_gb      = 50
    type                 = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true   # taints this pool: CriticalAddonsOnly

    upgrade_settings {
      max_surge = "33%"   # allow 33% extra nodes during cluster upgrade
    }

    tags = local.common_tags
  }

  # ── Networking ────────────────────────────────────────────────────────────
  network_profile {
    network_plugin     = "azure"         # Azure CNI — pods get VNet IPs
    network_policy     = "calico"        # NetworkPolicy enforcement
    load_balancer_sku  = "standard"
    outbound_type      = "loadBalancer"
    service_cidr       = var.service_cidr
    dns_service_ip     = var.dns_service_ip
  }

  # ── Addons ────────────────────────────────────────────────────────────────
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  azure_policy_enabled             = true
  http_application_routing_enabled = false   # use Nginx Ingress instead

  # ── RBAC ─────────────────────────────────────────────────────────────────
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # ── Auto-upgrade ──────────────────────────────────────────────────────────
  automatic_channel_upgrade = "patch"   # auto-apply patch versions (e.g. 1.29.x)
  node_os_channel_upgrade   = "NodeImage"

  tags = local.common_tags
}

# ── User node pool (runs application workloads) ───────────────────────────────
# Separate from system pool — can be scaled independently or replaced
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_vm_size
  min_count             = var.user_node_min_count
  max_count             = var.user_node_max_count
  enable_auto_scaling   = true
  vnet_subnet_id        = azurerm_subnet.aks_nodes.id
  os_disk_size_gb       = 100
  mode                  = "User"

  upgrade_settings {
    max_surge = "33%"
  }

  tags = local.common_tags
}

# ── Role Assignments ──────────────────────────────────────────────────────────

# Allow AKS kubelet identity to pull images from ACR
# This replaces imagePullSecrets — cleaner and no credentials to manage
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

# Allow AKS cluster identity to manage networking in the VNet
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}
