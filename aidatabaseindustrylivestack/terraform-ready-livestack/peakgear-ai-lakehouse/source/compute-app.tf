resource "oci_core_instance" "application" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_prefix}-application"
  shape               = var.vm_shape
  freeform_tags       = local.common_tags

  dynamic "shape_config" {
    for_each = local.vm_is_flex_shape ? [1] : []
    content {
      ocpus         = var.vm_ocpus
      memory_in_gbs = var.vm_memory_gbs
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.application.id
    assign_public_ip = true
    display_name     = "${local.name_prefix}-application-vnic"
    hostname_label   = "peakgear"
    nsg_ids          = [oci_core_network_security_group.application.id]
  }

  source_details {
    source_type             = "image"
    source_id               = local.vm_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = merge(local.ssh_enabled ? {
    ssh_authorized_keys = trimspace(var.ssh_public_key)
    } : {}, {
    user_data = base64gzip(templatefile("${path.module}/cloud-init/app.yaml", {
      wallet_archive_url_b64          = base64encode("https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.wallet.access_uri}")
      bootstrap_status_upload_url_b64 = base64encode("https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.bootstrap_status_write.access_uri}")
      adb_admin_password_b64          = base64encode(local.adb_admin_password)
      adb_connection_b64              = base64encode(local.adb_low_connection)
      adb_service_name_b64            = base64encode(local.adb_service_name)
      adb_name_b64                    = base64encode(local.adb_database_name)
      adb_ocid_b64                    = base64encode(oci_database_autonomous_database.application.id)
      adb_ords_url_b64                = base64encode(local.adb_ords_url)
      adb_base_url_b64                = base64encode(local.adb_base_url)
      oci_private_key_b64             = trimspace(var.application_api_private_key_b64)
      oci_fingerprint_b64             = base64encode(var.application_api_key_fingerprint)
      oci_user_ocid_b64               = base64encode(var.current_user_ocid)
      tenancy_ocid_b64                = base64encode(var.tenancy_ocid)
      compartment_ocid_b64            = base64encode(var.compartment_ocid)
      region_b64                      = base64encode(var.region)
      ai_endpoint_region_b64          = base64encode(var.ai_endpoint_region)
      object_namespace_b64            = base64encode(data.oci_objectstorage_namespace.stack.namespace)
      bucket_name_b64                 = base64encode(oci_objectstorage_bucket.lakehouse.name)
      bucket_par_b64                  = base64encode("https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.application_bucket.access_uri}")
      s3_endpoint_b64                 = base64encode("https://${data.oci_objectstorage_namespace.stack.namespace}.compat.objectstorage.${var.region}.oraclecloud.com")
      ai_data_catalog_url_b64         = base64encode("${local.adb_base_url}/catalog")
      ai_data_catalog_warehouse_b64   = base64encode("s3://${oci_objectstorage_bucket.ai_data_catalog.name}")
      ai_data_catalog_s3_endpoint_b64 = base64encode("https://${data.oci_objectstorage_namespace.stack.namespace}.compat.objectstorage.${var.region}.oci.customer-oci.com")
      s3_access_key_b64               = base64encode(var.object_storage_access_key)
      s3_secret_key_b64               = base64encode(var.object_storage_secret_key)
      registry_username_b64           = base64encode(var.registry_username)
      registry_auth_token_b64         = base64encode(var.registry_auth_token)
      ggsa_archive_url_b64            = base64encode(local.ggsa_archive_url)
      build_archive_url_b64           = base64encode(local.peakgear_build_archive_url)
      build_archive_sha256_b64        = base64encode(local.peakgear_build_archive_sha256)
      gravitino_archive_url_b64       = base64encode(local.gravitino_archive_url)
      application_port                = local.application_port
      gravitino_port                  = local.gravitino_port
      ggsa_https_port                 = local.ggsa_https_port
      goldengate_port                 = local.goldengate_port
      goldengate_api                  = local.goldengate_api
      bootstrap_lakehouse_vm_script   = indent(6, trimspace(file("${path.module}/scripts/bootstrap_lakehouse_vm.sh")))
    }))
  })

  depends_on = [
    oci_database_autonomous_database.application,
    oci_objectstorage_bucket.ai_data_catalog,
    oci_objectstorage_preauthrequest.application_bucket,
    oci_objectstorage_preauthrequest.wallet,
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.bootstrap_revision]

    precondition {
      condition = (
        (trimspace(var.ssh_public_key) == "" && trimspace(var.ssh_ingress_cidr) == "") ||
        (trimspace(var.ssh_public_key) != "" && trimspace(var.ssh_ingress_cidr) != "")
      )
      error_message = "Provide both the SSH public key and SSH source CIDR, or leave both blank to disable SSH."
    }
  }
}
