variable "inventory_path" {
  description = "Resolved inventory (lab.yaml + site.yaml), written by the orchestrator."
  type        = string
  default     = "../inventory/resolved/inventory.json"
}

variable "ledger_path" {
  description = "Path to the site's ledger, instances.yaml (written by the orchestrator, which always passes it)."
  type        = string
  default     = "../site/instances.yaml"
}
