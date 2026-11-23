# VPC -- isolated network for FAIG
resource "google_compute_network" "faig" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

# Per-instance placement. zones[i] overrides the default zone for instance i+1;
# the region is derived from the zone so instances can span regions (e.g.
# faig-1 in us-central1-c, faig-2 in us-east1-c when L4 is only there).
locals {
  instance_zones   = [for i in range(var.vm_count) : length(var.zones) > i ? var.zones[i] : var.zone]
  instance_regions = [for z in local.instance_zones : regex("^[a-z]+-[a-z0-9]+", z)]
  region_cidrs = {
    us-central1 = "10.0.1.0/24"
    us-east1    = "10.0.2.0/24"
    us-east4    = "10.0.3.0/24"
    us-west1    = "10.0.4.0/24"
    us-west4    = "10.0.5.0/24"
  }
  subnet_cidr = { for r in distinct(local.instance_regions) : r => lookup(local.region_cidrs, r, "10.0.9.0/24") }
  # Regional resources are keyed by region NAME, not position, so moving one VM
  # to another region never renumbers (and replaces) another VM's subnet. The
  # home region (var.region) keeps the original unsuffixed names.
  regions      = toset(local.instance_regions)
  region_name  = { for r in local.regions : r => r == var.region ? "" : "-${r}" }
  has_schedule = var.auto_start_schedule != "" || var.auto_stop_schedule != ""
}

# Subnet -- one per region an instance lands in (subnets are regional in GCP).
resource "google_compute_subnetwork" "faig" {
  for_each      = local.regions
  name          = "${var.name_prefix}-subnet${local.region_name[each.key]}"
  network       = google_compute_network.faig.id
  region        = each.key
  ip_cidr_range = local.subnet_cidr[each.key]
}

# Cloud Router -- required for Cloud NAT, one per region
resource "google_compute_router" "faig" {
  for_each = local.regions
  name     = "${var.name_prefix}-router${local.region_name[each.key]}"
  network  = google_compute_network.faig.id
  region   = each.key
}

# Cloud NAT -- outbound internet for VMs (no public IPs needed), one per region
resource "google_compute_router_nat" "faig" {
  for_each                           = local.regions
  name                               = "${var.name_prefix}-nat${local.region_name[each.key]}"
  router                             = google_compute_router.faig[each.key].name
  region                             = each.key
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# IAP firewall -- allows SSH/HTTP/HTTPS via Google IAP tunnels
# 35.235.240.0/20 is Google's IAP TCP forwarding proxy range
resource "google_compute_firewall" "iap" {
  name    = "${var.name_prefix}-allow-iap"
  network = google_compute_network.faig.name

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443"]
  }

  source_ranges = ["35.235.240.0/20"]
}

# Internal firewall -- allows traffic between VMs in all regional subnets
resource "google_compute_firewall" "internal" {
  name    = "${var.name_prefix}-allow-internal"
  network = google_compute_network.faig.name

  allow {
    protocol = "all"
  }

  source_ranges = values(local.subnet_cidr)
}

# Public FAIG ingress -- only when public_access_cidrs is set. Students' pods call
# the gateway (/ai/...) and browse the UI (/ui) from their pod desktops, which
# egress on the pod's IP, so an allowlist of pod IPs covers both.
resource "google_compute_address" "faig" {
  count  = length(var.public_access_cidrs) > 0 ? var.vm_count : 0
  name   = "${var.name_prefix}-${count.index + 1}-ip"
  region = local.instance_regions[count.index]
}

resource "google_compute_firewall" "public_https" {
  count   = length(var.public_access_cidrs) > 0 ? 1 : 0
  name    = "${var.name_prefix}-allow-public-https"
  network = google_compute_network.faig.name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = var.public_access_cidrs
  target_tags   = ["faig-cloud"]
}

# Enable IAP TCP forwarding API
resource "google_project_service" "iap" {
  project            = var.project_id
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

# VM instances -- IAP-only unless public_access_cidrs gives them a static IP
resource "google_compute_instance" "faig" {
  count        = var.vm_count
  name         = "${var.name_prefix}-${count.index + 1}"
  machine_type = var.machine_type
  zone         = local.instance_zones[count.index]
  tags         = ["faig-cloud"]

  boot_disk {
    initialize_params {
      image = var.source_image != "" ? var.source_image : "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.faig[local.instance_regions[count.index]].id

    dynamic "access_config" {
      for_each = length(var.public_access_cidrs) > 0 ? [1] : []
      content {
        nat_ip = google_compute_address.faig[count.index].address
      }
    }
  }

  metadata = {
    ssh-keys  = "${var.admin_username}:${var.ssh_public_key}"
    user-data = file("${path.module}/cloud-init/user-data.yml")
  }

  dynamic "guest_accelerator" {
    for_each = var.gpu_count > 0 ? [1] : []
    content {
      type  = var.gpu_type
      count = var.gpu_count
    }
  }

  scheduling {
    preemptible         = var.spot
    automatic_restart   = !var.spot
    on_host_maintenance = var.gpu_count > 0 ? "TERMINATE" : "MIGRATE"
  }

  labels = var.tags

  # Attach the schedule policy for this instance's region (if schedules are set)
  resource_policies = local.has_schedule ? [google_compute_resource_policy.lab_schedule[local.instance_regions[count.index]].self_link] : []
}

# Instance schedule policy -- auto-start/stop VMs on a cron schedule, one per
# region an instance lands in (policies are regional).
resource "google_compute_resource_policy" "lab_schedule" {
  for_each    = local.has_schedule ? local.regions : toset([])
  name        = "${var.name_prefix}-lab-schedule${local.region_name[each.key]}"
  region      = each.key
  description = "Auto start/stop schedule for FAIG lab VMs"

  instance_schedule_policy {
    time_zone = var.schedule_time_zone

    dynamic "vm_start_schedule" {
      for_each = var.auto_start_schedule != "" ? [1] : []
      content {
        schedule = var.auto_start_schedule
      }
    }

    dynamic "vm_stop_schedule" {
      for_each = var.auto_stop_schedule != "" ? [1] : []
      content {
        schedule = var.auto_stop_schedule
      }
    }
  }
}
