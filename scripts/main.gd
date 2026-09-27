extends Node3D
## 主场景：整合地形、植被、建筑、相机与输入交互

# 场景节点引用（节点结构在 scenes/main.tscn 中声明，脚本只做装配与行为）
@onready var terrain: TerrainSystem = $Terrain
@onready var vegetation: VegetationSystem = $Vegetation
@onready var buildings: BuildingManager = $Buildings
@onready var roads: RoadNetwork = $Roads
@onready var player: Player = $Player
@onready var camera_rig: CameraRig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var env: WorldEnvironment = $WorldEnvironment
@onready var ui: CanvasLayer = $UI
@onready var _minimap: CanvasLayer = $Minimap
var _hint_timer := 0.0            # 家具互动提示节流

# 预览节点（结构在场景中，材质为可复用资源）
@onready var preview_wall: MeshInstance3D = $PreviewWall
@onready var preview_roof: MeshInstance3D = $PreviewRoof
@onready var preview_place: Node3D = $PreviewPlace
const PREVIEW_WALL_MAT := preload("res://assets/materials/preview_wall.tres")
const PREVIEW_ROOF_MAT := preload("res://assets/materials/preview_roof.tres")
const PREVIEW_PLACE_OK := preload("res://assets/materials/preview_place_ok.tres")
const PREVIEW_PLACE_BLOCKED := preload("res://assets/materials/preview_place_blocked.tres")

# 单点放置工具（塔/屋/树/花/家具/山体：视野中心目标点的半透明模型，绿=可放置，红=占位）
var _place_tools := [Game.Tool.TOWER, Game.Tool.ROOF, Game.Tool.TREE, Game.Tool.FLOWER, Game.Tool.DECOR, Game.Tool.MOUNTAIN]
## 各分类当前选中的模型变体（滚轮切换）：{"tree": 0, "flower": 2, ...}
## 按分类而非按工具保存，切回同类工具时保留上次的选择；场景重载后自动归零。
var _variant_sel: Dictionary = {}
## 变体提示的剩余显示时间（秒），避免被互动提示立刻覆盖
var _variant_hint_time := 0.0
var _place_yaw := 0.0  # 放置朝向（右键旋转）
var _place_rot_accum := 0.0  # 按住右键旋转的累积时间（每 100ms +10°）
const PLACE_OCCUPY_RADIUS := 0.9    # 占位检测球半径（建筑层）
const PLACE_RECYCLE_RADIUS := 2.0   # 放置时回收植被范围

# 拖拽状态
var _drag_start: Vector3 = Vector3.ZERO
var _is_dragging := false
var _pending_wall := false

# 画笔
var wall_height := 3.0
var wall_thickness := 0.6
var tower_radius := 1.4
var tower_height := 5.0
var roof_width := 5.0
var roof_ridge := 2.6
var roof_eave := 1.0

# 调试截图帧计数（--capture 参数触发，渲染稳定后保存截图并退出）
var _capture_frames := 0

func _ready() -> void:
	# 节点树 / 环境光照 / 世界布局（出生点·平台·聚落·道路·植被）全部声明在 scenes/main.tscn。
	# 装配顺序：先接引用 → 生成世界（地形/平台/聚落/道路/植被/出生点）→ 再做依赖世界的
	# 预览、UI、输入动作。预览与相机都依赖 terrain/buildings/player，必须排在世界之后。
	_wire_camera_rig()
	var report := WorldBuilder.build(self, terrain, vegetation, buildings, roads, player, camera_rig)
	_setup_previews()
	_setup_ui()
	_setup_input_actions()
	vegetation.set_camera(camera_rig.camera)
	Game.world = self
	Settings.world_environment = env
	Settings.vegetation_root = vegetation
	Settings.apply_quality()
	print("World | 场景组装 平台=%d 建筑=%d 道路=%d 清场=%d 出生点=%s 地形=%dms"
			% [report["platforms"], report["buildings"], report["roads"],
			report["clear_zones"], str(report["spawn"]), report["generated_ms"]])
	# 调试截图模式：渲染稳定后保存画面并退出
	if "--capture" in OS.get_cmdline_user_args():
		_capture_frames = 90

func _process(delta: float) -> void:
	# 拖拽预览跟随准星持续更新（第一人称下相机在移动）
	if _is_dragging:
		_update_preview()
	# 单点放置工具的目标点半透明预览（绿/红）
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and Game.current_tool in _place_tools:
		_place_rot_accum += delta
		while _place_rot_accum >= 0.1:
			_place_rot_accum -= 0.1
			_place_yaw += deg_to_rad(10.0)
	_update_place_preview()
	var dt := delta if delta > 0.0 else 0.016
	if _variant_hint_time > 0.0:
		_variant_hint_time -= dt
	_hint_timer -= delta
	if _hint_timer <= 0.0:
		_hint_timer = 0.15
		if _variant_hint_time > 0.0:
			pass    # 模型切换提示优先显示，短暂保留
		else:
			_update_interact_hint()
	if _capture_frames > 0:
		_capture_frames -= 1
		if _capture_frames == 0:
			var img := get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("res://screenshot_check.png")
			get_tree().quit()

func _setup_ui() -> void:
	# UI 层在场景中声明（含脚本），这里只注入主场景引用
	ui.setup(self)
	_minimap.setup(self)

## 相机与角色引用由场景声明，运行时把 @export 引用接上
## 注意：子节点的 _ready() 在父节点 _ready() 之前执行，所以 CameraRig._ready()
## 里读到的 camera/player 只能来自场景绑定的导出引用（scenes/main.tscn），
## 这里再补一次，保证任何注入路径下都一致。
func _wire_camera_rig() -> void:
	camera_rig.camera = camera
	camera_rig.player = player
	# terrain 由 WorldBuilder 在地形生成后接入（相机贴地/地面拾取要用）

## 预览节点结构在场景中；这里只装配预览材质与真实模型网格（模型为运行时提取）
func _setup_previews() -> void:
	preview_wall.material_override = PREVIEW_WALL_MAT
	preview_roof.material_override = PREVIEW_ROOF_MAT
	# 塔预览：真实塔楼模型半透明（scale 与放置时一致）
	var tower_mi := MeshInstance3D.new()
	tower_mi.name = "TowerPreview"
	tower_mi.mesh = _extract_mesh(buildings.tower_scene)
	tower_mi.scale = Vector3.ONE * maxf(0.35, tower_radius * 2.0 / buildings._tower_base)
	preview_place.add_child(tower_mi)
	# 屋预览：真实小屋模型半透明（scale 与放置默认一致）
	var house_mi := MeshInstance3D.new()
	house_mi.name = "HousePreview"
	house_mi.mesh = _extract_mesh(buildings.house_scene)
	house_mi.scale = Vector3.ONE * buildings.HOUSE_BASE_SCALE
	preview_place.add_child(house_mi)
	# 树预览：真实树模型半透明（scale 取种树中值）
	var tree_mi := MeshInstance3D.new()
	tree_mi.name = "TreePreview"
	tree_mi.mesh = _extract_mesh(load(VegetationSystem.TREE_MODELS[0]))
	tree_mi.scale = Vector3.ONE * 1.2
	preview_place.add_child(tree_mi)
	# 花预览：真实花模型半透明
	var flower_mi := MeshInstance3D.new()
	flower_mi.name = "FlowerPreview"
	flower_mi.mesh = _extract_mesh(load(VegetationSystem.FLOWER_MODELS[0]))
	flower_mi.scale = Vector3.ONE * 1.1
	preview_place.add_child(flower_mi)
	# 家具预览：真实家具模型半透明（scale 与放置一致）
	var furniture_mi := MeshInstance3D.new()
	furniture_mi.name = "FurniturePreview"
	furniture_mi.mesh = _extract_mesh(load(VegetationSystem.FURNITURE_MODELS[0]))
	furniture_mi.scale = Vector3.ONE
	preview_place.add_child(furniture_mi)
	# 山体预览：真实 cliff 模型半透明（scale 与放置一致，用山体中值）
	var mountain_mi := MeshInstance3D.new()
	mountain_mi.name = "MountainPreview"
	mountain_mi.mesh = _extract_mesh(load(VegetationSystem.MOUNTAIN_MODELS[0]))
	mountain_mi.scale = Vector3.ONE * 4.0
	preview_place.add_child(mountain_mi)
	# 装配阶段即挂上半透明材质：即使当前没瞄到地面（落点更新会提前 return），
	# 换模型后的预览也一定是"半透明真实模型"。
	_apply_place_material(preview_place, PREVIEW_PLACE_OK)
	# 预览偏移与放置一致（每个工具按各自分类应用一次）
	for tool in _place_tools:
		var cat := _tool_category(tool)
		if cat.is_empty():
			continue
		var node := _preview_for_tool(tool)
		if node != null:
			_apply_preview_offset(node, cat)

func _setup_input_actions() -> void:
	# 快捷键：撤销
	var action := InputEventKey.new()
	action.physical_keycode = KEY_Z
	action.ctrl_pressed = true
	InputMap.action_add_event("ui_undo", action)

func _physics_process(_delta: float) -> void:
	# 拖拽预览跟随准星持续更新（第一人称下相机在移动）
	if _is_dragging:
		_update_preview()
	# 家具互动中：按移动键/跳跃立即退出
	if player.is_interacting():
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_C):
			player.stop_interact()
	# 家具互动期间冻结角色物理驱动（位置由 player 管理，防坐/睡高度被重力拉回）
	camera_rig.interact_freeze = player.is_interacting()

func _unhandled_input(event: InputEvent) -> void:
	# 键盘：撤销 / 重生成 / 数字键切工具
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Z and event.ctrl_pressed:
			buildings.undo()
			return
		if event.keycode == KEY_R:
			get_tree().reload_current_scene()
			return
		var tool_by_key := {
			KEY_1: Game.Tool.WALL,
			KEY_2: Game.Tool.TOWER,
			KEY_3: Game.Tool.ROOF,
			KEY_4: Game.Tool.TERRAIN_RAISE,
			KEY_5: Game.Tool.TERRAIN_LOWER,
			KEY_6: Game.Tool.TERRAIN_FLATTEN,
			KEY_7: Game.Tool.TREE,
			KEY_8: Game.Tool.FLOWER,
			KEY_9: Game.Tool.DECOR,
			KEY_0: Game.Tool.MOUNTAIN,
		}
		if tool_by_key.has(event.keycode):
			set_tool(tool_by_key[event.keycode])
			return
		if event.keycode == KEY_E:
			_try_interact()
			return

	# 第一人称：仅在鼠标捕获时响应左键搭建
	if not camera_rig.is_mouse_captured():
		return
	if event is InputEventMouseButton:
		# 滚轮：切换当前放置工具的模型变体（分类下有多个模型时）
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and Game.current_tool in _place_tools:
			_cycle_variant(-1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1)
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and Game.current_tool in _place_tools:
			_place_yaw += deg_to_rad(10.0)
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_begin_tool()
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_tool()

## ---------- 家具互动（E 键触发） ----------

const INTERACT_RADIUS := 2.6

## 交互/退出交互：交互中按 E 退出；否则触发附近家具互动
func _try_interact() -> void:
	if player.is_interacting():
		player.stop_interact()
		return
	var it := vegetation.find_nearest_interactable(player.global_position, INTERACT_RADIUS)
	if not it.is_empty():
		player.start_interact(it.kind, it.pos, it.yaw, it.height)

## 更新家具互动提示（节流调用）
func _update_interact_hint() -> void:
	if player.is_interacting():
		ui.show_interact_hint("按 E 退出 · 移动/跳跃退出")
		return
	var it := vegetation.find_nearest_interactable(player.global_position, INTERACT_RADIUS)
	if it.is_empty():
		ui.clear_interact_hint()
		return
	var action := "互动"
	match it.kind:
		"sit":
			action = "坐下"
		"sleep":
			action = "睡觉"
		"climb":
			action = "上梯子"
	ui.show_interact_hint("按 E %s" % action)

## 用准星射线求地面放置点（返回 null 表示未命中或超出交互距离）
func _get_ground_pos() -> Variant:
	return camera_rig.get_ground_point_center(terrain)

func _begin_tool() -> void:
	var p: Variant = _get_ground_pos()
	if p == null:
		return
	match Game.current_tool:
		Game.Tool.WALL:
			_drag_start = p
			_is_dragging = true
		Game.Tool.TOWER:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			buildings.add_tower(p, tower_radius, tower_height, true, _place_yaw)
			buildings.flush_all()
			player.play_cast_gesture()
		Game.Tool.ROOF:
			# 屋顶工具：点击放置预制小屋模型
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			buildings.add_house(p, 1.0, _place_yaw)
			buildings.flush_all()
			player.play_cast_gesture()
		Game.Tool.TREE:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			# 传入滚轮选中的变体；Placement 与半透明预览保证是同一个模型
			# 不再额外抬高：重定位偏移已保证模型底面落在放置点上
			_set_used_variant("tree", vegetation.add_tree(p, 1.2, _place_yaw, _current_variant("tree")))
			player.play_cast_gesture()
		Game.Tool.FLOWER:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			_set_used_variant("flower", vegetation.add_flower(p, 1.1, _place_yaw, _current_variant("flower")))
			player.play_cast_gesture()
		Game.Tool.DECOR:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			var cat := _tool_category(Game.current_tool)
			var vi := _current_variant(cat)
			# 楼梯同样生成模型碰撞（可走上去由自动抬步处理）
			_set_used_variant(cat, vegetation.add_furniture(p, 1.0, _place_yaw, true, vi))
			player.play_cast_gesture()
		Game.Tool.MOUNTAIN:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			_set_used_variant("mountain", vegetation.add_mountain(p, 4.0, _place_yaw, _current_variant("mountain")))
			player.play_cast_gesture()
		Game.Tool.TERRAIN_RAISE:
			terrain.apply_brush(p, terrain.brush_radius, terrain.brush_strength)
			_recycle_vegetation(p)
		Game.Tool.TERRAIN_LOWER:
			terrain.apply_brush(p, terrain.brush_radius, -terrain.brush_strength)
			_recycle_vegetation(p)
		Game.Tool.TERRAIN_FLATTEN:
			terrain.apply_brush(p, terrain.brush_radius, -terrain.brush_strength * 0.3)
			_recycle_vegetation(p)

## 刷地/放置后回收范围内的植被：植被→生物质，石头→石材（UI 自动更新）
func _recycle_vegetation(p: Vector3, radius: float = -1.0) -> void:
	var r := terrain.brush_radius + 0.8 if radius < 0.0 else radius
	var got := vegetation.recycle_around(p, r)
	if got["biomass"] > 0.0:
		Game.biomass += got["biomass"]
	if got["stone"] > 0.0:
		Game.stone += got["stone"]

func _end_tool() -> void:
	if not _is_dragging:
		return
	_is_dragging = false
	preview_wall.visible = false
	preview_roof.visible = false
	var end: Variant = _get_ground_pos()
	if end == null:
		return
	match Game.current_tool:
		Game.Tool.WALL:
			if _drag_start.distance_to(end) > 0.5:
				buildings.add_wall(_drag_start, end, wall_height, wall_thickness, false)
				buildings.flush_all()
				player.play_cast_gesture()
				_recycle_vegetation(_drag_start, PLACE_RECYCLE_RADIUS)
				_recycle_vegetation(end, PLACE_RECYCLE_RADIUS)
		_:
			pass

func _update_preview() -> void:
	if not _is_dragging:
		return
	var p: Variant = _get_ground_pos()
	if p == null:
		preview_wall.visible = false
		preview_roof.visible = false
		return
	match Game.current_tool:
		Game.Tool.WALL:
			var geom := ProceduralMesh.build_wall(_drag_start, p, wall_height, wall_thickness, 0.0)
			if not geom.is_empty():
				var arrays := ProceduralMesh.arrays_to_surface(geom)
				if not arrays.is_empty():
					var mesh := ArrayMesh.new()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					preview_wall.mesh = mesh
					preview_wall.visible = true
			preview_roof.visible = false
		Game.Tool.ROOF:
			var geom := ProceduralMesh.build_gable_roof(_drag_start, p, roof_width, roof_ridge, roof_eave)
			if not geom.is_empty():
				var arrays := ProceduralMesh.arrays_to_surface(geom)
				if not arrays.is_empty():
					var mesh := ArrayMesh.new()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					preview_roof.mesh = mesh
					preview_roof.visible = true
			preview_wall.visible = false

## 单点放置工具的目标点半透明预览：每帧跟随准星，绿=可放置，红=建筑占位
func _update_place_preview() -> void:
	if not Game.current_tool in _place_tools:
		preview_place.visible = false
		return
	var p: Variant = _get_ground_pos()
	if p == null:
		preview_place.visible = false
		return
	preview_place.visible = true
	preview_place.global_position = Vector3(p.x, p.y, p.z)
	preview_place.rotation = Vector3(0, _place_yaw, 0)
	var mat := PREVIEW_PLACE_BLOCKED if _is_occupied(p) else PREVIEW_PLACE_OK
	var want := _place_node_name(Game.current_tool)
	for child in preview_place.get_children():
		child.visible = (str(child.name) == want)
		_apply_place_material(child, mat)

## 工具 → 植被分类（无多模型可切换的工具返回空串）
func _tool_category(tool: int) -> String:
	match tool:
		Game.Tool.TREE:
			return "tree"
		Game.Tool.FLOWER:
			return "flower"
		Game.Tool.DECOR:
			return "furniture"
		Game.Tool.MOUNTAIN:
			return "mountain"
	return ""


## 当前选中的变体下标（越界自动夹回；无多模型时返回 -1）
func _current_variant(cat: String) -> int:
	var n := vegetation.category_variant_count(cat)
	if n <= 1:
		return -1
	var vi := int(_variant_sel.get(cat, 0))
	if vi < 0 or vi >= n:
		vi = 0
		_variant_sel[cat] = vi
	return vi


## 放置成功后把实际使用的变体记为当前选择（理论上与预览一致，这里兜底对齐）
func _set_used_variant(cat: String, used: int) -> void:
	if used >= 0:
		_variant_sel[cat] = used


## 滚轮切换：dir=+1 下一个模型，-1 上一个；只有一个模型时给出提示
func _cycle_variant(dir: int) -> void:
	var cat := _tool_category(Game.current_tool)
	if cat.is_empty():
		ui.show_interact_hint("该工具只有一种模型")
		_variant_hint_time = 1.2
		return
	var n := vegetation.category_variant_count(cat)
	if n <= 1:
		ui.show_interact_hint("该工具只有一种模型")
		_variant_hint_time = 1.2
		return
	var vi := posmod(_current_variant(cat) + dir, n)
	_variant_sel[cat] = vi
	_set_place_preview_mesh(cat)
	ui.show_interact_hint("模型 %d/%d · %s" % [vi + 1, n, _model_basename(cat, vi)])
	_variant_hint_time = 1.6


## 按分类取模型文件名（不含扩展名），用于提示
func _model_basename(cat: String, variant: int) -> String:
	return vegetation.category_model_path(cat, variant).get_file().get_basename()


## 把预览网格换成当前变体的真实模型（保留场景里那套半透明材质）
func _set_place_preview_mesh(cat: String) -> void:
	var node := _preview_for_tool(Game.current_tool)
	if node == null:
		return
	_apply_preview_offset(node, cat)
	var path := vegetation.category_model_path(cat, _current_variant(cat))
	if path.is_empty():
		return
	var scene: Variant = load(path)
	var mesh: Mesh = null
	if scene is PackedScene:
		mesh = _extract_mesh(scene)
	elif scene is Mesh:
		mesh = scene
	if mesh != null:
		node.mesh = mesh
	var base := _preview_base_scale(Game.current_tool)
	if base > 0.0:
		node.scale = Vector3.ONE * base
	# 换模型后立刻把半透明材质挂回去，不等下一帧的落点更新
	node.material_override = PREVIEW_PLACE_OK
	_apply_place_material(node, PREVIEW_PLACE_OK)


## 预览也要用与放置相同的重定位偏移，否则点下去模型会"跳"（ghost 与实物不一致）
## offset 在模型局部空间；预览父节点已按 _place_yaw 旋转，故无需再转。
func _apply_preview_offset(node: MeshInstance3D, cat: String) -> void:
	if cat.is_empty():
		return
	var variants := _tool_variant_count(cat)
	if variants <= 0:
		return
	var path := vegetation.category_model_path(cat, _current_variant(cat))
	if path.is_empty():
		return
	# 与放置完全同一个偏移（含底面抬升），否则模型底边会与预览差一点
	node.position = vegetation.model_preview_offset(path)


## 某分类的模型数量（无多变体时为 0）
func _tool_variant_count(cat: String) -> int:
	return vegetation.category_variant_count(cat)


## 各工具预览的基准缩放（与 _setup_previews 保持一致）
func _preview_base_scale(tool: int) -> float:
	match tool:
		Game.Tool.TREE:
			return 1.2
		Game.Tool.FLOWER:
			return 1.1
		Game.Tool.DECOR:
			return 1.0
		Game.Tool.MOUNTAIN:
			return 4.0
	return -1.0


## 取某工具对应的预览 MeshInstance3D（预览节点结构在场景中）
func _preview_for_tool(tool: int) -> MeshInstance3D:
	return preview_place.get_node_or_null(_place_node_name(tool)) as MeshInstance3D


func _place_node_name(tool: int) -> String:
	match tool:
		Game.Tool.TOWER:
			return "TowerPreview"
		Game.Tool.ROOF:
			return "HousePreview"
		Game.Tool.TREE:
			return "TreePreview"
		Game.Tool.FLOWER:
			return "FlowerPreview"
		Game.Tool.DECOR:
			return "FurniturePreview"
		Game.Tool.MOUNTAIN:
			return "MountainPreview"
	return ""

## 递归设置预览材质（树预览是 MeshInstance3D 或 Node3D 容器）
func _apply_place_material(node: Node, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		node.material_override = mat
	for c in node.get_children():
		_apply_place_material(c, mat)

## 从场景提取第一个 MeshInstance3D 的 Mesh（用于真实模型半透明预览）
func _extract_mesh(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var inst := scene.instantiate()
	var m := _find_first_mesh(inst)
	inst.free()
	return m

func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh
	for c in node.get_children():
		var m := _find_first_mesh(c)
		if m != null:
			return m
	return null

## 占位检测：目标点半径内是否有建筑（玩家创建的墙/塔/屋，层4）。
## 小植被（树/石/草/花/蘑菇/灌木）不占位，放置时自动回收为生物质/石材。
func _is_occupied(p: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = PLACE_OCCUPY_RADIUS
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, p + Vector3(0, PLACE_OCCUPY_RADIUS, 0))
	params.collision_mask = 4
	var hits := space.intersect_shape(params, 4)
	return not hits.is_empty()

## UI 回调：切换工具
func set_tool(tool: int) -> void:
	Game.current_tool = tool
	_is_dragging = false
	_place_yaw = 0.0
	preview_wall.visible = false
	preview_roof.visible = false
	preview_place.visible = false

## UI 回调：撤销
func undo() -> void:
	buildings.undo()
