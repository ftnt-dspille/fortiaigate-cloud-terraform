variable "name_prefix" {
  type        = string
  default     = "faig"
  description = "Prefix for all resource names"
}

variable "location" {
  type        = string
  default     = "eastus"
  description = "Azure region for the resource group (and build VM). Kept stable across phases."
}

variable "vm_location" {
  type        = string
  default     = ""
  description = "Region for VM/network resources. Empty = same as location. Set to a different region for GPU deploy when the build region lacks GPU quota/capacity."
}

variable "instance_type" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "VM size: cheap CPU for build (D4s_v5), T4 GPU for run (NC4as_T4_v3)"
}

variable "vm_count" {
  type        = number
  default     = 1
  description = "Number of VMs to deploy (for cloning from a custom image)"
}

variable "spot" {
  type        = bool
  default     = false
  description = "Use spot instance (cheaper, evictable). Use on-demand for the build phase."
}

variable "spot_max_price" {
  type        = number
  default     = 0.30
  description = "Max hourly price for spot instance (USD). NC4as_T4_v3 spot is ~$0.15/hr."
}

variable "source_image_id" {
  type        = string
  default     = ""
  description = "Custom image ID to deploy from (from make_image.sh). Empty = use marketplace Ubuntu."
}

variable "admin_username" {
  type        = string
  default     = "azureuser"
  description = "SSH user (Azure Ubuntu default is azureuser with passwordless sudo)"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for VM access"
}

variable "disk_size_gb" {
  type        = number
  default     = 256
  description = "OS disk size. 256 GB fits FAIG tars (~20 GB) + containerd (~20 GB) + k3s + headroom."
}

variable "disk_type" {
  type        = string
  default     = "StandardSSD_LRS"
  description = "OS disk SKU: StandardSSD_LRS (cheap build), PremiumV2_LRS (fast GPU run)"
}

variable "ssh_source_ips" {
  type        = list(string)
  description = <<-EOT
    CIDRs allowed SSH access. REQUIRED -- there is no open default.
    Restrict to your own IPs, e.g. ["203.0.113.10/32"]. Find yours with:
    curl -s http://checkip.amazonaws.com
  EOT

  validation {
    condition     = length(var.ssh_source_ips) > 0 && !contains(var.ssh_source_ips, "0.0.0.0/0") && !contains(var.ssh_source_ips, "::/0")
    error_message = "ssh_source_ips must list specific CIDRs (e.g. your office/home IP). 0.0.0.0/0 is not allowed -- SSH must not be world-open."
  }
}

variable "https_source_ips" {
  type        = list(string)
  description = <<-EOT
    CIDRs allowed HTTPS (FAIG web UI) access. REQUIRED -- there is no open
    default. Restrict to the networks that need the UI, e.g. your office range
    or one /32 per student pod.
  EOT

  validation {
    condition     = length(var.https_source_ips) > 0 && !contains(var.https_source_ips, "0.0.0.0/0") && !contains(var.https_source_ips, "::/0")
    error_message = "https_source_ips must list specific CIDRs. 0.0.0.0/0 is not allowed -- expose the FAIG UI only to networks that need it."
  }
}

variable "enable_http" {
  type        = bool
  default     = false
  description = "Also allow inbound HTTP (80). Off by default -- FAIG serves the UI on HTTPS; enable only if you need a plain-HTTP listener."
}

variable "tags" {
  type        = map(string)
  default     = { project = "faig-cloud" }
  description = "Tags applied to all resources"
}
