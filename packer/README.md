# Packer — the AMIs behind each checkpoint

One Packer config (all `*.pkr.hcl` here) with four builds: `sift`, `remnux`,
`opensearch`, `windows`. Every version is a required variable, so an AMI is
only ever built from explicit pins. **Run it through
[`checkpoints/bake.sh`](../checkpoints/README.md)**, which feeds a checkpoint's
pins in, builds the selected hosts in parallel, and records the AMI ids back
into the checkpoint.

| Build | Bakes | Done at first boot (Terraform user data) |
|---|---|---|
| sift | apt deps, XFCE/XRDP, `cast install sift@<tag>`, sift-mcp stack + RAG index, opensearch-mcp client | `/cases` mount, login password, gateway TLS cert (instance IP), gateway token, examiner identity, REMnux/OpenSearch backends, Windows join code + Samba share |
| remnux | `cast install remnux@<tag>`, Node.js (NodeSource, exact), `@remnux/mcp-server@<ver>` | token env file, service enable + health check |
| opensearch | Docker CE (exact), opensearch-mcp at the pinned commit, its OpenSearch image pre-pulled | data volume, admin password, upstream `setup-opensearch.sh` (cluster settings, GeoIP, analytics) |
| windows | Git for Windows + Python (official installers, exact), wintools-mcp + forensic-knowledge at the pinned commits, Python env resolved as of `pypi_exclude_newer`; the forensic tools wintools-mcp runs (`install-windows-tools.ps1`: .NET 9, Zimmerman, Sysinternals, Hayabusa, Chainsaw, capa, YARA, DensityScout, winpmem, Moneta, hollows_hunter, Get-InjectedThreadEx, Strawberry Perl + Sleuth Kit); sysprep | `setup-windows.ps1 -NonInteractive -JoinCode` (token, TLS cert, join, case-share mapping, startup task) |

The Linux builds run the same `scripts/install-*.sh` that `checkpoint=latest`
runs at first boot (with "latest" resolved to concrete versions up front), so
both paths install identically. Secrets and per-instance identity are never
baked: `scrub-sift.sh` / `scrub-linux.sh` remove the gateway TLS material and
token, SSH host keys, Packer's key and cloud-init state; Windows is sysprepped
(EC2Launch v2).

## Prerequisites

- Packer, with the amazon plugin pinned to `1.8.1`. If `packer init` can't fetch
  it (it's distributed via releases.hashicorp.com), download it from there and
  run `packer plugins install --path <binary> github.com/hashicorp/amazon`.
- The build network, once per account/region: `cd build-vpc && terraform init &&
  terraform apply`. Builders get a temporary public IP there; Packer's temporary
  security group admits SSH/WinRM only from the machine running Packer.

## Notes

- Expected `cast` failures (printed after each Linux build). SIFT (12, July
  pins): the exiftool source 404 chain and GNOME `gsettings`/`dconf` states on a
  headless box. REMnux (12, July pins): Malcat Lite and Speakeasy's helper
  scripts changed upstream since July, so their checksums no longer match; with
  current pins REMnux had none. Anything else is worth a look.
- The first snapshot of a large encrypted volume is slow (SIFT: ~40 min after
  the install); `aws_polling` waits up to 2 h.
- Windows tools: upstream `setup-windows.ps1` installs none; wintools-mcp only
  finds binaries in known folders (`C:\Tools\...`), which is where
  `install-windows-tools.ps1` puts them. Versions come from the checkpoint's
  `pins.windows_tools`. Eric Zimmerman and Sysinternals publish only their
  current builds (pins `net9` / `current`), so a re-bake may fetch newer copies;
  each bake records versions and SHA256s in
  `C:\ProgramData\valhuntir\versions\windows-tools.txt`. `C:\Tools` is
  excluded from Defender (it quarantines rule files and memory tools).
  Sysinternals' EULA is pre-accepted for SYSTEM (the wintools-mcp task's account).
  KAPE and DumpIt are registration-gated and not installed.
- `packer/logs/` keeps each bake's full log (gitignored).
