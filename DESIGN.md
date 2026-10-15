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
| Provisioning | **cloud-init / user-data** runs the existing `setup-sift.sh` and friends on first boot. Every deploy names a **checkpoint**: tested, Packer-baked AMIs for all four hosts plus their exact upstream versions (`checkpoints/`). `checkpoint=latest` installs the newest upstream versions at boot instead. |
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
- **OpenSearch:** baked Docker CE + upstream's opensearch-mcp deployment (its `docker-compose.yml` fixes OpenSearch 3.5.0). First boot mounts the data volume, patches the compose file to listen on the private IP and store indices on that volume (upstream's script runs compose with `-f`, which ignores override files), writes the admin password from the secret, and runs upstream `setup-opensearch.sh` (cluster settings, GeoIP pipeline, Security Analytics cleanup). SIFT gets `~/.vhir/opensearch.yaml` + the `opensearch-mcp` gateway backend.
- **Windows:** baked Git/Python (official installers) and wintools-mcp + forensic-knowledge + Python env at pinned versions. Join is upstream's own flow, unattended: SIFT's first boot mints a one-time join code from its gateway, configures the Samba case share for the Windows IP (upstream `_setup_samba_share`, IP fed on stdin), and publishes `{code, ca_cert}` to an SSM SecureString. Windows' first boot waits for it, trusts the gateway CA, and runs `setup-windows.ps1 -NonInteractive -JoinCode`, which generates its own bearer token + TLS cert, registers wintools-mcp with the gateway (hot-loaded), maps the case share, and registers its startup task. Fixed private IPs (`cidrhost`) let each side know the other's address without a Terraform cycle. `vhir-publish-join-code.sh` on SIFT re-joins a replaced Windows host.
- **REMnux:** baked `cast install remnux@<tag>` + Node.js + `@remnux/mcp-server@<ver>`. First boot writes the shared token (Secrets Manager `remnux_mcp_token`) to `/etc/remnux-mcp.env`, enables `remnux-mcp.service` (`--transport=http`, port 3000), and checks `/mcp` refuses unauthenticated requests. SIFT proxies it as the `remnux-mcp` gateway backend (`bearer_token`).

**Accounts vs. identity.** Each distro keeps its conventional OS login — **`sansforensics`** on SIFT, **`remnux`** on REMnux — created in cloud-init (SIFT's is created with our generated password *before* `cast`, so the salt-states' well-known default password never applies). The Valhuntir **examiner identity** (`VHIR_EXAMINER`, e.g. `analyst`) is separate and passed to `setup-sift.sh --examiner`; it drives audit attribution and finding IDs regardless of which OS account you log in as. The Windows SMB mount authenticates to the case-dir share as `sansforensics`.

> Each host runs its repo's own installer (`setup-sift.sh`, `setup-opensearch.sh`, `setup-windows.ps1`, the cast salt-states) in its documented unattended mode; local glue is limited to what those installers can't do without a human (secrets, the Windows join hand-off, private-IP networking).

---

## What to review / open questions

- **SIFT/REMnux base image:** there is no official SANS SIFT or REMnux AMI. We start from **Ubuntu 24.04** (Canonical) and install both distros with **[`cast`](https://github.com/ekristen/cast)** — the same salt-states method used on bare metal (`cast install sift` / `cast install remnux`). Both salt-states require 24.04.
  - **Checkpoints, same install logic.** Every deploy names a checkpoint (`terraform/checkpoint.tf`, `checkpoints/`). A named checkpoint launches Packer-baked AMIs for all four hosts, so first boot only applies per-deploy config and nothing upstream can drift under it; `checkpoint=latest` launches the base images and installs the newest upstream versions at boot. The heavy install lives in `packer/scripts/install-*.sh`, run by *both* Packer (bake) and the `latest` cloud-init (embedded gzip+base64; the whole Linux user data is also gzipped to stay under EC2's 16 KB limit), and each resolves "latest" to concrete versions up front, so the two paths install identically. See `checkpoints/README.md`.
  - **Version pins.** A checkpoint pins every input that would otherwise float: base AMIs, cast, the SIFT/REMnux salt-states releases, the sift-mcp / Valhuntir / opensearch-mcp / wintools-mcp commits, Node.js, Docker CE, Git/Python for Windows, the AWS CLI, and a PyPI cut-off time. The cut-off (`pypi_exclude_newer`, passed as `UV_EXCLUDE_NEWER` on Linux and `uv --exclude-newer` on Windows) matters as much as the commits: sift-mcp's open-ended `mcp>=1.26` otherwise pulled mcp 2.x, which broke the July code (`ImportError: streamablehttp_client`). Not pinned (and frozen only by baking): Ubuntu apt packages, `uv` itself, Docker Hub's monthly rebuilds of a tag, third-party RAG/baseline data. Providers (`versions.tf` + committed lock file) and the Packer plugin (`1.8.1`) are pinned in code.
  - **Per-instance secrets in a baked AMI.** `setup-sift.sh` generates a gateway CA/cert (SAN = install-time IP) and bearer token. `packer/scripts/scrub-sift.sh` removes them, empties `api_keys`, disables the gateway, and runs `cloud-init clean`; first boot regenerates TLS for the instance's own IP, installs the Secrets Manager token, sets `VHIR_EXAMINER` via a systemd drop-in, and health-checks the gateway (failing cloud-init if unhealthy). An empty `api_keys` means auth is *disabled* in sift-gateway, which is why the gateway stays off until the token is written.
- **Region / AZ / CIDR / instance sizes:** all Terraform variables with defaults in `variables.tf`; override in `terraform.tfvars`.
- **Object Lock mode:** GOVERNANCE (overridable by privileged role) vs COMPLIANCE (immutable even to root) — pick per your custody policy.
- **Cost:** this is a large always-on footprint (~SIFT m6i.2xlarge + OpenSearch + Windows + REMnux + NAT). Consider `enable_*=false` for unused workers and stop instances between engagements.
