# ============================================================================
# 风摆验证 · headless 运行器（Windows / PowerShell）
# ============================================================================
# 只做三件事：拉起 --headless Godot、把 stdout/stderr 落到 .runtime/wind_port/、
# 超时就杀掉（本项目有 autoload 会常驻，脚本里若抛错而未 quit() 会一直挂住）。
#
# 用法：
#   pwsh -File tests/wind/run_headless.ps1 -Script res://tests/wind/test_wind_motion.gd
#   pwsh -File tests/wind/run_headless.ps1 -Script res://tests/wind/test_baked_attrs.gd -TimeoutSec 600
# ============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [int]$TimeoutSec = 300,
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
$Godot = "D:\godot\Godot_v4.7.2-stable_win64_console.exe"
$Project = "D:\sgames\CozyVale"
$Rt = Join-Path $Project ".runtime\wind_port"
New-Item -ItemType Directory -Force -Path $Rt | Out-Null
if (-not $Tag) { $Tag = [IO.Path]::GetFileNameWithoutExtension($Script) }
$out = Join-Path $Rt ($Tag + "_out.txt")
$err = Join-Path $Rt ($Tag + "_err.txt")

# 清掉可能残留的上一轮进程（否则脚本文件被占用，编辑会 ReplaceFileW EIO）
Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

$p = Start-Process -FilePath $Godot `
    -ArgumentList '--headless', '--path', $Project, '--quit-after', '600', '--script', $Script `
    -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
$done = $p.WaitForExit($TimeoutSec * 1000)
if (-not $done) {
    try { $p.Kill() } catch {}
    Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[run] TIMEOUT after ${TimeoutSec}s — killed. See $out"
} else {
    Write-Host "[run] exited code=$($p.ExitCode)"
    Get-Process | Where-Object { $_.ProcessName -match 'Godot' } | Stop-Process -Force -ErrorAction SilentlyContinue
}
Write-Host "----- stdout ($out) -----"
Get-Content $out
$errs = Select-String -Path $err -Pattern 'SCRIPT ERROR|Parse Error|ERROR:' -SimpleMatch:$false -ErrorAction SilentlyContinue
if ($errs) {
    Write-Host "----- stderr: script/engine errors -----"
    $errs | Select-Object -First 40 | ForEach-Object { $_.Line }
}
