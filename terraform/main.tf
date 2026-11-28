# Terraform owns: virtual machines, storage, networking, templates, lifecycle.
# It reads two files and nothing else:
#   resolved/inventory.json  lab.yaml + site.yaml, merged by the orchestrator
#                            (Get-LabResolvedInventory); never hand-edited
#   instances.yaml           which instances exist (name, vmid, build date, slot,
#                            and the template version each is cloned from); the
#                            site's ledger, in site/ (Invoke-LabTerraform passes
#                            both paths as -var)
# Adding an instance to the ledger creates a VM; removing it destroys one.
# VMs are linked clones (proxmox.clone_mode) of the template version pinned in
# the ledger, so building a newer template never changes an existing VM.
# Ledger entries with origin: manual (the hand-built first MGMT) are skipped:
# Terraform never created them and never touches them.

locals {
  inv    = jsondecode(file(var.inventory_path))
  ledger = yamldecode(file(var.ledger_path))
  pve    = local.inv.proxmox

  role_defs = { for s in local.inv.servers : s.role => s }
  site_mode = lower(try(local.pve.clone_mode, "linked"))

  instances = coalesce(try(local.ledger.instances, null), [])

  vms = {
    for i in local.instances : i.name => {
      role          = i.role
      vmid          = i.vmid
      ipv4          = i.ipv4
      build_date    = i.build_date
      slot          = try(i.slot, null)
      def           = local.role_defs[i.role]
      template_vmid = try(i.template_vmid, null)
      # Recorded per instance when it was allocated, so changing the site's
      # clone_mode only affects new VMs (changing it would replace a VM).
      linked = lower(try(i.clone_mode, local.site_mode)) == "linked"
    }
    if try(i.origin, "pipeline") != "manual"
  }
}

resource "proxmox_virtual_environment_vm" "server" {
  for_each = local.vms

  name        = each.key
  node_name   = local.pve.node
  vm_id       = each.value.vmid
  pool_id     = local.pve.pool
  description = "MidCoast Lab ${each.value.role}${each.value.slot != null ? " slot ${each.value.slot}" : ""}, built ${each.value.build_date}. Managed by Terraform; do not edit."
  tags        = [local.pve.tag, lower(each.value.role), "build-${each.value.build_date}"]

  on_boot         = true
  started         = true
  stop_on_destroy = true
  timeout_clone   = 1800
  timeout_create  = 1800

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  clone {
    vm_id        = each.value.template_vmid
    node_name    = local.pve.node
    datastore_id = each.value.linked ? null : local.pve.storage.virtual_machines
    full         = !each.value.linked
    retries      = 3
  }

  # Terraform waits for the guest agent to report a DHCP address on first
  # boot; the orchestrator connects there, then bootstrap sets the static IP.
  agent {
    enabled = true
    timeout = "30m"
    wait_for_ip {
      ipv4 = true
    }
  }

  operating_system {
    type = "win11"
  }

  cpu {
    cores = each.value.def.cpu
    type  = "x86-64-v2-AES"
  }

  # Ballooning: up to memory_mb, and Proxmox may reclaim down to memory_min_mb
  # when the host runs short (needs the balloon service, which the templates have).
  memory {
    dedicated = each.value.def.memory_mb
    floating  = try(each.value.def.memory_min_mb, each.value.def.memory_mb)
  }

  disk {
    # Linked clones live on the template's storage.
    datastore_id = each.value.linked ? local.pve.storage.templates : local.pve.storage.virtual_machines
    interface    = "scsi0"
    size         = each.value.def.disk_gb
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = local.inv.network.bridge
    model  = "virtio"
  }

  # Config drive for Cloudbase-Init: hostname (from the VM name) only.
  initialization {
    datastore_id = local.pve.storage.virtual_machines
    interface    = "ide2"
    type         = "configdrive2"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(each.key) <= local.inv.naming.max_length
      error_message = "Hostname ${each.key} exceeds ${local.inv.naming.max_length} characters."
    }
    precondition {
      condition     = each.value.template_vmid != null
      error_message = "${each.key} has no template_vmid in the ledger; allocate instances through the pipeline."
    }
    precondition {
      condition     = each.value.vmid >= local.pve.vmid_base && each.value.vmid <= local.pve.vmid_base + 99
      error_message = "VMID ${each.value.vmid} for ${each.key} is outside the site's server range ${local.pve.vmid_base}-${local.pve.vmid_base + 99}."
    }
  }
}
