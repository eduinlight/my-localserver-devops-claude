# Provision the Windows GitHub Actions runner host (VM 125) with everything the
# lightchat macOS/Windows workflows need. Idempotent — safe to re-run.
#
# Run over SSH from the dev box once bootstrap.ps1 has been applied:
#
#     ssh <user>@192.168.0.244 "powershell -ExecutionPolicy Bypass -File C:\provision.ps1"
#
# Does NOT register the runner — see register.ps1 for that.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is glacial without this

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# winget is unreliable over SSH (no loaded user profile), so each install falls
# back to a direct download. Prefer the fallback when running headless.
function Install-ByWinget($id) {
  try {
    winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
  } catch { return $false }
}

# NB: do not name the last parameter $args — it collides with PowerShell's
# automatic $args variable and binds null.
# For .msi files, invoke msiexec explicitly — running the .msi directly does not
# reliably pass properties like /quiet or ADD_PATH.
function Install-FromUrl($url, $file, $argList) {
  $out = Join-Path $env:TEMP $file
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
  if ($out -match '\.msi$') {
    $msiArgs = @('/i', $out) + ($argList -split '\s+' | Where-Object { $_ })
    Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -NoNewWindow
  } else {
    Start-Process -FilePath $out -ArgumentList $argList -Wait -NoNewWindow
  }
  Remove-Item $out -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- power state
Step 'Disabling sleep and hibernation'
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off

# ------------------------------------------------------------------ long paths
# Rust target dirs nest past MAX_PATH; without this, builds fail on deep crates.
Step 'Enabling long path support'
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force | Out-Null

# ------------------------------------------------------------------------ git
Step 'Installing Git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  if (-not (Install-ByWinget 'Git.Git')) {
    Install-FromUrl 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' `
      'git-setup.exe' '/VERYSILENT /NORESTART /NOCANCEL /SP-'
  }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
git config --system core.longpaths true

# Git's installer adds cmd\ (git.exe) to PATH but NOT bin\ (bash.exe). The runner
# service runs as LocalSystem, and dtolnay/rust-toolchain@stable bootstraps through
# bash — without bin\ on the MACHINE PATH, "Install Rust" fails with
# "bash: command not found". This is the #1 self-hosted Windows gotcha.
$gitBin = 'C:\Program Files\Git\bin'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ((Test-Path $gitBin) -and $machinePath -notlike "*$gitBin*") {
  [Environment]::SetEnvironmentVariable('Path', "$machinePath;$gitBin", 'Machine')
  $env:Path += ";$gitBin"
}

# --------------------------------------------------------------- PowerShell 7
# release-desktop-windows.yml runs its bundle step with `shell: pwsh`.
# Windows ships only PowerShell 5.1 as `powershell` — pwsh does not exist yet.
#
# Install via MSI (machine-wide), NOT winget. Winget's PowerShell package is an
# MSIX that lands in %USERPROFILE%\...\WindowsApps — invisible to the LocalSystem
# runner service, so the bundle step would fail with "pwsh not found". The MSI
# installs to C:\Program Files\PowerShell\7 and adds it to the machine PATH.
Step 'Installing PowerShell 7 (machine-wide MSI)'
if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) {
  Install-FromUrl 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/PowerShell-7.6.5-win-x64.msi' `
    'pwsh.msi' '/quiet /norestart ADD_PATH=1'
}
$pwshDir = 'C:\Program Files\PowerShell\7'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$pwshDir*") {
  [Environment]::SetEnvironmentVariable('Path', "$machinePath;$pwshDir", 'Machine')
  $env:Path += ";$pwshDir"
}

# ------------------------------------------------- Visual Studio Build Tools
# Supplies the MSVC toolchain (link.exe) for x86_64-pc-windows-msvc, the Windows
# SDK, and signtool.exe. This is the long one — 20-40 minutes is normal.
Step 'Installing Visual Studio 2022 Build Tools (VCTools) — this takes a while'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVc = (Test-Path $vswhere) -and
         (& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $hasVc) {
  Install-FromUrl 'https://aka.ms/vs/17/release/vs_BuildTools.exe' 'vs_BuildTools.exe' `
    '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
}

# ---------------------------------------------------------------------- rustup
# dtolnay/rust-toolchain@stable calls `rustup toolchain install`; it does not
# bootstrap rustup itself.
#
# IMPORTANT: install Rust MACHINE-WIDE under C:\rust, not per-user. The runner
# service runs as LocalSystem (see register.ps1 — the interactive account here is
# a Microsoft account that cannot be a service logon), and a per-user
# %USERPROFILE%\.cargo install would be invisible to it. CARGO_HOME/RUSTUP_HOME
# are set at Machine scope so every account — LocalSystem included — resolves the
# same toolchain, and Swatinem/rust-cache + `cargo install dx` land in one place.
Step 'Installing rustup + stable toolchain (machine-wide, C:\rust)'
[Environment]::SetEnvironmentVariable('RUSTUP_HOME', 'C:\rust\rustup', 'Machine')
[Environment]::SetEnvironmentVariable('CARGO_HOME',  'C:\rust\cargo',  'Machine')
$env:RUSTUP_HOME = 'C:\rust\rustup'; $env:CARGO_HOME = 'C:\rust\cargo'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike '*C:\rust\cargo\bin*') {
  [Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\rust\cargo\bin", 'Machine')
}
$env:Path = "C:\rust\cargo\bin;$env:Path"
if (-not (Test-Path 'C:\rust\cargo\bin\rustup.exe')) {
  Install-FromUrl 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' `
    'rustup-init.exe' '-y --default-toolchain stable --profile minimal --no-modify-path'
}
& 'C:\rust\cargo\bin\rustup.exe' toolchain install stable
& 'C:\rust\cargo\bin\rustup.exe' target add x86_64-pc-windows-msvc

# ----------------------------------------------------------------------- NASM
# ilammy/setup-nasm@v1 downloads it per run; a permanent install removes that
# network dependency from every build.
Step 'Installing NASM'
# winget's NASM package fails in a non-interactive/scheduled-task context, so go
# straight to the upstream zip — it is just an extract + PATH entry.
if (-not (Get-Command nasm -ErrorAction SilentlyContinue) -and -not (Test-Path 'C:\nasm\nasm.exe')) {
  $ver = '2.16.03'
  $zip = Join-Path $env:TEMP 'nasm.zip'
  Invoke-WebRequest -UseBasicParsing `
    -Uri "https://www.nasm.us/pub/nasm/releasebuilds/$ver/win64/nasm-$ver-win64.zip" -OutFile $zip
  if (Test-Path 'C:\nasm') { Remove-Item 'C:\nasm' -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath 'C:\' -Force
  Rename-Item "C:\nasm-$ver" 'C:\nasm'
  Remove-Item $zip -Force
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  if ($machinePath -notlike '*C:\nasm*') {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\nasm", 'Machine')
  }
  $env:Path += ';C:\nasm'
}

# ----------------------------------------------------------------------- Perl
# The vendored OpenSSL build (openssl-sys, pulled via the dependency tree) runs
# its Configure script through perl. windows-latest ships Strawberry Perl; a bare
# box has none, so `cargo check` fails building openssl-sys. The MSI installs to
# C:\Strawberry and adds perl/bin, c/bin, perl/site/bin to the machine PATH.
Step 'Installing Strawberry Perl (machine-wide MSI)'
if (-not (Test-Path 'C:\Strawberry\perl\bin\perl.exe')) {
  # Resolve the latest asset from GitHub (URL/version changes per release).
  $rel = Invoke-RestMethod -UseBasicParsing `
    -Uri 'https://api.github.com/repos/StrawberryPerl/Perl-Dist-Strawberry/releases/latest'
  $asset = $rel.assets | Where-Object { $_.name -match '^strawberry-perl-.*-64bit\.msi$' } | Select-Object -First 1
  Install-FromUrl $asset.browser_download_url 'strawberry.msi' '/quiet /norestart'
}
$perlDirs = @('C:\Strawberry\c\bin', 'C:\Strawberry\perl\site\bin', 'C:\Strawberry\perl\bin')
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike '*Strawberry\perl\bin*') {
  [Environment]::SetEnvironmentVariable('Path', ($machinePath + ';' + ($perlDirs -join ';')), 'Machine')
  $env:Path += ';' + ($perlDirs -join ';')
}

# ----------------------------------------------------------- .NET Framework 3.5
# The release bundle uses WiX; its candle.exe is a .NET 3.5 app and won't start
# without NetFx3. On Win11 the payload is "DisabledWithPayloadRemoved", so it must
# be fetched from Windows Update (or an install-media \sources\sxs source).
#
# DISM requires a HIGH-integrity token. A plain SSH admin session is medium
# integrity, so DISM returns "Access is denied" (Error 5) — run it via a SYSTEM
# scheduled task, which has full privileges. (This is the same reason the runner
# service is installed as SYSTEM.)
Step 'Enabling .NET Framework 3.5 (NetFx3)'
if ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3).State -ne 'Enabled') {
  @'
@echo off
DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /Quiet /NoRestart > C:\netfx3.log 2>&1
'@ | Set-Content C:\netfx3.cmd -Encoding ASCII
  schtasks /Create /TN netfx3 /TR 'C:\netfx3.cmd' /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F | Out-Null
  schtasks /Run /TN netfx3 | Out-Null
  # DISM pulls from Windows Update — can take several minutes. Wait for Ready.
  do { Start-Sleep 15 } while ((schtasks /Query /TN netfx3 /FO LIST | Select-String 'Status:\s+Running'))
  schtasks /Delete /TN netfx3 /F | Out-Null
  Remove-Item C:\netfx3.cmd, C:\netfx3.log -Force -ErrorAction SilentlyContinue
  # If WU is blocked (0x800f0906/081f), attach the Win11 ISO and add
  #   /LimitAccess /Source:<CD>\sources\sxs to the DISM line above.
}
"NetFx3: $((Get-WindowsOptionalFeature -Online -FeatureName NetFx3).State)"

# ------------------------------------------------------- Defender exclusions
# Large build-time win — Defender scanning cargo target dirs dominates runtime.
Step 'Adding Defender exclusions'
# CARGO_HOME is machine-wide (C:\rust\cargo); ~/.dx for the LocalSystem service is
# under its systemprofile. Exclude the work tree and both.
foreach ($p in @('C:\actions-runner\_work', 'C:\rust\cargo',
                 "$env:SystemRoot\System32\config\systemprofile\.dx")) {
  Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------- report
Step 'Versions (checked at their machine-wide paths, as LocalSystem would resolve them)'
$checks = @(
  'C:\Program Files\Git\cmd\git.exe',
  'C:\Program Files\Git\bin\bash.exe',
  'C:\Program Files\PowerShell\7\pwsh.exe',
  'C:\rust\cargo\bin\rustc.exe',
  'C:\rust\cargo\bin\cargo.exe',
  'C:\nasm\nasm.exe',
  'C:\Strawberry\perl\bin\perl.exe'
)
foreach ($c in $checks) {
  $v = try { (& $c --version 2>&1 | Select-Object -First 1) } catch { 'NOT FOUND' }
  '{0,-8} {1}' -f (Split-Path $c -Leaf), $v
}
if (Test-Path $vswhere) {
  '{0,-8} {1}' -f 'msvc', (& $vswhere -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion)
}

Write-Host "`nProvisioning complete. Reboot recommended before registering the runner." -ForegroundColor Green
