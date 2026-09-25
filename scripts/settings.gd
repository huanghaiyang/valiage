extends Node
## 全局设置管理（自动加载单例）
## 管理渲染质量等级与性能选项，支持 NVIDIA/AMD 全系显卡

enum Quality { LOW, MEDIUM, HIGH, ULTRA }

const QUALITY_NAMES := {
	Quality.LOW: "低画质（兼容模式）",
	Quality.MEDIUM: "中画质",
	Quality.HIGH: "高画质",
	Quality.ULTRA: "极致画质",
}

## 当前质量等级
var quality: int = Quality.HIGH:
	set(v):
		quality = clamp(v, Quality.LOW, Quality.ULTRA)
		apply_quality()

## 是否显示草丛细节
var show_grass := true

## 是否启用体积雾（高配专属）
var volumetric_fog := false

## 植被绘制距离
var vegetation_distance := 120.0

## 是否显示网格辅助线
var show_grid := false

## 是否启用动态天空
var dynamic_sky := true

## 场景引用（由 main 注入）
var world_environment: WorldEnvironment = null
var vegetation_root: Node3D = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 从命令行参数读取质量等级（用于导出版本切换）
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			var q := arg.trim_prefix("--quality=").to_int()
			quality = q

func apply_quality() -> void:
	# 将质量设置同步到渲染器
	var vp := get_viewport()
	match quality:
		Quality.LOW:
			if vp: vp.msaa_3d = Viewport.MSAA_DISABLED
			show_grass = false
			vegetation_distance = 130.0
			volumetric_fog = false
		Quality.MEDIUM:
			if vp: vp.msaa_3d = Viewport.MSAA_2X
			show_grass = true
			vegetation_distance = 170.0
			volumetric_fog = false
		Quality.HIGH:
			if vp: vp.msaa_3d = Viewport.MSAA_4X
			show_grass = true
			vegetation_distance = 220.0
			volumetric_fog = true
		Quality.ULTRA:
			if vp: vp.msaa_3d = Viewport.MSAA_8X
			show_grass = true
			vegetation_distance = 280.0
			volumetric_fog = true
	_update_scene_settings()

func _update_scene_settings() -> void:
	if is_instance_valid(world_environment):
		var env: Environment = world_environment.environment
		if env:
			env.volumetric_fog_enabled = volumetric_fog
			env.fog_density = 0.004 if volumetric_fog else 0.0
	if is_instance_valid(vegetation_root):
		var veg := vegetation_root as VegetationSystem
		if veg != null:
			veg.view_radius = vegetation_distance
			veg.set_grass_visible(show_grass)
