# ── dev.tfvars ────────────────────────────────────────────────────────────────
# Usage: terraform apply -var-file="dev.tfvars"

environment         = "dev"
location            = "westeurope"
kubernetes_version  = "1.29"

# Smaller, cheaper nodes for dev
system_node_vm_size = "Standard_B2s"
user_node_vm_size   = "Standard_B4ms"
user_node_min_count = 1
user_node_max_count = 3
