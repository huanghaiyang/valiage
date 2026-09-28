class_name VegetationSystem
extends Node3D
## 植被系统：Kenney Nature Kit 第三方模型（CC0）
## 特点：
## 1. 全图铺满：按 150m 分块，每块按类别/模型变体使用 MultiMesh 实例化，密度覆盖 900×900m 全图
## 2. 视野剔除：仅激活相机 view_radius 范围内的块，远处块整块隐藏（含树碰撞禁用），大幅优化渲染与物理
## 3. 多样化：树/灌木/花/草/石/蘑菇/树桩 7 大类，每类多种模型；花/草/蘑菇/树桩叠加实例随机配色与随机旋转

# ---- 分块 ----
const CHUNK_SIZE := 150.0          # 每块边长（米），900m 地图 → 6×6 块

# ============================================================
# 花草树木：**当前为空表**。
#
# 这里先后放过两版自制模型（第三方 KayKit/Kenney 自然包 -> 自建几何体），
# 两版都按用户要求移除了（自建那版是"面数过低、无法使用"）。
# 分类表留空 = 世界暂时只长岩石 / 树桩 / 家具 / 山体这些非植物件，
# 等新的建模参考图到了再填回来。
#
# 关键：**不需要动烘焙好的 59220 个场景节点**。那些节点只存 `cat` + 变换
# （metadata/cat、px/py/pz、scale、yaw、variant），具体模型是运行时从
# `_category_models[cat]` 取的 —— 所以填回这张表就等于把整张地图的植被种回来。
# 撒点布局是烘焙出来的、带地形/道路/村庄的相对关系，**特意保留**，
# 空分类在 build_from_scene() 里直接跳过（不会逐个尝试放置再失败）。
# ============================================================

# ---- 类别模型（多样化） ----




## ROCK_MODELS：已清空 —— 用户要用第三方工具做地形/植被，先留白。
## 要恢复就把模型路径填回来。
const ROCK_MODELS := []

## STUMP_MODELS：已清空 —— 用户要用第三方工具做地形/植被，先留白。
## 要恢复就把模型路径填回来。
const STUMP_MODELS := []

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
var _requeue_timer := 0                  # 重新排队的节流计数（帧）
## 上次给队列排序时用的参考位置；玩家离它超过阈值就让排序失效并重排
var _sort_anchor := Vector3.INF
var _stream_budget_ms := 3.0             # 每帧用于建碰撞的时间预算（分摊，避免卡顿）
## 单个实例建碰撞（StaticBody3D + 入树 + 物理服务器 BVH 插入）实测要好几毫秒，
## 所以预算必须**每个实例都查一次**：以前是每 16 个才查，一次突发能冲到 150ms+
## （实测：走路时 p95 = 169ms，把预算降到 0.2ms 后 p95 = 48ms）。
## 12ms 的预算也太大：整帧才 30ms 上下，建碰撞最多只该占一小块。
## 重排触发：锚点移动超过这个距离 / 距上次重排至少这么久（毫秒）。
## 原来只有 1 米且无时间下限 —— 走路时几乎每帧都重排，是卡顿尖峰的源头。
const RESORT_DISTANCE := 8.0
const RESORT_INTERVAL_MS := 800
## 建体循环遇到"超出半径"的项时，最多往后扫描/挪动多少项（代替直接 break）。
const BUILD_SCAN_WINDOW := 64
## 碰撞体只在这个半径内建。必须**远小于** view_radius：视野 220m 内的块有几十个，
## 按 12ms/帧的预算根本追不上玩家前进速度 —— 于是"视野外走进来"的树到了跟前
## 还没建好碰撞，表现就是穿模。60m 内通常 2~3 个块，一两帧就建完。
var collision_radius := 60.0
var _interactables: Array = []          # 可交互家具注册表（kind/pos/yaw/height）
var _furniture_height_cache: Dictionary = {}  # 家具模型路径 -> 站立面/爬升高度缓存

# 类别元数据
## 自制参天大树（参考图"魔法山谷"系列）。真实尺寸建模，约 19.6m 高
## = 角色 1.7m 的 11.5 倍；树干/树枝/板根是真几何，树叶是带 alpha 的叶片卡片，
## 树皮 2048² / 叶簇 1024² 各有 BaseColor + Normal（树皮另有 ORM）。
var _category_models := {
	# 树：**顺序必须与 building_manager.TREE_MODELS 完全一致**。
	# 游戏内树工具的滚轮切换读的是这里的数量/下标（_current_variant），而实际放置是
	# buildings.add_tree(variant) 去查那张表 —— 两张表错位就会"滚轮显示 A、种下 B"。
	# 另外：全图撒点入口（populate_auto / plan_layout / _run_scatter）目前**没有任何调用方**，
	# 场景里也没有烘焙的撒点节点（metadata/cat = 0），所以填这张表只是"让模型可选"。
	"tree": [
		"res://assets/models/plants/autumn_tree_1.glb",
		"res://assets/models/plants/craystal_red_tree.glb",
	],
	# 花/草/蘑菇仍留空。
	"bush": [],
	"flower": [],
	"grass": [],
	"rock": ROCK_MODELS,
	"mushroom": [],
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
	# 花草树木**已经换成自制模型**，它们是按参考图的真实尺寸建的（catalog3d.json 的
	# height_m），所以这里的倍数只做"个体差异"，不再需要补偿小模型 ——
	# 旧范围里的 2.6~5.2 是给第三方 1.15~1.71m 的小树配的，套到自制树上会长成 25m 巨树。
	# 参考表 4 做完后树用的是真正的大树模型（catalog 里 3.4~5.1m），
	# 所以这里只要个体差异，不再是"用倍数把小树撑大"。
	"tree": [0.85, 1.25],
	"bush": [0.85, 1.45],
	"flower": [0.80, 1.25],
	"grass": [0.85, 1.40],
	"rock": [0.6, 1.6],
	"mushroom": [0.60, 1.00],
	"stump": [0.8, 1.6],
	"furniture": [1.0, 1.0],
	"mountain": [1.0, 1.0],
}

## 共享的风摇材质：所有植被实例共用同一份材质资源。
## 风向/风力由 Weather 每帧写进这份材质的 uniform（不能用全局着色器参数 —— 见
## assets/shaders/vegetation_wind.gdshader 顶部说明）。
const WIND_MATERIAL := preload("res://assets/materials/vegetation_wind.tres")

## 各分类的摆幅系数（每米高度的水平位移量），按实测标定：
##   0.35 → 6m 高物体在大风下横向摆 3~5px（12m 外看约 0.5m 幅度，明显但不夸张）
##   0.20 → 同样条件下只有 3px，远看几乎看不出（旧默认 0.06 完全不可见）
## 越低矮越贴地的越不该乱晃：草只是轻轻抖，树冠要明显摆。
const SWAY_BY_CATEGORY := {
	"tree": 0.35,
	"bush": 0.26,
	"flower": 0.24,
	"grass": 0.20,
	"mushroom": 0.08,
	"stump": 0.04,
	"rock": 0.0,
	"furniture": 0.0,
	"mountain": 0.0,
}
## 运行时生成的风摇材质（每分类一份，只改 sway_scale）。
## 必须保留引用，否则材质会被回收；天气系统要同时更新所有分类。
var _wind_materials: Array[ShaderMaterial] = []

func _ready() -> void:
	_rng.randomize()
	# 花草树木（含图鉴里那 222 株）已按用户要求整体移除，分类表**留空**：
	# 世界暂时只长岩石/树桩/家具/山体这些非植物件，等新参考图重做后再填回来。
	# 注意 main.tscn 里烘焙好的 59220 个撒点节点**保留**（那是布局数据，不是模型），
	# 空分类会在 build_from_scene() 里直接跳过，不再逐个尝试放置。






## 取某分类的风摇材质；首次访问时复制一份并把 sway_scale 设成该分类的值
func _wind_material_for(cat: String) -> ShaderMaterial:
	if WIND_MATERIAL == null:
		return null
	for m in _wind_materials:
		if str(m.get_meta("cat", "")) == cat:
			return m
	var m: ShaderMaterial = WIND_MATERIAL.duplicate() as ShaderMaterial
	m.set_meta("cat", cat)
	m.set_shader_parameter("sway_scale", float(SWAY_BY_CATEGORY.get(cat, 0.10)))
	_wind_materials.append(m)
	return m


## 供天气系统接管风参数：返回所有分类的风摇材质（风参数相同，sway_scale 各异）
func wind_materials() -> Array[ShaderMaterial]:
	return _wind_materials.duplicate()


# ============================================================ 几何体植物









## 把 GLB 里的**所有**子网格合并成一张单面网格（应用各自的节点变换）。
##
## 为什么必须合并：这些几何体植物是"一丛几十片叶子"，每片叶子在 Blender 里是独立
## 对象、各有自己的 loc/rot/scale。GLB 导入后是几十个 MeshInstance3D 子节点，
## 而 `_extract_mesh()` 只取**第一个** —— 结果整丛植物只剩一片叶子。
## 实测症状：草丛在游戏里是一根细条、白铃花只剩一个白点、穗草只剩一根穗
## （AABB 量出来 0.219 x 0.379 x 0.0039，几乎是一张纸）。
## 合并成单面网格后每株只占 1 个节点，也顺便省掉几十次 draw call。
func _extract_mesh_merged(path: String) -> Mesh:
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	var inst := scene.instantiate()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	_collect_merged(inst, Transform3D.IDENTITY, verts, norms, cols, idx)
	inst.free()
	if verts.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


func _collect_merged(n: Node, xf: Transform3D, verts: PackedVector3Array,
		norms: PackedVector3Array, cols: PackedColorArray,
		idx: PackedInt32Array) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			var nb := t.basis.inverse().transposed()   # 法线要用逆转置
			for s in mi.mesh.get_surface_count():
				var a: Array = mi.mesh.surface_get_arrays(s)
				if a.size() == 0 or a[Mesh.ARRAY_VERTEX] == null:
					continue
				var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
				var nn: Variant = a[Mesh.ARRAY_NORMAL]
				var cc: Variant = a[Mesh.ARRAY_COLOR]
				var ind: Variant = a[Mesh.ARRAY_INDEX]
				var base := verts.size()
				for i in v.size():
					verts.append(t * v[i])
					if nn != null and i < (nn as PackedVector3Array).size():
						norms.append((nb * (nn as PackedVector3Array)[i]).normalized())
					else:
						norms.append(Vector3.UP)
					if cc != null and i < (cc as PackedColorArray).size():
						cols.append((cc as PackedColorArray)[i])
					else:
						cols.append(Color.WHITE)
				if ind != null:
					for i in (ind as PackedInt32Array):
						idx.append(base + i)
				else:
					for i in v.size():
						idx.append(base + i)
	for c in n.get_children():
		_collect_merged(c, t, verts, norms, cols, idx)

















## 统一取"某分类某变体"要画的网格
func category_model_mesh(cat: String, variant: int) -> Mesh:
	var path := category_model_path(cat, variant)
	if path.is_empty():
		return null
	return _extract_mesh(path)


# ============================================================ 植物卡片


















## 从 glb 场景中提取第一个 MeshInstance3D 的 Mesh（提取后释放临时实例，Mesh 为共享资源）
##
## 关键：KayKit 的自然模型**没有贴图**，颜色全靠每个 surface 的 albedo_color。
## 植被为了风摇用了 material_override，而 material_override 会把原材质整个换掉 ——
## 于是所有模型都变成白模。解决办法是把每个 surface 的 albedo 颜色烘进顶点色
## （Mesh.ARRAY_COLOR），风摇着色器用 albedo_color * COLOR 取样，颜色就回来了。
func _load_glb_mesh(path: String) -> Mesh:
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	var inst := scene.instantiate()
	var m := _find_mesh(inst)
	inst.free()
	if m is ArrayMesh:
		m = _bake_surface_colors(m as ArrayMesh)
	return m


## 把每个 surface 的材质基色写进该 surface 的顶点色，返回新的 ArrayMesh。
## 已带顶点色的模型原样返回（避免重复烘）。
func _bake_surface_colors(src: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for si in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(si)
		var fmt: int = src.surface_get_format(si)
		var base := Color(1, 1, 1, 1)
		var mat := src.surface_get_material(si)
		if mat is StandardMaterial3D:
			base = (mat as StandardMaterial3D).albedo_color
		if (fmt & Mesh.ARRAY_FORMAT_COLOR) != 0:
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			out.surface_set_material(out.get_surface_count() - 1, mat)
			continue
		var vcount: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var cols := PackedColorArray()
		cols.resize(vcount)
		for i in vcount:
			cols[i] = base
		arrays[Mesh.ARRAY_COLOR] = cols
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	return out

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
		# 已建项永远是 col_queue 的前缀，col_built_n 是前缀长度
		"col_built_n": 0,
		# 队列需要按到相机的距离重排（玩家放置会插入队首，导致顺序失效）
		"col_order_dirty": false,
		"col_built": false,
	}
	for cat in _category_models:
		var models: Array = _category_models[cat]
		if models.is_empty():
			# 自制模型没载入（缺 catalog3d.json）时不能除零
			block["mmis"][cat] = []
			block["counts"][cat] = []
			continue
		# 每分类一份材质，只为让 sway_scale 不同（树摆得多、草摆得少）
		var cat_mat: ShaderMaterial = _wind_material_for(cat)
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
			# 风摇材质：顶点随风摆动由 Weather 每帧写入材质 uniform 驱动
			# （不能用全局着色器参数，见 assets/shaders/vegetation_wind.gdshader）
			if cat_mat != null:
				mmi.material_override = cat_mat
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
##
## 碰撞体是**按实例距离**流式建的，不按块。原因：
## 渲染块 CHUNK_SIZE = 150m，6×6 = 36 块覆盖 900m 地图，于是"块中心"之间隔 225m。
## 按块中心判断是否在碰撞半径内时，**玩家附近根本没有块中心** —— 全图 9044 条碰撞
## 队列里只有 1020 条被建出来（相差 8024 条），表现就是"远处的物体走过去没有碰撞"。
## 现在每条队列项带自己的位置，按到相机的距离排序，只在 collision_radius 内的建体。
func _queue_collision(cat: String, model_path: String, pos: Vector3, scale: float, yaw: float,
		immediate := false) -> void:
	if _blocks.is_empty():
		return
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bi := bz * _block_n + bx
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	queue.append({
		"cat": cat, "path": model_path, "pos": pos, "scale": scale, "yaw": yaw,
	})
	block["col_order_dirty"] = true
	block["col_built"] = false
	if immediate:
		# 玩家放置：立刻建体。插到"已建前缀"的下一位，保证已建项永远是队列前缀。
		var idx := int(block["col_built_n"])
		queue.insert(idx, queue[queue.size() - 1])
		queue.remove_at(queue.size() - 1)
		block["col_order_dirty"] = true
		_build_collision_at(bi, idx)
		return
	if not _pending_blocks.has(bi):
		_pending_blocks.append(bi)


## 为某块的队列中指定下标的一项建体（玩家放置用，立即生效）。
## 已建项必须是队列的**前缀**（_build_prefix 从 0 顺序建），所以这里只能建下一位。
func _build_collision_at(bi: int, queue_index: int) -> void:
	if bi < 0 or bi >= _blocks.size():
		return
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var bodies: Array = block["col_bodies"]
	if queue_index < 0 or queue_index >= queue.size():
		return
	while bodies.size() <= queue_index:
		var idx := bodies.size()
		var d: Dictionary = queue[idx]
		var sb := _make_instance_collision(str(d["cat"]), str(d["path"]),
				d["pos"] as Vector3, float(d["scale"]), float(d["yaw"]))
		sb.set_meta("veg_block", bi)
		bodies.append(sb)
	block["col_built_n"] = bodies.size()


## 供"已建前缀"重建：把队列按到相机的位置排序，已建的保持在前。
## 排序键是到相机的水平距离 —— 先建最近的，玩家往哪走都能优先拿到碰撞。
func _resort_block_queue(bi: int) -> void:
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var built := int(block["col_built_n"])
	if queue.size() <= 1:
		block["col_order_dirty"] = false
		return
	var p := _collision_anchor()
	# 只对未建部分排序：已建的是前缀，打乱它们会破坏 bodies 与 queue 的对应关系
	var head: Array = queue.slice(0, built)
	var tail: Array = queue.slice(built)
	tail.sort_custom(func(a, b):
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		var da := (pa.x - p.x) * (pa.x - p.x) + (pa.z - p.z) * (pa.z - p.z)
		var db := (pb.x - p.x) * (pb.x - p.x) + (pb.z - p.z) * (pb.z - p.z)
		return da < db)
	block["col_queue"] = head + tail
	block["col_order_dirty"] = false
	block["sort_ms"] = Time.get_ticks_usec()
	# 记住这次排序用的锚点：建体循环"遇到第一条超出半径的就停"，只有排序是最新的，
	# 边界才准；锚点一动排序就过期，边缘处的实例会被误判成更远而永远建不到。
	block["sort_anchor"] = p


## 碰撞判断用的参考点：优先相机，其次玩家
func _collision_anchor() -> Vector3:
	if _camera != null:
		return _camera.global_position
	return Vector3.ZERO


## 兼容旧调用：这个块现在需不需要（继续）建碰撞体
func _is_block_active(bi: int) -> bool:
	return _block_needs_collision(bi)


## 该块里有没有"还没建且进入半径"的项（决定要不要排队建体）
func _block_needs_collision(bi: int) -> bool:
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var built := int(block["col_built_n"])
	if built >= queue.size():
		return false
	if _camera == null:
		return true
	var pos: Vector3 = (queue[built] as Dictionary)["pos"]
	var p := _collision_anchor()
	var dx := pos.x - p.x
	var dz := pos.z - p.z
	return dx * dx + dz * dz <= collision_radius * collision_radius


## 在时间预算内补建碰撞体。
##
## 队列按到相机的水平距离排序，"已建"永远是队列的前缀（col_built_n = 前缀长度），
## 于是 bodies 与 queue 的下标天然一一对应，不需要额外的映射表。
## 建到第一条超出 collision_radius 的项就停 —— 后面只会更远；
## 这时**不能**把块标记为"建完"，否则玩家走近时它不会再入队，那些项就永远没有碰撞。
func _stream_collisions() -> void:
	if _camera == null or _pending_blocks.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var p := _collision_anchor()
	var r2 := collision_radius * collision_radius
	var remaining: Array = []
	for bi_v in _pending_blocks:
		var bi := int(bi_v)
		if (Time.get_ticks_usec() - t0) / 1000.0 >= _stream_budget_ms:
			remaining.append(bi)
			continue
		var block: Dictionary = _blocks[bi]
		# 重排很贵（对整条队列做 GDScript 闭包排序，上千项时实测几十毫秒），
		# 所以**不能"锚点一动就重排"**：1 米的阈值在走路时几乎每帧都成立，
		# 实测这正是走路卡顿的尖峰来源。排序不够新鲜带来的"半径边缘漏建"，
		# 由下面的扫描窗口兜底：遇到超出半径的项不再直接 break，而是挪到队尾继续往后看。
		var last_anchor: Vector3 = block.get("sort_anchor", Vector3.INF)
		var since_sort_ms := Time.get_ticks_usec() - int(block.get("sort_ms", 0))
		if bool(block["col_order_dirty"]) or last_anchor == Vector3.INF \
				or (last_anchor.distance_to(p) > RESORT_DISTANCE \
						and since_sort_ms > RESORT_INTERVAL_MS):
			_resort_block_queue(bi)
		var queue: Array = block["col_queue"]
		var bodies: Array = block["col_bodies"]
		var far_run := 0
		while bodies.size() < queue.size():
			# 预算**每个实例都查**（原来 `% 16 == 0` 才查，突发能冲 150ms+）
			if (Time.get_ticks_usec() - t0) / 1000.0 >= _stream_budget_ms:
				break
			var idx := bodies.size()
			var d: Dictionary = queue[idx]
			var pos: Vector3 = d["pos"]
			var dx := pos.x - p.x
			var dz := pos.z - p.z
			if dx * dx + dz * dz > r2:
				# 超出碰撞半径：挪到队尾（已建前缀 [0, built) 不受影响）再看下一项。
				# 这样"排序过期"只会让个别项**晚**建，不会把它后面那些其实在
				# 半径内的项永远堵住（原来是 break，正是漏建的真因）。
				far_run += 1
				if far_run > BUILD_SCAN_WINDOW:
					break
				var last_idx := queue.size() - 1
				queue[idx] = queue[last_idx]
				queue[last_idx] = d
				continue
			far_run = 0
			var sb := _make_instance_collision(str(d["cat"]), str(d["path"]),
					pos, float(d["scale"]), float(d["yaw"]))
			sb.set_meta("veg_block", bi)
			bodies.append(sb)
		block["col_built_n"] = bodies.size()
		# 只有整条队列都建完才算完成；否则留在待办里等玩家靠近
		block["col_built"] = bodies.size() >= queue.size()
		if not block["col_built"]:
			remaining.append(bi)
	_pending_blocks = remaining


## 玩家移动后重排队列并补建。
##
## 队列的排序是相对某个位置算的（到相机距离升序），而"已建项"永远是队列前缀。
## 玩家走远之后这个顺序就失效了：原本排在很后面的近处实例仍在队尾，而建体循环
## 遇到第一条超出半径的项就停 —— 于是它们永远建不到。实测玩家身边 11.8m 的实例
## 都没有碰撞体，正是这个原因（远处物体碰撞失效的真因）。
## 所以一旦玩家移动超过阈值就让所有排序失效，并给队首仍在半径内的块重新排队。
func _requeue_collision_blocks() -> void:
	_requeue_timer -= 1
	if _requeue_timer > 0:
		return
	_requeue_timer = 6
	if _blocks.is_empty():
		return
	var p := _collision_anchor()
	if _sort_anchor == Vector3.INF or p.distance_to(_sort_anchor) > 12.0:
		_sort_anchor = p
		for bi in _blocks.size():
			var b0: Dictionary = _blocks[bi]
			if (b0["col_bodies"] as Array).size() < (b0["col_queue"] as Array).size():
				b0["col_order_dirty"] = true
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		if (block["col_bodies"] as Array).size() >= queue.size():
			continue
		if bool(block["col_order_dirty"]) or _block_needs_collision(bi):
			if not _pending_blocks.has(bi):
				_pending_blocks.append(bi)


## 释放已经离开碰撞半径的已建体（从右往左，保持"已建是前缀"的不变式）
func _trim_block_collisions(bi: int) -> void:
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var bodies: Array = block["col_bodies"]
	if bodies.is_empty():
		return
	var p := _collision_anchor()
	var r2 := collision_radius * collision_radius
	var n := bodies.size()
	while not bodies.is_empty():
		n = bodies.size()
		var pos: Vector3 = (queue[n - 1] as Dictionary)["pos"]
		var dx := pos.x - p.x
		var dz := pos.z - p.z
		if dx * dx + dz * dz <= r2:
			break
		var sb: Node = bodies[n - 1]
		if is_instance_valid(sb):
			# _erase_body_from_block 会把 sb 从本块的 col_bodies 里 erase 掉，而
			# bodies 正是那个数组的别名 —— 这一句已经删掉了末尾元素。所以它删过之后
			# 不能再用 n-1 去 remove_at：数组已经短了一格，index == size 直接越界。
			_erase_body_from_block(sb)
			sb.queue_free()
		if bodies.size() == n:
			bodies.remove_at(n - 1)
	block["col_built_n"] = bodies.size()
	block["col_built"] = bodies.size() >= queue.size()


## 释放某块的全部碰撞体（离开视野）
func _despawn_block_collisions(bi: int) -> void:
	if bi < 0 or bi >= _blocks.size():
		return
	var block: Dictionary = _blocks[bi]
	var bodies: Array = block["col_bodies"]
	if bodies.is_empty():
		block["col_built_n"] = 0
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
	if mmis.is_empty():
		return {"ok": false, "vi": -1, "pos": pos}
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
	var thinned := 0
	for cat in _category_models.keys():
		var holder := spawned.get_node_or_null(str(cat))
		if holder == null:
			continue
		# 分类表为空（植物已移除）：整支跳过。否则这 59220 个撒点会逐个
		# 尝试放置再失败，白白刷一屏失败数。
		if (_category_models[cat] as Array).is_empty():
			thinned += holder.get_child_count()
			continue
		for c in holder.get_children():
			if not (c is Node3D):
				failed += 1
				continue
			if place_scene_item(c, str(cat)):
				placed += 1
			else:
				failed += 1
	_rebuild_interactables()
	print("Vegetation | 从场景重建 %d 株（抽稀跳过 %d，失败 %d）" % [placed, thinned, failed])


## 地形高度改变后，把所有已放置实例重新贴合到新地表。
##
## 场景烘焙的 py 是当时的地形高度，地形起伏被重做（或玩家用刷子推土）之后
## 这些 y 就全部作废 —— 山坡长高会把植被埋进地里，山坡挖低会让植被浮空。
## 这里按每个实例的模型偏移反推原始放置点，再用当前地形高度重新贴回地表。
func sync_heights() -> int:
	if _terrain == null:
		return 0
	_ensure_blocks()
	var moved := 0
	var off_cache := {}
	for block in _blocks:
		var mmis_by_cat: Dictionary = block["mmis"]
		var counts_by_cat: Dictionary = block["counts"]
		for cat in mmis_by_cat.keys():
			var mmis: Array = mmis_by_cat[cat]
			var counts: Array = counts_by_cat[cat]
			var models: Array = _category_models[cat]
			for vi in mmis.size():
				var n: int = counts[vi]
				if n <= 0:
					continue
				var model_path := str(models[vi])
				var off: Vector3 = off_cache.get(model_path, Vector3.INF)
				if off == Vector3.INF:
					off = _model_place_offset(model_path)
					off_cache[model_path] = off
				var mm: MultiMesh = mmis[vi].multimesh
				# 用 while 而不是 for：河道剔除会在循环里做 O(1) 交换删除
				var i := 0
				while i < n:
					var xf := mm.get_instance_transform(i)
					var origin := xf.origin
					# 反推原始放置点（抵消缩放后的模型偏移）
					var sc := xf.basis.get_scale().x
					var yaw := xf.basis.get_euler().y
					var raw := origin - off.rotated(Vector3.UP, yaw) * sc
					var h := _terrain.get_height_at(raw.x, raw.z)
					# 河道里的植被要清掉：地形被挖下去以后，原本长在这里的草树会半淹在水里
					if _terrain.has_method("is_in_river") and _terrain.is_in_river(raw.x, raw.z):
						# 与末尾元素交换后缩短可见数量（不保留顺序，O(1) 删除）
						var last := n - 1
						if i != last:
							var lxf := mm.get_instance_transform(last)
							mm.set_instance_transform(i, lxf)
						n -= 1
						# **这里绝对不能 `i -= 1`。**
						# 这是 while 循环、自增是手写的（见下面两个分支的 i += 1），
						# continue 不会自增，再减一就等于回退到上一项；i == 0 时更会变成
						# -1，下一轮 get_instance_transform(-1) 直接越界报错，整个块的地形
						# 贴合和 counts/visible_instance_count 写回全部作废。
						# 交换进来的新元素正好落在 i 上，下一轮自然会处理它，不用动 i。
						# （实测：窗口模式每次运行报 22 条越界，headless 0 条 —— 因为
						#   headless 下随机撒点的顺序碰巧没让河道实例落在下标 0 上。）
						continue
					if absf(h - raw.y) < 0.005:
						i += 1          # while 循环必须手动推进，否则原地死循环
						continue
					xf.origin = Vector3(raw.x, h, raw.z) + off.rotated(Vector3.UP, yaw) * sc
					mm.set_instance_transform(i, xf)
					moved += 1
					i += 1
				if n < counts[vi]:
					counts[vi] = n
					mm.visible_instance_count = n
			pass
	return moved


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
## variant 落在额外变体区间（即归到树木下的植物）时走植物放置：不建碰撞、不吃 3.4 倍缩放。
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
	_queue_collision("tree", str((_category_models["tree"] as Array)[vi]),
			placed["pos"] as Vector3, scale, yaw, true)
	return vi

func add_bush(pos: Vector3, scale := 1.0) -> void:
	_add_instance("bush", pos, scale, _bush_hist)

## variant >= 0 时指定模型变体；返回实际使用的变体下标
## variant 落在额外变体区间（即归到花草下的植物）时走植物放置。
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

## 某分类原来（分块 MultiMesh 那套）的模型数量
func category_base_count(cat: String) -> int:
	var models: Variant = _category_models.get(cat, null)
	return (models as Array).size() if models is Array else 0


## 某分类的模型变体数量（供 UI 滚轮切换用）
func category_variant_count(cat: String) -> int:
	return category_base_count(cat)

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

## 丢弃某块中落在圆形范围内的碰撞队列描述（清场/回收后不再补建）。
##
## 注意：队列被裁短时必须同步重建 col_bodies / col_built_n。
## 裁剪率通常很高（清一个 52m 的村庄会砍掉几百条），而且被裁掉的项里
## 可能已经有建好的碰撞体 —— 不同步的话下次 _resort_block_queue 会按
## 残留的 col_built_n 去索引已经变短的队列，直接越界报错。
func _drop_queued_in_area(center: Vector3, radius: float) -> void:
	if _blocks.is_empty():
		return
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		if queue.is_empty():
			continue
		# 快照：_erase_body_from_block 改的就是 block["col_bodies"] 这个数组本身，
		# 直接在活数组上按 i 索引会越走越偏（会漏释放 / 误保留）。
		var bodies: Array = (block["col_bodies"] as Array).duplicate()
		var kept: Array = []
		var new_bodies: Array = []
		var i := 0
		var changed := false
		for d in queue:
			var p: Vector3 = (d as Dictionary).get("pos", Vector3.ZERO)
			var dx := p.x - center.x
			var dz := p.z - center.z
			if dx * dx + dz * dz >= r2:
				kept.append(d)
				# 这一项之前建过体就一并保留（保持 bodies 与 queue 前缀一一对应）
				if i < bodies.size():
					new_bodies.append(bodies[i])
			else:
				changed = true
				# 这一项被丢掉：它若已建体，必须先释放掉
				if i < bodies.size():
					var sb: Node = bodies[i]
					if is_instance_valid(sb):
						_erase_body_from_block(sb)
						sb.queue_free()
			i += 1
		if changed or kept.size() != queue.size():
			block["col_queue"] = kept
			block["col_bodies"] = new_bodies
			block["col_built_n"] = new_bodies.size()
			block["col_built"] = new_bodies.size() >= kept.size()


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
	# 玩家走远后，把最近的未建项又进入半径的块重新排队
	_requeue_collision_blocks()

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
		# 碰撞流式化：**按实例距离**判断，不按块中心。
		# 块是 150m 见方，块中心之间隔 225m —— 按块中心判断的话玩家附近根本没有
		# "活跃块"，全图 9044 条碰撞队列只会建出 1020 条（远处物体没碰撞的真因）。
		if _block_needs_collision(bi):
			if not _pending_blocks.has(bi):
				_pending_blocks.append(bi)
		elif not (block["col_bodies"] as Array).is_empty():
			# 已建项全部离开碰撞半径：只裁掉远端那些，别整块释放
			_trim_block_collisions(bi)
