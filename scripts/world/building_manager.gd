class_name BuildingManager
extends Node3D
## 搭建管理器：KayKit Medieval Hexagon Pack 预制模型（CC0）
## 墙 → wall_straight 模型沿路径拼接；塔 → building_tower_A；屋顶工具 → 放置房屋模型
## 支持撤销（历史重建）；所有建筑带静态碰撞体（层4），阻止玩家穿入

var container: Node3D
var wall_scene: PackedScene
var tower_scene: PackedScene
var house_scene: PackedScene

var _undo_stack: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

# 模型尺寸校准（运行时从 AABB 读取）
var _wall_len := 3.0
var _wall_axis := "z"      # 模型长边沿哪个轴（x 或 z）
var _tower_base := 2.2     # 塔底部宽度（模型实际尺度）
var _house_base := 3.6     # 房屋底部长边

# 预制模型原始尺寸偏小（房子 ~0.93m 高、墙 ~1.1m 高），需放大到与 1.35m 角色匹配的尺度
const HOUSE_BASE_SCALE := 3.5   # 房子放大到 ~3.2m 高（约 2.4 倍角色高）
const WALL_HEIGHT_SCALE := 1.8  # 墙放大到 ~2m 高

func _ready() -> void:
	_rng.randomize()
	container = Node3D.new()
	container.name = "Placed"
	add_child(container)
	wall_scene = load("res://assets/models/buildings/buildings/neutral/wall_straight.gltf")
	tower_scene = load("res://assets/models/buildings/buildings/red/building_tower_A_red.gltf")
	house_scene = load("res://assets/models/buildings/buildings/red/building_home_A_red.gltf")
	_calibrate_sizes()

func _calibrate_sizes() -> void:
	if wall_scene != null:
		var wall_inst := wall_scene.instantiate()
		var wmi := _find_mesh_instance(wall_inst)
		if wmi != null and wmi.mesh != null:
			var ws: Vector3 = wmi.mesh.get_aabb().size
			if ws.x >= ws.z:
				_wall_len = ws.x
				_wall_axis = "x"
			else:
				_wall_len = ws.z
				_wall_axis = "z"
		wall_inst.free()
	if tower_scene != null:
		var t_inst := tower_scene.instantiate()
		var tmi := _find_mesh_instance(t_inst)
		if tmi != null and tmi.mesh != null:
			_tower_base = maxf(tmi.mesh.get_aabb().size.x, tmi.mesh.get_aabb().size.z)
		t_inst.free()
	if house_scene != null:
		var h_inst := house_scene.instantiate()
		var hmi := _find_mesh_instance(h_inst)
		if hmi != null and hmi.mesh != null:
			_house_base = maxf(hmi.mesh.get_aabb().size.x, hmi.mesh.get_aabb().size.z)
		h_inst.free()

func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var r := _find_mesh_instance(c)
		if r != null:
			return r
	return null

func _instantiate(scene: PackedScene) -> Node3D:
	if scene == null:
		return null
	var inst := scene.instantiate()
	container.add_child(inst)
	return inst

## 给建筑实例加静态碰撞盒（均匀缩放，随实例 scale 一起缩放；size/center 为模型原始尺度）
func _add_box_collision(inst: Node3D, size: Vector3, center: Vector3) -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = 4
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = center
	sb.add_child(col)
	inst.add_child(sb)

## 给墙加世界尺度碰撞盒（墙高做了非均匀缩放，碰撞体独立放到 container 避免形状失真）
func _add_wall_collision(world_pos: Vector3, yaw: float) -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = 4
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(_wall_len, 1.1 * WALL_HEIGHT_SCALE, 0.8)
	col.shape = shape
	col.position = Vector3(0, 0.55 * WALL_HEIGHT_SCALE, 0)
	sb.add_child(col)
	sb.position = world_pos
	sb.rotation = Vector3(0, yaw, 0)
	container.add_child(sb)

## 添加一段墙：沿 a→b 路径按模型长度拼接多个墙段
func add_wall(a: Vector3, b: Vector3, _height: float, _thickness: float, _crenellated := false) -> void:
	_place_wall(a, b)
	_undo_stack.append({"type": "wall", "a": a, "b": b})

func _place_wall(a: Vector3, b: Vector3) -> void:
	var seg := a.distance_to(b)
	if seg < 0.5:
		return
	var dir := (b - a) / seg
	var yaw := 0.0
	if _wall_axis == "x":
		yaw = atan2(-dir.z, dir.x)
	else:
		yaw = atan2(dir.x, dir.z)
	var n := maxi(1, int(round(seg / _wall_len)))
	for i in n:
		var p := a + dir * (seg * float(i) / float(n))
		var inst := _instantiate(wall_scene)
		if inst == null:
			return
		inst.global_position = Vector3(p.x, p.y, p.z)
		inst.scale = Vector3(1.0, WALL_HEIGHT_SCALE, 1.0)
		inst.rotation = Vector3(0, yaw, 0)
		_add_wall_collision(Vector3(p.x, p.y, p.z), yaw)

## 添加一座塔
func add_tower(center: Vector3, radius: float, _height: float, _with_roof := true) -> void:
	_place_tower(center, radius)
	_undo_stack.append({"type": "tower", "c": center, "r": radius})

func _place_tower(center: Vector3, radius: float) -> void:
	var inst := _instantiate(tower_scene)
	if inst == null:
		return
	var s := maxf(0.35, radius * 2.0 / _tower_base)
	inst.global_position = Vector3(center.x, center.y, center.z)
	inst.scale = Vector3.ONE * s
	inst.rotation = Vector3(0, _rng.randf_range(0.0, TAU), 0)
	# 塔碰撞盒（含锥顶，原始总高约 2.4）
	_add_box_collision(inst, Vector3(1.0, 2.4, 1.2), Vector3(0, 1.2, 0))

## 放置一栋房屋（对应原"屋顶"工具，改用预制小屋模型）
func add_house(pos: Vector3, scale := 1.0) -> void:
	_place_house(pos, scale)
	_undo_stack.append({"type": "house", "p": pos, "s": scale})

func _place_house(pos: Vector3, scale: float) -> void:
	var inst := _instantiate(house_scene)
	if inst == null:
		return
	inst.global_position = Vector3(pos.x, pos.y, pos.z)
	inst.scale = Vector3.ONE * (maxf(0.4, scale) * HOUSE_BASE_SCALE)
	inst.rotation = Vector3(0, _rng.randf_range(0.0, TAU), 0)
	# 房子碰撞盒（原始尺度，随均匀缩放）
	_add_box_collision(inst, Vector3(0.8, 0.93, 0.85), Vector3(0, 0.465, 0))

## 兼容旧接口（已改为放置房屋模型）
func add_gable_roof(a: Vector3, b: Vector3, width: float, _ridge_h: float, _eave_h: float) -> void:
	var center := (a + b) * 0.5
	var scale := maxf(0.8, width / _house_base)
	add_house(center, scale)

func flush_all() -> void:
	pass

## 撤销最后一个操作
func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_undo_stack.pop_back()
	_rebuild_from_history()
	return true

func clear_all() -> void:
	_undo_stack.clear()
	_rebuild_from_history()

func get_undo_count() -> int:
	return _undo_stack.size()

func _rebuild_from_history() -> void:
	var history: Array[Dictionary] = []
	for op in _undo_stack:
		history.append(op.duplicate(true))
	_clear_all()
	for op in history:
		match op.type:
			"wall":
				_place_wall(op.a, op.b)
			"tower":
				_place_tower(op.c, op.r)
			"house":
				_place_house(op.p, op.s)
	_undo_stack = history

func _clear_all() -> void:
	for c in container.get_children():
		c.queue_free()