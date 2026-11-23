variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "name_prefix" {
  type        = string
  default     = "faig"
  description = "Prefix for all resource names"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region"
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
  description = "Default GCP zone (used when zones list is empty or shorter than vm_count)"
}

variable "zones" {
  type        = list(string)
  default     = []
  description = "Zone per instance (zones[0] = faig-1, ...); falls back to var.zone. Written by scripts/gpu_place.sh into placement.tfvars.json -- a zone in gpu.tfvars is only a preference."
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-4"
  description = "GCP machine type: cheap CPU for build (e2-standard-4), T4 GPU for run (n1-standard-4)"
}

variable "gpu_type" {
  type        = string
  default     = "nvidia-tesla-t4"
  description = "GPU accelerator type (nvidia-tesla-t4, nvidia-tesla-v100, etc.)"
}

variable "gpu_count" {
  type        = number
  default     = 0
  description = "Number of GPUs per VM. Set to 1+ for GPU phase (requires n1-* machine type)."
}

variable "vm_count" {
  type        = number
  default     = 1
  description = "Number of VMs to deploy (for cloning from a custom image)"
}

variable "spot" {
  type        = bool
  default     = false
  description = "Use preemptible instance (cheaper, evictable). Use on-demand for the build phase."
}

variable "source_image" {
  type        = string
  default     = ""
  description = "Custom image self-link to deploy from (from make_image.sh). Empty = use marketplace Ubuntu."
}

variable "admin_username" {
  type        = string
  default     = "ubuntu"
  description = "SSH user (GCP Ubuntu default is ubuntu with passwordless sudo)"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for VM access (without username prefix)"
}

variable "disk_size_gb" {
  type        = number
  default     = 256
  description = "Boot disk size. 256 GB fits FAIG tars (~43 GB) + containerd (~20 GB) + k3s + headroom."
}

variable "disk_type" {
  type        = string
  default     = "pd-standard"
  description = "Boot disk type: pd-standard (cheap build), pd-ssd (fast GPU run)"
}

variable "auto_start_schedule" {
  type        = string
  default     = ""
  description = "Cron schedule to auto-start VMs (UTC). Example: '0 8 * * 1-5' = 8am UTC Mon-Fri. Empty = disabled."
}

variable "auto_stop_schedule" {
  type        = string
  default     = ""
  description = "Cron schedule to auto-stop VMs (UTC). Example: '0 18 * * 1-5' = 6pm UTC Mon-Fri. Empty = disabled."
}

variable "schedule_time_zone" {
  type        = string
  default     = "UTC"
  description = "Time zone for auto-start/stop schedules (e.g. America/New_York)"
}

variable "tags" {
  type        = map(string)
  default     = { project = "faig-cloud" }
  description = "Labels applied to all resources"
}

variable "public_access_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Source CIDRs allowed to reach each VM's FAIG ingress on 443 over a static
    public IP. Empty (the default) keeps the VMs IAP-only with no public IP.
    For the workshop: one /32 per student FortiDemo pod -- a pod's workstations
    egress on the pod hostname's own A record, both through the FGT and OOB.
  EOT
}

variable "dns_zone" {
  type        = string
  default     = ""
  description = "Subdomain delegated to Cloud DNS for FAIG's name (e.g. faig.example.com); empty = no DNS"
}

variable "auto_unreserve" {
  type        = bool
  default     = true
  description = "Release each VM's GPU hold (faig-<n>-hold) on auto_stop_schedule, so a stopped lab stops billing for it"
}
