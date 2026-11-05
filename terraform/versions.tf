terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.95"
    }
  }

  # State lives on the active MGMT, outside the repo (inventory: terraform.state.path).
  # Invoke-LabTerraform (used by phases and rotations) passes it with -state;
  # see docs/decisions.md for why it
  # is not a backend block yet (CentralTerraformState is deferred).
}

provider "proxmox" {
  endpoint = local.pve.endpoint
  insecure = local.pve.insecure_tls
  # API token comes from PROXMOX_VE_API_TOKEN ("terraform-prov@pve!terraform=<secret>"),
  # which the orchestrator reads from KeePass. No SSH, no root.
}
