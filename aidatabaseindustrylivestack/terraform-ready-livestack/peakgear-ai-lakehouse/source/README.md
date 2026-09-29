# Peak Gear AI Lakehouse Resource Manager source

This directory is the root of the OCI Resource Manager stack. The customer ZIP
must contain these files at its root, not inside another folder.

## Customer input contract

Resource Manager provides `tenancy_ocid`, `current_user_ocid`, and `region`.
The customer must select a non-root child compartment in the deployment form;
the stack rejects tenancy root and creates every resource in that selection.
The customer supplies:

- Location, availability domain, one Peak Gear access CIDR for the application and administration tools, plus optional paired SSH key and SSH CIDR values.
- A direct HTTPS Object Storage URL for the approved GGSA `V1054826-01.zip` archive.
- Oracle Container Registry username and Auth Token.
- An existing OCI API key and Customer Secret Key owned by the signed-in user.

The reviewed VM, paid Autonomous Database, and AI defaults are used unless
**Show advanced options** is enabled. Peak Gear, GGSA, Gravitino, and GoldenGate
access is restricted to the required application CIDR.

The reviewed Peak Gear runtime URL and SHA-256 checksum are maintained in
`approved-artifacts.json`. The checksum makes the VM reject a changed or stale
download. The runtime remains separate because OCI Resource Manager rejects a
stack package containing the full application archive. The reviewed Gravitino
location also remains in `approved-artifacts.json`. GGSA is a required sensitive
Resource Manager input; use the approved direct Object Storage link for the
archive whose terms were accepted by the customer.

The OCI API key is required because the current Peak Gear application creates
OCI Generative AI database profiles with API-key authentication. The Customer
Secret Key is required because the approved Gravitino build uses OCI Object
Storage through its S3-compatible API. These are runtime credentials, not
software download locations, and must never be embedded in the release ZIP.

No local OCI profile, Packer file, `.tfvars` file, or manually generated
runtime credential belongs in this directory or the release ZIP.

## Deployment lifecycle

1. Terraform creates the network, ADB, private Object Storage bucket, and
   application VM.
2. Cloud-init receives deployment-specific values through protected instance
   metadata and writes a root-only bootstrap environment. Terraform gzip
   compresses cloud-init so the request stays safely below OCI's 32,000-byte
   instance metadata limit.
3. The VM downloads the checksum-pinned Peak Gear build plus the approved
   Gravitino and customer-supplied GGSA archives, loads ADB, and starts the
   Podman services.
4. The VM publishes a credential-free status callback to the stack-owned
   bucket.
5. Resource Manager Apply waits for ADB loading and every declared service
   check. GGSA passes only when Peak Gear reports that Streaming Analytics is
   connected to ADB; an open TCP port is not sufficient. Apply fails when
   bootstrap reports a failure or times out.
6. First boot removes registry credentials, archive URLs, wallets, and source
   archives that are no longer needed.
7. Resource Manager Destroy removes the workload. It does not modify the
   customer-supplied OCI credentials.

The stack carries an explicit bootstrap revision. Updating to a release with a
new revision replaces only the application VM so first boot runs again, while
Terraform retains compatible database, network, and Object Storage resources.

## Source of truth and release flow

Do not edit either ZIP directly. The maintained sources are:

- this `source` directory for the Resource Manager Terraform and bootstrap;
- `../../../../ailakehouse/_deploy/ll-lakehouse` for the Peak Gear runtime that
  becomes `peakgear-build-dev.zip`; and
- `../deployment-inputs.md` plus
  `../../../../ailakehouse/deploy-livestack-terraform/deploy-livestack-terraform.md`
  for the deployment documentation.

Build the runtime ZIP first, record its SHA-256 in `approved-artifacts.json`
and both packaging contracts, then build the Resource Manager ZIP. Test builds
may use an immutable test location. Before promotion, the runtime URL must point
to the matching artifact on `oracle-livelabs/livestack` `main`, and the brown
button must continue to point to the Resource Manager ZIP on that same branch.

### Release protections to preserve

Keep these behaviors in editable source and in both packaging contracts:

- SSH remains optional. `ssh_public_key` and `ssh_ingress_cidr` must either
  both be supplied or both be blank.
- `app_ingress_cidr` is the single trusted CIDR for Peak Gear, Gravitino,
  GoldenGate, and GGSA. Do not reintroduce `tools_ingress_cidr`.
- `ggsa_archive_url` remains a required HTTPS URL supplied by the customer.
- The large Peak Gear runtime remains outside the Resource Manager ZIP and is
  accepted only when its SHA-256 matches `approved-artifacts.json`.
- Runtime text is normalized to LF before Linux execution, and registry login
  retries bounded transient failures.
- The reviewed ORDS environment mapping and application-service dependency
  order are preserved when the downloaded runtime is prepared.
- Select AI package detection checks objects accessible to the Peak Gear
  schema so OCI Generative AI does not silently fall back to Ollama.
- Destroy empties both stack-owned Object Storage buckets before Terraform
  deletes them.
- The GGSA image and entrypoint create `${SPARK_HOME}/conf`; the corresponding
  runtime source is under
  `../../../../ailakehouse/_deploy/ll-lakehouse/ingestion/ggsa`.
- Apply verifies `/api/streaming-analytics/status` reports `connected: true`.
  A listening GGSA port alone must never complete deployment readiness.

## Validate the source

```powershell
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

The Linux bootstrap scripts can be syntax-checked with:

```bash
bash -n scripts/bootstrap_lakehouse_vm.sh
bash -n scripts/wait_for_bootstrap_callback.sh
```

## Build the customer ZIP

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\package-resource-manager.ps1 `
  -OutputPath ..\peakgear-ai-lakehouse-resource-manager.zip
```

macOS or Linux:

```bash
bash ./package-resource-manager.sh ../peakgear-ai-lakehouse-resource-manager.zip
```

The release output is `../peakgear-ai-lakehouse-resource-manager.zip`.

Both packagers reject Terraform state, variable files, local OCI configuration,
environment files, wallets, private keys, concrete OCI resource OCIDs,
unreviewed pre-authenticated request URLs, and generated artifacts. They require
the reviewed external Peak Gear URL and SHA-256 checksum, permit only the
reviewed external Gravitino location in `approved-artifacts.json`, and verify
the ZIP structure required by Resource Manager.
