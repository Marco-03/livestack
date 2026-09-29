data "oci_core_images" "oracle_linux" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.vm_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_objectstorage_namespace" "stack" {
  compartment_id = var.tenancy_ocid
}

resource "random_id" "deployment" {
  byte_length = 4
}

resource "terraform_data" "bootstrap_revision" {
  input = "20260929.4"
}

resource "random_password" "adb_admin" {
  length      = 20
  special     = false
  upper       = true
  lower       = true
  numeric     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

locals {
  sanitized_stack_name = trim(replace(lower(var.stack_name), "/[^a-z0-9-]/", "-"), "-")
  name_prefix          = substr(local.sanitized_stack_name, 0, 24)
  availability_domain  = var.availability_domain

  application_name = "peakgear"
  application_port = 8505
  gravitino_port   = 1525
  ggsa_https_port  = 8085
  goldengate_port  = 8501
  goldengate_api   = 8502

  ssh_enabled = trimspace(var.ssh_public_key) != "" && trimspace(var.ssh_ingress_cidr) != ""

  tool_ports = {
    ggsa = {
      port        = local.ggsa_https_port
      description = "GoldenGate Stream Analytics UI."
    }
    gravitino = {
      port        = local.gravitino_port
      description = "Gravitino Iceberg REST API."
    }
    goldengate = {
      port        = local.goldengate_port
      description = "GoldenGate Studio UI."
    }
    goldengate_api = {
      port        = local.goldengate_api
      description = "GoldenGate runtime API."
    }
  }

  vcn_cidr        = "10.52.0.0/16"
  app_subnet_cidr = "10.52.10.0/24"

  vm_is_flex_shape = endswith(var.vm_shape, ".Flex")
  vm_image_ocid    = data.oci_core_images.oracle_linux.images[0].id

  adb_database_name           = upper(substr("PG${random_id.deployment.hex}", 0, 14))
  adb_service_name            = "${local.adb_database_name}_high"
  supplied_adb_admin_password = trimspace(var.adb_admin_password == null ? "" : var.adb_admin_password)
  adb_admin_password          = local.supplied_adb_admin_password == "" ? random_password.adb_admin.result : var.adb_admin_password
  adb_low_index               = index(oci_database_autonomous_database.application.connection_strings[0].profiles.*.consumer_group, "LOW")
  adb_low_connection          = oci_database_autonomous_database.application.connection_strings[0].profiles[local.adb_low_index].value
  adb_ords_url                = oci_database_autonomous_database.application.connection_urls[0].ords_url
  adb_base_url                = trimsuffix(replace(local.adb_ords_url, "/ords//", ""), "/")

  common_tags = {
    "created-by" = "oci-resource-manager"
    "livestack"  = local.application_name
    "template"   = "terraform-ready-livestack"
  }
}
