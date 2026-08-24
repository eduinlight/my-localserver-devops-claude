# Register VM 125 as an organization-level GitHub Actions runner.
#
#     ssh <user>@192.168.0.244 "powershell -ExecutionPolicy Bypass -File C:\register.ps1 -Token <TOKEN>"
#
# Get the token from: github.com/organizations/eduinlight-org/settings/actions/runners
#   -> New runner -> Windows.  Registration tokens expire ~1 hour after issue.
#
# `self-hosted`, `Windows` and `X64` are applied by GitHub automatically; only
# `homelab` needs to be requested here.

param(
  [Parameter(Mandatory)] [string] $Token,
  [string] $Url      = 'https://github.com/eduinlight-org',
  [string] $Name     = 'gh-runner-windows',
  [string] $Labels   = 'homelab',
  [string] $Version  = '2.336.0',          # matches the Linux runner on LXC 124
  [string] $Dir      = 'C:\actions-runner',
  # Runs as LocalSystem by default. The interactive account on this box is a
  # Microsoft account, which cannot be used as a Windows service logon, so the
  # toolchain is installed MACHINE-WIDE (see provision.ps1) and the service uses
  # LocalSystem — no password needed. To bind to a real *local* account instead,
  # pass -RunAsUser 'HOST\user' -RunAsPassword '...'.
  [string] $RunAsUser     = 'NT AUTHORITY\SYSTEM',
  [string] $RunAsPassword
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
Set-Location $Dir

if (-not (Test-Path (Join-Path $Dir 'config.cmd'))) {
  $zip = "actions-runner-win-x64-$Version.zip"
  Write-Host "==> Downloading runner $Version" -ForegroundColor Cyan
  Invoke-WebRequest -UseBasicParsing `
    -Uri "https://github.com/actions/runner/releases/download/v$Version/$zip" `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $Dir -Force
  Remove-Item $zip -Force
}

Write-Host "==> Configuring runner as a service (account: $RunAsUser)" -ForegroundColor Cyan
# config.cmd will not reconfigure an already-configured runner even with
# --replace; it must be removed first. Remove local state if present.
if (Test-Path (Join-Path $Dir '.runner')) {
  Write-Host '==> Removing existing runner config' -ForegroundColor Cyan
  & "$Dir\config.cmd" remove --token $Token
}

$svcArgs = @(
  '--unattended', '--replace',
  '--url', $Url, '--token', $Token, '--name', $Name, '--labels', $Labels,
  '--work', '_work', '--runasservice',
  '--windowslogonaccount', $RunAsUser
)
# LocalSystem / NETWORK SERVICE take no password; a real account needs one.
if ($RunAsPassword) { $svcArgs += @('--windowslogonpassword', $RunAsPassword) }
& "$Dir\config.cmd" @svcArgs

Write-Host '==> Service state' -ForegroundColor Cyan
Get-Service 'actions.runner.*' | Format-Table Name, Status, StartType -AutoSize
