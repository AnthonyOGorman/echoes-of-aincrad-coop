# Screenshot of a game window (by process id) to a PNG, scaled to -Width.  snap.ps1 -ProcId <pid> -Out <png>
param([int]$ProcId, [string]$Out, [int]$Width = 960)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public class Snap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@
[Snap]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null
$H = (Get-Process -Id $ProcId).MainWindowHandle
$R = New-Object Snap+RECT
[Snap]::GetWindowRect($H, [ref]$R) | Out-Null
$W, $Ht = ($R.R - $R.L), ($R.B - $R.T)
$Bmp = New-Object System.Drawing.Bitmap $W, $Ht
$G = [System.Drawing.Graphics]::FromImage($Bmp)
$G.CopyFromScreen($R.L, $R.T, 0, 0, $Bmp.Size)
$Scale = [Math]::Min(1.0, $Width / $W)
$Small = New-Object System.Drawing.Bitmap ([int]($W * $Scale)), ([int]($Ht * $Scale))
$G2 = [System.Drawing.Graphics]::FromImage($Small)
$G2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$G2.DrawImage($Bmp, 0, 0, $Small.Width, $Small.Height)
$Small.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out ($($Small.Width)x$($Small.Height))"
