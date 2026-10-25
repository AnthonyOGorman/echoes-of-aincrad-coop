# Start only copy 1 (the host, normal save folder) and move its window to the left half once it is windowed.
$Bin = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")).Path   # Win64 (this file: Win64\ue4ss\Mods\NetDebug\tools\dev)
$Exe = Join-Path $Bin "EchoesofAincrad-Win64-Shipping.exe"

Add-Type @'
using System; using System.Runtime.InteropServices;
public class CoopWin1 {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
}
'@
[CoopWin1]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null
$P2 = Start-Process -FilePath $Exe -WorkingDirectory $Bin -PassThru
Write-Host "Started copy 1 (pid $($P2.Id))"
$Deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2
    $P = Get-Process -Id $P2.Id -ErrorAction SilentlyContinue
    if (-not $P) { Write-Host "copy 1 exited"; break }
    if ($P.MainWindowHandle -eq 0) { continue }
    if (([CoopWin1]::GetWindowLong($P.MainWindowHandle, -16) -band 0x00C00000) -eq 0) { continue }
    [CoopWin1]::SetWindowPos($P.MainWindowHandle, [IntPtr]::Zero, -8, 0, 0, 0, 0x15) | Out-Null
    Write-Host "Placed copy 1 window at x=-8"
    break
}
