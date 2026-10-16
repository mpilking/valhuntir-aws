# Valhuntir on AWS (Terraform)

Infrastructure-as-code to deploy the [Valhuntir](https://github.com/AppliedIR/Valhuntir) /
[sift-mcp](https://github.com/AppliedIR/sift-mcp) AI-assisted DFIR harness to AWS.

See **[DESIGN.md](DESIGN.md)** for the architecture and decisions,
**[COST.md](COST.md)** for a monthly cost estimate,
**[TEARDOWN.md](TEARDOWN.md)** for how to pause or fully remove the deployment,
and **[testing/](testing/)** for the IAM permissions a dedicated deploy identity
needs. Short version:

- **One public host** (a bastion). SIFT, OpenSearch, Windows, and REMnux live in
  a private subnet and reach the internet only outbound via NAT.
- You reach the platform by **SSH-tunneling through the bastion** — XRDP into
  SIFT, and forward the gateway/Examiner Portal (`:4508`). SSM Session Manager
  is wired up as a keyless fallback.
- **Evidence** goes into a dedicated **WORM S3 bucket** (Object Lock + versioning
  + SSE-KMS) and is pulled onto SIFT over an **S3 VPC endpoint** — never over the
  internet or the bastion.
- Every deploy names a **checkpoint** — a tested set of baked AMIs for all four
  hosts plus the exact upstream versions they contain
  ([checkpoints/README.md](checkpoints/README.md)). Deploys boot in minutes and
  upstream drift can't break them. `checkpoint=latest` instead installs the
  newest upstream versions from scratch, to try them before cutting a new
  checkpoint.

## Layout

```
terraform/
├── versions.tf providers.tf variables.tf
├── network.tf              # VPC, subnets, NAT, S3 + SSM VPC endpoints
├── security_groups.tf      # least-privilege SGs per host
├── kms.tf secrets.tf iam.tf
├── evidence.tf             # WORM S3 bucket + bucket policy
├── checkpoint.tf           # which software: checkpoints/<name>.json or "latest"
├── ami.tf instances.tf     # bastion, SIFT, OpenSearch, Windows, REMnux
├── outputs.tf
├── terraform.tfvars.example
└── templates/              # cloud-init / user-data per host
checkpoints/                # <name>.json (pins + AMI ids), new.sh, bake.sh, promote.sh
packer/                     # AMI builds for all four hosts (run via checkpoints/bake.sh)
├── variables.pkr.hcl sift.pkr.hcl remnux.pkr.hcl opensearch.pkr.hcl windows.pkr.hcl
├── scripts/                # install-*.sh/.ps1 — shared with checkpoint=latest cloud-init
└── build-vpc/              # one-time public subnet for builds (free while idle)
bootstrap/                  # one-time: S3 bucket for remote state (local state)
```

## Checkpoints (what software gets deployed)

`terraform apply` requires `-var checkpoint=<name>` (or `checkpoint = ...` in
`terraform.tfvars`). Available checkpoints are the JSON files in
[checkpoints/](checkpoints/); deploy one from its git tag
(`git checkout checkpoint/<name>`) to reproduce exactly what was tested. See
[checkpoints/README.md](checkpoints/README.md) for `latest`, cutting new
checkpoints, and validation.

## Remote state (recommended for teams)

> **This is not the evidence bucket.** There are two unrelated S3 buckets:
> the **evidence bucket** (case data you upload from on-prem; SIFT pulls from it)
> and this **state bucket**, which holds Terraform's own bookkeeping file — the
> record of what AWS resources it created. The state bucket is pure
> infrastructure plumbing and never contains evidence. See [COST.md](COST.md) and
> [DESIGN.md](DESIGN.md).

Terraform "state" is a JSON file mapping your `.tf` code to the real AWS
resources (instance ids, bucket names, etc.). By default it lives on your laptop;
storing it in a shared, versioned, encrypted S3 bucket with **native S3 locking**
(no DynamoDB) lets a team share one source of truth and prevents concurrent
`apply`s from clobbering each other. Create the bucket once with `bootstrap/`,
then point the main config at it:

```bash
cd bootstrap
terraform init && terraform apply          # creates the state bucket
terraform output backend_hcl > ../terraform/backend.hcl
```

To keep local state instead, just delete `terraform/backend.tf`.

## Quick start

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set checkpoint, allowed_admin_cidrs (YOUR_IP/32), ssh_public_key

# with remote state:
terraform init -backend-config=backend.hcl
# or, for local state (after deleting backend.tf):  terraform init
terraform plan
terraform apply

# then:
terraform output usage_hint
terraform output -raw ssh_tunnel_cmd | bash      # open the tunnel
terraform output -raw get_credentials_cmd | bash # reveal generated creds
```

RDP a client to `localhost:3389` to land on the SIFT desktop, or point the
Examiner Portal / an LLM client at `https://localhost:4508` (the gateway serves TLS
with a CA generated on each instance: `~/.vhir/tls/ca-cert.pem` on SIFT).

## Loading evidence

```bash
# from your acquisition workstation (through the VPC — e.g. over the tunnel/VPN):
aws s3 cp ./INC-2026-0219.E01 s3://<evidence_bucket>/incoming/INC-2026-0219/

# on SIFT:
pull-evidence INC-2026-0219
vhir evidence register /cases/INC-2026-0219/evidence/*
```

## Status / caveats

Validated end to end on AWS (2026-10-15), all four hosts, both ways:

- **Checkpoint `2026-07-12`** (baked AMIs; component versions as of 2026-07-12):
  every host boots unattended; the SIFT gateway serves all nine backends
  (incl. `remnux-mcp`, `opensearch-mcp`, `wintools-mcp`) behind the Secrets
  Manager token; Windows joins the gateway and maps the case share by itself.
  Re-validated 2026-10-16 with the Windows forensic tools baked in: wintools-mcp
  finds 29 of its 31 catalog tools (all but the registration-gated KAPE and
  DumpIt), and EvtxECmd and Hayabusa run end to end through the SIFT gateway.
- **`checkpoint=latest`** (newest upstream that day): same result.

Known limitations:

- First boot of a baked SIFT pre-reads ~11 GB (lazy-loaded snapshot blocks), so
  the gateway's heavier backends are ready ~15 minutes after launch.
- Windows: KAPE and DumpIt (registration-gated response tools) aren't
  installed. Upstream quirks: `mactime.pl` and `Get-InjectedThreadEx.ps1` are
  installed (mactime runs under Strawberry Perl), but from reading wintools-mcp's
  code (not exercised) it launches `.pl` files without Perl and runs the `.ps1`,
  which only defines a function, as a script — so through `run_windows_command`
  neither is likely to do anything useful.
- Windows Defender stays on, but its first boot excludes the case share
  (`\\<sift>\cases` and `S:\`) and `C:\Tools`. Without the share exclusion
  Defender blocks tools from reading flagged evidence over SMB and tries to
  delete it on SIFT (tested with EICAR). Evidence copied to local Windows
  folders is still scanned.
- The Windows host finishes first boot ~3 minutes after SIFT publishes its join
  code; the gateway shows `wintools-mcp` ~2 minutes after that.
- REMnux at the July pins: 12 salt states fail because Malcat Lite and
  Speakeasy's helper scripts changed upstream since July (checksum mismatch);
  the rest of REMnux and remnux-mcp work. Current pins have no failures.
- OpenSearch uses the security plugin's demo TLS certificates (upstream's
  setup); SIFT connects with `verify_certs: false` over the private subnet.

Nothing sensitive is hardcoded — the examiner password, gateway API key, and
OpenSearch admin password are generated by Terraform (`random_password`), stored
in Secrets Manager, and fetched by each host via its instance role.

> **Cost note:** the full topology (SIFT m6i.2xlarge + OpenSearch + Windows +
> REMnux + NAT gateway, always on) is not cheap. Set `enable_*=false` for unused
> workers and stop instances between engagements.
