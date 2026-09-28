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

## ---- 模型精度（自动 LOD 阈值）----
## 越大 = 越早切到模型的**低精度 LOD 版本**（省 GPU）；越小 = 越精细。
## 引擎在**导入模型时**就生成好了 LOD 层级（导入设置 meshes/generate_lods，默认开），
## 所以"改精度"是**运行时切换**，不需要把高模拿去抽面成低模 ——
## 例如 1.8M 面的水晶树，近距离用 LOD0，中远距离自动降级。
## 0 = 关闭自动 LOD（永远最高精度，最费）。1.0 是引擎默认值。
var mesh_lod_threshold := 1.0:
	set(v):
		mesh_lod_threshold = maxf(0.0, float(v))
		_apply_mesh_lod()

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
	# 初始值不会走 setter，所以这里显式把"模型精度"写进视口
	_apply_mesh_lod()

func apply_quality() -> void:
	# 将质量设置同步到渲染器
	var vp := get_viewport()
	match quality:
		Quality.LOW:
			if vp: vp.msaa_3d = Viewport.MSAA_DISABLED
			mesh_lod_threshold = 4.0
			show_grass = false
			vegetation_distance = 130.0
			volumetric_fog = false
		Quality.MEDIUM:
			if vp: vp.msaa_3d = Viewport.MSAA_2X
			mesh_lod_threshold = 2.0
			show_grass = true
			vegetation_distance = 170.0
			volumetric_fog = false
		Quality.HIGH:
			if vp: vp.msaa_3d = Viewport.MSAA_4X
			mesh_lod_threshold = 1.0
			show_grass = true
			vegetation_distance = 220.0
			volumetric_fog = true
		Quality.ULTRA:
			if vp: vp.msaa_3d = Viewport.MSAA_8X
			mesh_lod_threshold = 0.5
			show_grass = true
			vegetation_distance = 280.0
			volumetric_fog = true
	_update_scene_settings()


## 把"模型精度"写进视口。Viewport.mesh_lod_threshold 就是引擎的自动 LOD 阈值，
## 等价于项目设置 rendering/mesh_lod/lod_change/threshold_pixels。
func _apply_mesh_lod() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.mesh_lod_threshold = mesh_lod_threshold

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
