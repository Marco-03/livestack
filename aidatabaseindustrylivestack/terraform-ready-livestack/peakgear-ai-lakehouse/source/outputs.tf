output "application_url" {
  description = "Public Peak Gear AI Lakehouse URL. Apply succeeds only after the app and required services are ready."
  value       = "http://${oci_core_instance.application.public_ip}:${local.application_port}/"
}

output "application_health_url" {
  description = "Peak Gear application health endpoint."
  value       = "http://${oci_core_instance.application.public_ip}:${local.application_port}/api/health"
}

output "application_ssh_command" {
  description = "SSH command for the application VM."
  value       = local.ssh_enabled ? "ssh opc@${oci_core_instance.application.public_ip}" : "SSH access was not configured for this stack."
}

output "first_boot_status_command" {
  description = "Display cloud-init and the recorded deployment state."
  value       = local.ssh_enabled ? "ssh opc@${oci_core_instance.application.public_ip} 'sudo cloud-init status --wait; result=$?; sudo cat /opt/peakgear-livestack/deployment-status.txt 2>/dev/null || true; exit $result'" : "SSH access was not configured for this stack."
}

output "bootstrap_log_command" {
  description = "Display the Peak Gear bootstrap log after an Apply failure."
  value       = local.ssh_enabled ? "ssh opc@${oci_core_instance.application.public_ip} 'sudo tail -n 300 /var/log/peakgear-livestack-bootstrap.log'" : "SSH access was not configured for this stack."
}

output "installer_log_command" {
  description = "Display both Peak Gear installer logs, including the registry-login console output."
  value       = local.ssh_enabled ? "ssh opc@${oci_core_instance.application.public_ip} 'sudo tail -n 300 /opt/peakgear-livestack/installer-console.log 2>/dev/null || true; tail -n 300 /home/opc/inst.log 2>/dev/null || true'" : "SSH access was not configured for this stack."
}

output "application_diagnostics_command" {
  description = "Display the Peak Gear user service, container state, and application logs."
  value       = local.ssh_enabled ? "ssh opc@${oci_core_instance.application.public_ip} 'runtime=/run/user/$(id -u); export XDG_RUNTIME_DIR=$runtime DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus; systemctl --user --no-pager --full status user-podman.service || true; podman ps -a --format \"table {{.Names}}\\t{{.Status}}\"; app_id=$(podman ps -aq --filter label=io.podman.compose.service=app | head -n 1); if [ -n \"$app_id\" ]; then podman logs --tail 200 \"$app_id\"; fi'" : "SSH access was not configured for this stack."
}

output "database_bootstrap_diagnostics_command" {
  description = "Display ADB wallet and loader service state plus the current ADB loader log."
  value       = local.ssh_enabled ? "ssh opc@${oci_core_instance.application.public_ip} 'XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus systemctl --user --no-pager --full status adb-wallet.service adb-load.service || true; tail -n 300 /home/opc/ingestion/logs/adb-load.log 2>/dev/null || true'" : "SSH access was not configured for this stack."
}

output "autonomous_database_name" {
  description = "Autonomous Database name."
  value       = oci_database_autonomous_database.application.db_name
}

output "autonomous_database_ocid" {
  description = "Autonomous Database OCID."
  value       = oci_database_autonomous_database.application.id
}

output "autonomous_database_service" {
  description = "ADB wallet service used by Peak Gear."
  value       = local.adb_service_name
}

output "peakgear_database_user" {
  description = "Peak Gear application schema."
  value       = "PG"
}

output "peakgear_database_password" {
  description = "Password used by the Peak Gear PG schema. Treat Resource Manager state as sensitive."
  value       = local.adb_admin_password
  sensitive   = true
}

output "autonomous_database_admin_password" {
  description = "Configured ADMIN password. Treat Resource Manager state as sensitive."
  value       = local.adb_admin_password
  sensitive   = true
}

output "ggsa_url" {
  description = "GoldenGate Stream Analytics URL. It is reachable only from the trusted tools CIDR."
  value       = "https://${oci_core_instance.application.public_ip}:${local.ggsa_https_port}/osa/index.html"
}

output "goldengate_studio_url" {
  description = "GoldenGate Studio URL. It is reachable only when a trusted tools CIDR was supplied."
  value       = "https://${oci_core_instance.application.public_ip}:${local.goldengate_port}/"
}

output "gravitino_url" {
  description = "Gravitino REST endpoint. It is reachable only when a trusted tools CIDR was supplied."
  value       = "http://${oci_core_instance.application.public_ip}:${local.gravitino_port}/iceberg/v1/config"
}

output "tool_access_note" {
  description = "Configured access for the administration endpoints exposed through the NSG."
  value       = "Peak Gear, GGSA, GoldenGate, and Gravitino ports are restricted to ${var.app_ingress_cidr}."
}

output "object_storage_bucket_name" {
  description = "Private stack-owned bucket used for the wallet, status callback, uploads, and Iceberg data."
  value       = oci_objectstorage_bucket.lakehouse.name
}

output "first_boot_note" {
  description = "What a successful Resource Manager Apply means."
  value       = "Apply waits for ADB data loading, the Peak Gear health endpoint, Gravitino, GGSA, and GoldenGate. A successful Apply means RESOURCE_MANAGER_DEPLOYMENT_OK was reached."
}
