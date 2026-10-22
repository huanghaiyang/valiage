# fast-tree GLB → Godot 资产 · 一条命令
#
#   .\tools\import_fasttree.ps1 -Glb "assets/models/树/大樱花树.glb"
#   .\tools\import_fasttree.ps1 -Glb "res://assets/models/树/大樱花树.glb" -Name BigSakura -Collision convex -Force
#
# 它做的事（对应 tools/fasttree_import.gd）：
#   1) 解析 GLB 二进制里的 _AWIND/_APHASE/_AORIGIN（Godot 导入器会丢掉它们）
#   2) 烘成 ArrayMesh 的 CUSTOM0/CUSTOM1 → assets/models/树/<名字>/wind/<节点>.res
#   3) 用 GLB 的贴图引用建树着色器材质 → scenes/树/<名字>/_ft_mat_{bark,leaves,flowers}.tres
#   4) 生成可直接拖进场景的 tscn → scenes/树/<名字>/<名字>.tscn（含树冠分块剔除；可选碰撞）
#
# 前置：GLB 必须已被 Godot 导入过（打开过编辑器，或跑过 `--headless --import`）。

param(
    [Parameter(Mandatory = $true)][string]$Glb,
    [string]$Name = "",
    [string]$ResDir = "",
    [string]$SceneDir = "",
    [ValidateSet("none", "convex", "trimesh")][string]$Collision = "none",
    [switch]$Force,
    [switch]$DryRun,
    [string]$Godot = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

# ---- 1) 找 Godot ----
if ($Godot -eq "") {
    $candidates = @(
        "D:\godot\Godot_v4.7.2-stable_win64_console.exe",
        "D:\godot\Godot_v4.7.2-stable_win64.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $Godot = $c; break }
    }
    if ($Godot -eq "") {
        $cmd = Get-Command "godot*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $Godot = $cmd.Source }
    }
}
if ($Godot -eq "" -or -not (Test-Path $Godot)) {
    throw "找不到 Godot。用 -Godot 'D:\path\to\Godot_console.exe' 指定。"
}

# ---- 2) GLB 路径 → res:// ----
$glbArg = $Glb
if ($Glb -notlike "res://*") {
    $full = $Glb
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        $full = Join-Path (Get-Location) $Glb
    }
    $full = (Resolve-Path $full).Path
    $root = (Resolve-Path $projectRoot).Path.TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "GLB 不在项目目录里（Godot 里必须是 res:// 路径）：$full"
    }
    $glbArg = "res://" + ($full.Substring($root.Length) -replace '\\', '/')
}

# ---- 3) 组参数 ----
$godotArgs = @(
    "--headless", "--path", $projectRoot,
    "--script", "res://tools/fasttree_import.gd", "--",
    "--glb=$glbArg",
    "--collision=$Collision"
)
if ($Name -ne "") { $godotArgs += "--name=$Name" }
if ($ResDir -ne "") { $godotArgs += "--res-dir=$ResDir" }
if ($SceneDir -ne "") { $godotArgs += "--scene-dir=$SceneDir" }
if ($Force) { $godotArgs += "--force" }
if ($DryRun) { $godotArgs += "--dry-run" }

Write-Host ">> $Godot $($godotArgs -join ' ')" -ForegroundColor DarkGray
& $Godot @godotArgs
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host "!! 退出码 $code（看上面的 [ft] 日志）" -ForegroundColor Red
    exit $code
}
Write-Host "完成。产物在 assets/models/树/<名字>/wind 与 scenes/树/<名字>/" -ForegroundColor Green

