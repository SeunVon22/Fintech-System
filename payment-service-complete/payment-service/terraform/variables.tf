# ── variables.tf ──────────────────────────────────────────────────────────────

variable "prefix" {
  description = "Short prefix for all resource names (e.g. 'monie')"
  type        = string
  default     = "monie"
}

variable "environment" {
  description = "Deployment environment: dev | staging | prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "westeurope"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version (check: az aks get-versions --location westeurope)"
  type        = string
  default     = "1.29"
}

# ── Networking ─────────────────────────────────────────────────────────────────
variable "vnet_cidr" {
  description = "CIDR block for the Virtual Network"
  type        = string
  default     = "10.10.0.0/16"
}

variable "aks_nodes_cidr" {
  description = "CIDR for the AKS nodes subnet (within vnet_cidr)"
  type        = string
  default     = "10.10.1.0/24"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services (must NOT overlap with vnet or pod CIDRs)"
  type        = string
  default     = "10.96.0.0/16"
}

variable "dns_service_ip" {
  description = "IP for the kube-dns service (must be within service_cidr)"
  type        = string
  default     = "10.96.0.10"
}

# ── Node pools ─────────────────────────────────────────────────────────────────
variable "system_node_vm_size" {
  description = "VM size for the system node pool"
  type        = string
  default     = "Standard_D2s_v3"   # 2 vCPU, 8 GB RAM
}

variable "user_node_vm_size" {
  description = "VM size for the user (workload) node pool"
  type        = string
  default     = "Standard_D4s_v3"   # 4 vCPU, 16 GB RAM
}

variable "user_node_min_count" {
  description = "Minimum nodes in the user pool (autoscaler lower bound)"
  type        = number
  default     = 2
}

variable "user_node_max_count" {
  description = "Maximum nodes in the user pool (autoscaler upper bound)"
  type        = number
  default     = 10
}
