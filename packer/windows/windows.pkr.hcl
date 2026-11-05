// Golden Windows templates: WIN2022-TEMPLATE and WIN11-TEMPLATE.
//
// One definition for both. Pick the template with -var template_key=
// (windows_server_2022 | windows_11); everything else, including drivers,
// TPM and image index, comes from the resolved inventory (lab.yaml + site.yaml),
// templates.<key>.build.
// Only secrets are variables:
//   PKR_VAR_proxmox_token_secret   API token secret for <user>!<packer_token_name>
//   PKR_VAR_local_admin_password   built-in Administrator (KeePass: MidCoast-LocalAdministrator)
//
// Run through orchestration/Build-LabTemplate.ps1, which builds at the
// staging VMID and, on success, clones the result into a new template version.

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
    windows-update = {
      version = ">= 0.15.0"
      source  = "github.com/rgl/windows-update"
    }
  }
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
}

variable "local_admin_password" {
  type      = string
  sensitive = true
}

variable "template_key" {
  type        = string
  default     = "windows_server_2022"
  description = "Key under templates: in lab.yaml."
}

variable "inventory_path" {
  type    = string
  default     = ""
  description = "Resolved inventory JSON (lab.yaml + site.yaml). Build-LabTemplate passes it; empty = inventory/resolved/inventory.json."
}

locals {
  inv_file = var.inventory_path != "" ? var.inventory_path : "${path.root}/../../inventory/resolved/inventory.json"
  inv      = jsondecode(file(local.inv_file))
  tpl     = local.inv.templates[var.template_key]
  build   = local.tpl.build
  pve     = local.inv.proxmox
  stamp   = formatdate("YYYYMMDD-hhmm", timestamp())

  // Every address an MGMT can hold. Guests allow WinRM from all of them, so a
  // replacement MGMT (built into the spare slot) can manage the whole lab.
  mgmt_role = [for s in local.inv.servers : s if s.role == "MGMT"][0]
  mgmt_ips  = try([for sl in local.mgmt_role.slots : sl.ipv4], [local.mgmt_role.ipv4])

  // Unattend files take passwords as base64(UTF-16LE(password + suffix)).
  admin_pw_b64     = textencodebase64("${var.local_admin_password}AdministratorPassword", "UTF-16LE")
  autologon_pw_b64 = textencodebase64("${var.local_admin_password}Password", "UTF-16LE")

  // Windows 10/11 (client) clones need a local account in OOBE, or OOBE stops at
  // "Who's going to use this device?". Server doesn't.
  is_client = length(regexall("(?i)windows 1[01]", try(local.tpl.operating_system, ""))) > 0

  cbi_conf = "C:/Program Files/Cloudbase Solutions/Cloudbase-Init/conf"
  cbi_ls   = "C:/Program Files/Cloudbase Solutions/Cloudbase-Init/LocalScripts"
}

source "proxmox-iso" "windows" {
  proxmox_url              = "${trimsuffix(local.pve.endpoint, "/")}/api2/json"
  username                 = "${local.pve.service_account.user}!${local.pve.service_account.packer_token_name}"
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = local.pve.insecure_tls
  node                     = local.pve.node
  pool                     = local.pve.pool
  task_timeout             = "20m"

  vm_id                = local.build.staging_vmid
  vm_name              = "${upper(local.build.tag)}-BUILD-${local.stamp}"
  template_name        = "${local.tpl.template_name}-STAGING"
  template_description = "${local.tpl.operating_system} evaluation, built ${local.stamp} by Packer from ${try(local.inv.release, "")} (compatibility ${local.inv.version})."
  tags                 = "midcoast-lab;template;${local.build.tag}"

  os              = "win11"
  bios            = "ovmf"
  machine         = "q35"
  cpu_type        = "x86-64-v2-AES"
  cores           = 2
  memory          = 4096
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  efi_config {
    efi_storage_pool  = local.pve.storage.templates
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  // Windows 11 requires TPM 2.0 (inventory: build.tpm).
  dynamic "tpm_config" {
    for_each = try(local.build.tpm, false) ? [1] : []
    content {
      tpm_storage_pool = local.pve.storage.templates
      tpm_version      = "v2.0"
    }
  }

  disks {
    type         = "scsi"
    disk_size    = "${local.build.disk_gb}G"
    storage_pool = local.pve.storage.templates
    io_thread    = true
    discard      = true
    ssd          = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = local.inv.network.bridge
    firewall = false
  }

  boot_iso {
    type         = "sata"
    index        = "0"
    iso_file     = local.build.iso
    iso_checksum = "none"
    unmount      = true
  }

  additional_iso_files {
    type         = "sata"
    index        = "1"
    iso_file     = local.build.virtio_iso
    iso_checksum = "none"
    unmount      = true
  }

  // Generated CD (needs oscdimg on MGMT: Windows ADK Deployment Tools).
  additional_iso_files {
    type             = "sata"
    index            = "2"
    iso_storage_pool = local.pve.storage.iso_repository
    unmount          = true
    cd_label         = "BOOTSTRAP"
    cd_content = {
      "autounattend.xml" = templatefile("${path.root}/files/autounattend.xml.pkrtpl", {
        image_index      = local.build.image_index
        driver_os        = local.build.driver_os
        computer_name    = "${upper(local.build.tag)}-BUILD"
        time_zone        = local.inv.environment.time_zone
        admin_pw_b64     = local.admin_pw_b64
        autologon_pw_b64 = local.autologon_pw_b64
      })
      "build-bootstrap.ps1" = file("${path.root}/files/build-bootstrap.ps1")
    }
  }

  // No cloud-init drive here: Terraform adds one to each clone (ide2).

  boot         = "order=scsi0;sata0"
  boot_wait    = "3s"
  boot_command = ["<spacebar><wait1s><spacebar><wait1s><spacebar><wait1s><spacebar><wait1s><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.local_admin_password
  winrm_port     = 5986
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "2h"
}

build {
  sources = ["source.proxmox-iso.windows"]

  // ── Patch ──────────────────────────────────────────────────────────
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
    update_limit = 50
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  // ── Template software: PowerShell 7, Cloudbase-Init ───────────────
  // (QEMU guest agent came with the VirtIO guest tools in build-bootstrap.ps1.)
  provisioner "powershell" {
    script = "${path.root}/scripts/Install-LabSoftware.ps1"
    environment_vars = [
      "LAB_PWSH_VERSION=${local.build.software_versions.powershell}",
      "LAB_CBI_CHANNEL=${local.build.software_versions.cloudbase_init}",
    ]
  }

  // A second update pass catches anything the new software pulled in.
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
  }

  // ── Cloudbase-Init configuration and first-boot script ────────────
  provisioner "file" {
    source      = "${path.root}/files/cloudbase-init.conf"
    destination = "${local.cbi_conf}/cloudbase-init.conf"
  }

  provisioner "file" {
    source      = "${path.root}/files/cloudbase-init-unattend.conf"
    destination = "${local.cbi_conf}/cloudbase-init-unattend.conf"
  }

  provisioner "file" {
    content = templatefile("${path.root}/files/Initialize-LabRemoting.ps1.pkrtpl", {
      mgmt_ips = join(",", local.mgmt_ips)
    })
    destination = "${local.cbi_ls}/Initialize-LabRemoting.ps1"
  }

  provisioner "file" {
    content = templatefile("${path.root}/files/unattend.xml.pkrtpl", {
      time_zone        = local.inv.environment.time_zone
      admin_pw_b64     = local.admin_pw_b64
      localacct_pw_b64 = local.autologon_pw_b64
      is_client        = local.is_client
    })
    destination = "C:/Windows/Panther/unattend-midcoast.xml"
  }

  // ── Generalize (last; Packer then stops the VM and makes it a template)
  provisioner "powershell" {
    script = "${path.root}/scripts/Finalize-Template.ps1"
  }
}
