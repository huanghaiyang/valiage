# ============================================================================
# 风摆验证 · 视觉截图运行器（**非 headless**：dummy 渲染器截不到图）
# ============================================================================
# 用法：
#   pwsh -File tests/wind/run_gui.ps1
#   pwsh -File tests/wind/run_gui.ps1 -TimeoutSec 240
# 注意：连续启动两个窗口化 Godot 进程偶发 exit 1；本脚本启动前会先清残留进程并 sleep 3s。
# ============================================================================
param(
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"
$Godot = "D:\godot\Godot_v4.7.2-stable_win64_console.exe"
$Project = "D:\sgames\CozyVale"
$Rt = Join-Path $Project ".runtime\wind_port"
New-Item -ItemType Directory -Force -Path $Rt | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Rt "shots") | Out-Null
$out = Join-Path $Rt "visual_out.txt"
$err = Join-Path $Rt "visual_err.txt"

Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$p = Start-Process -FilePath $Godot `
    -ArgumentList '--path', $Project, 'res://tests/wind/wind_visual.tscn', '--quit-after', '1200' `
    -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
$done = $p.WaitForExit($TimeoutSec * 1000)
if (-not $done) {
    try { $p.Kill() } catch {}
    Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[visual] TIMEOUT after ${TimeoutSec}s — killed"
} else {
    Write-Host "[visual] exited code=$($p.ExitCode)"
    Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
}
Write-Host "----- stdout -----"
Get-Content $out | Select-String -Pattern '\[visual\]|树冠剔除' | ForEach-Object { $_.Line }
$errs = Select-String -Path $err -Pattern 'SCRIPT ERROR|Parse Error' -ErrorAction SilentlyContinue
if ($errs) {
    Write-Host "----- stderr: script errors -----"
    $errs | Select-Object -First 20 | ForEach-Object { $_.Line }
}
Write-Host "----- shots -----"
Get-ChildItem (Join-Path $Rt "shots") -Filter 't0*.png' | Select-Object Name, Length
