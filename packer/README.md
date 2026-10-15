# Packer — golden AMIs for SIFT and REMnux

These builds bake the slow, deployment-independent work into reusable AMIs so
Terraform launches are fast. The expensive part is the **`cast` salt run**
(SANS SIFT / REMnux, ~20–40 min) plus, for SIFT, the sift-mcp stack and RAG
index build. Baking it moves that cost from every boot to a one-time build.

Status: the **SIFT** build is validated (2026-10-15: baked instance ready ~3½ min
after launch; the full install took ~25 min in the bake and ~78 min on the July
from-base boot). The **REMnux** template has not been run
yet and lacks the SIFT template's fixes (exact plugin pin, pinned `source_ami`,
`cd /` in `execute_command`, `aws_polling`); port them before relying on it.

## What's baked

The build runs the **same** `scripts/install-*.sh` that the from-base cloud-init
runs — a single source of truth. So a baked instance and a from-base instance
install identical software; only *when* differs.

| | Baked | Configured at first boot |
|---|-------|--------------------------|
| SIFT | apt deps, XFCE/XRDP, `cast install sift`, sift-mcp stack, RAG index | `/cases` mount, sansforensics password, gateway TLS cert (instance IP), gateway token from Secrets Manager, examiner identity, OpenSearch URL, gateway enable + health check |
| REMnux | `cast install remnux`, Node + `@remnux/mcp-server` | token env file, service enable |

Secrets and per-case identity are **never** baked. `setup-sift.sh` does create a
gateway CA/cert and bearer token during the install; the last provisioner,
`scripts/scrub-sift.sh`, removes them (plus SSH host keys, Packer's key, shell
history, and cloud-init state) and leaves the gateway disabled with an empty
`api_keys` map. First boot regenerates them per instance. It refuses to bake if
an approval password exists.

## Version pins

The SIFT build defaults to the versions validated on 2026-07-12: source AMI
`ami-0a02a779008fa3b99` (Ubuntu noble 20260626), cast `v1.0.22`, sift-saltstack
`v2026.04.21`, sift-mcp `c67a860…`, Valhuntir `ce1ae36…`, AWS CLI `2.35.21`, and
`pypi_exclude_newer = 2026-07-12T19:00:00Z` (required — newer mcp 2.x breaks
the gateway). Keep them in lockstep with the matching `terraform/variables.tf`
defaults. The pins are recorded as tags on the AMI and its snapshot.

## Build

Requires Packer and AWS credentials. The amazon plugin is pinned to `1.8.1`;
if `packer init` can't fetch it (it's distributed via releases.hashicorp.com),
download it from there and run `packer plugins install --path <binary> github.com/hashicorp/amazon`.

`subnet_id` is **required**: the build needs a subnet with outbound internet and
auto-assigned public IP routing (us-east-1 in our account has no default VPC). The
Terraform public subnet works. The builder gets a temporary public IP, and its
temporary security group allows SSH only from the machine running Packer.

```bash
cd packer
packer init .
packer build -var subnet_id=subnet-0abc... sift.pkr.hcl      # ~30 min install + snapshot time

# overrides
packer build -var subnet_id=... -var region=us-west-2 -var sift_mode=server sift.pkr.hcl
```

Each build writes the AMI id to `manifest-sift.json` and prints the cast salt
states that failed. Expected on a headless box (12 as of 2026-10-15): the exiftool
source 404 chain (`sift-exiftool-*`, `sift-scripts`, `sift-server-include`, the
version-file states) and the GNOME `gsettings`/`dconf` config states
(`sift-config*`). exiftool comes from apt instead. Anything else is worth a look.

The first snapshot of the encrypted 100 GB volume is slow (it took ~60 min);
`aws_polling` waits up to 2 h for the AMI.

## Use the baked AMIs in Terraform

Put the AMI ids in `terraform/terraform.tfvars`:

```hcl
sift_ami   = "ami-0abc...sift"
remnux_ami = "ami-0def...remnux"
```

Terraform then launches those AMIs and the cloud-init `baked=true` path skips the
heavy install. First boot only applies per-deploy config. Leave a variable empty
to build that host from the pinned Ubuntu 24.04 base (`ubuntu_ami_id`) at boot.

## Notes

- Rebuild when any pin, `sift_mode`/`remnux_mode`, or the install scripts change.
  AMIs are immutable; old ones (and their snapshots, ~$0.05/GB-month) remain
  until you deregister them; see TEARDOWN.md §6.
- The build runs `cloud-init clean` so the launched instance re-runs user-data.
