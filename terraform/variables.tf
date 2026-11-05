variable "inventory_path" {
  description = "Resolved inventory (lab.yaml + site.yaml), written by the orchestrator."
  type        = string
  default     = "../inventory/resolved/inventory.json"
}

variable "ledger_path" {
  description = "Path to inventory/instances.yaml (written by the orchestrator)."
  type        = string
  default     = "../inventory/instances.yaml"
}
