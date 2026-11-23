# Release the GPU holds when the lab schedule stops the VMs.
#
# A hold (faig-<n>-hold, scripts/gpu_place.sh) bills like a running g2-standard-8
# + L4 whenever its VM is stopped. The instance schedule stops the VMs every
# evening but never touches reservations, so a kept hold billed all night. One
# Cloud Scheduler job per VM fires on the same cron and DELETEs that VM's hold in
# that VM's zone through the Compute API. Deleting a reservation leaves a running
# VM running; the next `make up` holds again before it starts the VM. A 404
# (nothing held, the usual case) just shows as a failed run.

locals {
  auto_unreserve = var.auto_stop_schedule != "" && var.auto_unreserve
}

resource "google_project_service" "scheduler" {
  count              = local.auto_unreserve ? 1 : 0
  project            = var.project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "unreserve" {
  count        = local.auto_unreserve ? 1 : 0
  account_id   = "${var.name_prefix}-unreserve"
  display_name = "Releases the FAIG GPU reservation on the stop schedule"
}

# Only what the DELETE needs: not roles/compute.admin.
resource "google_project_iam_custom_role" "unreserve" {
  count       = local.auto_unreserve ? 1 : 0
  role_id     = "${replace(var.name_prefix, "-", "_")}_unreserve"
  title       = "FAIG GPU reservation release"
  permissions = ["compute.reservations.delete", "compute.reservations.get"]
}

resource "google_project_iam_member" "unreserve" {
  count   = local.auto_unreserve ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.unreserve[0].id
  member  = "serviceAccount:${google_service_account.unreserve[0].email}"
}

resource "google_cloud_scheduler_job" "unreserve" {
  count       = local.auto_unreserve ? var.vm_count : 0
  name        = count.index == 0 ? "${var.name_prefix}-unreserve" : "${var.name_prefix}-unreserve-${count.index + 1}"
  description = "Delete reservation ${var.name_prefix}-${count.index + 1}-hold when the lab schedule stops the VMs"
  region      = var.region
  schedule    = var.auto_stop_schedule
  time_zone   = var.schedule_time_zone

  http_target {
    http_method = "DELETE"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/zones/${local.instance_zones[count.index]}/reservations/${var.name_prefix}-${count.index + 1}-hold"
    oauth_token {
      service_account_email = google_service_account.unreserve[0].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_service.scheduler, google_project_iam_member.unreserve]
}
