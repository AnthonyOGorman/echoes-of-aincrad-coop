# Two-PC LAN co-op: run this on each PC, giving the OTHER PC's address.
#   launch_lan.bat 192.168.1.20
# Starts the UDP link helper (listening on the LAN, port 47777; Windows Firewall asks once - allow on
# Private networks) and the game. The mod must be in link mode (coop_transport.txt = link).
param([Parameter(Mandatory = $true)][string]$PeerIp, [int]$Port = 47777)
$ErrorActionPreference = "Stop"
$Bin = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$Exe = Join-Path $Bin "EchoesofAincrad-Win64-Shipping.exe"
$Link = Join-Path $PSScriptRoot "coop_link.py"

Set-Content -Path (Join-Path $PSScriptRoot "coop_transport.txt") -Value "link"
# this PC's role: coop_role.txt ("A" host / "B" guest, the mod reads it too), else A
$Me = "A"
$RoleFile = Join-Path $PSScriptRoot "coop_role.txt"
if (Test-Path $RoleFile) { $R = (Get-Content $RoleFile -TotalCount 1).Trim(); if ($R -in "A", "B") { $Me = $R } }
Start-Process -FilePath "python" -ArgumentList "-u `"$Link`" --me $Me --bind 0.0.0.0 --port $Port --peer ${PeerIp}:$Port"
Start-Process -FilePath $Exe -WorkingDirectory $Bin
Write-Host "Started the link as $Me (udp $Port -> ${PeerIp}:$Port) and the game."
