# Valhuntir on AWS — Deployment Design

**Status:** Working design for the Terraform IaC in `terraform/`.
**Goal:** Deploy the full Valhuntir / sift-mcp analysis harness (SIFT + OpenSearch + Windows + REMnux) to AWS with no sensitive host directly on the internet, examiner access via a bastion, and a defensible evidence-ingest path.

---

## Decisions (locked)

| Question | Decision |
|----------|----------|
| IaC tool | **Terraform** (HCL modules in `terraform/`) |
| VMs | **SIFT** (core) · **OpenSearch** data store · **Windows** (wintools) · **REMnux** — each individually toggleable |
| Examiner access | **Bastion + SSH port-forwarding**; run XRDP into SIFT over the tunnel. SSM Session Manager enabled as a keyless fallback. |
| Internet exposure | **Only the bastion** has a public IP. All forensic hosts are in private subnets, egress via NAT. |
| Provisioning | **cloud-init / user-data** runs the existing `setup-sift.sh` and friends on first boot. Optional Packer golden AMI for SIFT (validated 2026-10-15; REMnux template untested). |
| Evidence ingest | **Dedicated S3 evidence bucket** (Object Lock WORM + SSE-KMS), pulled by SIFT over an **S3 Gateway VPC Endpoint**. |

---

## Network topology

```
Internet ──SSH 22 (your IP only)──► Bastion (public subnet, EIP)
                                        │
        ┌───────────── private subnet (egress via NAT GW) ─────────────┐
        │   SIFT        OpenSearch      Windows        REMnux           │
        │  :4508 gw     :9200 data      :4624          :3000            │
        │  :3389 xrdp                                                   │
        │  :445 smb◄────────────────────┘ (SMB mount of case dir)      │
        └──────────────────────────────────────────────────────────────┘
                                        │
                          S3 Gateway VPC Endpoint (no internet)
                                        │
                             Evidence S3 bucket (WORM)
```

- **VPC** `10.20.0.0/16` (configurable), single AZ by default to avoid cross-AZ evidence transfer cost and keep it simple. Public subnet for the bastion + NAT GW; private subnet for everything else.
- **NAT Gateway** gives private hosts outbound internet for `apt`, `pip`, `git clone`, Sigma/Hayabusa rule downloads, threat-intel feeds. No inbound.
- **S3 Gateway VPC Endpoint** keeps evidence transfer (`aws s3 cp`) on the AWS backbone — it never traverses NAT/IGW/bastion, and it's free.
- **SSM VPC Interface Endpoints** (`ssm`, `ssmmessages`, `ec2messages`) let Session Manager reach private hosts without the bastion if you prefer.

## Security groups (least privilege)

| SG | Inbound | From |
|----|---------|------|
| bastion | 22/tcp | `var.allowed_admin_cidrs` (your IP) |
| sift | 22, 3389 (xrdp), 4508 (gw/portal) | bastion SG |
| sift | 445 (smb) | windows SG |
| sift | 3000 reachability n/a — SIFT is the *client* to remnux/opensearch | — |
| opensearch | 9200 | sift SG |
| windows | 4624 | sift SG |
| windows | 3389 (rdp admin) | bastion SG |
| remnux | 3000 | sift SG |
| remnux | 22 | bastion SG |

All egress open (needed for installers); tighten later with an egress proxy if required.

## Compute & storage defaults

| Host | Instance (default) | vCPU/RAM | Root | Data volume |
|------|--------------------|----------|------|-------------|
| bastion | t3.small | 2 / 2 GB | 20 GB gp3 | — |
| SIFT | m6i.2xlarge | 8 / 32 GB | 100 GB gp3 | 500 GB gp3 `/cases` (evidence+extractions) |
| OpenSearch | r6i.large | 2 / 16 GB | 40 GB gp3 | 200 GB gp3 `/var/lib/opensearch` |
| Windows | m6i.xlarge | 4 / 16 GB | 100 GB gp3 | — |
| REMnux | m6i.large | 2 / 8 GB | 120 GB gp3 | — |

SIFT is sized for Volatility 3 memory analysis (24 GB+ recommendation). All EBS encrypted with the project KMS key.

---

## Evidence ingest — the custody boundary

Evidence is the sensitive part, so it gets its own controls rather than riding the bastion path.

**Primary path — S3 evidence bucket:**
1. You upload acquired images/triage to `s3://<prefix>-evidence/incoming/…` from your acquisition workstation (`aws s3 cp --expected-size` multipart, or **Snowball** for TB-scale).
2. The bucket has **Object Lock in COMPLIANCE/GOVERNANCE mode + versioning** → objects are write-once-read-many (WORM), which is a tamper-evident chain-of-custody store. **SSE-KMS** with the project key. **Block Public Access** fully on. Bucket policy restricts `s3:*` to the **VPC endpoint** only.
3. SIFT's instance profile grants read on `incoming/` and write on `exports/` (for reports/case exports back out). SIFT pulls with `aws s3 cp` over the **S3 Gateway Endpoint** — no internet, no bastion, no NAT.
4. `vhir` registers the evidence (hashes, chain of custody) after it lands on the `/cases` volume.

**Secondary path — scp through bastion:** fine for a few small files; `scp -o ProxyJump=bastion file sift:/cases/INC-XXXX/evidence/`. Not for large images (bastion disk + single-hop bottleneck).

**Why not EFS/shared FS:** the architecture is explicitly local-case-dir per examiner with SMB export only to the Windows worker. S3 + WORM matches the custody model better than a shared mutable filesystem.

---

## Provisioning flow (cloud-init)

Each host bootstraps itself on first boot. Secrets (examiner password, gateway API key, OpenSearch admin, remnux-mcp token) are generated by Terraform (`random_password`), stored in **Secrets Manager**, and fetched by the instance via its IAM role — never rendered into user-data in plaintext beyond the secret ARN. For SIFT and REMnux the heavy install can be pre-baked (see the Packer note under *open questions*); the `baked` flag controls whether cloud-init runs the install or just the config.

- **SIFT:** mount `/cases` volume → create examiner user → install SANS SIFT via **`cast install sift --mode desktop --user <examiner>`** → install XRDP + XFCE → clone `sift-mcp` → `setup-sift.sh --remote -y --recommended` → point `opensearch-mcp` at the OpenSearch host → write `gateway.yaml` API-key→examiner map from the secret → enable systemd services.
  - `server` and `desktop` modes install identical forensic tooling; `desktop` only adds the `sift.config` layer (dotfiles, aliases, theme, folder layout, `foremost.conf`, Samba config) and installs no extra packages. `setup-sift.sh --remote` runs after `cast` and owns the case-dir Samba export.
- **OpenSearch:** Docker → OpenSearch container bound to private IP, JVM 6 GB, security enabled, admin creds from secret.
- **Windows:** install Python 3.10+/Git (choco) → store SIFT SMB creds for the service account (`cmdkey`) → clone `wintools-mcp` → `scripts\setup-windows.ps1 -NonInteractive -AcknowledgeSecurityHole -BindAddress 0.0.0.0 -Port 4624 -Examiner <slug>` → firewall `:4624` to the SIFT host. The installer self-generates a `vhir_wt_` bearer token; wiring it into the SIFT client is a documented one-time step.
- **REMnux:** create the conventional `remnux` OS account → **`cast install remnux --mode dedicated --user remnux`** → install Node 20 + `@remnux/mcp-server` → systemd unit `remnux-mcp.service` running `remnux-mcp-server --mode=local --transport=http --http-host=0.0.0.0 --http-port=3000`, authenticated with a **shared token from Secrets Manager** (`remnux_mcp_token`) so the SIFT client uses the same value.

**Accounts vs. identity.** Each distro keeps its conventional OS login — **`sansforensics`** on SIFT, **`remnux`** on REMnux — created in cloud-init (SIFT's is created with our generated password *before* `cast`, so the salt-states' well-known default password never applies). The Valhuntir **examiner identity** (`VHIR_EXAMINER`, e.g. `analyst`) is separate and passed to `setup-sift.sh --examiner`; it drives audit attribution and finding IDs regardless of which OS account you log in as. The Windows SMB mount authenticates to the case-dir share as `sansforensics`.

> The exact installer invocations are the documented commands from each repo; where a repo's unattended flags differ, the cloud-init template calls it out with a `# TODO(verify)` marker so it's easy to reconcile on first real run.

---

## What to review / open questions

- **SIFT/REMnux base image:** there is no official SANS SIFT or REMnux AMI. We start from **Ubuntu 24.04** (Canonical) and install both distros with **[`cast`](https://github.com/ekristen/cast)** — the same salt-states method used on bare metal (`cast install sift` / `cast install remnux`). Both salt-states require 24.04.
  - **Two provisioning modes, same install logic.** By default each host builds from the Ubuntu base at first boot (long, ~20–40 min for the salt run). Alternatively, build a **Packer golden AMI** (`packer/`) that bakes the `cast` run, and set `sift_ami` / `remnux_ami` — first boot then only applies per-deploy config. The heavy install lives in `packer/scripts/install-*.sh`, run by *both* Packer (bake) and the from-base cloud-init (boot) via a gzip+base64-embedded copy (gzip keeps SIFT's user-data under EC2's 16 KB limit; a Terraform precondition checks it), so the two paths install identical software; a `baked` flag in the cloud-init just skips the install step. See `packer/README.md`.
  - **Version pins.** Every input that would otherwise float to "latest" is pinned to what was validated on 2026-07-12, with matching defaults in `terraform/variables.tf`, `packer/sift.pkr.hcl`, and `install-sift.sh`: Ubuntu AMI `ami-0a02a779008fa3b99` (noble 20260626), cast `v1.0.22`, sift-saltstack `v2026.04.21`, sift-mcp `c67a860`, Valhuntir `ce1ae36`, AWS CLI `2.35.21`, providers in `versions.tf` + committed `.terraform.lock.hcl`, Packer amazon plugin `1.8.1`. Python deps are resolved as of `pypi_exclude_newer` (`UV_EXCLUDE_NEWER`), which is **required**: sift-mcp's open-ended `mcp>=1.26` otherwise pulls mcp 2.x, which breaks the gateway (`ImportError: streamablehttp_client`). Not pinned: Ubuntu apt packages, the `uv` binary, third-party RAG/baseline data. Bump pins deliberately and re-test; don't let them drift.
  - **Per-instance secrets in a baked AMI.** `setup-sift.sh` generates a gateway CA/cert (SAN = install-time IP) and bearer token. `packer/scripts/scrub-sift.sh` removes them, empties `api_keys`, disables the gateway, and runs `cloud-init clean`; first boot regenerates TLS for the instance's own IP, installs the Secrets Manager token, sets `VHIR_EXAMINER` via a systemd drop-in, and health-checks the gateway (failing cloud-init if unhealthy). An empty `api_keys` means auth is *disabled* in sift-gateway, which is why the gateway stays off until the token is written.
- **Region / AZ / CIDR / instance sizes:** all Terraform variables with defaults in `variables.tf`; override in `terraform.tfvars`.
- **Object Lock mode:** GOVERNANCE (overridable by privileged role) vs COMPLIANCE (immutable even to root) — pick per your custody policy.
- **Cost:** this is a large always-on footprint (~SIFT m6i.2xlarge + OpenSearch + Windows + REMnux + NAT). Consider `enable_*=false` for unused workers and stop instances between engagements.
