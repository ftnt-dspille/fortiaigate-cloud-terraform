# A stable name for FAIG, so a region/zone move (L4 stockout) only moves the A
# record: students and lab vars use the name, never the IP.
#
# dns_zone is a subdomain delegated to Cloud DNS (e.g. "faig.example.com"); the
# parent domain stays at its registrar. After the first apply, add the four
# `dns_name_servers` as NS records for that subdomain at the registrar (once).
# VM n answers at the zone apex for n=1 and at faig-<n>.<zone> for the rest.
# Empty dns_zone = no DNS resources.

resource "google_project_service" "dns" {
  count              = var.dns_zone != "" ? 1 : 0
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_dns_managed_zone" "faig" {
  count       = var.dns_zone != "" ? 1 : 0
  name        = "${var.name_prefix}-lab"
  dns_name    = "${trimsuffix(var.dns_zone, ".")}."
  description = "FortiAIGate lab (delegated subdomain)"
  depends_on  = [google_project_service.dns]
}

resource "google_dns_record_set" "faig" {
  count        = var.dns_zone != "" ? length(google_compute_address.faig) : 0
  managed_zone = google_dns_managed_zone.faig[0].name
  name         = count.index == 0 ? google_dns_managed_zone.faig[0].dns_name : "${var.name_prefix}-${count.index + 1}.${google_dns_managed_zone.faig[0].dns_name}"
  type         = "A"
  ttl          = 60 # short: a region move reaches students within a minute
  rrdatas      = [google_compute_address.faig[count.index].address]
}
