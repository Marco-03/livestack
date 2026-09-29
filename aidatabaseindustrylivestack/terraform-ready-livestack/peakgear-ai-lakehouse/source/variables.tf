variable "region" {
  description = "OCI region where Resource Manager creates Peak Gear."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the current OCI tenancy. It is used to resolve the tenancy home region."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "Provide a valid OCI tenancy OCID."
  }
}

variable "compartment_ocid" {
  description = "Compartment where every stack resource is created."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\.", var.compartment_ocid))
    error_message = "Select a non-root OCI compartment. This stack cannot deploy resources in the tenancy root compartment."
  }
}

variable "current_user_ocid" {
  description = "OCID of the Resource Manager user. OCI supplies this value from the active stack context."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.user\\.", var.current_user_ocid))
    error_message = "Provide a valid OCI user OCID."
  }
}

variable "availability_domain" {
  description = "Availability domain where the application VM is created."
  type        = string

  validation {
    condition     = length(trimspace(var.availability_domain)) > 0
    error_message = "Select an availability domain."
  }
}

variable "stack_name" {
  description = "Short display-name prefix for stack resources."
  type        = string
  default     = "peakgear-lakehouse"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{2,29}$", var.stack_name))
    error_message = "Stack name must start with a letter and contain 3-30 letters, numbers, or hyphens."
  }
}

variable "ssh_public_key" {
  description = "Optional OpenSSH public key used for opc access to the Peak Gear VM. Leave blank to disable SSH access."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.ssh_public_key) == "" ||
      can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-)", trimspace(var.ssh_public_key)))
    )
    error_message = "SSH public key must be blank or a valid OpenSSH public key."
  }
}

variable "ssh_ingress_cidr" {
  description = "Optional public IPv4 CIDR allowed to SSH to the VM. Leave blank to disable SSH access."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.ssh_ingress_cidr) == "" ||
      (
        can(cidrnetmask(var.ssh_ingress_cidr)) &&
        !strcontains(var.ssh_ingress_cidr, ":") &&
        var.ssh_ingress_cidr != "0.0.0.0/0"
      )
    )
    error_message = "SSH source CIDR must be blank or a valid IPv4 CIDR other than 0.0.0.0/0."
  }
}

variable "app_ingress_cidr" {
  description = "IPv4 CIDR allowed to open the Peak Gear application."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.app_ingress_cidr)) && !strcontains(var.app_ingress_cidr, ":") && var.app_ingress_cidr != "0.0.0.0/0"
    error_message = "Peak Gear and administration ingress must be a trusted IPv4 CIDR other than 0.0.0.0/0."
  }
}

variable "show_advanced_options" {
  description = "Shows optional sizing, service-tuning, tool-access, and artifact-override fields in the Resource Manager form."
  type        = bool
  default     = false
}

variable "vm_shape" {
  description = "Compute shape for the VM that runs the Peak Gear containers."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "vm_ocpus" {
  description = "OCPUs assigned when a flexible VM shape is selected."
  type        = number
  default     = 8

  validation {
    condition     = var.vm_ocpus >= 6 && var.vm_ocpus <= 64
    error_message = "Peak Gear needs at least 6 OCPUs; choose a value between 6 and 64."
  }
}

variable "vm_memory_gbs" {
  description = "Memory in GB assigned when a flexible VM shape is selected."
  type        = number
  default     = 64

  validation {
    condition     = var.vm_memory_gbs >= 48 && var.vm_memory_gbs <= 1024
    error_message = "Peak Gear needs at least 48 GB of memory."
  }
}

variable "boot_volume_size_gbs" {
  description = "Boot-volume size for container images, GoldenGate, GGSA, models, and application data."
  type        = number
  default     = 300

  validation {
    condition     = var.boot_volume_size_gbs >= 250 && var.boot_volume_size_gbs <= 32768
    error_message = "Peak Gear needs at least 250 GB of boot-volume storage."
  }
}

variable "adb_license_model" {
  description = "Autonomous Database license model available in the target tenancy."
  type        = string
  default     = "LICENSE_INCLUDED"

  validation {
    condition     = contains(["LICENSE_INCLUDED", "BRING_YOUR_OWN_LICENSE"], var.adb_license_model)
    error_message = "Choose LICENSE_INCLUDED or BRING_YOUR_OWN_LICENSE."
  }
}

variable "adb_compute_count" {
  description = "ECPUs assigned to Autonomous Database."
  type        = number
  default     = 2

  validation {
    condition     = var.adb_compute_count >= 2 && var.adb_compute_count <= 512
    error_message = "ADB compute count must be between 2 and 512 ECPUs."
  }
}

variable "adb_storage_tbs" {
  description = "Autonomous Database storage in TB."
  type        = number
  default     = 1

  validation {
    condition     = var.adb_storage_tbs >= 1
    error_message = "ADB storage must be at least 1 TB."
  }
}

variable "adb_admin_password" {
  description = "Optional Autonomous Database ADMIN password. Leave blank to generate one."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true

  validation {
    condition = (
      trimspace(var.adb_admin_password == null ? "" : var.adb_admin_password) == "" ||
      (
        can(regex("^[^\\s'\"]{12,30}$", var.adb_admin_password)) &&
        can(regex("[A-Z]", var.adb_admin_password)) &&
        can(regex("[a-z]", var.adb_admin_password)) &&
        can(regex("[0-9]", var.adb_admin_password)) &&
        !can(regex("(?i)admin", var.adb_admin_password))
      )
    )
    error_message = "ADB ADMIN password must be 12-30 characters with uppercase, lowercase, and numeric characters. Quotes, whitespace, and the word admin are not allowed."
  }
}

variable "ai_endpoint_region" {
  description = "OCI Generative AI region used by Peak Gear."
  type        = string
  default     = "us-chicago-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.ai_endpoint_region))
    error_message = "Provide a valid OCI region identifier such as us-chicago-1."
  }
}

variable "registry_username" {
  description = "Oracle Container Registry login email."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.registry_username)) >= 3
    error_message = "Provide the Oracle account email used for Oracle Container Registry."
  }
}

variable "registry_auth_token" {
  description = "Oracle Container Registry Auth Token. Do not use the Oracle SSO password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.registry_auth_token)) >= 8
    error_message = "Provide an Oracle Container Registry Auth Token."
  }
}

variable "application_api_private_key_b64" {
  description = "Base64-encoded PEM private key for an existing OCI API key owned by current_user_ocid."
  type        = string
  sensitive   = true

  validation {
    condition = can(
      regex(
        "-----BEGIN (RSA )?PRIVATE KEY-----",
        base64decode(trimspace(var.application_api_private_key_b64))
      )
    )
    error_message = "Provide the complete API private-key PEM as one Base64-encoded string."
  }
}

variable "application_api_key_fingerprint" {
  description = "Fingerprint of the existing OCI API key."
  type        = string

  validation {
    condition     = can(regex("^([0-9a-fA-F]{2}:){15}[0-9a-fA-F]{2}$", trimspace(var.application_api_key_fingerprint)))
    error_message = "Provide a valid OCI API key fingerprint."
  }
}

variable "object_storage_access_key" {
  description = "Access key from an existing OCI Customer Secret Key used by Gravitino S3FileIO."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.object_storage_access_key)) >= 8
    error_message = "Provide the access key from an OCI Customer Secret Key."
  }
}

variable "object_storage_secret_key" {
  description = "Secret value from the same OCI Customer Secret Key."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.object_storage_secret_key)) >= 16
    error_message = "Provide the secret value from the OCI Customer Secret Key."
  }
}

variable "ggsa_archive_url" {
  description = "Direct HTTPS URL for the approved GGSA V1054826-01.zip archive."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^https://[^\\s'\"]+$", trimspace(var.ggsa_archive_url))) && length(trimspace(var.ggsa_archive_url)) <= 4096
    error_message = "GGSA archive URL must be a direct HTTPS URL without whitespace or quotes."
  }
}
