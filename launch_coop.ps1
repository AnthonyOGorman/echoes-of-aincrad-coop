# Launch two copies of Echoes of Aincrad for co-op testing and tile them side by side.
# Copy 1 uses the normal save folder; copy 2 uses %LOCALAPPDATA%\EchoesofAincrad_P2 so saves don't collide.
# NetDebug switches each copy to a 1280x720 window ~15 s after it starts (see autoexec.txt).
$ErrorActionPreference = "Stop"
$Bin = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$Exe = Join-Path $Bin "EchoesofAincrad-Win64-Shipping.exe"
$UserDir2 = Join-Path $env:LOCALAPPDATA "EchoesofAincrad_P2"
New-Item -ItemType Directory -Force $UserDir2 | Out-Null

Add-Type @'
using System; using System.Runtime.InteropServices;
public class CoopWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
}
'@
[CoopWin]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

# coop_transport.txt = link: start one UDP link helper per copy (loopback, so no firewall prompt).
$Transport = Get-Content (Join-Path $PSScriptRoot "coop_transport.txt") -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Transport -and $Transport.Trim() -eq "link") {
    $Link = Join-Path $PSScriptRoot "coop_link.py"
    foreach ($L in @(@{ Me = "A"; Port = 47777; Peer = "127.0.0.1:47778" }, @{ Me = "B"; Port = 47778; Peer = "127.0.0.1:47777" })) {
        Start-Process -FilePath "python" -ArgumentList "-u `"$Link`" --me $($L.Me) --bind 127.0.0.1 --port $($L.Port) --peer $($L.Peer)" -WindowStyle Minimized
    }
    Write-Host "Started link helpers A (47777) and B (47778)."
}

$Copy1 = Start-Process -FilePath $Exe -WorkingDirectory $Bin -PassThru
Start-Sleep -Seconds 6
$Copy2 = Start-Process -FilePath $Exe -WorkingDirectory $Bin -ArgumentList "-userdir=`"$UserDir2`"" -PassThru
Write-Host "Started copy 1 (pid $($Copy1.Id)) and copy 2 (pid $($Copy2.Id)). Waiting for windowed mode..."

$WS_CAPTION = 0x00C00000
$Placed = @{}
$Deadline = (Get-Date).AddMinutes(5)
while ($Placed.Count -lt 2 -and (Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2
    foreach ($Entry in @(@{ P = $Copy1; X = -8 }, @{ P = $Copy2; X = 1272 })) {
        $P = Get-Process -Id $Entry.P.Id -ErrorAction SilentlyContinue
        if (-not $P -or $Placed.ContainsKey($P.Id) -or $P.MainWindowHandle -eq 0) { continue }
        if (([CoopWin]::GetWindowLong($P.MainWindowHandle, -16) -band $WS_CAPTION) -eq 0) { continue }
        # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        [CoopWin]::SetWindowPos($P.MainWindowHandle, [IntPtr]::Zero, $Entry.X, 0, 0, 0, 0x15) | Out-Null
        $Placed[$P.Id] = $true
        Write-Host "Placed pid $($P.Id) at x=$($Entry.X)"
    }
}
if ($Placed.Count -lt 2) { Write-Host "Not every window switched to windowed mode within 5 minutes." }
