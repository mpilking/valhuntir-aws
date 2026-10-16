# Checkpoints — deploy a known-good stack at any time

A **checkpoint** is a tested, frozen set of software for the whole stack:

- one **baked AMI per host** (SIFT, REMnux, OpenSearch, Windows), built by
  Packer from exact versions, and
- the **pins** those AMIs were built from (every upstream commit, release tag,
  package version and base image), recorded in `checkpoints/<name>.json`, and
- the **git tag** `checkpoint/<name>`, which freezes the Terraform and first-boot
  templates the AMIs were tested with.

Deploying a checkpoint downloads and installs nothing at boot beyond
per-instance configuration (secrets, TLS certs, the Windows join), so upstream
drift — moved repos, deleted downloads, new library majors, retired base images
— cannot break it. The AMIs are owned by this account and don't expire.

## Deploy

Terraform requires a checkpoint; there is no default.

```bash
git checkout checkpoint/2026-07-12        # the exact IaC that checkpoint was tested with
cd terraform
terraform apply -var checkpoint=2026-07-12
```

Using a newer IaC commit with an older checkpoint usually works too, but only
the tagged commit is guaranteed. Terraform stops early with a readable error if
the checkpoint file is missing, its region differs from `region`, a pin is
empty, or an enabled host has no baked AMI. It warns (but proceeds) when the
checkpoint is still a `candidate`.

### `checkpoint=latest`

```bash
terraform apply -var checkpoint=latest
```

Builds every host from a fresh Ubuntu/Windows base with every component at its
newest version (~30–90 min of installs at boot). This **can fail** — that is its
purpose: to find out whether today's upstream still works before cutting a new
checkpoint. Each Linux host records what it actually installed in
`/etc/valhuntir/versions/` (Windows: `C:\ProgramData\valhuntir\`).

Two choices stay fixed even under `latest`: Ubuntu 24.04 (required by the SIFT
and REMnux salt-states) and Windows Python 3.12.x (setup-windows.ps1's
recommended series; a brand-new Python minor tends to lack wheels).

## Cut a new checkpoint

```bash
cd checkpoints
./new.sh 2027-01-15            # resolve today's newest versions -> 2027-01-15.json (candidate)
./bake.sh 2027-01-15           # build the 4 AMIs in parallel (~70 min), record their ids
cd ../terraform
terraform apply -var checkpoint=2027-01-15    # deploy and test (see "Validate")
terraform destroy -var checkpoint=2027-01-15
cd ../checkpoints
./promote.sh 2027-01-15        # status=validated, records date + IaC commit
git add 2027-01-15.json && git commit -m "Checkpoint 2027-01-15 validated"
git tag -a checkpoint/2027-01-15 -m "Checkpoint 2027-01-15"
```

To hold one component back (e.g. a new sift-mcp breaks something), edit that
pin in the JSON before `bake.sh`. `bake.sh <name> sift remnux` rebuilds only
some hosts. `bake.sh` needs the one-time build network: `cd ../packer/build-vpc
&& terraform init && terraform apply` (free while idle).

## Validate

A checkpoint is promoted only after a full-stack deploy passes:

- every first-boot log ends in `... complete` (`/var/log/*-firstboot.log`,
  `C:\ProgramData\valhuntir\firstboot.log`) and cloud-init is `done`
- SIFT gateway: `GET /api/v1/backends` shows every backend `ok`, including
  `remnux-mcp`, `opensearch-mcp` and `wintools-mcp`; `/api/v1/tools` lists tools
  for each; requests without the Secrets Manager token get 401
- TLS cert SAN is the instance's own IP; examiner identity is `examiner_name`
- Windows: joined the gateway, case share mapped (`smbstatus -b` on SIFT shows
  the Windows session); wintools-mcp's `check_windows_tools` finds the installed
  tools, and EvtxECmd / Hayabusa / Chainsaw produce output from an event log
- OpenSearch: cluster green, reachable from SIFT on the private IP

## File format

```json
{
  "name": "2026-07-12",
  "status": "candidate | validated",
  "region": "us-east-1",
  "validated_on": "", "iac_commit": "",
  "build": { "sift_user", "sift_mode", "remnux_user", "remnux_mode" },
  "pins":  { "ubuntu_ami", "windows_base_ami", "awscli", "cast",
             "sift_saltstack", "sift_mcp", "valhuntir", "opensearch_mcp",
             "pypi_exclude_newer", "remnux_saltstack", "remnux_mcp_server",
             "nodejs", "docker", "wintools_mcp", "git_windows", "python_windows",
             "windows_tools": { "dotnet_runtime", "zimmerman", "sysinternals",
               "hayabusa", "chainsaw", "capa", "yara", "densityscout", "winpmem",
               "moneta", "hollows_hunter", "get_injectedthreadex",
               "strawberry_perl", "sleuthkit" } },
  "amis":  { "sift", "remnux", "opensearch", "windows" },
  "notes": []
}
```

Pin names match the Packer variables (`packer/variables.pkr.hcl`) and Terraform's
`local.pins` (`terraform/checkpoint.tf`). `windows_tools` is only used by the
Windows bake (`packer/scripts/install-windows-tools.ps1`); its `zimmerman`
(`net9`) and `sysinternals` (`current`) entries can't name a version because
those vendors only publish current builds — the baked AMI is what freezes them.

## Cost and cleanup

Each checkpoint's four AMIs are backed by EBS snapshots (~360 GB provisioned,
billed on used blocks: roughly $5–10/month per checkpoint). Keep the ones you
might deploy; deregister old ones per [TEARDOWN.md](../TEARDOWN.md) §6 and mark
their JSON accordingly. AMIs are regional — to deploy in another region, copy
them (`aws ec2 copy-image`) into a checkpoint file for that region.
