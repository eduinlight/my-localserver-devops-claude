# One-time console bootstrap for the Windows GitHub Actions runner (VM 125).
#
# Run this ONCE from the Proxmox noVNC console, in an *Administrator* PowerShell:
#
#     irm http://192.168.0.15:8000/bootstrap.ps1 | iex
#
# It enables OpenSSH server and installs the dev box key so the rest of the
# provisioning can be driven remotely over SSH. Nothing here is runner-specific.

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an Administrator PowerShell.'
}

Write-Host '==> Installing OpenSSH server' -ForegroundColor Cyan
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null

Write-Host '==> Starting sshd' -ForegroundColor Cyan
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

Write-Host '==> Opening firewall port 22' -ForegroundColor Cyan
if (-not (Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# Administrator accounts authenticate against this file, NOT ~/.ssh/authorized_keys.
Write-Host '==> Installing dev box public key' -ForegroundColor Cyan
$key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOkBDDFEMvYsDU3wNzVfCjYdvvOdLoy8wnZD5nsM7rQ light@light-pc'
$authKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path $authKeys) -or -not (Select-String -Path $authKeys -SimpleMatch $key -Quiet)) {
  Add-Content -Path $authKeys -Value $key
}
icacls $authKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

Write-Host '==> Setting PowerShell as the default SSH shell' -ForegroundColor Cyan
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force | Out-Null

Restart-Service sshd

Write-Host ''
Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host "Reachable at: $(whoami)@$((Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -like '192.168.*' }).IPAddress)" -ForegroundColor Green
