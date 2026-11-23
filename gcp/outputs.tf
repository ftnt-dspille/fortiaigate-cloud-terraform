output "vm_count" {
  value       = var.vm_count
  description = "Number of VMs deployed"
}

output "project_id" {
  value       = var.project_id
  description = "GCP project ID"
}

output "zone" {
  value       = var.zone
  description = "Default GCP zone"
}

output "zones" {
  value       = [for vm in google_compute_instance.faig : vm.zone]
  description = "Actual zone per VM"
}

output "vm_names" {
  value       = [for vm in google_compute_instance.faig : vm.name]
  description = "All VM names"
}

output "internal_ips" {
  value       = [for vm in google_compute_instance.faig : vm.network_interface[0].network_ip]
  description = "Internal IPs"
}

output "public_ips" {
  value       = google_compute_address.faig[*].address
  description = "Static public IPs (empty unless public_access_cidrs is set)"
}

output "gateway_urls" {
  # Prefer each VM's DNS name (the record sets exist when dns_zone is set and
  # follow the VM across zone moves); fall back to the raw IP without DNS.
  value = length(google_dns_record_set.faig) > 0 ? [
    for r in google_dns_record_set.faig :
    "https://${trimsuffix(r.name, ".")}/ai/openai/v1/chat/completions"
    ] : [
    for a in google_compute_address.faig :
    "https://${a.address}/ai/openai/v1/chat/completions"
  ]
  description = "FAIG OpenAI-compatible gateway per VM (needs a virtual key)"
}

output "iap_ssh_commands" {
  value       = [for vm in google_compute_instance.faig : "gcloud compute ssh --tunnel-through-iap --zone=${vm.zone} ${vm.name}"]
  description = "SSH to each VM via IAP tunnel"
}

output "iap_http_tunnels" {
  value       = [for i, vm in google_compute_instance.faig : "gcloud compute start-iap-tunnel --zone=${vm.zone} ${vm.name} 80 --local-host-port=localhost:808${i + 1}"]
  description = "Tunnel HTTP (FAIG UI) to localhost via IAP (one per VM)"
}

output "iap_https_tunnels" {
  value       = [for i, vm in google_compute_instance.faig : "gcloud compute start-iap-tunnel --zone=${vm.zone} ${vm.name} 443 --local-host-port=localhost:844${i + 1}"]
  description = "Tunnel HTTPS (FAIG UI) to localhost via IAP (one per VM)"
}

output "dns_name_servers" {
  value       = try(google_dns_managed_zone.faig[0].name_servers, [])
  description = "Add these as NS records for dns_zone at the parent domain's registrar (once)"
}

output "faig_hostnames" {
  value       = [for r in google_dns_record_set.faig : trimsuffix(r.name, ".")]
  description = "FAIG names (use these in lab vars, not the IP)"
}
