# ── prod.tfvars ───────────────────────────────────────────────────────────────
# Usage: terraform apply -var-file="prod.tfvars"

environment         = "prod"
location            = "westeurope"
kubernetes_version  = "1.29"

# Production-grade nodes
system_node_vm_size = "Standard_D2s_v3"
user_node_vm_size   = "Standard_D4s_v3"
user_node_min_count = 3
user_node_max_count = 10
