output "public_ip" {
  value       = azurerm_public_ip.faig[0].ip_address
  description = "Public IP of the first VM"
}

output "public_ips" {
  value       = azurerm_public_ip.faig[*].ip_address
  description = "Public IPs of all VMs"
}

output "vm_names" {
  value       = azurerm_linux_virtual_machine.faig[*].name
  description = "Names of all VMs (for az vm stop/start/deallocate)"
}

output "resource_group_name" {
  value       = azurerm_resource_group.faig.name
  description = "Resource group name (for snapshot/image operations)"
}

output "ssh_command" {
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.faig[0].ip_address}"
  description = "SSH command to connect to the first VM"
}
