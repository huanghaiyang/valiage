@tool
class_name TerrainSystem
extends Node3D
## 地形服务（精简版）
##
## 原来这里有 ~970 行**程序化地形**：噪声高度图、河流中心线与雕刻、11x11 分块网格、
## HeightMapShape3D 碰撞、顶点着色、笔刷雕刻。用户改用 Terrain3D 之后，这些**全部删除**。
##
## 本节点现在只做两件事：
##   1. 对外提供 `get_height_at()` —— Terrain3D 在就查它，否则查外接高度图，再否则返回 0
##   2. Terrain3D 还没雕数据时，放一块 y=0 的**兜底平面碰撞**，免得角色掉进虚空
##
## 对外接口保持不变（外部实际用到的）：generate / get_height_at / apply_brush /
## rebuild / is_in_river / HALF / brush_radius / brush_strength。
## apply_brush / flatten_region / rebuild* 保留为**空实现**，避免别的脚本调用时报错。

const SIZE := 900.0
const HALF := SIZE * 0.5
const RESOLUTION := 1024
const GRID := RESOLUTION - 1
const CELL := SIZE / float(GRID)

@export var use_terrain3d := true
@export var flat_fallback_collider := false   # Terrain3D 有地形时必须 false，否则两层碰撞面打架 -> 上下抖动
@export var terrain3d_path: NodePath

@export var use_import_map := false
@export var heightmap_import: Texture2D
@export var import_height_scale := 60.0
@export var import_invert := false

var brush_radius := 4.0
var brush_strength := 1.2

## 兼容：UI/相机在读这三个值画笔刷圈。地形归 Terrain3D 后不再有笔刷，
## 保持"很久以前"的状态 -> 圈不会画出来，但类型明确，外部代码不会推断失败。
var _last_brush_center := Vector3.ZERO
var _last_brush_radius := 0.0
var _last_brush_time := -1000.0

var _t3d: Node = null
var _hinted := false
var _t3d_configured := false


func _ready() -> void:
	pass


func generate(_seed_value: int = -1) -> void:
	if using_terrain3d():
		if not _hinted:
			_hinted = true
			print("Terrain | 地形由 Terrain3D 提供（自有地形/河流代码已删除）")
		_build_flat_fallback()
		return
	print("Terrain | 未启用 Terrain3D：高度来自 heightmap_import（没设图则为平地 y=0）")


func get_height_at(x: float, z: float) -> float:
	if using_terrain3d():
		var d: Variant = _t3d.get("data")
		if d != null and d.has_method("get_height"):
			var h: float = float(d.call("get_height", Vector3(x, 0.0, z)))
			if not is_nan(h):
				return h
		return 0.0
	return _height_from_map(x, z)


func _height_from_map(wx: float, wz: float) -> float:
	if not use_import_map or heightmap_import == null:
		return 0.0
	var img := heightmap_import.get_image()
	var w := img.get_width()
	var h := img.get_height()
	if w < 2 or h < 2:
		return 0.0
	var u := clampf((wx + HALF) / SIZE, 0.0, 0.999999)
	var v := clampf((wz + HALF) / SIZE, 0.0, 0.999999)
	var t := img.get_pixel(int(u * float(w)), int(v * float(h))).r
	if import_invert:
		t = 1.0 - t
	return t * import_height_scale


func _find_terrain3d() -> Node:
	if _t3d != null and is_instance_valid(_t3d):
		return _t3d
	if terrain3d_path != NodePath():
		var n := get_node_or_null(terrain3d_path)
		if n != null:
			_t3d = n
			return _t3d
	if not is_inside_tree():
		return null
	var root := get_tree().current_scene
	if root == null:
		return null
	var stack: Array = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur.is_class("Terrain3D"):
			_t3d = cur
			return _t3d
		for c in cur.get_children():
			stack.append(c)
	return null


## 把 Terrain3D 对齐本项目的碰撞层约定：**地形 = layer 2**
## （角色 collision_mask = 2|4|8；Terrain3D 默认在 layer 1，不改的话角色会直接穿过地面）
func _configure_terrain3d(t: Node) -> void:
	if t == null or _t3d_configured:
		return
	_t3d_configured = true
	# 开碰撞：collision_mode 0=Disabled 1=Dynamic/Game 2=Dynamic/Editor 3=Full/Game 4=Full/Editor
	# ★ 修正：以前只在 0 时才改成 1，于是项目一直停在 **4 = Full/Editor**
	#   （Terrain3D 自己在启动时警告 "Change collision mode to a non-editor mode for releases"）。
	#   编辑器模式在发布/运行时会带来额外的构建与更新开销 —— 这里统一改成 **Game 模式**。
	var mode := int(t.get("collision_mode"))
	if mode == 0 or mode == 2 or mode == 4:
		t.set("collision_mode", 1)
		mode = 1
	# 层/掩码在 **Terrain3DCollision 子对象** 上（Terrain3D.collision 不是 bool！）
	var col: Object = t.get("collision")
	var lay := -1
	var msk := -1
	if col != null:
		lay = int(col.get("layer"))
		msk = int(col.get("mask"))
		if lay != 2:
			col.set("layer", 2)
		if msk != 0:
			col.set("mask", 0)
		lay = int(col.get("layer"))
		msk = int(col.get("mask"))
	print("Terrain | Terrain3D 碰撞: mode=%d layer=%d mask=%d（角色 mask=%d，地形须为 layer 2）" % [
			mode, lay, msk, 2 | 4 | 8])

func using_terrain3d() -> bool:
	if not use_terrain3d:
		return false
	var t := _find_terrain3d()
	if t == null:
		return false
	_configure_terrain3d(t)
	return true


func _build_flat_fallback() -> void:
	if not flat_fallback_collider or has_node("Terrain3DFallback"):
		return
	var body := StaticBody3D.new()
	body.name = "Terrain3DFallback"
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SIZE, 1.0, SIZE)
	cs.shape = box
	cs.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(cs)
	add_child(body)
	print("Terrain | 已放置 y=0 兜底平面（雕好 Terrain3D 地形后关掉 flat_fallback_collider）")


# ---- 兼容空实现：地形归 Terrain3D 管，这些入口只保留名字 ----

func apply_brush(_world_pos: Vector3, _radius: float, _delta: float) -> void:
	pass


func flatten_region(_center: Vector3, _radius: float, _target_h: float) -> void:
	pass


func rebuild() -> void:
	pass


func rebuild_mesh() -> void:
	pass


func rebuild_mesh_around(_center: Vector3, _radius: float) -> void:
	pass


func rebuild_collision() -> void:
	pass


func rebuild_river_mesh() -> void:
	pass


func is_in_river(_wx: float, _wz: float) -> bool:
	return false