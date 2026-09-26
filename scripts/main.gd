extends Node3D
## 主场景：整合地形、植被、建筑、相机与输入交互

# 系统引用
var terrain: TerrainSystem
var vegetation: VegetationSystem
var buildings: BuildingManager
var camera_rig: CameraRig
var player: Player
var sun: DirectionalLight3D
var env: WorldEnvironment

# 预览节点
var preview_wall: MeshInstance3D
var preview_wall_mat: StandardMaterial3D
var preview_roof: MeshInstance3D
var preview_roof_mat: StandardMaterial3D

# 单点放置预览（塔/屋/树/花：视野中心目标点的半透明模型，绿=可放置，红=占位）
var preview_place: Node3D
var preview_place_mat_green: StandardMaterial3D
var preview_place_mat_red: StandardMaterial3D
var _place_tools := [Game.Tool.TOWER, Game.Tool.ROOF, Game.Tool.TREE, Game.Tool.FLOWER, Game.Tool.DECOR, Game.Tool.MOUNTAIN]
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
	_build_world()
	_setup_environment()
	_setup_previews()
	_setup_ui()
	_setup_input_actions()
	# 初始生成世界
	terrain.generate()
	# 出生点与演示建筑区整平为一片平台，避免地形起伏遮挡视野
	terrain.flatten_region(Vector3(3.0, 0.0, 5.0), 18.0, 0.4)
	vegetation.populate_auto(terrain)
	vegetation.set_camera(camera_rig.camera)
	# 演示建筑示例
	_build_demo()
	# 出生点清场：确保角色出生和第三人称相机不被植被遮挡
	vegetation.clear_around(Vector3(6.0, 0.0, 11.0), 3.5)
	Game.world = self
	Settings.world_environment = env
	Settings.vegetation_root = vegetation
	Settings.apply_quality()
	# 相机依赖地形高度，生成后再绑定
	camera_rig.terrain = terrain

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
	if _capture_frames > 0:
		_capture_frames -= 1
		if _capture_frames == 0:
			var img := get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("res://screenshot_check.png")
			get_tree().quit()

func _setup_ui() -> void:
	var ui: CanvasLayer = load("res://scripts/ui/game_ui.gd").new()
	ui.name = "UI"
	add_child(ui)
	ui.setup(self)

func _build_world() -> void:
	terrain = TerrainSystem.new()
	terrain.name = "Terrain"
	add_child(terrain)

	vegetation = VegetationSystem.new()
	vegetation.name = "Vegetation"
	add_child(vegetation)

	buildings = BuildingManager.new()
	buildings.name = "Buildings"
	add_child(buildings)

	# 玩家角色（程序化卡通人形）
	player = Player.new()
	player.name = "Player"
	add_child(player)

	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 60.0
	cam.near = 0.1
	cam.far = 1200.0
	camera_rig.add_child(cam)
	camera_rig.camera = cam
	camera_rig.player = player
	add_child(camera_rig)

func _setup_environment() -> void:
	# 方向光（暖色午后阳光）
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.4
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	sun.directional_shadow_blend_splits = 3
	add_child(sun)

	# 补光（天光）
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.light_color = Color(0.55, 0.7, 0.95)
	fill.light_energy = 0.45
	fill.rotation_degrees = Vector3(30, 120, 0)
	fill.shadow_enabled = false
	add_child(fill)

	# 环境
	env = WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.58, 0.78, 0.95)
	sky_mat.sky_horizon_color = Color(0.9, 0.92, 0.85)
	sky_mat.ground_bottom_color = Color(0.55, 0.7, 0.5)
	sky_mat.ground_horizon_color = Color(0.9, 0.92, 0.85)
	sky_mat.sun_angle_max = 20.0
	environment.sky.sky_material = sky_mat
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.9
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	env.environment = environment
	add_child(env)

func _setup_previews() -> void:
	preview_wall_mat = StandardMaterial3D.new()
	preview_wall_mat.albedo_color = Color(1, 1, 1, 0.45)
	preview_wall_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_wall_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_wall = MeshInstance3D.new()
	preview_wall.name = "PreviewWall"
	preview_wall.material_override = preview_wall_mat
	preview_wall.visible = false
	add_child(preview_wall)

	preview_roof_mat = StandardMaterial3D.new()
	preview_roof_mat.albedo_color = Color(1.0, 0.75, 0.6, 0.4)
	preview_roof_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_roof_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_roof = MeshInstance3D.new()
	preview_roof.name = "PreviewRoof"
	preview_roof.material_override = preview_roof_mat
	preview_roof.visible = false
	add_child(preview_roof)

	# 单点放置预览：半透明模型显示在视野中心目标点（绿=可放置，红=建筑占位）
	preview_place_mat_green = StandardMaterial3D.new()
	preview_place_mat_green.albedo_color = Color(0.3, 1.0, 0.4, 0.5)
	preview_place_mat_green.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_place_mat_green.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_place_mat_red = StandardMaterial3D.new()
	preview_place_mat_red.albedo_color = Color(1.0, 0.3, 0.3, 0.5)
	preview_place_mat_red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_place_mat_red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_place = Node3D.new()
	preview_place.name = "PreviewPlace"
	preview_place.visible = false
	add_child(preview_place)
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

func _setup_input_actions() -> void:
	# 快捷键：撤销
	var action := InputEventKey.new()
	action.physical_keycode = KEY_Z
	action.ctrl_pressed = true
	InputMap.action_add_event("ui_undo", action)

func _build_demo() -> void:
	# 一座小屋 + 围墙 + 塔的示例，展示玩法
	var cx := 0.0; var cz := 0.0
	var gy := 0.4   # 与 flatten 后的地面高度对齐，避免建筑被地形掩埋
	buildings.add_wall(Vector3(cx - 4, gy, cz - 3), Vector3(cx + 4, gy, cz - 3), 3.0, 0.5)
	buildings.add_wall(Vector3(cx + 4, gy, cz - 3), Vector3(cx + 4, gy, cz + 3), 3.0, 0.5)
	buildings.add_wall(Vector3(cx + 4, gy, cz + 3), Vector3(cx - 4, gy, cz + 3), 3.0, 0.5)
	buildings.add_wall(Vector3(cx - 4, gy, cz + 3), Vector3(cx - 4, gy, cz - 3), 3.0, 0.5)
	buildings.add_house(Vector3(cx, gy, cz + 5), 1.0)
	buildings.add_tower(Vector3(cx + 6, gy, cz + 2), 1.0, 5.0, true)
	buildings.flush_all()
	# demo 周围点缀植被，营造温馨氛围（围绕小屋/围墙外圈）
	for i in 20:
		var fa := TAU * float(i) / 20.0 + 0.13
		var fr := 7.0 + float(i % 5) * 0.8
		var fh := terrain.get_height_at(cos(fa) * fr, sin(fa) * fr)
		vegetation.add_flower(Vector3(cos(fa) * fr, fh, sin(fa) * fr), 1.1)
	for i in 12:
		var ba := TAU * float(i) / 12.0 + 0.4
		var br := 8.0 + float(i % 4) * 1.2
		var bh := terrain.get_height_at(cos(ba) * br, sin(ba) * br)
		vegetation.add_bush(Vector3(cos(ba) * br, bh, sin(ba) * br), 1.2)
	for i in 6:
		var ta := TAU * float(i) / 6.0 + 0.9
		var tr := 11.0 + float(i % 3) * 1.5
		var th := terrain.get_height_at(cos(ta) * tr, sin(ta) * tr)
		vegetation.add_tree(Vector3(cos(ta) * tr, th, sin(ta) * tr), 1.15)

func _physics_process(_delta: float) -> void:
	# 拖拽预览跟随准星持续更新（第一人称下相机在移动）
	if _is_dragging:
		_update_preview()

func _unhandled_input(event: InputEvent) -> void:
	# 键盘：撤销 / 重生成 / 数字键切工具
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Z and event.ctrl_pressed:
			buildings.undo()
			return
		if event.keycode == KEY_R:
			terrain.generate()
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

	# 第一人称：仅在鼠标捕获时响应左键搭建
	if not camera_rig.is_mouse_captured():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and Game.current_tool in _place_tools:
			_place_yaw += deg_to_rad(10.0)
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_begin_tool()
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_tool()

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
		Game.Tool.ROOF:
			# 屋顶工具：点击放置预制小屋模型
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			buildings.add_house(p, 1.0, _place_yaw)
			buildings.flush_all()
		Game.Tool.TREE:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			vegetation.add_tree(p + Vector3(0, 0.1, 0), 1.2, _place_yaw)
		Game.Tool.FLOWER:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			vegetation.add_flower(p, 1.1, _place_yaw)
		Game.Tool.DECOR:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			vegetation.add_furniture(p + Vector3(0, 0.1, 0), 1.0, _place_yaw)
		Game.Tool.MOUNTAIN:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			vegetation.add_mountain(p + Vector3(0, 0.1, 0), 4.0, _place_yaw)
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
	var mat := preview_place_mat_red if _is_occupied(p) else preview_place_mat_green
	var want := _place_node_name(Game.current_tool)
	for child in preview_place.get_children():
		child.visible = (child.name == want)
		_apply_place_material(child, mat)

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
