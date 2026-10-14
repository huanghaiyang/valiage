@tool
class_name FogBeam
extends Node3D
## ============================================================================
## fog_beam.gd —— **穿过雾体的光束**（激光/探照灯/火光条），由迷雾体积着色器照亮
## ============================================================================
## 【它是什么】一个"数据节点"：只描述一条世界空间的光束（起点/终点/半径/颜色/强度），
##   由 FogField 收集后打包给体积雾着色器。着色器在步进时算"当前采样点到线段的距离"，
##   按 1/(1+(d/r)²) 累积散射 —— 于是光束在雾里呈现 **细亮核心 + 柔和光晕**，
##   雾浓处更亮、雾薄处更暗，而且被前景的烟遮挡时自然地"埋进雾里"。
##
## 【为什么不做成真正发光的几何体】几何体是"可见的面"，永远不会有随距离衰减的体积光晕，
##   近距离还会穿帮；而激光在真实雾里的样子几乎完全由**散射**决定（这正是参考画面的观感）。
##   需要实体亮线可以再挂一个薄的发光 MeshInstance3D 补上核心。
##
## 【用法】
##   1. 场景里加一个 FogBeam（或把节点类型改成它）；
##   2. 填 `length_m` / `radius_m` / `color` / `intensity`（起点 = 本节点位置，终点沿 -Z）；
##   3. 想改方向就旋转本节点；想让光束跟随某物就把它挂到那个物体下。
##   4. 编辑器里会画一段线框预览（@tool，不产生实际效果）。
##
## 【关键依赖】FogField 每帧读这些属性（名字固定）：
##   fog_beam_start / fog_beam_end / fog_beam_radius / fog_beam_color / fog_beam_intensity
##
## 【已知的坑】
##   1. 光束**不参与遮挡**：它不会因为中间有块石头就断掉。要断掉就得做体素阴影，
##      成本远高于当前收益；参考画面里激光本身也几乎不受遮挡。
##   2. 半径给太小（<0.3 米）时，如果 march_steps 不够，细光束会被步进采漏
##      （表现为闪烁的虚线）—— 细光束请把 march_steps 提到 10 以上。
##   3. 上限 4 束：FogField 的 uniform 数组就 4 个，超出的会被忽略。
## ============================================================================

## 光束长度（米，沿本节点的 -Z 方向）
@export_range(0.1, 400.0, 0.1) var length_m: float = 60.0
## 光束半径（米）：0.5~2 比较像激光在雾里的光晕
@export_range(0.02, 20.0, 0.02) var radius_m: float = 0.8
## 光束颜色
@export var color: Color = Color(1.0, 0.12, 0.06)
## 散射强度（雾被点亮的亮度）
@export_range(0.0, 8.0, 0.05) var intensity: float = 2.2
## 是否双向延长（探照灯/环境光条）
@export var bidirectional: bool = true
## 编辑器预览
@export var show_preview: bool = true
## ==================== 实体亮线（加法混合条带） ====================
## 体积散射给的是**光晕**（光把烟点亮），激光那条**线**必须由实体几何来画 ——
## 否则雾一薄、光束就散了。两者叠加才等于参考画面里的"红线穿过烟"。
## 0 = 只保留体积散射（不画线）。
@export_range(0.0, 8.0, 0.05) var glow_intensity: float = 2.5
## 视觉半宽相对 `radius_m` 的倍率：<1 更细更像激光（推荐 0.25~0.5），>1 更像泛光。
## 散射半径略大于视觉线宽，才有"线的外面裹着一层光晕"的层次。
@export_range(0.05, 8.0, 0.05) var glow_width_scale: float = 0.35
## 是否画实体亮线
@export var show_glow: bool = true

# FogField 读取的属性名（保持固定，不要在别处改）
var fog_beam_start: Vector3 = Vector3.ZERO
var fog_beam_end: Vector3 = Vector3.ZERO
var fog_beam_radius: float = 0.8
var fog_beam_color: Color = Color(1.0, 0.12, 0.06)
var fog_beam_intensity: float = 2.2

var _preview: MeshInstance3D
var _glow: MeshInstance3D
var _glow_material: ShaderMaterial

const GLOW_SHADER := "res://assets/shaders/fog_beam_glow.gdshader"


func _ready() -> void:
	add_to_group("fog_beam")
	_sync()


func _process(_delta: float) -> void:
	# ★ 每帧同步：光束位置会随父节点移动（挂在角色/武器上），不能只在 _ready 算一次
	_sync()
	if Engine.is_editor_hint() and show_preview:
		_refresh_preview()


func _sync() -> void:
	var origin := global_position
	var forward := -global_basis.z.normalized()
	var start := origin
	if bidirectional:
		start = origin - forward * length_m
	fog_beam_start = start
	fog_beam_end = origin + forward * length_m
	fog_beam_radius = radius_m
	fog_beam_color = color
	fog_beam_intensity = intensity
	_sync_glow()


## 实体亮线：加法混合条带。几何完全由着色器在**世界空间**构造
## （沿光束拉伸 + 绕光轴面向相机），所以这里把节点固定为单位变换。
## ★ 必须设 custom_aabb：引擎看不到着色器造出来的几何，不设会被视锥剔除
##   （表现：转个视角整条亮线突然消失）。
func _sync_glow() -> void:
	if not show_glow or glow_intensity <= 0.0:
		if is_instance_valid(_glow):
			_glow.visible = false
		return
	if not is_instance_valid(_glow):
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		_glow_material = ShaderMaterial.new()
		_glow_material.shader = load(GLOW_SHADER)
		_glow = MeshInstance3D.new()
		_glow.name = "FogBeamGlow"
		_glow.mesh = quad
		_glow.material_override = _glow_material
		_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_glow.top_level = true          # 不受本节点变换影响（着色器自己算世界坐标）
		add_child(_glow)
	_glow.visible = true
	_glow.global_transform = Transform3D.IDENTITY
	_glow_material.set_shader_parameter("beam_start", fog_beam_start)
	_glow_material.set_shader_parameter("beam_end", fog_beam_end)
	_glow_material.set_shader_parameter("beam_radius", radius_m)
	_glow_material.set_shader_parameter("beam_color", color)
	_glow_material.set_shader_parameter("beam_intensity", glow_intensity)
	_glow_material.set_shader_parameter("width_scale", glow_width_scale)
	var margin := Vector3.ONE * maxf(radius_m * maxf(glow_width_scale, 0.1), 0.5)
	var low := fog_beam_start.min(fog_beam_end) - margin
	var high := fog_beam_start.max(fog_beam_end) + margin
	_glow.custom_aabb = AABB(low, high - low)
	# 已收到的纹理/雾域参数（由 FogField 推来）在这里落地：
	# 不推送时 noise_strength=0、fog_enabled=0，亮线就是一条干净直线（不会崩）。
	if _glow_noise != null:
		_glow_material.set_shader_parameter("noise_tex", _glow_noise)
		_glow_material.set_shader_parameter("noise_strength", glow_noise_strength)
	if _glow_density != null:
		_glow_material.set_shader_parameter("fog_density_tex", _glow_density)
		_glow_material.set_shader_parameter("fog_enabled", 1.0)
		_glow_material.set_shader_parameter("fog_absorption", glow_fog_absorption)


func _refresh_preview() -> void:
	if not show_preview:
		return
	if not is_instance_valid(_preview):
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 1.0
		cylinder.bottom_radius = 1.0
		cylinder.height = 1.0
		cylinder.radial_segments = 8
		cylinder.rings = 0
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(color.r, color.g, color.b, 0.25)
		_preview = MeshInstance3D.new()
		_preview.name = "FogBeamPreview"
		_preview.mesh = cylinder
		_preview.material_override = material
		_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_preview)
	# CylinderMesh 默认沿 +Y，转到本节点的 -Z
	_preview.visible = true
	_preview.scale = Vector3(radius_m, length_m * (2.0 if bidirectional else 1.0), radius_m)
	_preview.position = Vector3(0.0, 0.0, -length_m * 0.5) if not bidirectional else Vector3.ZERO
	_preview.rotation_degrees = Vector3(90.0, 0.0, 0.0)


# ==================== 由 FogField 推来的资源（纹理 / 雾域） ====================
## 沿途颗粒感强度：需要 FogField 推来噪声纹理才有效（未推来时为 0，线是干净的）
@export_range(0.0, 1.0, 0.01) var glow_noise_strength: float = 0.45
## 雾吸收系数：亮线经过浓雾处被压暗的程度（需要 FogField 推来密度纹理）
@export_range(0.0, 12.0, 0.1) var glow_fog_absorption: float = 3.0

var _glow_noise: Texture2D
var _glow_density: Texture2D


## FogField 每帧把"噪声纹理 + 密度纹理 + 雾域范围"推给光束的亮线材质。
## ★ 为什么由雾体推送而不是光束自己去拿：光束是"数据节点"，不该知道雾体在哪；
##   而纹理是雾体生成的（程序化噪声、画笔/求解密度），只有它知道。
## 未推送时：noise_strength=0、fog_enabled=0 ⇒ 一条干净直线（安全默认）。
func set_glow_textures(noise_texture: Texture2D, density_texture: Texture2D,
		domain_size: Vector2, domain_center: Vector2) -> void:
	_glow_noise = noise_texture
	_glow_density = density_texture
	if is_instance_valid(_glow_material):
		_glow_material.set_shader_parameter("fog_domain_size", domain_size)
		_glow_material.set_shader_parameter("fog_domain_center", domain_center)
