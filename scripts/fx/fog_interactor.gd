@tool
class_name FogInteractor
extends Node3D
## ============================================================================
## fog_interactor.gd —— 把**任何会动的东西**变成雾的搅动源（交互组件）
## ============================================================================
## 【职责】挂在玩家/角色/道具/法术上，它只做三件事：
##     ① _ready 时把自己加进 `fog_interactor` 组（FogField 靠这个组找到它）；
##     ② 暴露三个可调参数（半径 / 挖雾量 / 速度放大），FogField 会读它们；
##     ③ 在编辑器里画一个线框球，方便对准半径（@tool，但**运行时才生效**）。
##
## 【它不做什么】不直接碰流体场。所有注入都由 FogField 每帧扫描组后完成 —— 这样
##   一个场景放 20 个交互体也只有一处写入流体的代码，参数与顺序都可预测；
##   反过来（每个组件自己去 push 到求解器）会踩"一帧内谁先谁后"的坑。
##
## 【用法】
##     1. 在玩家/角色根节点下加一个 `FogInteractor`（或把节点类型直接改成它）；
##     2. 调 `radius_m` 到比角色略大（雾被"推开"的范围）；
##     3. 想挖出空洞就把 `carve` 保持负值；想让角色"带起一阵风"就调大
##        `velocity_scale`；纯装饰（只搅动、不挖洞）把 carve 设 0。
##
## 【关键依赖】
##   · FogField.interactor_group 默认 "fog_interactor"（两边必须一致）
##   · FogField.interactor_* 提供"没有显式属性时的默认值"，本组件只是覆盖它
##
## 【已知的坑】
##   1. 速度默认由 FogField 用**位置差分**算（对任何 Node3D 都成立）；如果本节点
##      恰好是 CharacterBody3D 的子节点，位置差分同样有效 —— 不要在这里自己算速度，
##      否则会因为帧率抖动出现"忽强忽弱"。
##   2. 静止时不会注入源（velocity < 0.05 被跳过）：这是刻意的，否则 20 个站着不动的
##      交互体会把每帧 8 个源配额全占满，真正的动态源反而挤不进去。
##   3. 编辑器里线框球只为对准半径，别忘了它**不产生任何实际效果**。
## ============================================================================

## 搅动半径（米）：比物件略大一圈比较自然
@export_range(0.5, 60.0, 0.5) var radius_m: float = 8.0
## 挖雾速率（每秒）：负值把雾推开（形成空洞），0 = 只搅动不挖洞
@export_range(-2.0, 2.0, 0.01) var carve: float = -0.9
## 速度放大：1.0 = 目标风速等于物体速度；大于 1 会推出更夸张的尾流
@export_range(0.0, 5.0, 0.05) var velocity_scale: float = 1.0
## 编辑器里是否画半径线框
@export var show_radius_gizmo: bool = true

## FogField 会读这两个属性名（保持与 fog_field.gd 的 duck-typing 约定一致）
var fog_interactor_radius: float = 8.0
var fog_interactor_carve: float = -0.9
var fog_interactor_velocity_scale: float = 1.0

var _gizmo: MeshInstance3D


func _ready() -> void:
	add_to_group("fog_interactor")
	_sync_properties()
	if Engine.is_editor_hint():
		_refresh_gizmo()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() and show_radius_gizmo:
		_refresh_gizmo()


## 把导出参数同步成 FogField 读取的属性名（duck typing）。
## ★ 每次取值都同步：编辑器里调 SpinBox 能立刻反映到（已加载的）FogField 上。
func _sync_properties() -> void:
	fog_interactor_radius = radius_m
	fog_interactor_carve = carve
	fog_interactor_velocity_scale = velocity_scale


func _refresh_gizmo() -> void:
	if not show_radius_gizmo:
		if is_instance_valid(_gizmo):
			_gizmo.visible = false
		return
	if not is_instance_valid(_gizmo):
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 12
		sphere.rings = 6
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(0.45, 0.8, 1.0, 0.16)
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_gizmo = MeshInstance3D.new()
		_gizmo.name = "FogInteractorGizmo"
		_gizmo.mesh = sphere
		_gizmo.material_override = material
		_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_gizmo)
	_sync_properties()
	_gizmo.visible = true
	_gizmo.scale = Vector3.ONE * radius_m
