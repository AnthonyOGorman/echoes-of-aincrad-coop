# Post a key press (down + up) to a game window without focusing it.  sendkey.ps1 -ProcId <pid> [-Key Enter]
param([int]$ProcId, [string]$Key = "Enter")
Add-Type @'
using System; using System.Runtime.InteropServices;
public class KeyPost { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); }
'@
$Keys = @{ Enter = @(0x0D, 0x1C); Escape = @(0x1B, 0x01); Space = @(0x20, 0x39); V = @(0x56, 0x2F); S = @(0x53, 0x1F); W = @(0x57, 0x11) }
$VK, $Scan = $Keys[$Key]
$H = (Get-Process -Id $ProcId).MainWindowHandle
[KeyPost]::PostMessage($H, 0x100, [IntPtr]$VK, [IntPtr](1 -bor ($Scan -shl 16))) | Out-Null
Start-Sleep -Milliseconds 80
[KeyPost]::PostMessage($H, 0x101, [IntPtr]$VK, [IntPtr]([int64]0xC0000001 -bor ($Scan -shl 16))) | Out-Null
"posted $Key to pid $ProcId"
