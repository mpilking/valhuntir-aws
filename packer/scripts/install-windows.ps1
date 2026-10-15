# install-windows.ps1 — bake-time install for the Windows wintools-mcp host.
#
# Run by Packer only. It stages, at pinned versions, everything upstream's
# setup-windows.ps1 would otherwise fetch as "latest" at first boot:
#   - Git + Python via Chocolatey (exact versions)
#   - wintools-mcp checked out *detached* at the pinned commit in
#     C:\Tools\vhir\wintools-mcp (setup-windows.ps1's `git pull` then fails and
#     it explicitly continues with the existing code)
#   - forensic-knowledge from the pinned sift-mcp commit in
#     C:\Tools\vhir\forensic-knowledge (setup-windows.ps1 installs a local copy
#     when present instead of downloading sift-mcp main)
#   - the .venv with all Python deps resolved as of PYPI_EXCLUDE_NEWER (uv)
# It does NOT run setup-windows.ps1: that generates the per-instance bearer
# token + TLS cert and joins SIFT, which happens at first boot (user data).
#
# Versions via environment — REQUIRED:
#   WINTOOLS_MCP_REF, SIFT_MCP_REF, CHOCO_GIT, CHOCO_PYTHON312, PYPI_EXCLUDE_NEWER

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
foreach ($v in "WINTOOLS_MCP_REF","SIFT_MCP_REF","CHOCO_GIT","CHOCO_PYTHON312","PYPI_EXCLUDE_NEWER") {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "missing required env var $v" }
}
$Install  = "C:\Tools\vhir"
$Wintools = Join-Path $Install "wintools-mcp"
$FK       = Join-Path $Install "forensic-knowledge"

# Native tools (git, uv) write progress to stderr, which PowerShell 5.1 turns
# into error records under a captured host; judge them by exit code only.
function Invoke-Native { param([scriptblock]$Cmd)
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { & $Cmd 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE): $Cmd" } }
function Update-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User") }

# --- Chocolatey + exact Git / Python ------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
  Invoke-Expression ((New-Object Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
  Update-Path
}
Invoke-Native { choco install -y --no-progress git --version $env:CHOCO_GIT }
Invoke-Native { choco install -y --no-progress python312 --version $env:CHOCO_PYTHON312 }
Update-Path
$Py = (Get-Command python -ErrorAction Stop).Source
Invoke-Native { & $Py --version }

# --- Pinned source ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Install | Out-Null
if (-not (Test-Path (Join-Path $Wintools ".git"))) {
  Invoke-Native { git clone --quiet https://github.com/AppliedIR/wintools-mcp.git $Wintools }
}
Invoke-Native { git -C $Wintools -c advice.detachedHead=false checkout --quiet --detach $env:WINTOOLS_MCP_REF }

$Tmp = Join-Path $env:TEMP "sift-mcp"
if (Test-Path $Tmp) { Remove-Item -Recurse -Force $Tmp }
Invoke-Native { git clone --quiet https://github.com/AppliedIR/sift-mcp.git $Tmp }
Invoke-Native { git -C $Tmp -c advice.detachedHead=false checkout --quiet --detach $env:SIFT_MCP_REF }
if (Test-Path $FK) { Remove-Item -Recurse -Force $FK }
Copy-Item -Recurse (Join-Path $Tmp "packages\forensic-knowledge") $FK
Remove-Item -Recurse -Force $Tmp

# --- venv with deps resolved as of the checkpoint date -------------------------
# --seed puts pip in the venv: setup-windows.ps1 runs `python -m pip install -e`
# against it, which finds every dependency already satisfied and keeps them.
Invoke-Native { & $Py -m pip install --quiet --disable-pip-version-check uv }
$Uv = Join-Path (Split-Path $Py) "Scripts\uv.exe"
$Venv = Join-Path $Wintools ".venv"
Invoke-Native { & $Uv venv --seed --python $Py $Venv }
$VPy = Join-Path $Venv "Scripts\python.exe"
Invoke-Native { & $Uv pip install --python $VPy --exclude-newer $env:PYPI_EXCLUDE_NEWER -e $Wintools -e $FK }
Invoke-Native { & $VPy -c "import wintools_mcp, forensic_knowledge; print('wintools-mcp', wintools_mcp.__version__)" }

# --- Record versions ----------------------------------------------------------
$Rec = "C:\ProgramData\valhuntir\versions"
New-Item -ItemType Directory -Force -Path $Rec | Out-Null
@(
  "wintools_mcp=$(git -C $Wintools rev-parse HEAD)",
  "sift_mcp_fk=$env:SIFT_MCP_REF",
  "git=$((git --version) -replace 'git version ','')",
  "python=$((& $VPy --version) -replace 'Python ','')",
  "pypi_exclude_newer=$env:PYPI_EXCLUDE_NEWER",
  "installed_at=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
) | Set-Content -Encoding ASCII (Join-Path $Rec "windows.txt")
Get-Content (Join-Path $Rec "windows.txt")
Write-Output "install-windows.ps1 complete"
