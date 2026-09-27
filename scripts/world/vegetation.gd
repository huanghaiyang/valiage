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

# ---- 家具/梯子（Kenney Furniture Kit + KayKit Dungeon，CC0，低多边形卡通风） ----
const FURNITURE_MODELS := [
	"res://assets/models/furniture/bench.glb",
	"res://assets/models/furniture/chair.glb",
	"res://assets/models/furniture/chairRounded.glb",
	"res://assets/models/furniture/loungeChair.glb",
	"res://assets/models/furniture/table.glb",
	"res://assets/models/furniture/tableRound.glb",
	"res://assets/models/furniture/tableCoffee.glb",
	"res://assets/models/furniture/desk.glb",
	"res://assets/models/furniture/sideTable.glb",
	"res://assets/models/furniture/stoolBar.glb",
	"res://assets/models/furniture/bookcaseOpen.glb",
	"res://assets/models/furniture/bookcaseClosed.glb",
	"res://assets/models/furniture/bedSingle.glb",
	"res://assets/models/furniture/bedDouble.glb",
	"res://assets/models/furniture/pillow.glb",
	"res://assets/models/furniture/lampRoundFloor.glb",
	"res://assets/models/furniture/lampRoundTable.glb",
	"res://assets/models/furniture/lampWall.glb",
	"res://assets/models/furniture/pottedPlant.glb",
	"res://assets/models/furniture/rugRound.glb",
	"res://assets/models/furniture/stairs.glb",
	"res://assets/models/furniture/stairsOpen.glb",
	"res://assets/models/furniture/stairsCorner.glb",
	"res://assets/models/dungeon/stairs_wood.glb",
	"res://assets/models/dungeon/stairs_wide.glb",
	"res://assets/models/dungeon/wall_scaffold.glb",
	"res://assets/models/dungeon/barrel_large.glb",
	"res://assets/models/dungeon/barrel_small.glb",
	"res://assets/models/dungeon/chest.glb",
	"res://assets/models/dungeon/candle.glb",
	"res://assets/models/dungeon/torch_mounted.glb",
	"res://assets/models/dungeon/table_medium.glb",
	"res://assets/models/dungeon/shelf_large.glb",
	"res://assets/models/dungeon/bed_decorated.glb",
]

# ---- 山体（Kenney Nature Kit cliff 悬崖/岩壁，CC0，风格统一） ----
const MOUNTAIN_MODELS := [
	"res://assets/models/mountain/cliff_block_rock.glb",
	"res://assets/models/mountain/cliff_large_rock.glb",
	"res://assets/models/mountain/cliff_steps_rock.glb",
	"res://assets/models/mountain/cliff_corner_rock.glb",
	"res://assets/models/mountain/cliff_diagonal_rock.glb",
	"res://assets/models/mountain/cliff_half_rock.glb",
	"res://assets/models/mountain/cliff_halfCorner_rock.glb",
	"res://assets/models/mountain/cliff_cornerLarge_rock.glb",
	"res://assets/models/mountain/cliff_rock.glb",
	"res://assets/models/mountain/cliff_top_rock.glb",
	"res://assets/models/mountain/cliff_cave_rock.glb",
	"res://assets/models/mountain/cliff_waterfall_rock.glb",
]

# ---- 每类全图上限（已大幅放宽，玩家种植不再受感知限制；满员时自动顶掉最近一棵兜底） ----
const MAX_TREES := 20000
const MAX_BUSHES := 20000
const MAX_FLOWERS := 80000
const MAX_GRASS := 200000
const MAX_ROCKS := 9000
const MAX_MUSHROOMS := 6000
const MAX_STUMPS := 4000
const MAX_FURNITURE := 4000
const MAX_MOUNTAIN := 2000

# ---- 每类生物质量（操作地形/放置建筑时植被自动回收） ----
## 生物质：植被类回收为生物质
const BIOMASS := {
	"tree": 10.0,
	"bush": 4.0,
	"flower": 1.5,
	"grass": 0.5,
	"mushroom": 2.5,
	"stump": 5.0,
}
## 石材：石头单独回收为石材（不混入生物质）
const STONE_VALUE := {
	"rock": 8.0,
}

# 使用实例随机配色的类别
const COLORED_CATEGORIES := ["flower", "grass", "mushroom", "stump"]
# 开启阴影的类别（低矮植被/杂物关闭阴影，明显提升阴影 pass 性能）
const SHADOW_CATEGORIES := ["tree", "bush", "furniture", "mountain"]

var _rng := RandomNumberGenerator.new()
## 场景播种种子：固定后自动撒点布局可复现（烘焙与运行时一致）
var scene_seed := 20260927
## 布局模式：只记录落点、不建碰撞体（供烘焙导出布局）
var layout_mode := false
## 布局模式下收集的落点
var plan_items: Array = []

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
var _furniture_hist: Array = []
var _mountain_hist: Array = []
## 各类别的碰撞参数：形状缓存 + 按类别登记的碰撞体
## 除花草外的所有类别都有模型三角网碰撞（与房屋一致：贴合视觉模型的多面体）
const COLLISION_CATEGORIES := ["tree", "bush", "rock", "mushroom", "stump", "furniture", "mountain"]
const COLLISION_LAYER := 8              # collision_mask 2|4|8 中的第 3 层（建筑/植被层）

## 形状缓存：{cat: {model_path: ConcavePolygonShape3D}}
var _shape_cache: Dictionary = {}
## 模型局部 AABB 与放置偏移缓存（每模型一份，视觉与碰撞共用同一偏移）
var _model_aabb_cache: Dictionary = {}
var _model_offset_cache: Dictionary = {}
## 已放置碰撞体：{cat: Array[StaticBody3D]}，与实例一一对应（顺序按类别）
var _collision_nodes: Dictionary = {}

## ---- 碰撞流式化：只给视野内的块建碰撞体 ----
## 每块待建碰撞的实例描述（懒加载队列），碰撞体随块进出视野创建/释放
var _pending_blocks: Array = []          # 需要补建碰撞的块下标
var _stream_budget_ms := 12.0            # 每帧用于建碰撞的时间预算（分摊，避免卡顿）
var _interactables: Array = []          # 可交互家具注册表（kind/pos/yaw/height）
var _furniture_height_cache: Dictionary = {}  # 家具模型路径 -> 站立面/爬升高度缓存

# 类别元数据
var _category_models := {
	"tree": TREE_MODELS,
	"bush": BUSH_MODELS,
	"flower": FLOWER_MODELS,
	"grass": GRASS_MODELS,
	"rock": ROCK_MODELS,
	"mushroom": MUSHROOM_MODELS,
	"stump": STUMP_MODELS,
	"furniture": FURNITURE_MODELS,
	"mountain": MOUNTAIN_MODELS,
}
var _category_max := {
	"tree": MAX_TREES,
	"bush": MAX_BUSHES,
	"flower": MAX_FLOWERS,
	"grass": MAX_GRASS,
	"rock": MAX_ROCKS,
	"mushroom": MAX_MUSHROOMS,
	"stump": MAX_STUMPS,
	"furniture": MAX_FURNITURE,
	"mountain": MAX_MOUNTAIN,
}
var _category_total := {
	"tree": 0,
	"bush": 0,
	"flower": 0,
	"grass": 0,
	"rock": 0,
	"mushroom": 0,
	"stump": 0,
	"furniture": 0,
	"mountain": 0,
}
var _scale_ranges := {
	"tree": [0.7, 1.6],
	"bush": [0.8, 1.6],
	"flower": [0.8, 1.5],
	"grass": [0.8, 1.5],
	"rock": [0.6, 1.6],
	"mushroom": [0.8, 1.5],
	"stump": [0.8, 1.6],
	"furniture": [1.0, 1.0],
	"mountain": [1.0, 1.0],
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

## 供预览使用：与放置完全一致的偏移（水平居中 + 底面抬升）
func model_preview_offset(model_path: String) -> Vector3:
	var box := _model_local_aabb(model_path)
	return Vector3(-(box.position.x + box.size.x * 0.5),
			maxf(0.0, -box.position.y),
			-(box.position.z + box.size.z * 0.5))


## 供预览使用：模型足迹中心（局部空间 AABB 中心，水平分量）
func model_footprint_center(model_path: String) -> Vector3:
	var box := _model_local_aabb(model_path)
	return Vector3(box.position.x + box.size.x * 0.5, 0.0, box.position.z + box.size.z * 0.5)


## 模型的"视觉体"局部包围盒：取第一个有网格的 MeshInstance3D 的 AABB。
## 这是画面上真正看到的体积（预览与实例都只画这一个网格），因此作为
## 视觉/预览/放置偏移的唯一基准。注意不要用"全部面集合"的 AABB：
## 多网格模型的细节子网格可能超出主体（例如 stairsOpen 的 Group 子网格
## 比主体更低），那会让偏移与看到的模型不一致。
func _model_local_aabb(model_path: String) -> AABB:
	if _model_aabb_cache.has(model_path):
		return _model_aabb_cache[model_path]
	var out := AABB()
	var m: Variant = load(model_path)
	if m is Mesh:
		out = (m as Mesh).get_aabb()
	elif m is PackedScene:
		var inst := (m as PackedScene).instantiate()
		var mi := _find_first_mesh_node(inst)
		if mi != null and mi.mesh != null:
			out = mi.mesh.get_aabb()
		inst.free()
	_model_aabb_cache[model_path] = out
	return out


## 第一个含网格的 MeshInstance3D（其 AABB 即视觉体）
func _find_first_mesh_node(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node
	for c in node.get_children():
		var r := _find_first_mesh_node(c)
		if r != null:
			return r
	return null


## 放置偏移：把模型"摆正"到放置点
##  - 水平：模型 AABB 中心 → 放置点（准星点即模型中心）
##  - 垂直：仅当模型底面低于原点时上抬，使模型底面正好落在放置高度上
## 返回 (dx, dy, dz)；未缩放前调用方需乘实例缩放（线性）。视觉与碰撞共用同一值。
func _model_place_offset(model_path: String) -> Vector3:
	if _model_offset_cache.has(model_path):
		return _model_offset_cache[model_path]
	var box := _model_local_aabb(model_path)
	var offset := Vector3.ZERO
	if box.size.x > 0.0 or box.size.z > 0.0 or box.size.y > 0.0:
		offset.x = -(box.position.x + box.size.x * 0.5)
		offset.z = -(box.position.z + box.size.z * 0.5)
		# 底面低于原点才上抬（不上抬本来就在原点之上的模型，避免悬空）
		offset.y = maxf(0.0, -box.position.y)
	_model_offset_cache[model_path] = offset
	return offset


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
		# 该块待建/已建的碰撞体：queue 是描述（懒加载），bodies 是已创建实例
		"col_queue": [],
		"col_bodies": [],
		"col_built": false,
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

## 登记一处需要模型碰撞的实例。
## immediate=true（玩家放置）时立刻建体，不等帧预算与视野判断——否则放置太快
## 或所在块恰在视野半径外时，会出现"有的物体没有碰撞"。
func _queue_collision(cat: String, model_path: String, pos: Vector3, scale: float, yaw: float,
		immediate := false) -> void:
	if _blocks.is_empty():
		return
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bi := bz * _block_n + bx
	var block: Dictionary = _blocks[bi]
	(block["col_queue"] as Array).append({
		"cat": cat, "path": model_path, "pos": pos, "scale": scale, "yaw": yaw,
	})
	block["col_built"] = false
	if immediate:
		# 玩家放置：同步建体（该块若在视野外，也给它的这一件建上，保证手感一致）
		_build_one_collision(bi, (block["col_queue"] as Array).size() - 1)
		return
	if _is_block_active(bi) or _camera == null:
		if not _pending_blocks.has(bi):
			_pending_blocks.append(bi)


## 为某块的队列中指定下标的一项建体（玩家放置用，立即生效）
func _build_one_collision(bi: int, queue_index: int) -> void:
	if bi < 0 or bi >= _blocks.size():
		return
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var bodies: Array = block["col_bodies"]
	if queue_index < 0 or queue_index >= queue.size():
		return
	# 该下标若已建过（bodies 与 queue 一一对应），跳过
	if queue_index < bodies.size():
		return
	# 队列中间可能有未建项：先把 [bodies.size(), queue_index] 都建出来
	while bodies.size() <= queue_index:
		var idx := bodies.size()
		var d: Dictionary = queue[idx]
		var sb := _make_instance_collision(str(d["cat"]), str(d["path"]),
				d["pos"] as Vector3, float(d["scale"]), float(d["yaw"]))
		sb.set_meta("veg_block", bi)
		bodies.append(sb)


func _is_block_active(bi: int) -> bool:
	if _camera == null:
		return true
	var block: Dictionary = _blocks[bi]
	var bx := bi % _block_n
	var bz := bi / _block_n
	var cx := -_terrain_half + (bx + 0.5) * CHUNK_SIZE
	var cz := -_terrain_half + (bz + 0.5) * CHUNK_SIZE
	var p := _camera.global_position
	var dx := cx - p.x
	var dz := cz - p.z
	var active_r := view_radius + CHUNK_SIZE * 0.5
	return dx * dx + dz * dz <= active_r * active_r


## 在时间预算内为"已进入视野且尚未建体"的块补建碰撞体
func _stream_collisions() -> void:
	if _camera == null or _pending_blocks.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var remaining: Array = []
	for bi in _pending_blocks:
		# 相机已接入后，只给仍在视野内的块建体；否则先释放已建的（若曾预建过）
		if not _is_block_active(int(bi)):
			_despawn_block_collisions(int(bi))
			continue
		if (Time.get_ticks_usec() - t0) / 1000.0 >= _stream_budget_ms:
			remaining.append(bi)
			continue
		if _spawn_block_collisions(int(bi)):
			continue
		remaining.append(bi)
	_pending_blocks = remaining


## 建立某块的全部碰撞体；返回 true 表示该块已完成（不再排队）
func _spawn_block_collisions(bi: int) -> bool:
	if bi < 0 or bi >= _blocks.size():
		return true
	var block: Dictionary = _blocks[bi]
	if block["col_built"]:
		return true
	var t0 := Time.get_ticks_usec()
	var queue: Array = block["col_queue"]
	var bodies: Array = block["col_bodies"]
	while bodies.size() < queue.size():
		# 每建若干个体检查一次预算，超出就下次继续（块保持未完成）
		if bodies.size() % 24 == 0 and (Time.get_ticks_usec() - t0) / 1000.0 >= _stream_budget_ms:
			return false
		var d: Dictionary = queue[bodies.size()]
		var cat := str(d["cat"])
		var sb := _make_instance_collision(cat, str(d["path"]),
				d["pos"] as Vector3, float(d["scale"]), float(d["yaw"]))
		sb.set_meta("veg_block", bi)
		bodies.append(sb)
		block["col_built"] = false
	block["col_built"] = true
	return true


## 释放某块的全部碰撞体（离开视野）
func _despawn_block_collisions(bi: int) -> void:
	if bi < 0 or bi >= _blocks.size():
		return
	var block: Dictionary = _blocks[bi]
	var bodies: Array = block["col_bodies"]
	if bodies.is_empty():
		return
	for sb in bodies:
		if not is_instance_valid(sb):
			continue
		# 从按类别登记的数组里摘掉，避免悬空引用
		for cat in _collision_nodes.keys():
			(_collision_nodes[cat] as Array).erase(sb)
		sb.queue_free()
	bodies.clear()
	block["col_built"] = false


## 共享的模型三角网碰撞形状（每模型一份，与 building_manager 同样思路）
func _shape_for(cat: String, model_path: String) -> ConcavePolygonShape3D:
	if not _shape_cache.has(cat):
		_shape_cache[cat] = {}
	var cache: Dictionary = _shape_cache[cat]
	if cache.has(model_path):
		return cache[model_path]
	var shape := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array()
	var m: Variant = load(model_path)
	if m is Mesh:
		faces = (m as Mesh).get_faces()
	elif m is PackedScene:
		var inst := (m as PackedScene).instantiate()
		if inst is Node3D:
			_collect_mesh_faces(inst as Node3D, Transform3D.IDENTITY, faces)
			inst.free()
	if faces.is_empty():
		# 兜底：极小三角片，避免空形状导致物理报错
		faces.append(Vector3(-0.25, 0.0, -0.25))
		faces.append(Vector3(0.25, 0.0, -0.25))
		faces.append(Vector3(0.0, 0.05, 0.0))
	shape.set_faces(faces)
	cache[model_path] = shape
	return shape


## 为一个已放置实例建立模型碰撞：形状共享、朝向在 CollisionShape3D、位置与缩放在 body 上。
## 返回该 body（已在树内），调用方可移动到别的父节点。
func _make_instance_collision(cat: String, model_path: String, pos: Vector3,
		scale: float, yaw: float) -> StaticBody3D:
	var block_x := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block_z := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block: Dictionary = _blocks[block_z * _block_n + block_x]
	var holder := block["collisions"] as Node3D
	var sb := StaticBody3D.new()
	sb.collision_layer = COLLISION_LAYER
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = _shape_for(cat, model_path)
	col.rotation.y = yaw
	sb.add_child(col)
	holder.add_child(sb)
	# 必须先入树再设 global_position，否则全局变换无效
	sb.global_position = pos
	sb.scale = Vector3.ONE * scale
	if not _collision_nodes.has(cat):
		_collision_nodes[cat] = []
	(_collision_nodes[cat] as Array).append(sb)
	return sb


func _last_variant(cat: String) -> int:
	var hist := _hist_for(cat)
	if hist.is_empty():
		return 0
	return int(hist[hist.size() - 1].get("vi", 0))


func _hist_for(cat: String) -> Array:
	match cat:
		"tree": return _tree_hist
		"bush": return _bush_hist
		"flower": return _flower_hist
		"grass": return _grass_hist
		"rock": return _rock_hist
		"mushroom": return _mushroom_hist
		"stump": return _stump_hist
		"furniture": return _furniture_hist
		"mountain": return _mountain_hist
	return []

## 通用添加：定位所在块 → 随机模型变体 → 指定/随机旋转 → 随机缩放 → 可选实例色
## yaw >= 0 使用指定朝向（玩家放置旋转），-1 随机朝向。
## 返回 {ok, vi, pos}：pos 是**已应用重定位偏移**的实际实例位置（Vector3 是值类型，
## 调用方必须用回传值去建碰撞，否则碰撞会落在未偏移的准星点上）。
func _add_instance(cat: String, pos: Vector3, scale: float, hist: Array, yaw: float = -1.0, force_variant: int = -1) -> Dictionary:
	var max_total: int = _category_max[cat]
	if _category_total[cat] >= max_total:
		return {"ok": false, "vi": -1, "pos": pos}
	_ensure_blocks()
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var mmis: Array = block["mmis"][cat]
	var counts: Array = block["counts"][cat]
	var cap: int = mmis[0].multimesh.instance_count
	# 指定变体（场景烘焙）优先，否则随机起始变体
	var start: int = force_variant if force_variant >= 0 and force_variant < mmis.size() else _rng.randi_range(0, mmis.size() - 1)
	var vi := -1
	for k in mmis.size():
		var cand := (start + k) % mmis.size()
		if counts[cand] < cap:
			vi = cand
			break
	if vi == -1:
		return {"ok": false, "vi": -1, "pos": pos}
	var mm: MultiMesh = mmis[vi].multimesh
	var idx: int = counts[vi]
	var rot := _rng.randf_range(0.0, TAU) if yaw < 0.0 else yaw
	var basis := Basis.IDENTITY.rotated(Vector3.UP, rot).scaled(Vector3.ONE * scale)
	# 把模型 AABB 的水平中心对到放置点：偏移在模型局部空间，
	# 必须先用实例 yaw 旋转，再按缩放放大，最后加到世界放置点。
	var model_path := str((_category_models[cat] as Array)[vi])
	var offset := _model_place_offset(model_path)
	if offset != Vector3.ZERO:
		pos += offset.rotated(Vector3.UP, rot) * scale
	mm.set_instance_transform(idx, Transform3D(basis, pos))
	var tint := Color.WHITE
	if cat in COLORED_CATEGORIES:
		tint = _random_plant_color(cat)
		mm.set_instance_color(idx, tint)
	counts[vi] += 1
	mm.visible_instance_count = counts[vi]
	_category_total[cat] += 1
	# 历史项携带复原所需全部数据（块坐标/变体/位置/缩放/朝向/配色），
	# 使场景烘焙出的布局与玩家放置都能按原样重建。
	hist.append({
		"bx": bx, "bz": bz, "vi": vi, "pos": pos,
		"scale": scale, "yaw": rot, "color": tint, "cat": cat,
	})
	# 除花草外，所有类别都要模型碰撞（灌木/蘑菇/树桩也按模型面贴合）
	# 这里只登记描述，碰撞体随块进入视野时再建（流式化）
	if not layout_mode and cat in COLLISION_CATEGORIES \
			and cat not in ["tree", "rock", "mountain", "furniture"]:
		_queue_collision(cat, model_path, pos, scale, rot, true)
	if layout_mode:
		plan_items.append({
			"cat": cat, "pos": pos, "scale": scale, "yaw": rot,
			"variant": vi, "color": tint, "bx": bx, "bz": bz,
		})
	return {"ok": true, "vi": vi, "pos": pos}

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

## 按场景节点重建一株植被（不写入玩家历史，只铺底）
func place_scene_item(node: Node3D, cat: String) -> bool:
	var p := Vector3(node.get_meta("px", node.position.x),
			node.get_meta("py", node.position.y),
			node.get_meta("pz", node.position.z))
	var s := float(node.get_meta("scale", 1.0))
	var yaw := float(node.get_meta("yaw", 0.0))
	var vi := int(node.get_meta("variant", 0))
	var placed: Dictionary = _add_instance(cat, p, s, _hist_for(cat), yaw, vi)
	if not placed["ok"]:
		return false
	# 场景烘焙的物件同样要进碰撞队列（树/石/家具/山体不走通用路径）
	if cat in COLLISION_CATEGORIES and cat not in ["bush", "mushroom", "stump"]:
		var model_path := str((_category_models[cat] as Array)[int(placed["vi"])])
		_queue_collision(cat, model_path, placed["pos"] as Vector3, s, yaw)
	return true


## 从场景节点重建全部植被（Vegetation/Spawned/<cat> 下的子节点）
## 位置在烘焙时已固化；地形被刷改后由 sync_heights() 重新贴合。
func build_from_scene() -> void:
	var spawned := get_node_or_null("Spawned")
	if spawned == null:
		return
	_ensure_blocks()
	var placed := 0
	var failed := 0
	for cat in _category_models.keys():
		var holder := spawned.get_node_or_null(str(cat))
		if holder == null:
			continue
		for c in holder.get_children():
			if c is Node3D and place_scene_item(c, str(cat)):
				placed += 1
			else:
				failed += 1
	_rebuild_interactables()
	print("Vegetation | 从场景重建 %d 株（跳过 %d）" % [placed, failed])


## 场景自动撒点（铺满全图：每块均匀分配，保证远处也有植被）
func populate_auto(terrain: TerrainSystem, count_trees: int = 3200, count_flowers: int = 12000, count_grass: int = 32000, count_bushes: int = 3200, count_rocks: int = 1400, count_mushrooms: int = 1000, count_stumps: int = 600) -> void:
	_terrain = terrain
	_terrain_half = terrain.HALF
	if scene_seed > 0:
		_rng.seed = scene_seed
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
	_run_scatter(terrain, plan)


## 按计划撒点（populate_auto 与 plan_layout 共用同一条路径，保证结果一致）
func _run_scatter(terrain: TerrainSystem, plan: Dictionary) -> void:
	for cat in plan:
		var per_block := ceili(plan[cat] / float(_block_n * _block_n))
		var sr: Array = _scale_ranges[cat]
		for bi in _block_n * _block_n:
			var bx := bi % _block_n
			var bz := bi / _block_n
			for _i in per_block:
				var p := _random_in_block(terrain, bx, bz)
				if p == Vector3.INF:
					continue
				var s := _rng.randf_range(sr[0], sr[1])
				match cat:
					"tree":
						add_tree(p, s)   # 带树干胶囊碰撞
					"rock":
						add_rock(p, s)   # 带石头盒碰撞
					_:
						_add_instance(cat, p, s, _hist_for(cat))


## 烘焙用：跑一次撒点并把落点导出为纯数据（不建碰撞体，可由场景节点取代）
func plan_layout(terrain: TerrainSystem, counts: Dictionary) -> Dictionary:
	_terrain = terrain
	_terrain_half = terrain.HALF
	layout_mode = true
	plan_items = []
	_reset_totals()
	if scene_seed > 0:
		_rng.seed = scene_seed
	_ensure_blocks()
	_run_scatter(terrain, counts)
	var out := {"counts": counts, "items": plan_items, "seed": scene_seed,
			"placed": _category_total.duplicate()}
	layout_mode = false
	plan_items = []
	return out


## 清空各类计数（烘焙前复位）
func _reset_totals() -> void:
	for cat in _category_total.keys():
		_category_total[cat] = 0

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

## 添加一棵树（随机变体 + 模型 trimesh 碰撞体；yaw>=0 指定朝向；满员时顶掉最近一棵保证可种）
## variant >= 0 时指定模型变体（滚轮选中的那一个），否则随机；返回实际使用的变体下标
func add_tree(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if _category_total["tree"] >= MAX_TREES:
		remove_last_tree()
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("tree", pos, scale, _tree_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	_queue_collision("tree", TREE_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	return vi

func add_bush(pos: Vector3, scale := 1.0) -> void:
	_add_instance("bush", pos, scale, _bush_hist)

## variant >= 0 时指定模型变体；返回实际使用的变体下标
func add_flower(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if _category_total["flower"] >= MAX_FLOWERS:
		remove_last_flower()
	var placed: Dictionary = _add_instance("flower", pos, scale, _flower_hist, yaw, variant)
	return int(placed["vi"])

func add_grass(pos: Vector3, scale := 1.0) -> void:
	_add_instance("grass", pos, scale, _grass_hist)

## variant >= 0 时指定模型变体；返回实际使用的变体下标
func add_rock(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("rock", pos, scale, _rock_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	_queue_collision("rock", ROCK_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	return vi

## 植被碰撞体：直接使用对应视觉模型的三角网格（共享 shape 资源），碰撞顶面与模型表面完全一致，避免踩上去浮空
## 收集场景内所有 MeshInstance3D 的 faces，并按节点变换到根空间，保证与视觉完全贴合
func _collect_mesh_faces(n: Node3D, xform: Transform3D, out: PackedVector3Array) -> void:
	var t: Transform3D = xform * n.transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mf := (n as MeshInstance3D).mesh.get_faces()
		for v in mf:
			out.append(t * v)
	for c in n.get_children():
		if c is Node3D:
			_collect_mesh_faces(c as Node3D, t, out)

func _extract_mesh(model_path: String) -> Mesh:
	var m: Variant = load(model_path)
	if m is Mesh:
		return m
	if m is PackedScene:
		var inst := (m as PackedScene).instantiate()
		var mi := _find_first_mesh(inst)
		if mi != null and mi.mesh != null:
			return mi.mesh
	return null

func _find_first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_first_mesh(c)
		if r != null:
			return r
	return null

func add_mushroom(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	_add_instance("mushroom", pos, scale, _mushroom_hist, yaw, variant)
	return _last_variant("mushroom")

func add_stump(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	_add_instance("stump", pos, scale, _stump_hist, yaw, variant)
	return _last_variant("stump")

## 添加一件家具/梯子（随机变体 + 模型 trimesh 碰撞；yaw>=0 指定朝向；满员顶掉最近一件）
## variant >= 0 时指定模型变体；返回实际使用的变体下标
func add_furniture(pos: Vector3, scale := 1.0, yaw := -1.0, with_collision := true, variant := -1) -> int:
	if _category_total["furniture"] >= MAX_FURNITURE:
		remove_last_furniture()
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("furniture", pos, scale, _furniture_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	if with_collision:
		_queue_collision("furniture", FURNITURE_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	# 楼梯等可走上去的家具不生成碰撞：避免踏面被判成墙而卡住，台阶交给自动抬步
	_rebuild_interactables()
	return vi

## 某分类的模型变体数量（供 UI 滚轮切换用）
func category_variant_count(cat: String) -> int:
	var models: Variant = _category_models.get(cat, null)
	return (models as Array).size() if models is Array else 0

## 某分类某个变体对应的模型路径（供预览加载真实模型）
func category_model_path(cat: String, variant: int) -> String:
	var models: Variant = _category_models.get(cat, null)
	if not (models is Array) or (models as Array).is_empty():
		return ""
	var list: Array = models
	return str(list[posmod(variant, list.size())])

## ---------- 家具互动（坐/睡/爬梯） ----------

## 家具交互类型：sit 坐 / sleep 睡 / climb 爬梯；"" 表示不可交互
func _furniture_kind(path: String) -> String:
	var n := path.get_file().get_basename()
	if n.begins_with("chair") or n == "bench" or n == "loungeChair" or n == "stoolBar":
		return "sit"
	if n.begins_with("bed"):
		return "sleep"
	if n.begins_with("ladder"):
		return "climb"
	return ""

## 家具站立面/爬升高度估算（由模型包围盒高度推导，带缓存）
func _furniture_stand_height(path: String) -> float:
	if _furniture_height_cache.has(path):
		return _furniture_height_cache[path]
	var mesh := _extract_mesh(path)
	var h := 0.5
	if mesh != null:
		var s: float = mesh.get_aabb().size.y
		match _furniture_kind(path):
			"sit":
				h = clampf(s * 0.42, 0.3, 0.8)
			"sleep":
				h = clampf(s * 0.5, 0.3, 0.8)
			"climb":
				h = maxf(s, 0.5)
	_furniture_height_cache[path] = h
	return h

## 重建可交互家具注册表（家具增删/回收后调用，遍历全部家具实例）
func _rebuild_interactables() -> void:
	_interactables.clear()
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var mmis: Array = block["mmis"]["furniture"]
		var counts: Array = block["counts"]["furniture"]
		for vi in mmis.size():
			var kind := _furniture_kind(FURNITURE_MODELS[vi])
			if kind == "":
				continue
			var mm: MultiMesh = (mmis[vi] as MultiMeshInstance3D).multimesh
			var cnt: int = counts[vi]
			var stand_h := _furniture_stand_height(FURNITURE_MODELS[vi])
			for i in cnt:
				var t: Transform3D = mm.get_instance_transform(i)
				_interactables.append({
					"kind": kind,
					"pos": t.origin,
					"yaw": t.basis.get_euler().y,
					"height": stand_h,
				})

## 查询玩家附近最近的可交互家具；返回 {} 或 {kind,pos,yaw,height,distance}
func find_nearest_interactable(pos: Vector3, radius: float) -> Dictionary:
	var best := {}
	var best_d2 := radius * radius
	for it in _interactables:
		var dx: float = (it.pos as Vector3).x - pos.x
		var dz: float = (it.pos as Vector3).z - pos.z
		var d2 := dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = it
	if best.is_empty():
		return {}
	var res := best.duplicate()
	res["distance"] = sqrt(best_d2)
	return res

## 添加一座山体（悬崖/岩壁随机变体 + 模型 trimesh 碰撞；yaw>=0 指定朝向；满员顶掉最近一座）
## variant >= 0 时指定模型变体；返回实际使用的变体下标
func add_mountain(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if _category_total["mountain"] >= MAX_MOUNTAIN:
		remove_last_mountain()
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("mountain", pos, scale, _mountain_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	_queue_collision("mountain", MOUNTAIN_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	return vi

## 顶掉某类别最后放置的一个实例（含其模型碰撞体）
func _remove_last_with_collision(cat: String, hist: Array) -> void:
	if hist.is_empty():
		return
	var raw: Variant = hist[hist.size() - 1]
	var pos: Vector3 = raw.get("pos", Vector3.ZERO) if raw is Dictionary else Vector3.ZERO
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bi := bz * _block_n + bx
	_remove_last(cat, hist)
	# 队列描述与已建实例都要去掉最后一个该类别项
	if bi >= 0 and bi < _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		for i in range(queue.size() - 1, -1, -1):
			if str((queue[i] as Dictionary).get("cat", "")) == cat:
				queue.remove_at(i)
				break
	if _collision_nodes.has(cat) and not (_collision_nodes[cat] as Array).is_empty():
		var sb: StaticBody3D = (_collision_nodes[cat] as Array).pop_back()
		if is_instance_valid(sb):
			_erase_body_from_block(sb)
			sb.queue_free()

func remove_last_tree() -> void:
	_remove_last_with_collision("tree", _tree_hist)

func remove_last_bush() -> void:
	_remove_last_with_collision("bush", _bush_hist)

func remove_last_flower() -> void:
	_remove_last("flower", _flower_hist)

func remove_last_grass() -> void:
	_remove_last("grass", _grass_hist)

func remove_last_rock() -> void:
	_remove_last_with_collision("rock", _rock_hist)

func remove_last_mushroom() -> void:
	_remove_last_with_collision("mushroom", _mushroom_hist)

func remove_last_furniture() -> void:
	_remove_last_with_collision("furniture", _furniture_hist)
	_rebuild_interactables()

func remove_last_mountain() -> void:
	_remove_last_with_collision("mountain", _mountain_hist)

func remove_last_stump() -> void:
	_remove_last_with_collision("stump", _stump_hist)

func _remove_last(cat: String, hist: Array) -> void:
	if hist.is_empty():
		return
	var raw: Variant = hist.pop_back()
	var bx: int = int(raw.get("bx", 0)) if raw is Dictionary else int(raw[0])
	var bz: int = int(raw.get("bz", 0)) if raw is Dictionary else int(raw[1])
	var vi: int = int(raw.get("vi", -1)) if raw is Dictionary else int(raw[2])
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var counts: Array = block["counts"][cat]
	if vi >= 0 and vi < counts.size() and counts[vi] > 0:
		counts[vi] -= 1
		var mm: MultiMesh = (block["mmis"][cat] as Array)[vi].multimesh
		mm.visible_instance_count = counts[vi]
	_category_total[cat] = maxi(0, _category_total[cat] - 1)

## 丢弃某块中落在圆形范围内的碰撞队列描述（清场/回收后不再补建）
func _drop_queued_in_area(center: Vector3, radius: float) -> void:
	if _blocks.is_empty():
		return
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		if queue.is_empty():
			continue
		var kept: Array = []
		for d in queue:
			var p: Vector3 = (d as Dictionary).get("pos", Vector3.ZERO)
			var dx := p.x - center.x
			var dz := p.z - center.z
			if dx * dx + dz * dz >= r2:
				kept.append(d)
		if kept.size() != queue.size():
			block["col_queue"] = kept
			block["col_built"] = false


## 把碰撞体从它所属块的登记数组里摘掉
func _erase_body_from_block(sb: StaticBody3D) -> void:
	if not sb.has_meta("veg_block"):
		return
	var bi := int(sb.get_meta("veg_block"))
	if bi >= 0 and bi < _blocks.size():
		(_blocks[bi] as Dictionary)["col_bodies"].erase(sb)


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
	_drop_queued_in_area(center, radius)
	_rebuild_all_hist()
	_rebuild_interactables()

## 回收指定中心周围半径内的植被：移除实例（含树/石碰撞体）
## 返回 {"biomass": 植被生物质, "stone": 石头石材}——石头不混入生物质
func recycle_around(center: Vector3, radius: float) -> Dictionary:
	var result := {"biomass": 0.0, "stone": 0.0}
	if _blocks.is_empty():
		return result
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		for cat in block["mmis"]:
			var mmis: Array = block["mmis"][cat]
			var counts: Array = block["counts"][cat]
			var bm: float = BIOMASS.get(cat, 0.0)
			var sv: float = STONE_VALUE.get(cat, 0.0)
			var removed := 0
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
						result["biomass"] += bm
						result["stone"] += sv
						removed += 1
					else:
						i += 1
				counts[mi] = count
			_category_total[cat] = maxi(0, _category_total[cat] - removed)
	# 同步清理树/石碰撞体，避免残留隐形障碍
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
	if result["biomass"] > 0.0 or result["stone"] > 0.0:
		_drop_queued_in_area(center, radius)
		_rebuild_all_hist()
	_rebuild_interactables()
	return result

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
					hist.append({"bx": bx, "bz": bz, "vi": vi, "pos": Vector3.ZERO,
							"scale": 1.0, "yaw": 0.0, "color": Color.WHITE, "cat": cat})

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
	if _vis_timer <= 0.0:
		_vis_timer = VIS_UPDATE_INTERVAL
		_update_visibility()
	# 每帧分摊补建视野内块的碰撞体（与剔除频率解耦，避免一次性卡顿）
	_stream_collisions()

## 视野剔除：按块中心到相机的距离，激活 view_radius 内的块。
## 同时驱动碰撞流式化：块进入视野补建碰撞体，离开视野释放。
func _update_visibility() -> void:
	if _blocks.is_empty():
		return
	# 相机未接入前不做剔除：可见性保持默认（碰撞体此时也尚未建立）
	if _camera == null:
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
		# 碰撞流式化：进入视野的块排队补建，离开视野的块立即释放碰撞体
		if active:
			if not block["col_built"] and not _pending_blocks.has(bi):
				_pending_blocks.append(bi)
		elif not (block["col_bodies"] as Array).is_empty():
			_despawn_block_collisions(bi)
