output "servers" {
  description = "Per instance: VMID, inventory address, and the address(es) the guest agent reports."
  value = {
    for name, vm in proxmox_virtual_environment_vm.server : name => {
      vmid       = vm.vm_id
      role       = local.vms[name].role
      ipv4       = local.vms[name].ipv4
      agent_ipv4 = [for ip in flatten(vm.ipv4_addresses) : ip if !startswith(ip, "127.") && !startswith(ip, "169.254.")]
    }
  }
}
