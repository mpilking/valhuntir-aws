# install-windows-tools.ps1 — the forensic tools wintools-mcp runs.
#
# Upstream setup-windows.ps1 installs no tools: wintools-mcp only discovers
# binaries in known folders (C:\Tools\..., see wintools-mcp environment.py and
# data/catalog/*.yaml). This installs every freely downloadable catalog tool
# where it looks:
#
#   C:\Program Files\dotnet     .NET Desktop Runtime 9 (Zimmerman tools need it)
#   C:\Tools\ZimmermanTools     14 EZ tools (net9 builds)
#   C:\Tools\SysinternalsSuite  autorunsc, strings, handle, procdump, sigcheck
#                               (EULA pre-accepted for SYSTEM, which runs wintools-mcp)
#   C:\Tools\Hayabusa           hayabusa.exe + its rules/config
#   C:\Tools\Chainsaw           chainsaw.exe + sigma rules/mappings
#   C:\Tools\CAPA, YARA, DensityScout, Memory (winpmem), Moneta, HollowsHunter
#   C:\Tools\Scripts            Get-InjectedThreadEx.ps1
#   C:\Strawberry + C:\Tools\SleuthKit   Perl + TSK (mactime.pl)
# Not installed: KAPE and DumpIt (registration-gated response tools).
#
# Versions: WINDOWS_TOOLS_B64 = base64 of a JSON object (the checkpoint's
# pins.windows_tools). Any value may be "latest" (checkpoint=latest first boot).
# Zimmerman ("net9") and Sysinternals ("current") publish only their current
# builds; for every tool the resolved version and SHA256 of each download are
# recorded in C:\ProgramData\valhuntir\versions\windows-tools.txt.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $env:WINDOWS_TOOLS_B64) { throw "missing required env var WINDOWS_TOOLS_B64" }
$V = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:WINDOWS_TOOLS_B64)) | ConvertFrom-Json
$Keys = "dotnet_runtime","zimmerman","sysinternals","hayabusa","chainsaw","capa","yara","densityscout",
        "winpmem","moneta","hollows_hunter","get_injectedthreadex","strawberry_perl","sleuthkit"
foreach ($k in $Keys) { if (-not $V.$k) { throw "windows_tools.$k is not set" } }

$Tools = "C:\Tools"
$Dl    = Join-Path $Tools "_download"
New-Item -ItemType Directory -Force -Path $Tools, $Dl | Out-Null
# Defender would quarantine parts of these (memory acquisition, sigma/yara rule
# text that quotes malware); exclude the tools folder before downloading.
if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
  Add-MpPreference -ExclusionPath $Tools
}

$Record = [System.Collections.Generic.List[string]]::new()
function Get-File { param([string]$Url, [string]$Name)
  $out = Join-Path $Dl $Name
  for ($i = 1; ; $i++) {
    try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $out; break }
    catch { if ($i -ge 4) { throw "download failed: $Url : $_" }; Start-Sleep -Seconds (15 * $i) }
  }
  $Record.Add("  $Name sha256=$((Get-FileHash $out -Algorithm SHA256).Hash.ToLower())")
  $out }
# (Expand-Archive takes minutes on the rule-heavy zips; overwrite, as several
# Sysinternals zips each carry Eula.txt.)
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Expand-To { param([string]$Zip, [string]$Dest)
  $z = [IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    foreach ($e in $z.Entries) {
      $out = Join-Path $Dest $e.FullName
      if ($e.FullName.EndsWith("/")) { New-Item -ItemType Directory -Force -Path $out | Out-Null; continue }
      New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
    }
  } finally { $z.Dispose() } }
# Native tools may write to stderr, which PowerShell 5.1 turns into terminating
# errors here; capture both streams as text.
function Invoke-Text { param([scriptblock]$Cmd)
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { (& $Cmd 2>&1 | ForEach-Object { "$_" }) -join " " } finally { $ErrorActionPreference = $prev } }
# GitHub release: "latest" -> newest non-prerelease; returns @{tag; url} of the asset matching $Pattern.
function Get-GhAsset { param([string]$Repo, [string]$Tag, [string]$Pattern)
  $api = if ($Tag -eq "latest") { "https://api.github.com/repos/$Repo/releases/latest" }
         else { "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
  $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "valhuntir-bake" }
  $a = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
  if (-not $a) { throw "$Repo $($rel.tag_name): no asset matching $Pattern" }
  @{ tag = $rel.tag_name; url = $a.browser_download_url; name = $a.name } }
function Note { param([string]$Line) $Record.Add($Line); Write-Output $Line }

# --- .NET Desktop Runtime 9 (includes the base runtime) -------------------------
$dn = $V.dotnet_runtime
if ($dn -eq "latest") {
  $dn = (Invoke-RestMethod https://builds.dotnet.microsoft.com/dotnet/release-metadata/9.0/releases.json)."latest-runtime" }
Note "dotnet_runtime=$dn"
$exe = Get-File "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/$dn/windowsdesktop-runtime-$dn-win-x64.exe" "windowsdesktop-runtime-$dn-win-x64.exe"
$p = Start-Process -FilePath $exe -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw ".NET runtime installer exited $($p.ExitCode)" }

# --- Eric Zimmerman tools (catalog: data/catalog/zimmerman.yaml) ----------------
Note "zimmerman=$($V.zimmerman)"
$ez = Join-Path $Tools "ZimmermanTools"
foreach ($t in "AmcacheParser","AppCompatCacheParser","EvtxECmd","JLECmd","LECmd","MFTECmd","PECmd",
               "RBCmd","RECmd","SBECmd","SQLECmd","SrumECmd","WxTCmd","bstrings") {
  $flavor = if ($V.zimmerman -eq "latest") { "net9" } else { $V.zimmerman }
  Expand-To (Get-File "https://download.ericzimmermanstools.com/$flavor/$t.zip" "ez-$t.zip") $ez
}

# --- Sysinternals ------------------------------------------------------------------
Note "sysinternals=$($V.sysinternals)"
$si = Join-Path $Tools "SysinternalsSuite"
foreach ($t in "Autoruns","Strings","Handle","Procdump","Sigcheck") {
  Expand-To (Get-File "https://download.sysinternals.com/files/$t.zip" "si-$t.zip") $si
}
# Each tool shows a EULA dialog on first use per user (and blocks a headless
# run) unless accepted. Accept here, then copy the acceptance to SYSTEM (the
# wintools-mcp scheduled task's account) and to new user profiles.
foreach ($c in @(@("autorunsc64.exe","-accepteula -nobanner -a b"), @("autorunsc.exe","-accepteula -nobanner -a b"),
                 @("strings64.exe","-accepteula -nobanner C:\Windows\win.ini"), @("strings.exe","-accepteula -nobanner C:\Windows\win.ini"),
                 @("handle64.exe","-accepteula -nobanner -p 4"), @("handle.exe","-accepteula -nobanner -p 4"),
                 @("procdump64.exe","-accepteula"), @("procdump.exe","-accepteula"),
                 @("sigcheck64.exe","-accepteula -nobanner C:\Windows\notepad.exe"), @("sigcheck.exe","-accepteula -nobanner C:\Windows\notepad.exe"))) {
  $proc = Start-Process -FilePath (Join-Path $si $c[0]) -ArgumentList $c[1] -PassThru `
    -RedirectStandardOutput (Join-Path $Dl "eula.out") -RedirectStandardError (Join-Path $Dl "eula.err")
  if (-not $proc.WaitForExit(120000)) { $proc.Kill() }
}
New-ItemProperty -Path HKCU:\Software\Sysinternals -Name EulaAccepted -Value 1 -PropertyType DWord -Force | Out-Null
Write-Output (Invoke-Text { reg.exe copy "HKCU\Software\Sysinternals" "HKU\.DEFAULT\Software\Sysinternals" /s /f })
Write-Output (Invoke-Text { reg.exe load "HKU\VhirDefault" "C:\Users\Default\NTUSER.DAT" })
Write-Output (Invoke-Text { reg.exe copy "HKCU\Software\Sysinternals" "HKU\VhirDefault\Software\Sysinternals" /s /f })
[gc]::Collect(); Write-Output (Invoke-Text { reg.exe unload "HKU\VhirDefault" })
Note "  EULA accepted: $((Get-ChildItem 'Registry::HKEY_USERS\.DEFAULT\Software\Sysinternals').PSChildName -join ', ')"

# --- Hayabusa ------------------------------------------------------------------------
$a = Get-GhAsset "Yamato-Security/hayabusa" $V.hayabusa '-win-x64\.zip$'
Note "hayabusa=$($a.tag)"
$hb = Join-Path $Tools "Hayabusa"
Expand-To (Get-File $a.url $a.name) $hb
Get-ChildItem $hb -Filter "hayabusa-*-win-x64.exe" | Move-Item -Destination (Join-Path $hb "hayabusa.exe") -Force

# --- Chainsaw (binary + sigma rules + mappings) ------------------------------------
$a = Get-GhAsset "WithSecureLabs/chainsaw" $V.chainsaw '^chainsaw_all_platforms\+rules\.zip$'
Note "chainsaw=$($a.tag)"
$cz = Join-Path $Dl "chainsaw"
Expand-To (Get-File $a.url "chainsaw-rules.zip") $cz
$cs = Join-Path $Tools "Chainsaw"
if (Test-Path $cs) { Remove-Item -Recurse -Force $cs }
Move-Item (Join-Path $cz "chainsaw") $cs
Get-ChildItem $cs -File -Filter "chainsaw_*" | Where-Object { $_.Name -ne "chainsaw_x86_64-pc-windows-msvc.exe" } | Remove-Item -Force
Move-Item (Join-Path $cs "chainsaw_x86_64-pc-windows-msvc.exe") (Join-Path $cs "chainsaw.exe") -Force

# --- capa, YARA, DensityScout ---------------------------------------------------------
$a = Get-GhAsset "mandiant/capa" $V.capa '-windows\.zip$'
Note "capa=$($a.tag)"
Expand-To (Get-File $a.url $a.name) (Join-Path $Tools "CAPA")
$a = Get-GhAsset "VirusTotal/yara" $V.yara '-win64\.zip$'
Note "yara=$($a.tag)"
Expand-To (Get-File $a.url $a.name) (Join-Path $Tools "YARA")
$ds = $V.densityscout
if ($ds -eq "latest") {
  $ds = ((Invoke-WebRequest -UseBasicParsing https://www.cert.at/en/downloads/software/software-densityscout).Links.href |
    Select-String 'densityscout_build_(\d+)_windows\.zip' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value } |
    Sort-Object -Descending | Select-Object -First 1) }
Note "densityscout=build_$ds"
$dz = Join-Path $Dl "densityscout"
Expand-To (Get-File "https://www.cert.at/media/files/downloads/software/densityscout/files/densityscout_build_${ds}_windows.zip" "densityscout_build_${ds}_windows.zip") $dz
New-Item -ItemType Directory -Force -Path (Join-Path $Tools "DensityScout") | Out-Null
Copy-Item (Join-Path $dz "win64\densityscout.exe") (Join-Path $Tools "DensityScout\densityscout.exe") -Force

# --- Memory / live-process tools ------------------------------------------------------
$a = Get-GhAsset "Velocidex/WinPmem" $V.winpmem '^winpmem_mini_x64.*\.exe$'
Note "winpmem=$($a.tag) ($($a.name))"
New-Item -ItemType Directory -Force -Path (Join-Path $Tools "Memory") | Out-Null
Copy-Item (Get-File $a.url $a.name) (Join-Path $Tools "Memory\winpmem.exe") -Force
$a = Get-GhAsset "forrest-orr/moneta" $V.moneta '^Moneta64\.exe$'
Note "moneta=$($a.tag)"
New-Item -ItemType Directory -Force -Path (Join-Path $Tools "Moneta") | Out-Null
Copy-Item (Get-File $a.url $a.name) (Join-Path $Tools "Moneta\moneta64.exe") -Force
$a = Get-GhAsset "hasherezade/hollows_hunter" $V.hollows_hunter '^hollows_hunter64\.exe$'
Note "hollows_hunter=$($a.tag)"
New-Item -ItemType Directory -Force -Path (Join-Path $Tools "HollowsHunter") | Out-Null
Copy-Item (Get-File $a.url $a.name) (Join-Path $Tools "HollowsHunter\hollows_hunter.exe") -Force
$ref = $V.get_injectedthreadex
if ($ref -eq "latest") {
  $ref = (Invoke-RestMethod -Uri https://api.github.com/repos/jdu2600/Get-InjectedThreadEx/commits/HEAD -Headers @{ "User-Agent" = "valhuntir-bake" }).sha }
Note "get_injectedthreadex=$ref"
New-Item -ItemType Directory -Force -Path (Join-Path $Tools "Scripts") | Out-Null
Copy-Item (Get-File "https://raw.githubusercontent.com/jdu2600/Get-InjectedThreadEx/$ref/Get-InjectedThreadEx.ps1" "Get-InjectedThreadEx.ps1") `
  (Join-Path $Tools "Scripts\Get-InjectedThreadEx.ps1") -Force

# --- Strawberry Perl + The Sleuth Kit (mactime.pl) ----------------------------------
$a = Get-GhAsset "StrawberryPerl/Perl-Dist-Strawberry" $V.strawberry_perl '-64bit\.msi$'
Note "strawberry_perl=$($a.tag) ($($a.name))"
$msi = Get-File $a.url $a.name
$p = Start-Process -FilePath msiexec.exe -ArgumentList "/i", "`"$msi`"", "/qn", "/norestart" -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "Strawberry Perl installer exited $($p.ExitCode)" }
$a = Get-GhAsset "sleuthkit/sleuthkit" $V.sleuthkit '-win32\.zip$'
Note "sleuthkit=$($a.tag)"
$tz = Join-Path $Dl "sleuthkit"
Expand-To (Get-File $a.url $a.name) $tz
$tsk = Join-Path $Tools "SleuthKit"
if (Test-Path $tsk) { Remove-Item -Recurse -Force $tsk }
Move-Item (Get-ChildItem $tz -Directory | Select-Object -First 1).FullName $tsk

# --- Verify every binary the catalog looks for is in place -----------------------------
$expect = @("C:\Program Files\dotnet\dotnet.exe", "C:\Strawberry\perl\bin\perl.exe", "$tsk\bin\mactime.pl",
  "$hb\hayabusa.exe", "$hb\rules", "$cs\chainsaw.exe", "$cs\sigma", "$cs\mappings",
  "$Tools\CAPA\capa.exe", "$Tools\YARA\yara64.exe", "$Tools\DensityScout\densityscout.exe",
  "$Tools\Memory\winpmem.exe", "$Tools\Moneta\moneta64.exe", "$Tools\HollowsHunter\hollows_hunter.exe",
  "$Tools\Scripts\Get-InjectedThreadEx.ps1",
  "$si\autorunsc.exe", "$si\strings64.exe", "$si\handle64.exe", "$si\procdump64.exe", "$si\sigcheck.exe")
foreach ($t in "AmcacheParser","AppCompatCacheParser","EvtxECmd","JLECmd","LECmd","MFTECmd","PECmd",
               "RBCmd","RECmd","SBECmd","SQLECmd","SrumECmd","WxTCmd","bstrings") {
  $f = Get-ChildItem $ez -Recurse -Filter "$t.exe" | Select-Object -First 1
  if (-not $f) { throw "missing $t.exe under $ez" }
}
$missing = $expect | Where-Object { -not (Test-Path $_) }
if ($missing) { throw "missing after install: $($missing -join ', ')" }
$rt = Invoke-Text { & "C:\Program Files\dotnet\dotnet.exe" --list-runtimes }
Note "  dotnet --list-runtimes: $rt"
$evtx = (Get-ChildItem $ez -Recurse -Filter "EvtxECmd.exe" | Select-Object -First 1).FullName
$ver = Invoke-Text { & $evtx --version }
Note "  EvtxECmd --version: $ver"

Remove-Item -Recurse -Force $Dl
$Rec = "C:\ProgramData\valhuntir\versions"
New-Item -ItemType Directory -Force -Path $Rec | Out-Null
(@("installed_at=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))") + $Record) |
  Set-Content -Encoding ASCII (Join-Path $Rec "windows-tools.txt")
Get-Content (Join-Path $Rec "windows-tools.txt")
Write-Output "install-windows-tools.ps1 complete"
