class_name VegetationSystem
extends Node3D
## 植被系统：Kenney Nature Kit 第三方模型（CC0）
## 特点：
## 1. 全图铺满：按 150m 分块，每块按类别/模型变体使用 MultiMesh 实例化，密度覆盖 900×900m 全图
## 2. 视野剔除：仅激活相机 view_radius 范围内的块，远处块整块隐藏（含树碰撞禁用），大幅优化渲染与物理
## 3. 多样化：树/灌木/花/草/石/蘑菇/树桩 7 大类，每类多种模型；花/草/蘑菇/树桩叠加实例随机配色与随机旋转

# ---- 分块 ----
const CHUNK_SIZE := 150.0          # 每块边长（米），900m 地图 → 6×6 块

# ---- 类别模型（多样化） ----
const TREE_MODELS := [
	"res://assets/models/nature/tree_default.glb",
	"res://assets/models/nature/tree_oak.glb",
	"res://assets/models/nature/tree_pineRoundA.glb",
	"res://assets/models/nature/tree_pineTallA.glb",
	"res://assets/models/nature/tree_tall.glb",
	"res://assets/models/nature/tree_cone.glb",
	"res://assets/models/nature/tree_fat.glb",
	"res://assets/models/nature/tree_default_fall.glb",
]
const BUSH_MODELS := [
	"res://assets/models/nature/plant_bush.glb",
	"res://assets/models/nature/plant_bushSmall.glb",
	"res://assets/models/nature/plant_bushDetailed.glb",
	"res://assets/models/nature/plant_bushLarge.glb",
	"res://assets/models/nature/plant_flatShort.glb",
	"res://assets/models/nature/plant_flatTall.glb",
]
const FLOWER_MODELS := [
	"res://assets/models/nature/flower_purpleA.glb",
	"res://assets/models/nature/flower_purpleB.glb",
	"res://assets/models/nature/flower_redA.glb",
	"res://assets/models/nature/flower_redB.glb",
	"res://assets/models/nature/flower_yellowA.glb",
	"res://assets/models/nature/flower_yellowC.glb",
]
const GRASS_MODELS := [
	"res://assets/models/nature/grass.glb",
	"res://assets/models/nature/grass_large.glb",
	"res://assets/models/nature/grass_leafs.glb",
	"res://assets/models/nature/grass_leafsLarge.glb",
]
const ROCK_MODELS := [
	"res://assets/models/nature/rock_smallB.glb",
	"res://assets/models/nature/rock_smallD.glb",
	"res://assets/models/nature/rock_tallA.glb",
	"res://assets/models/nature/stone_smallA.glb",
	"res://assets/models/nature/stone_largeA.glb",
	"res://assets/models/nature/rock_smallFlatA.glb",
]
const MUSHROOM_MODELS := [
	"res://assets/models/nature/mushroom_red.glb",
	"res://assets/models/nature/mushroom_redGroup.glb",
	"res://assets/models/nature/mushroom_tan.glb",
	"res://assets/models/nature/mushroom_tanGroup.glb",
]
const STUMP_MODELS := [
	"res://assets/models/nature/stump_round.glb",
	"res://assets/models/nature/stump_square.glb",
	"res://assets/models/nature/log.glb",
	"res://assets/models/nature/log_large.glb",
]

# ---- 每类全图上限 ----
const MAX_TREES := 3200
const MAX_BUSHES := 3200
const MAX_FLOWERS := 12000
const MAX_GRASS := 32000
const MAX_ROCKS := 1400
const MAX_MUSHROOMS := 1000
const MAX_STUMPS := 600

# 使用实例随机配色的类别
const COLORED_CATEGORIES := ["flower", "grass", "mushroom", "stump"]
# 开启阴影的类别（低矮植被/杂物关闭阴影，明显提升阴影 pass 性能）
const SHADOW_CATEGORIES := ["tree", "bush"]

var _rng := RandomNumberGenerator.new()

# 块数据：_blocks 为一维数组，index = bz * _block_n + bx
# 每个元素 Dictionary：
#   "node"       : Node3D（块容器，visible 控制整块显隐）
#   "mmis"       : {cat: Array[MultiMeshInstance3D]}（每模型一个）
#   "counts"     : {cat: Array[int]}
#   "collisions" : Node3D（树碰撞容器）
var _blocks: Array = []
var _block_n := 0
var _terrain_half := 450.0
var _terrain: TerrainSystem = null

# 可见性（由 Settings 质量等级驱动）
var view_radius := 220.0:
	set(v):
		view_radius = v
		_update_visibility()
var _camera: Camera3D = null
var _vis_timer := 0.0
const VIS_UPDATE_INTERVAL := 0.2
var _grass_visible := true

# 撤销历史（每项 [bx, bz, variant]）
var _tree_hist: Array = []
var _bush_hist: Array = []
var _flower_hist: Array = []
var _grass_hist: Array = []
var _rock_hist: Array = []
var _mushroom_hist: Array = []
var _stump_hist: Array = []
var _tree_collision_nodes: Array = []   # 全局顺序，撤销删除最近一棵树的碰撞体

# 类别元数据
var _category_models := {
	"tree": TREE_MODELS,
	"bush": BUSH_MODELS,
	"flower": FLOWER_MODELS,
	"grass": GRASS_MODELS,
	"rock": ROCK_MODELS,
	"mushroom": MUSHROOM_MODELS,
	"stump": STUMP_MODELS,
}
var _category_max := {
	"tree": MAX_TREES,
	"bush": MAX_BUSHES,
	"flower": MAX_FLOWERS,
	"grass": MAX_GRASS,
	"rock": MAX_ROCKS,
	"mushroom": MAX_MUSHROOMS,
	"stump": MAX_STUMPS,
}
var _category_total := {
	"tree": 0,
	"bush": 0,
	"flower": 0,
	"grass": 0,
	"rock": 0,
	"mushroom": 0,
	"stump": 0,
}
var _scale_ranges := {
	"tree": [0.7, 1.6],
	"bush": [0.8, 1.6],
	"flower": [0.8, 1.5],
	"grass": [0.8, 1.5],
	"rock": [0.6, 1.6],
	"mushroom": [0.8, 1.5],
	"stump": [0.8, 1.6],
}

func _ready() -> void:
	_rng.randomize()

## 从 glb 场景中提取第一个 MeshInstance3D 的 Mesh（提取后释放临时实例，Mesh 为共享资源）
func _load_glb_mesh(path: String) -> Mesh:
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	var inst := scene.instantiate()
	var m := _find_mesh(inst)
	inst.free()
	return m

func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh
	for c in node.get_children():
		var m := _find_mesh(c)
		if m != null:
			return m
	return null

## 懒初始化分块网格（首次撒点前建立；terrain 传入后按真实 HALF 建块）
func _ensure_blocks() -> void:
	if not _blocks.is_empty():
		return
	_block_n = maxi(1, ceili((_terrain_half * 2.0) / CHUNK_SIZE))
	for bz in _block_n:
		for bx in _block_n:
			_blocks.append(_create_block(bx, bz))

func _create_block(bx: int, bz: int) -> Dictionary:
	var node := Node3D.new()
	node.name = "Chunk_%d_%d" % [bx, bz]
	add_child(node)
	var collisions := Node3D.new()
	collisions.name = "TreeCollisions"
	node.add_child(collisions)
	var block := {
		"node": node,
		"mmis": {},
		"counts": {},
		"collisions": collisions,
	}
	for cat in _category_models:
		var models: Array = _category_models[cat]
		var cap_per := ceili(_category_max[cat] / float(_block_n * _block_n * models.size()))
		var use_color: bool = cat in COLORED_CATEGORIES
		var use_shadow: bool = cat in SHADOW_CATEGORIES
		var mmis: Array = []
		var counts: Array = []
		for p in models:
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = MultiMesh.new()
			mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			mmi.multimesh.mesh = _load_glb_mesh(p)
			if use_color:
				# Godot 4.5：实例颜色通过 use_colors + set_instance_color 启用
				mmi.multimesh.use_colors = true
				var mat := StandardMaterial3D.new()
				mat.vertex_color_use_as_albedo = true
				mat.roughness = 1.0
				mmi.material_override = mat
			if not use_shadow:
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.multimesh.instance_count = cap_per
			mmi.multimesh.visible_instance_count = 0
			node.add_child(mmi)
			mmis.append(mmi)
			counts.append(0)
		block["mmis"][cat] = mmis
		block["counts"][cat] = counts
	return block

func _hist_for(cat: String) -> Array:
	match cat:
		"tree": return _tree_hist
		"bush": return _bush_hist
		"flower": return _flower_hist
		"grass": return _grass_hist
		"rock": return _rock_hist
		"mushroom": return _mushroom_hist
		"stump": return _stump_hist
	return []

## 通用添加：定位所在块 → 随机模型变体 → 随机旋转/缩放 → 可选实例色
func _add_instance(cat: String, pos: Vector3, scale: float, hist: Array) -> bool:
	var max_total: int = _category_max[cat]
	if _category_total[cat] >= max_total:
		return false
	_ensure_blocks()
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var mmis: Array = block["mmis"][cat]
	var counts: Array = block["counts"][cat]
	var cap: int = mmis[0].multimesh.instance_count
	# 随机起始变体；该块该模型满则顺延其他变体
	var start := _rng.randi_range(0, mmis.size() - 1)
	var vi := -1
	for k in mmis.size():
		var cand := (start + k) % mmis.size()
		if counts[cand] < cap:
			vi = cand
			break
	if vi == -1:
		return false
	var mm: MultiMesh = mmis[vi].multimesh
	var idx: int = counts[vi]
	var basis := Basis.IDENTITY.rotated(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * scale)
	mm.set_instance_transform(idx, Transform3D(basis, pos))
	if cat in COLORED_CATEGORIES:
		mm.set_instance_color(idx, _random_plant_color(cat))
	counts[vi] += 1
	mm.visible_instance_count = counts[vi]
	_category_total[cat] += 1
	hist.append([bx, bz, vi])
	return true

## 随机植被配色（让花/草/蘑菇/树桩观感更丰富）
func _random_plant_color(cat: String) -> Color:
	match cat:
		"flower":
			var palettes := [
				Color(0.95, 0.30, 0.42),
				Color(0.96, 0.76, 0.18),
				Color(0.72, 0.42, 0.92),
				Color(0.95, 0.52, 0.78),
				Color(0.94, 0.94, 0.97),
				Color(0.42, 0.68, 0.96),
			]
			return palettes[_rng.randi_range(0, palettes.size() - 1)]
		"grass":
			return Color(
				0.24 + _rng.randf_range(0.0, 0.20),
				0.52 + _rng.randf_range(0.0, 0.22),
				0.14 + _rng.randf_range(0.0, 0.14))
		"mushroom":
			return Color(
				0.82 + _rng.randf_range(0.0, 0.14),
				0.72 + _rng.randf_range(0.0, 0.18),
				0.55 + _rng.randf_range(0.0, 0.20))
		"stump":
			return Color(
				0.42 + _rng.randf_range(0.0, 0.14),
				0.30 + _rng.randf_range(0.0, 0.10),
				0.16 + _rng.randf_range(0.0, 0.08))
	return Color.WHITE

## 场景自动撒点（铺满全图：每块均匀分配，保证远处也有植被）
func populate_auto(terrain: TerrainSystem, count_trees: int = 3200, count_flowers: int = 12000, count_grass: int = 32000, count_bushes: int = 3200, count_rocks: int = 1400, count_mushrooms: int = 1000, count_stumps: int = 600) -> void:
	_terrain = terrain
	_terrain_half = terrain.HALF
	_ensure_blocks()
	var plan := {
		"tree": count_trees,
		"bush": count_bushes,
		"flower": count_flowers,
		"grass": count_grass,
		"rock": count_rocks,
		"mushroom": count_mushrooms,
		"stump": count_stumps,
	}
	for cat in plan:
		var per_block := ceili(plan[cat] / float(_block_n * _block_n))
		var sr: Array = _scale_ranges[cat]
		for bi in _block_n * _block_n:
			var bx := bi % _block_n
			var bz := bi / _block_n
			for _i in per_block:
				var p := _random_in_block(terrain, bx, bz)
				if p != Vector3.INF:
					_add_instance(cat, p, _rng.randf_range(sr[0], sr[1]), _hist_for(cat))

func _random_in_block(terrain: TerrainSystem, bx: int, bz: int) -> Vector3:
	var margin := 4.0
	var x0 := -_terrain_half + bx * CHUNK_SIZE + margin
	var z0 := -_terrain_half + bz * CHUNK_SIZE + margin
	for _try in 8:
		var x := x0 + _rng.randf_range(0.0, CHUNK_SIZE - margin * 2.0)
		var z := z0 + _rng.randf_range(0.0, CHUNK_SIZE - margin * 2.0)
		var h := terrain.get_height_at(x, z)
		# 放宽高度过滤：低洼草地与整平平台（0.4）也长草/花/树，保证全图铺满
		if h > -0.5 and h < 4.0:
			return Vector3(x, h, z)
	return Vector3.INF

## 添加一棵树（随机变体 + 树干碰撞体）
func add_tree(pos: Vector3, scale := 1.0) -> void:
	if not _add_instance("tree", pos, scale, _tree_hist):
		return
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var sb := StaticBody3D.new()
	sb.collision_layer = 8
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32 * scale
	cap.height = 2.6 * scale
	col.shape = cap
	col.position = Vector3(0, 1.3 * scale, 0)
	sb.add_child(col)
	sb.position = pos
	(block["collisions"] as Node3D).add_child(sb)
	_tree_collision_nodes.append(sb)

func add_bush(pos: Vector3, scale := 1.0) -> void:
	_add_instance("bush", pos, scale, _bush_hist)

func add_flower(pos: Vector3, scale := 1.0) -> void:
	_add_instance("flower", pos, scale, _flower_hist)

func add_grass(pos: Vector3, scale := 1.0) -> void:
	_add_instance("grass", pos, scale, _grass_hist)

func add_rock(pos: Vector3, scale := 1.0) -> void:
	_add_instance("rock", pos, scale, _rock_hist)

func add_mushroom(pos: Vector3, scale := 1.0) -> void:
	_add_instance("mushroom", pos, scale, _mushroom_hist)

func add_stump(pos: Vector3, scale := 1.0) -> void:
	_add_instance("stump", pos, scale, _stump_hist)

func remove_last_tree() -> void:
	_remove_last("tree", _tree_hist)
	if _tree_collision_nodes.size() > 0:
		var sb: StaticBody3D = _tree_collision_nodes.pop_back()
		sb.queue_free()

func remove_last_bush() -> void:
	_remove_last("bush", _bush_hist)

func remove_last_flower() -> void:
	_remove_last("flower", _flower_hist)

func remove_last_grass() -> void:
	_remove_last("grass", _grass_hist)

func remove_last_rock() -> void:
	_remove_last("rock", _rock_hist)

func remove_last_mushroom() -> void:
	_remove_last("mushroom", _mushroom_hist)

func remove_last_stump() -> void:
	_remove_last("stump", _stump_hist)

func _remove_last(cat: String, hist: Array) -> void:
	if hist.is_empty():
		return
	var entry: Array = hist.pop_back()
	var bx: int = entry[0]
	var bz: int = entry[1]
	var vi: int = entry[2]
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var counts: Array = block["counts"][cat]
	if counts[vi] > 0:
		counts[vi] -= 1
		var mm: MultiMesh = (block["mmis"][cat] as Array)[vi].multimesh
		mm.visible_instance_count = counts[vi]
	_category_total[cat] = maxi(0, _category_total[cat] - 1)

## 清空指定中心周围半径内的植被（出生点清场、建造区清理）
func clear_around(center: Vector3, radius: float) -> void:
	if _blocks.is_empty():
		return
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		for cat in block["mmis"]:
			var mmis: Array = block["mmis"][cat]
			var counts: Array = block["counts"][cat]
			for mi in mmis.size():
				var mm: MultiMesh = mmis[mi].multimesh
				var count: int = counts[mi]
				var i := 0
				while i < count:
					var origin: Vector3 = mm.get_instance_transform(i).origin
					var dx := origin.x - center.x
					var dz := origin.z - center.z
					if dx * dx + dz * dz < r2:
						var last_t: Transform3D = mm.get_instance_transform(count - 1)
						mm.set_instance_transform(i, last_t)
						count -= 1
						mm.visible_instance_count = count
					else:
						i += 1
				counts[mi] = count
	# 同步清理树的碰撞体，避免残留隐形障碍
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var collisions := block["collisions"] as Node3D
		for c in collisions.get_children():
			var sb := c as StaticBody3D
			var dx: float = sb.global_position.x - center.x
			var dz: float = sb.global_position.z - center.z
			if dx * dx + dz * dz < r2:
				collisions.remove_child(c)
				c.queue_free()
	_rebuild_all_hist()

func _rebuild_all_hist() -> void:
	for cat in _category_models:
		_hist_for(cat).clear()
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var bx := bi % _block_n
		var bz := bi / _block_n
		for cat in block["counts"]:
			var counts: Array = block["counts"][cat]
			var hist: Array = _hist_for(cat)
			for vi in counts.size():
				for _j in counts[vi]:
					hist.append([bx, bz, vi])

## 绑定相机（由 main 注入），立即做一次视野剔除
func set_camera(cam: Camera3D) -> void:
	_camera = cam
	_update_visibility()

## 设置草丛显隐（低画质关闭）
func set_grass_visible(v: bool) -> void:
	_grass_visible = v
	_update_visibility()

func _process(delta: float) -> void:
	if _camera == null or _blocks.is_empty():
		return
	_vis_timer -= delta
	if _vis_timer > 0.0:
		return
	_vis_timer = VIS_UPDATE_INTERVAL
	_update_visibility()

## 视野剔除：按块中心到相机的距离，激活 view_radius 内的块（隐藏其余，禁用其树碰撞）
func _update_visibility() -> void:
	if _camera == null or _blocks.is_empty():
		return
	var p := _camera.global_position
	var active_r := view_radius + CHUNK_SIZE * 0.5
	var active_r2 := active_r * active_r
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var bx := bi % _block_n
		var bz := bi / _block_n
		var cx := -_terrain_half + (bx + 0.5) * CHUNK_SIZE
		var cz := -_terrain_half + (bz + 0.5) * CHUNK_SIZE
		var dx := cx - p.x
		var dz := cz - p.z
		var active := dx * dx + dz * dz <= active_r2
		(block["node"] as Node3D).visible = active
		if active:
			var grass_mmis: Array = block["mmis"]["grass"]
			for gmmi in grass_mmis:
				(gmmi as MultiMeshInstance3D).visible = _grass_visible
		var collisions := block["collisions"] as Node3D
		for c in collisions.get_children():
			var sb := c as StaticBody3D
			sb.collision_layer = 8 if active else 0
