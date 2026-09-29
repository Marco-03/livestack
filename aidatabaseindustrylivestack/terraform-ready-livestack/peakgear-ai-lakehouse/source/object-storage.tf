resource "oci_objectstorage_bucket" "lakehouse" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.stack.namespace
  name           = substr("${local.name_prefix}-${random_id.deployment.hex}", 0, 63)
  access_type    = "NoPublicAccess"
  auto_tiering   = "Disabled"
  storage_tier   = "Standard"
  freeform_tags  = local.common_tags
}

# Oracle AI Data Catalog requires a dedicated, initially empty warehouse
# bucket. Keep it separate from the lakehouse bucket used by Gravitino and the
# demo application.
resource "oci_objectstorage_bucket" "ai_data_catalog" {
  compartment_id        = var.compartment_ocid
  namespace             = data.oci_objectstorage_namespace.stack.namespace
  name                  = substr("${local.name_prefix}-aicat-${random_id.deployment.hex}", 0, 63)
  access_type           = "NoPublicAccess"
  auto_tiering          = "Disabled"
  storage_tier          = "Standard"
  object_events_enabled = false
  freeform_tags         = local.common_tags
}

# The ADB wallet API returns base64 text. Uploading that text keeps the stack
# independent from local files that do not survive between Resource Manager
# Plan, Apply, and Destroy workers.
resource "oci_objectstorage_object" "wallet" {
  bucket       = oci_objectstorage_bucket.lakehouse.name
  namespace    = data.oci_objectstorage_namespace.stack.namespace
  object       = "runtime/adb-wallet.b64"
  content      = oci_database_autonomous_database_wallet.application.content
  content_type = "text/plain"
}

resource "oci_objectstorage_object" "bootstrap_status" {
  bucket       = oci_objectstorage_bucket.lakehouse.name
  namespace    = data.oci_objectstorage_namespace.stack.namespace
  object       = "runtime/bootstrap-status.txt"
  content_type = "text/plain"
  content      = <<-EOT
    format=peakgear-rm-bootstrap/v1
    state=PENDING
    phase=waiting_for_cloud_init
    marker=RESOURCE_MANAGER_DEPLOYMENT_PENDING
  EOT

  lifecycle {
    ignore_changes = [content]
  }
}

resource "oci_objectstorage_preauthrequest" "wallet" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.lakehouse.name
  namespace    = data.oci_objectstorage_namespace.stack.namespace
  name         = "${local.name_prefix}-wallet-download"
  object_name  = oci_objectstorage_object.wallet.object
  time_expires = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [time_expires]
  }
}

resource "oci_objectstorage_preauthrequest" "bootstrap_status_write" {
  access_type  = "ObjectWrite"
  bucket       = oci_objectstorage_bucket.lakehouse.name
  namespace    = data.oci_objectstorage_namespace.stack.namespace
  name         = "${local.name_prefix}-bootstrap-status-write"
  object_name  = oci_objectstorage_object.bootstrap_status.object
  time_expires = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [time_expires]
  }
}

resource "oci_objectstorage_preauthrequest" "bootstrap_status_read" {
  access_type  = "ObjectRead"
  bucket       = oci_objectstorage_bucket.lakehouse.name
  namespace    = data.oci_objectstorage_namespace.stack.namespace
  name         = "${local.name_prefix}-bootstrap-status-read"
  object_name  = oci_objectstorage_object.bootstrap_status.object
  time_expires = timeadd(timestamp(), "24h")

  lifecycle {
    ignore_changes = [time_expires]
  }
}

# Peak Gear writes demo uploads and Iceberg data below this private bucket.
# The URL is generated per deployment and never embedded in the release ZIP.
resource "oci_objectstorage_preauthrequest" "application_bucket" {
  access_type           = "AnyObjectReadWrite"
  bucket                = oci_objectstorage_bucket.lakehouse.name
  namespace             = data.oci_objectstorage_namespace.stack.namespace
  name                  = "${local.name_prefix}-application-data"
  bucket_listing_action = "ListObjects"
  time_expires          = timeadd(timestamp(), "168h")

  lifecycle {
    ignore_changes = [time_expires]
  }
}

# Peak Gear writes Iceberg tables and uploads through the bucket PAR, so those
# objects are not tracked individually in Terraform state. Empty the complete
# deployment bucket before Terraform asks OCI to delete the bucket itself.
resource "terraform_data" "empty_lakehouse_bucket" {
  input = {
    bucket_name            = oci_objectstorage_bucket.lakehouse.name
    ai_catalog_bucket_name = oci_objectstorage_bucket.ai_data_catalog.name
    namespace              = data.oci_objectstorage_namespace.stack.namespace
    region                 = var.region
    tenancy_ocid           = var.tenancy_ocid
    user_ocid              = var.current_user_ocid
    key_fingerprint        = var.application_api_key_fingerprint
    private_key_b64        = var.application_api_private_key_b64
  }

  depends_on = [
    oci_objectstorage_preauthrequest.application_bucket,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["python3"]
    command     = "scripts/empty_object_storage_bucket.py"

    environment = {
      PEAKGEAR_BUCKET_NAME            = self.input.bucket_name
      PEAKGEAR_AI_CATALOG_BUCKET_NAME = self.input.ai_catalog_bucket_name
      PEAKGEAR_BUCKET_NAMESPACE       = self.input.namespace
      PEAKGEAR_OCI_REGION             = self.input.region
      PEAKGEAR_TENANCY_OCID           = self.input.tenancy_ocid
      PEAKGEAR_USER_OCID              = self.input.user_ocid
      PEAKGEAR_KEY_FINGERPRINT        = self.input.key_fingerprint
      PEAKGEAR_PRIVATE_KEY_B64        = self.input.private_key_b64
    }
  }
}
