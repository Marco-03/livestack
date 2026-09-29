locals {
  approved_artifacts = jsondecode(file("${path.module}/approved-artifacts.json"))

  peakgear_build_archive_url    = local.approved_artifacts.peakgear_build_archive_url
  peakgear_build_archive_sha256 = local.approved_artifacts.peakgear_build_archive_sha256
  gravitino_archive_url         = local.approved_artifacts.gravitino_archive_url
  ggsa_archive_url              = trimspace(var.ggsa_archive_url)
}
