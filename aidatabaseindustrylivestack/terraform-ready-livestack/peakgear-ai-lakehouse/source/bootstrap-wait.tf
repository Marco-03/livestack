# Resource Manager has no native awareness of cloud-init. The VM publishes a
# credential-free terminal status to a stack-owned Object Storage object. Apply
# succeeds only after ADB loading and the Peak Gear service checks pass.
resource "terraform_data" "bootstrap_readiness" {
  triggers_replace = [
    oci_core_instance.application.id,
    oci_objectstorage_preauthrequest.bootstrap_status_read.id,
  ]

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/wait_for_bootstrap_callback.sh"

    environment = {
      BOOTSTRAP_STATUS_URL           = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.bootstrap_status_read.access_uri}"
      EXPECTED_INSTANCE_OCID         = oci_core_instance.application.id
      WAIT_TIMEOUT_SECONDS           = "10800"
      POLL_INTERVAL_SECONDS          = "20"
      INITIAL_STATUS_TIMEOUT_SECONDS = "1200"
    }
  }

  depends_on = [
    oci_core_instance.application,
    oci_objectstorage_preauthrequest.bootstrap_status_read,
    oci_objectstorage_preauthrequest.bootstrap_status_write,
  ]
}
