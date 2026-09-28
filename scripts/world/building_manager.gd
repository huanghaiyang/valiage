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
var _shape_cache: Dictionary = {}   # 场景路径 -> ConcavePolygonShape3D（同类模型共享，按模型实际面）
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
	# Placed 容器由场景声明（Main/Buildings/Placed）；缺失时兜底新建
	container = get_node_or_null("Placed")
	if container == null:
		container = Node3D.new()
		container.name = "Placed"
		add_child(container)
	wall_scene = load("res://assets/models/buildings/buildings/neutral/wall_straight.gltf")
	tower_scene = load("res://assets/models/buildings/buildings/red/building_tower_A_red.gltf")
	house_scene = house_scene_at(0)      # 兼容旧引用（预览等处），默认第一套
	_calibrate_sizes()
	_recalibrate_house()

## 可以放的房屋（滚轮在"房屋"工具里切换）。
##
## `base` 是**模型自身尺寸 -> 游戏尺寸**的倍数，两套模型差别很大，所以必须逐项给：
##   * KayKit 那套是按玩具尺寸做的，要放大 3.5 倍（HOUSE_BASE_SCALE）
##   * 自制的茅草屋是**按真实米数建的**（占地 4.2x3.0m、脊高 3.45m），倍数只能是 1.0，
##     否则套上 3.5 会变成一栋十几米的房子
const HOUSE_MODELS := [
	{"id": "red_home", "name": "红顶小屋", "base": HOUSE_BASE_SCALE,
	 "path": "res://assets/models/buildings/buildings/red/building_home_A_red.gltf"},
	{"id": "cottage", "name": "茅草屋", "base": 1.0,
	 "path": "res://assets/models/buildings/cottage/cottage.glb"},
]
## 当前选中的房屋（对应 HOUSE_MODELS 下标）
var house_variant := 0
var _house_cache := {}


func house_variant_count() -> int:
	return HOUSE_MODELS.size()


func house_variant_name(i: int = -1) -> String:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return ""
	return str((HOUSE_MODELS[idx] as Dictionary).get("name", ""))


func house_variant_id(i: int = -1) -> String:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return ""
	return str((HOUSE_MODELS[idx] as Dictionary).get("id", ""))


func house_base_scale(i: int = -1) -> float:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return HOUSE_BASE_SCALE
	return float((HOUSE_MODELS[idx] as Dictionary).get("base", 1.0))


## 取某号房屋的场景（带缓存）。返回 null 表示文件缺失。
func house_scene_at(i: int = -1) -> PackedScene:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return null
	var path := str((HOUSE_MODELS[idx] as Dictionary).get("path", ""))
	if path.is_empty():
		return null
	if not _house_cache.has(path):
		_house_cache[path] = load(path) if ResourceLoader.exists(path) else null
		if _house_cache[path] == null:
			push_warning("BuildingManager: 房屋模型缺失 %s" % path)
	return _house_cache[path] as PackedScene


## 切换房屋变体（滚轮）；返回切换后的下标
func cycle_house_variant(dir: int) -> int:
	var n := house_variant_count()
	if n > 0:
		house_variant = posmod(house_variant + dir, n)
		_recalibrate_house()
	return house_variant


func set_house_variant(i: int) -> void:
	if i >= 0 and i < house_variant_count():
		house_variant = i
		_recalibrate_house()


## 当前房屋的占地尺寸（供旧的 add_gable_roof 用）
func _recalibrate_house() -> void:
	var sc := house_scene_at()
	if sc == null:
		return
	var inst := sc.instantiate()
	var mi := _find_mesh_instance(inst)
	if mi != null and mi.mesh != null:
		var sz: Vector3 = mi.mesh.get_aabb().size
		_house_base = maxf(sz.x, sz.z)
	inst.free()


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

func _instantiate(scene: PackedScene, target: Node3D = null) -> Node3D:
	if scene == null:
		return null
	var inst := scene.instantiate()
	(target if target != null else container).add_child(inst)
	return inst

## 给建筑实例加模型三角网格碰撞（ConcavePolygonShape3D）
## 收集模型内所有 MeshInstance 的实际三角面（多部件：墙身/塔身/屋顶等全部覆盖），
## 按模型实际面碰撞而非写死体积；shape 顶点在模型本地空间，随 inst 的 scale/rotation 一起变换。
## 同类场景共享同一 shape（缓存），避免每段墙/每座塔重复收集面。
func _add_mesh_collision(inst: Node3D, scene: PackedScene) -> void:
	if scene == null or inst == null:
		return
	var shape: ConcavePolygonShape3D = _shape_cache.get(scene.resource_path)
	if shape == null:
		var faces := PackedVector3Array()
		# 从 inst 收集但不乘 inst 自身 transform（shape 挂 inst 下，inst 的 scale/rotation 会整体作用）
		_collect_mesh_faces(inst, Transform3D.IDENTITY, faces, false)
		if faces.is_empty():
			return
		shape = ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		_shape_cache[scene.resource_path] = shape
	var sb := StaticBody3D.new()
	sb.collision_layer = 4
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = shape
	sb.add_child(col)
	inst.add_child(sb)

## 递归收集场景内所有 MeshInstance3D 的三角面顶点，按节点 transform 链式变换到根空间
## include_self 为 false 时跳过根节点自身 transform（shape 挂根节点下随根 transform 整体变换）
func _collect_mesh_faces(n: Node3D, xform: Transform3D, out: PackedVector3Array, include_self: bool = true) -> void:
	var t: Transform3D = xform * (n.transform if include_self else Transform3D.IDENTITY)
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mf := (n as MeshInstance3D).mesh.get_faces()
		for v in mf:
			out.append(t * v)
	for c in n.get_children():
		if c is Node3D:
			_collect_mesh_faces(c as Node3D, t, out, true)

## 添加一段墙：沿 a→b 路径按模型长度拼接多个墙段
func add_wall(a: Vector3, b: Vector3, _height: float, _thickness: float, _crenellated := false) -> void:
	_place_wall(a, b)
	_undo_stack.append({"type": "wall", "a": a, "b": b})

func _place_wall(a: Vector3, b: Vector3, target: Node3D = null) -> void:
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
		var inst := _instantiate(wall_scene, target)
		if inst == null:
			return
		inst.global_position = Vector3(p.x, p.y, p.z)
		inst.scale = Vector3(1.0, WALL_HEIGHT_SCALE, 1.0)
		inst.rotation = Vector3(0, yaw, 0)
		_add_mesh_collision(inst, wall_scene)

## 添加一座塔（yaw>=0 指定朝向，-1 随机）
func add_tower(center: Vector3, radius: float, _height: float, _with_roof := true, yaw := -1.0) -> void:
	_place_tower(center, radius, yaw)
	_undo_stack.append({"type": "tower", "c": center, "r": radius, "y": yaw})

func _place_tower(center: Vector3, radius: float, yaw: float, target: Node3D = null) -> void:
	var inst := _instantiate(tower_scene, target)
	if inst == null:
		return
	var s := maxf(0.35, radius * 2.0 / _tower_base)
	inst.global_position = Vector3(center.x, center.y, center.z)
	inst.scale = Vector3.ONE * s
	inst.rotation = Vector3(0, yaw if yaw >= 0.0 else _rng.randf_range(0.0, TAU), 0)
	# 塔碰撞：模型三角网格多面体（含锥顶/塔身，角色可沿塔身形状交互）
	_add_mesh_collision(inst, tower_scene)

## 放置一栋房屋（对应原"屋顶"工具，改用预制小屋模型；yaw>=0 指定朝向，-1 随机）
## ---------------- 参天大树（自制） ----------------
##
## **为什么走这里而不是植被系统**：植被用 MultiMesh 摆，而 MultiMesh 一个实例
## 只渲染一个 surface —— 参天大树是"树皮 + 叶片(带 alpha)"两个材质的高精度模型，
## 放进 MultiMesh 必然串材质（实测：叶子先变成无贴图白片、再变成棕色木片）。
## 房屋那条路用真实节点摆放，多材质天然支持，所以树照抄房屋这条路。
## 参天大树模型表（**当前为空**：自制那棵已从项目里撤掉，用户将用 Tripo3D 重做）。
## 接入新模型只需在这里加一行，例如：
##   {"id": "tripo_maple", "name": "参天枫树", "base": 1.0,
##    "path": "res://assets/models/trees/xxx.glb"}
## `base` 是模型自带的基准缩放：按真实米数建模的填 1.0，玩具尺寸的按需放大。
## 表为空时 add_tree 会直接返回（不会报错），树木工具点了没反应是正常的。
const TREE_MODELS := []
var tree_variant := 0
var _tree_cache := {}


func tree_variant_count() -> int:
	return TREE_MODELS.size()


func tree_variant_name(i: int = -1) -> String:
	var idx := tree_variant if i < 0 else i
	if idx < 0 or idx >= TREE_MODELS.size():
		return ""
	return str((TREE_MODELS[idx] as Dictionary).get("name", ""))


func tree_base_scale(i: int = -1) -> float:
	var idx := tree_variant if i < 0 else i
	if idx < 0 or idx >= TREE_MODELS.size():
		return 1.0
	return float((TREE_MODELS[idx] as Dictionary).get("base", 1.0))


## 取某号树的场景（带缓存）
func tree_scene_at(i: int = -1) -> PackedScene:
	var idx := tree_variant if i < 0 else i
	if idx < 0 or idx >= TREE_MODELS.size():
		return null
	var path := str((TREE_MODELS[idx] as Dictionary).get("path", ""))
	if path.is_empty():
		return null
	if not _tree_cache.has(path):
		_tree_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _tree_cache[path] as PackedScene


func cycle_tree_variant(dir: int = 1) -> void:
	if TREE_MODELS.is_empty():
		return
	tree_variant = posmod(tree_variant + dir, TREE_MODELS.size())


func set_tree_variant(i: int) -> void:
	if i >= 0 and i < TREE_MODELS.size():
		tree_variant = i


func add_tree(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> void:
	_place_tree(pos, scale, yaw, null, variant)
	_undo_stack.append({"type": "tree", "p": pos, "s": scale, "y": yaw,
			"v": tree_variant if variant < 0 else variant})


func _place_tree(pos: Vector3, scale: float, yaw: float, target: Node3D = null,
		variant: int = -1) -> void:
	var sc := tree_scene_at(variant)
	if sc == null:
		return
	var inst := _instantiate(sc, target)
	if inst == null:
		return
	inst.global_position = Vector3(pos.x, pos.y, pos.z)
	inst.scale = Vector3.ONE * (maxf(0.05, scale) * tree_base_scale(variant))
	inst.rotation = Vector3(0, yaw if yaw >= 0.0 else _rng.randf_range(0.0, TAU), 0)
	# 树干碰撞：三角网格（树叶卡片也在里面，但角色撞上去就是"树"的感觉，
	# 而且可以顺着树干站上枝桠）
	_add_mesh_collision(inst, sc)


func add_house(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> void:
	_place_house(pos, scale, yaw, null, variant)
	_undo_stack.append({"type": "house", "p": pos, "s": scale, "y": yaw,
			"v": house_variant if variant < 0 else variant})

func _place_house(pos: Vector3, scale: float, yaw: float, target: Node3D = null,
		variant: int = -1) -> void:
	var sc := house_scene_at(variant)
	if sc == null:
		return
	var inst := _instantiate(sc, target)
	if inst == null:
		return
	inst.global_position = Vector3(pos.x, pos.y, pos.z)
	# 每套模型自带基准缩放（玩具尺寸那套 3.5，按真实米数建的茅草屋 1.0）
	inst.scale = Vector3.ONE * (maxf(0.4, scale) * house_base_scale(variant))
	inst.rotation = Vector3(0, yaw if yaw >= 0.0 else _rng.randf_range(0.0, TAU), 0)
	# 房屋碰撞：模型三角网格多面体（含屋顶斜面，角色可跳到屋顶上）
	_add_mesh_collision(inst, sc)

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
	# 重建到临时容器后整体替换 Placed；历史里已包含场景件（build_from_scene 写入）。
	# 注意：cache 必须挂进树里——实例的 global_position/global_transform 只在树内有效，
	# 否则 Godot 会报 "!is_inside_tree()" 并把所有墙段放在原点。
	var cache := Node3D.new()
	cache.name = "PlacedRebuild"
	add_child(cache)
	var history: Array[Dictionary] = []
	for op in _undo_stack:
		history.append(op.duplicate(true))
	_clear_all()
	for op in history:
		match op.type:
			"wall":
				_place_wall(op.a, op.b, cache)
			"tower":
				_place_tower(op.c, op.r, op.get("y", -1.0), cache)
			"house":
				_place_house(op.p, op.s, op.get("y", -1.0), cache,
						int(op.get("v", -1)))
			"tree":
				_place_tree(op.p, op.s, op.get("y", -1.0), cache,
						int(op.get("v", -1)))
	_undo_stack = history
	for c in cache.get_children():
		cache.remove_child(c)
		container.add_child(c)
	remove_child(cache)
	cache.free()

func _clear_all() -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


## 从场景布局节点重建全部建筑：Buildings/Layout 下每个子节点用 meta 描述一个构建件
## （kind=wall/house/tower，配合 a/b 或 scale/radius/yaw 等参数）。
## 布局节点始终保留在场景中，构建实例进 Buildings/Placed；
## 写回历史栈后，撤销/重建都能原样复现场景件与玩家后续放置。
func build_from_scene() -> void:
	_undo_stack.clear()
	var layout := get_node_or_null("Layout")
	if layout != null:
		for c in layout.get_children():
			if not (c is Node3D):
				continue
			var node := c as Node3D
			if not node.has_meta("kind"):
				continue
			var kind := str(node.get_meta("kind"))
			var yaw := float(node.get_meta("yaw", -1.0))
			match kind:
				"wall":
					var a := node.get_meta("a", node.position) as Vector3
					var b := node.get_meta("b", node.position) as Vector3
					_undo_stack.append({"type": "wall", "a": a, "b": b})
				"house":
					_undo_stack.append({"type": "house", "p": node.position,
							"s": float(node.get_meta("scale", 1.0)), "y": yaw})
				"tower":
					_undo_stack.append({"type": "tower", "c": node.position,
							"r": float(node.get_meta("radius", 1.4)), "y": yaw})
	print("Buildings | 从场景重建 %d 个构建件" % _undo_stack.size())
	_rebuild_from_history()