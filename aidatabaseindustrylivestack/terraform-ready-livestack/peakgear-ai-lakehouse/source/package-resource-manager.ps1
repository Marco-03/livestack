[CmdletBinding()]
param(
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path (Split-Path -Parent $root) 'peakgear-ai-lakehouse-resource-manager-v26.zip'
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $OutputPath

$excludedPatterns = @(
  '^\.terraform/',
  '^\.terraform\.lock\.hcl$',
  '(^|/)\.terraform\.tfstate\.lock\.info$',
  '(^|/)\.oci/',
  '^dist/',
  '(^|/)\.DS_Store$',
  '\.tfstate(\.|$)',
  '\.tfplan$',
  '\.tfvars(\.json)?$',
  '(^|/)crash(\..*)?\.log$',
  '\.generated\.zip$',
  'wallet.*\.(zip|b64)$',
  '\.pem$',
  '\.key$',
  '\.(p12|pfx|jks)$',
  '(^|/)\.env$'
)

$textExtensions = @(
  '.tf', '.yaml', '.yml', '.json', '.md', '.txt', '.sh', '.ps1', '.tpl'
)

$sensitiveContentPatterns = @(
  @{
    Name    = 'a private key'
    Pattern = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
  },
  @{
    Name    = 'an embedded Object Storage pre-authenticated request'
    Pattern = '/p/[A-Za-z0-9_-]{20,}/'
  },
  @{
    Name    = 'a concrete OCI resource OCID'
    Pattern = '\bocid1\.(?:tenancy|user|compartment|instance|image|subnet|vcn|networksecuritygroup|autonomousdatabase)\.[A-Za-z0-9._-]{20,}\b'
  }
)

function Test-Excluded([string]$RelativePath) {
  foreach ($pattern in $excludedPatterns) {
    if ($RelativePath -match $pattern) { return $true }
  }
  return $false
}

function Assert-SafeSourceFile(
  [System.IO.FileInfo]$File,
  [string]$RelativePath
) {
  if ($textExtensions -notcontains $File.Extension.ToLowerInvariant()) {
    return
  }

  $content = [System.IO.File]::ReadAllText($File.FullName)
  if ($RelativePath -eq 'approved-artifacts.json') {
    $manifest = $content | ConvertFrom-Json
    $expectedKeys = @(
      'peakgear_build_archive_url',
      'peakgear_build_archive_sha256',
      'gravitino_archive_url'
    )
    $actualKeys = @($manifest.PSObject.Properties.Name)

    if (@(Compare-Object $expectedKeys $actualKeys).Count -ne 0) {
      throw 'approved-artifacts.json must contain only the reviewed external artifact keys.'
    }

    $approvedPatterns = @{
      peakgear_build_archive_url    = '^https://github\.com/oracle-livelabs/livestack/raw/refs/heads/main/aidatabaseindustrylivestack/terraform-ready-livestack/peakgear-ai-lakehouse/peakgear-build-dev\.zip$'
      peakgear_build_archive_sha256 = '^7afe244845b0eaab381efe67bcc643cbb54f45d33498df5ecb1203c14fdf5117$'
      gravitino_archive_url         = '^https://objectstorage\.us-ashburn-1\.oraclecloud\.com/p/[A-Za-z0-9_-]+/n/c4u04/b/ai-lh-build/o/gravitino-iceberg-rest-server-0\.7\.0-incubating-SNAPSHOT-bin\.zip$'
    }

    foreach ($key in $expectedKeys) {
      $value = [string]$manifest.$key
      if ($value -notmatch $approvedPatterns[$key]) {
        throw "approved-artifacts.json contains an unapproved value for $key."
      }
    }

    $content = $content -replace '/p/[A-Za-z0-9_-]{20,}/', '/p/<reviewed-central-artifact>/'
  }

  foreach ($entry in $sensitiveContentPatterns) {
    if ($content -match $entry.Pattern) {
      throw "Refusing to package $RelativePath because it contains $($entry.Name)."
    }
  }
}

$sourceFiles = @(
  Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    if (-not (Test-Excluded $relativePath)) {
      Assert-SafeSourceFile -File $_ -RelativePath $relativePath
      [PSCustomObject]@{
        File         = $_
        RelativePath = $relativePath
      }
    }
  }
)

$computeSource = [System.IO.File]::ReadAllText((Join-Path $root 'compute-app.tf'))
if ($computeSource -notmatch 'user_data\s*=\s*base64gzip\s*\(') {
  throw 'compute-app.tf must gzip cloud-init user data to remain below the OCI instance metadata limit.'
}

$variablesSource = [System.IO.File]::ReadAllText((Join-Path $root 'variables.tf'))
if ($variablesSource -notmatch 'variable "compartment_ocid"' -or $variablesSource -notmatch '\^ocid1\\\\\.compartment\\\\\.') {
  throw 'variables.tf must require a non-root OCI compartment for every Peak Gear resource.'
}

$adbSource = [System.IO.File]::ReadAllText((Join-Path $root 'autonomous-database.tf'))
if ($adbSource -notmatch '"ADB\$TOOLS"\s*=\s*"AI_CAT"') {
  throw 'autonomous-database.tf must include the Peak Gear ADB tools tag.'
}

$bootstrapSource = [System.IO.File]::ReadAllText(
  (Join-Path $root 'scripts\bootstrap_lakehouse_vm.sh')
)
$schemaSource = [System.IO.File]::ReadAllText((Join-Path $root 'schema.yaml'))
$variablesSource = [System.IO.File]::ReadAllText((Join-Path $root 'variables.tf'))
$networkSource = [System.IO.File]::ReadAllText((Join-Path $root 'network.tf'))
if ($schemaSource -match 'tools_ingress_cidr' -or $variablesSource -match 'variable\s+"tools_ingress_cidr"' -or $networkSource -match 'var\.tools_ingress_cidr') {
  throw 'The Peak Gear package must use one application source CIDR for the application and administration tools.'
}
$bucketCleanupSource = [System.IO.File]::ReadAllText(
  (Join-Path $root 'scripts\empty_object_storage_bucket.py')
)
if ($bucketCleanupSource -notmatch 'objectVersions' -or
    $bucketCleanupSource -notmatch 'delete_object' -or
    $bucketCleanupSource -notmatch 'PEAKGEAR_AI_CATALOG_BUCKET_NAME') {
  throw 'The Peak Gear destroy cleanup must delete all objects and versions from both deployment buckets.'
}
$objectStorageSource = [System.IO.File]::ReadAllText((Join-Path $root 'object-storage.tf'))
if ($objectStorageSource -notmatch 'resource\s+"oci_objectstorage_bucket"\s+"ai_data_catalog"' -or
    $objectStorageSource -notmatch 'PEAKGEAR_AI_CATALOG_BUCKET_NAME' -or
    $objectStorageSource -notmatch 'terraform_data" "empty_lakehouse_bucket' -or
    $objectStorageSource -notmatch 'when\s*=\s*destroy') {
  throw 'The Peak Gear package must create and clean its dedicated AI Data Catalog bucket.'
}
if ($computeSource -notmatch 'ai_data_catalog_url_b64' -or
    $computeSource -notmatch 'ai_data_catalog_warehouse_b64' -or
    $computeSource -notmatch 'ai_data_catalog_s3_endpoint_b64') {
  throw 'compute-app.tf must pass the AI Data Catalog connection contract to cloud-init.'
}
if ($bootstrapSource -notmatch 'write_env_value "AI_DATA_CATALOG_ENABLED" "true"' -or
    $bootstrapSource -notmatch 'write_env_value "AI_DATA_CATALOG_REGISTER_STORAGE" "true"' -or
    $bootstrapSource -notmatch 'systemctl --user start pg-ai-data-catalog.service' -or
    $bootstrapSource -notmatch '\.ai_data_catalog_done') {
  throw 'The Peak Gear bootstrap must configure AI Data Catalog before application startup.'
}
if ($bootstrapSource -match '\|\s*tee\s+"\$\{INSTALLER_CONSOLE_LOG\}"') {
  throw 'The Peak Gear installer must not use a tee pipeline because long-lived Podman helpers can keep it open.'
}
if ($bootstrapSource -notmatch '>\s*"\$\{INSTALLER_CONSOLE_LOG\}"\s+2>&1') {
  throw 'The Peak Gear installer must redirect output directly to its console log.'
}
if ($bootstrapSource -notmatch 'ORACLE_USER_PWD:\s+\$\{ORACLE_PWD:-oracle\}') {
  throw 'The Peak Gear bootstrap must provide the database password expected by current ORDS images.'
}
if ($bootstrapSource -notmatch 'ACTUAL_BUILD_SHA256="\$\(sha256sum "\$\{BUILD_ZIP\}"' -or $bootstrapSource -notmatch 'Peak Gear build bundle checksum does not match the reviewed release\.') {
  throw 'The Peak Gear bootstrap must verify the reviewed runtime checksum.'
}
if ($bootstrapSource -notmatch 'ords_has_user_password=false' -or $bootstrapSource -notmatch 'The production compose file can add, rename, or reorder services') {
  throw 'The Peak Gear bootstrap must normalize the ORDS password field within the ORDS service.'
}
if ($bootstrapSource -notmatch "grep -Eq '\^ExecStartPre=\.\*\\/usr\\/local\\/bin\\/podman-compose") {
  throw 'The Peak Gear bootstrap must accept the reviewed legacy and TLS-aware Compose cleanup steps.'
}
if ($bootstrapSource -notmatch "sed -i '\\\#\^ExecStartPre=\.\*\\/usr\\/local\\/bin\\/podman-compose") {
  throw 'The Peak Gear bootstrap must remove the active Compose cleanup step before startup.'
}
if ($bootstrapSource -notmatch 'Unable to normalize the Peak Gear service definition') {
  throw 'The Peak Gear bootstrap must normalize Windows line endings in the systemd unit.'
}
if ($bootstrapSource -notmatch 'normalize_runtime_text_files' -or
    $bootstrapSource -notmatch 'Peak Gear installer still contains Windows line endings\.') {
  throw 'The Peak Gear bootstrap must normalize portable runtime text before execution.'
}
if ($bootstrapSource -notmatch 'login-container-registry\.sh --username' -or
    $bootstrapSource -notmatch 'max_attempts=6' -or
    $bootstrapSource -notmatch 'Container registry login failed after') {
  throw 'The Peak Gear bootstrap must retry transient container registry login failures.'
}
if ($bootstrapSource -notmatch 'wait_for_streaming_analytics' -or
    $bootstrapSource -notmatch '/api/streaming-analytics/status' -or
    $bootstrapSource.Contains('wait_for_tcp "${GGSA_HTTPS_PORT}"')) {
  throw 'The Peak Gear bootstrap must verify GGSA and its ADB connection through the application status API.'
}
if ($bootstrapSource -notmatch 'SC_SECURITY_CTX package and body must both be valid') {
  throw 'The Peak Gear bootstrap must verify the database security context package.'
}
if ($bootstrapSource -notmatch 'repair_select_ai_package_detection' -or $bootstrapSource -notmatch 'FROM all_objects') {
  throw 'The Peak Gear bootstrap must detect DBMS_CLOUD packages and synonyms visible to the application schema.'
}
if ($bootstrapSource -match 'python3\.11 - "\$\{service_file\}"') {
  throw 'The Peak Gear Select AI package repair must not require Python before the installer runs.'
}
if ($bootstrapSource -notmatch '\\140SELECT DISTINCT object_name' -or $bootstrapSource -notmatch 'SYNONYM\\047\)\\140,') {
  throw 'The Peak Gear Select AI package repair must preserve the JavaScript template-literal delimiters.'
}
if ($bootstrapSource -notmatch "index\(\`$0, end\) \{ exit \}" -or $bootstrapSource -notmatch 'AUDIT POLICY \(Unified Auditing\)') {
  throw 'The Peak Gear ADB security bootstrap must omit unsupported unified-audit policy creation.'
}
$startupHelperMatch = [regex]::Match(
  $bootstrapSource,
  '(?s)cat > "\$\{OPC_HOME\}/init/start-application-services\.sh" <<''EOF''\r?\n(?<Body>.*?)\r?\nEOF'
)
if (-not $startupHelperMatch.Success) {
  throw 'Unable to locate the generated Peak Gear service startup helper.'
}

$startupHelper = $startupHelperMatch.Groups['Body'].Value
$startupContract = @(
  'bash /home/opc/init/setenv.sh',
  'source /home/opc/ingestion/.env',
  'systemctl --user start adb-wallet.service',
  '/home/opc/ingestion/.adb_load_done',
  '/home/opc/init/ensure-security-schema.sh',
  '/home/opc/ingestion/.security_schema_done',
  'systemctl --user start pg-ai-data-catalog.service',
  '/home/opc/ingestion/.ai_data_catalog_done',
  'build_service_image gravitino',
  'up --no-deps -d gravitino',
  'build_service_image ggsa',
  'systemctl --user start user-podman.service'
)
$previousPosition = -1
foreach ($step in $startupContract) {
  $position = $startupHelper.IndexOf($step, [System.StringComparison]::Ordinal)
  if ($position -lt 0) {
    throw "Peak Gear service startup helper is missing required step: $step"
  }
  if ($position -le $previousPosition) {
    throw "Peak Gear service startup helper has an invalid dependency order at: $step"
  }
  $previousPosition = $position
}
if ($bootstrapSource -notmatch 'find "\$\{OPC_HOME\}/init" "\$\{INGESTION_DIR\}"' -or
    $bootstrapSource -notmatch '-type d -exec chmod 0755 \{\} \+' -or
    $bootstrapSource -notmatch '-type f -exec chmod 0644 \{\} \+' -or
    $bootstrapSource -notmatch "-type f -name '\*\.sh' -exec chmod 0755 \{\} \+") {
  throw 'Peak Gear bootstrap must restore readable runtime files and executable shell scripts after ZIP extraction.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open(
  $OutputPath,
  [System.IO.Compression.ZipArchiveMode]::Create
)

try {
  foreach ($sourceFile in $sourceFiles) {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive,
      $sourceFile.File.FullName,
      $sourceFile.RelativePath,
      [System.IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
  }
} finally {
  $archive.Dispose()
}

$requiredEntries = @(
  'approved-artifacts.json',
  'artifacts.tf',
  'schema.yaml',
  'versions.tf',
  'main.tf',
  'variables.tf',
  'cloud-init/app.yaml',
  'scripts/bootstrap_lakehouse_vm.sh',
  'scripts/empty_object_storage_bucket.py',
  'scripts/wait_for_bootstrap_callback.sh'
)

$verificationArchive = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)
try {
  $entryNames = @{}
  foreach ($entry in $verificationArchive.Entries) {
    $entryNames[$entry.FullName] = $true
    if (Test-Excluded $entry.FullName) {
      throw "Refusing to release an archive containing excluded artifact: $($entry.FullName)"
    }
  }

  foreach ($requiredEntry in $requiredEntries) {
    if (-not $entryNames.ContainsKey($requiredEntry)) {
      throw "Resource Manager archive is missing required entry: $requiredEntry"
    }
  }
} finally {
  $verificationArchive.Dispose()
}

Write-Host "Created and verified $OutputPath"
