# capwin.ps1 -out <dir> [-count N] [-every s] [-wait s]: PrintWindow captures of the dev5 game windows A, B and C
# (found by their --coop-dev-name), every few seconds, as layout evidence. Works on background windows. Used by
# tools/m5_final.py; the machine check is gate_m5.py gate 2, these images are for the PR.
param([string]$out, [int]$count = 16, [int]$every = 8, [int]$wait = 30)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W7 { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
 public struct RECT { public int L, T, R, B; } }
"@
New-Item -ItemType Directory -Force $out | Out-Null
Start-Sleep -Seconds $wait
for ($n = 0; $n -lt $count; $n++) {
  foreach ($p in Get-CimInstance Win32_Process -Filter "Name='Delta-V.exe'") {
    $tag = $null
    foreach ($t in "A", "B", "C") { if ($p.CommandLine -like "*--coop-dev-name=$t*") { $tag = $t } }
    if ($tag -eq $null) { continue }
    $h = (Get-Process -Id $p.ProcessId).MainWindowHandle; if ($h -eq 0) { continue }
    $r = New-Object W7+RECT; [W7]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    if ($w -le 0 -or $hh -le 0) { continue }
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
    [W7]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
    $f = Join-Path $out ("{0}-{1:D2}.png" -f $tag, $n); $bmp.Save($f); $g.Dispose(); $bmp.Dispose()
  }
  Start-Sleep -Seconds $every
}
"done"
