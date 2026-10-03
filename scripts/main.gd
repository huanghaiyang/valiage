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
# 家具互动距离（原来被误删过：删函数时把夹在两个函数之间的这段常量一起吃掉了）
const INTERACT_RADIUS := 2.6

@onready var _minimap: CanvasLayer = $Minimap
var _hint_timer := 0.0            # 家具互动提示节流
var _capture_aerial := false      # 调试截图：俯视全景
var _capture_free := false        # 调试截图：--cam=x,y,z --look=x,y,z 自由机位
var _capture_cam := Vector3.ZERO
var _capture_look := Vector3.ZERO
var _capture_staff := ""              # 调试截图：--staff=<id> 先装备指定法杖
var _capture_seq: PackedStringArray = []   # 调试截图：--staffseq=a,b,c 一次运行连拍
var _seq_idx := -1
var _seq_step := 18                   # 连拍时每根法杖占用的帧数（--seqstep=N 可改）
var _capture_start := 90              # 本次截图模式的起始帧数（--capframes=N 可改）
var _verify := false                  # --verify：无人值守自检（见 _run_verify()）
var _verify_frame := 0                # 自检等待的帧数（等世界与各系统装配完）
var _plant_demo := false              # --plantdemo：截图时把归入树木/花草的植物按分类摆一片
var _plant3d_demo := false            # --plant3d：只有几何体植物的近景（验收造型用）
var _plant_sheet := ""                 # --sheet=N：--plant3d 只摆第 N 张参考表的植株
var _staff_panel_demo := false         # --staffpanel：截图时打开装备（法杖）面板
var _staff_demo := false               # --staffdemo：截图时连按 3 次 Q，验收换杖提示与手持模型
var _staff_run_demo := false           # --staffrun：截图时让角色全速跑（验收法杖前挥姿态）
var _coltest := false                 # --coltest：远距离碰撞流式加载的功能测试
var _coltest_frame := 0

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

## ---- 树木笔刷（红枫树）----
## 按住左键拖动 -> 沿笔迹成片种树；单击仍然是种一棵。
@export var tree_brush_spacing := 4.0      ## 相邻两棵的最小间距（米）
@export var tree_brush_radius := 1.6       ## 每棵在放置点周围的随机偏移半径（米）
@export var tree_brush_scale_jitter := 0.12 ## 尺寸抖动幅度（±比例）
@export var tree_brush_max_per_stroke := 80 ## 一次笔画最多刷几棵
var _tree_brush_active := false
var _tree_brush_count := 0
var _last_tree_pos := Vector3.INF
## 各分类当前选中的模型变体（滚轮切换）：{"tree": 0, "flower": 2, ...}
## 按分类而非按工具保存，切回同类工具时保留上次的选择；场景重载后自动归零。
var _variant_sel: Dictionary = {}
## 变体提示的剩余显示时间（秒），避免被互动提示立刻覆盖
var _variant_hint_time := 0.0
var _place_yaw := 0.0  # 放置朝向（右键旋转）
## 未选工具时按住右键拖动 = 旋转场景（俯视角的 yaw/pitch）
var _rotating := false
var _place_rot_accum := 0.0  # 按住右键旋转的累积时间（每 100ms +10°）
const PLACE_OCCUPY_RADIUS := 0.9    # 占位检测半径（建筑层）
## 占位检测的高度：**只查贴地那一圈**。
## 原来是一个球体（把屋檐、树冠这些悬在上方的几何也算进来），于是"墙根下、大树下"
## 都放不了花草 —— 用户明确要求改成不按立体体积检测。
const PLACE_OCCUPY_HEIGHT := 0.55
## 与角色的最小间距：放置点离角色太近（会插进身体）时不允许放置
const PLACE_PLAYER_CLEAR := 0.95
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
var _probe_t := 0.0
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
	# 天气系统：绑定太阳/环境/雨，并订阅相机跟随
	Weather.bind_world(sun, env, self, vegetation.wind_materials())
	Game.world = self
	Settings.world_environment = env
	Settings.vegetation_root = vegetation
	Settings.apply_quality()
	print("World | 场景组装 平台=%d 建筑=%d 道路=%d 清场=%d 出生点=%s 地形=%dms"
			% [report["platforms"], report["buildings"], report["roads"],
			report["clear_zones"], str(report["spawn"]), report["generated_ms"]])
	# 命令行指定初始天气：--weather=0..5（配合 --capture 做截图验证）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--weather="):
			var k := int(a.split("=")[1])
			if k >= 0 and k < Weather.KIND_NAMES.size():
				Weather.auto_change = false
				Weather.set_weather(k, true)
				print("Weather | 启动指定 -> %s (wind=%.2f)" % [Weather.weather_name(), Weather.wind])
	# 调试截图模式：渲染稳定后保存画面并退出
	if "--capture" in OS.get_cmdline_user_args():
		_capture_frames = 90
		_capture_start = 90
		_capture_aerial = "--aerial" in OS.get_cmdline_user_args()
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--cam="):
				_capture_free = true
				_capture_cam = _parse_vec3(a.split("=")[1])
			if a.begins_with("--look="):
				_capture_look = _parse_vec3(a.split("=")[1])
			if a.begins_with("--staff="):
				_capture_staff = a.split("=")[1]
			if a.begins_with("--staffseq="):
				# 一次启动连拍多根法杖（每根 18 帧），省掉反复启动 Godot 的
				# 地形生成开销（单次约 6s，一轮 20 根要跑 20 次太慢）
				_capture_seq = a.split("=")[1].split(",")
			if a.begins_with("--capframes="):
				_capture_frames = maxi(1, int(a.split("=")[1]))
				_capture_start = _capture_frames
			if a.begins_with("--seqstep="):
				_seq_step = maxi(2, int(a.split("=")[1]))
	if "--verify" in OS.get_cmdline_user_args():
		_verify = true
	if "--plantdemo" in OS.get_cmdline_user_args():
		_plant_demo = true
	if "--plant3d" in OS.get_cmdline_user_args():
		_plant3d_demo = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sheet="):
			_plant_sheet = a.split("=")[1]
	if "--staffpanel" in OS.get_cmdline_user_args():
		_staff_panel_demo = true
	if "--staffdemo" in OS.get_cmdline_user_args():
		_staff_demo = true
	if "--staffrun" in OS.get_cmdline_user_args():
		_staff_run_demo = true
	if "--no-veg" in OS.get_cmdline_user_args():
		# 注意：渲染用的 MultiMesh 挂在 Vegetation/Chunk_x_y 下，**不是** Spawned
		# （Spawned 只是烘焙的位置数据）。第一版藏了 Spawned，前后三角面只差 2%，
		# 等于没隔离 —— 要藏的是 Chunk_* 这批块节点。
		var hid := 0
		for c in vegetation.get_children():
			if str(c.name).begins_with("Chunk_"):
				(c as Node3D).visible = false
				hid += 1
		print("Capture | [no-veg] 隐藏了 %d 个植被块（隔离植被开销）" % hid)
	if "--coltest" in OS.get_cmdline_user_args():
		_coltest = true
	# --no-ui 是独立的截图开关，别缩进到上面任何一个 if 里面去
	if "--capture" in OS.get_cmdline_user_args() \
			and "--no-ui" in OS.get_cmdline_user_args():
		ui.visible = false
		_minimap.visible = false

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
	# 雨盒跟随相机
	Weather.follow_camera(camera_rig.camera)
	# 自检模式：等世界和各系统装配完，把关键状态打出来再退出。
	# 放在截图逻辑之前：截图会把 _capture_frames 递减，两者共用一个计数器容易打架。
	if _verify:
		_verify_frame += 1
		# 分两段：装备格互斥的验证里会**换杖**，而 _fx 要等下一帧的 _place_head()
		# 才建出来。同一帧里装备完立刻查 _fx 必然查到 null（第一版就这么误报过 FAIL）。
		if _verify_frame == 40:
			_run_verify()
		elif _verify_frame == 70:
			_run_verify_late()
		elif _verify_frame >= 150:
			# 第 150 帧（约 2.5 秒，远超 0.8 秒的跑步剪辑）再查动画还在不在播
			_verify_anim_loop()
			get_tree().quit()
			return
	# 碰撞流式加载的功能测试（与截图无关，独立跑）
	if _coltest:
		_coltest_frame += 1
		if _coltest_frame == 60:
			_run_coltest_teleport()
		elif _coltest_frame == 300:
			_run_coltest_report()
			get_tree().quit()
			return
	# 连拍模式优先：一次运行内依次装备多根法杖，每根稳定 16 帧后存图
	if _capture_frames > 0 and not _capture_seq.is_empty():
		_run_capture_sequence()
	if _capture_frames == 88 and _capture_staff != "":
		var sys := get_node_or_null("/root/StaffSystem")
		if sys != null:
			sys.call("unlock", _capture_staff)
			sys.call("equip", _capture_staff)
			print("Capture | 已装备法杖 %s" % _capture_staff)
			_dump_staff_state()
	# 临时演示：把两套房屋并排放出来对照（--houses），验收用
	if "--houses" in OS.get_cmdline_user_args() and _capture_frames == 88:
		var base := player.global_position + Vector3(0.0, 0.0, -11.0)
		for i in buildings.house_variant_count():
			var pos := base + Vector3(i * 9.0 - 4.5, 0.0, 0.0)
			buildings.add_house(pos, 1.0, 0.0, i)
		print("Capture | [houses] 已放置 %d 套房屋：%s"
				% [buildings.house_variant_count(), buildings.house_variant_name(0)
				   + " / " + buildings.house_variant_name(1)])
	if "--newmodels" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 验收：把 Tripo 的树各放一棵（走正式放置入口）
		for ti in mini(4, buildings.tree_variant_count()):
			var tp2 := player.global_position + Vector3(-11.0 + ti * 7.5, 0.0, -5.0)
			tp2.y = terrain.get_height_at(tp2.x, tp2.z)
			buildings.add_tree(tp2, 1.0, 0.5, ti)
		print("Capture | [newmodels] 已放置 %d 棵树（变体 %s ...）"
				% [buildings.tree_variant_count(), buildings.tree_variant_name(0)])
	if "--treepaint" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 验收：以程序方式"画"一条树枝笔画（走的是和鼠标拖动同一条函数）
		Game.current_tool = Game.Tool.TREE
		if terrain != null:
			var t3d: Node = terrain._find_terrain3d()
			if t3d != null and t3d.has_method("set_collision_enabled"):
				pass
		_tree_brush_active = true
		_tree_brush_count = 0
		_last_tree_pos = Vector3.INF
		for i in 30:
			var bp := player.global_position + Vector3(-14.0 + i * 1.0, 0.0, -6.0)
			bp.y = terrain.get_height_at(bp.x, bp.z)
			# 模拟"鼠标走到这里"：直接调用笔刷的内部放置逻辑
			if _last_tree_pos == Vector3.INF or bp.distance_to(_last_tree_pos) >= tree_brush_spacing:
				var ang := randf() * TAU
				var rad := sqrt(randf()) * tree_brush_radius
				var q := bp + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
				q.y = terrain.get_height_at(q.x, q.z)
				if not _is_occupied(q):
					buildings.add_tree(q, 1.0 + randf_range(-tree_brush_scale_jitter, tree_brush_scale_jitter),
							randf() * 360.0, _current_variant("tree"))
					_last_tree_pos = bp
					_tree_brush_count += 1
		buildings.flush_all()
		print("TreeBrush | [treepaint] 程序化笔画种了 %d 棵" % _tree_brush_count)
		_tree_brush_active = false
	if "--mapcheck" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 验收小地图朝向：把 yaw 设成 45°，在"镜头正前方"种一棵树。
		# 正确的话，它应该出现在小地图的**上方**（玩家箭头之上）。
		camera_rig.iso_yaw_deg = 45.0
		var mp := player.global_position + Vector3(9.0, 0.0, 9.0)   # yaw45 时镜头朝 (-0.707,0,-0.707)，正前方是 -X-Z
		var fwd := Vector3(-sin(deg_to_rad(45.0)), 0.0, -cos(deg_to_rad(45.0)))
		var tp3 := player.global_position + fwd * 9.0
		tp3.y = terrain.get_height_at(tp3.x, tp3.z)
		buildings.add_tree(tp3, 1.0, 0.0, 0)
		buildings.flush_all()
		print("MapCheck | 已把树种在镜头正前方 %s（小地图上应出现在玩家**上方**）" % str(tp3))
	if "--occl" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 遮挡穿透验收：在**相机与角色之间**放一棵树（相机在角色的 +X +Z 方向）
		var op := player.global_position + Vector3(3.4, 0.0, 3.4)
		op.y = terrain.get_height_at(op.x, op.z)
		buildings.add_tree(op, 1.0, 0.5, 0)
		print("Capture | [occl] 已在相机与角色之间放一棵树（应被淡化）")
	# --probe：每 0.5s 打印角色贴地状态（诊断"掉地底/抖动"用）
	if "--probe" in OS.get_cmdline_user_args():
		_probe_t += delta
		if _probe_t >= 0.5:
			_probe_t = 0.0
			var py := player.global_position
			print("PROBE | y=%.3f on_floor=%s vy=%.2f th=%.3f mask=%d" % [
					py.y, str(player.is_on_floor()), player.velocity.y,
					terrain.get_height_at(py.x, py.z), player.collision_mask])
			var t3 := terrain._find_terrain3d()
			if t3 != null:
				terrain._configure_terrain3d(t3)

			if t3 != null:
				print("PROBE3D | collision=%s layer=%d mask=%d mode=%s regions=%s" % [
						str(t3.get("collision")), int(t3.get("collision_layer")),
						int(t3.get("collision_mask")), str(t3.get("collision_mode")),
						str(t3.call("get_region_count") if t3.has_method("get_region_count") else -1)])
	if _capture_frames > 0:
		_apply_capture_view()
		_capture_frames -= 1
		if _capture_frames == 0:
			_save_capture("user://screenshot_check.png")
			get_tree().quit()


## 连拍：--staffseq=a,b,c  每根法杖占 SEQ_STEP 帧
func _run_capture_sequence() -> void:
	var elapsed := _capture_start - _capture_frames
	var idx := elapsed / _seq_step
	if idx >= _capture_seq.size():
		return
	if idx != _seq_idx:
		_seq_idx = idx
		var sys := get_node_or_null("/root/StaffSystem")
		if sys != null:
			sys.call("unlock", _capture_seq[idx])
			sys.call("equip", _capture_seq[idx])
			print("Capture | 已装备法杖 %s" % _capture_seq[idx])
	if elapsed % _seq_step == _seq_step - 2:
		var path := "user://screenshot_check.png"
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--out="):
				path = "user://%s" % a.split("=")[1]
		var dot := path.rfind(".")
		var out := ("%s_%s%s" % [path.substr(0, dot), _capture_seq[idx],
				path.substr(dot)]) if dot > 0 else "%s_%s" % [path, _capture_seq[idx]]
		_save_capture(out)


## 诊断：手持法杖到底挂在什么尺寸/朝向上（截图/排查用）
func _dump_staff_state() -> void:
	var hs = player.get("held_staff")
	if hs == null:
		print("StaffDump | held_staff 为空（没挂上）")
		return
	var d: Dictionary = hs.call("debug_info")
	print("StaffDump | %s" % JSON.stringify(d))

func _save_capture(out_path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("Capture | 取帧失败 %s" % out_path)
		return
	var err := img.save_png(out_path)
	print("Capture | 已保存 %s err=%d abs=%s"
			% [out_path, err, ProjectSettings.globalize_path(out_path)])
	# 植被换成自制模型之后，"一帧画多少三角面"必须能直接读出来 ——
	# 密度（PLANT_KEEP）就是照这个数调的，靠目测帧率太不稳。
	print("Input | mouse_mode=%d（0=可见 2=捕获）captured=%s 工具=%s 放置点=%s"
			% [Input.mouse_mode, str(camera_rig.is_mouse_captured()),
			   str(Game.current_tool), str(_get_ground_pos())])
	print("Perf | 三角面=%d 绘制调用=%d 渲染物件=%d FPS=%.1f"
			% [RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			   RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			   RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
			   Performance.get_monitor(Performance.TIME_FPS)])

## --verify：无人值守自检。
##
## 把法杖系统 / 装备格 / 手持模型 / 长老系统的关键状态打到 stdout。
## 存在的理由：MCP 的 game_eval 需要游戏窗口**有焦点**才能推进主循环，
## 而后台跑 CI / 截图时窗口一定是失焦的（实测反复 AppActivate 也不稳）。
## 这条路径只依赖 stdout，headless 也能跑：
##     godot --headless --path . -- --verify
func _run_verify() -> void:
	print("Verify | ==== Cozy Vale 自检 ====")
	print("Verify | 法杖/植物建模已整体移除，这部分自检项不再适用")


## 自检的第二段
func _run_verify_late() -> void:
	print("Verify | ==== 自检结束 ====")












## 把 defs 里的元素全部还原成登记时的基准值（自检里抹内存态用）
func _reset_def_elements(sys: Node, ids: Array) -> void:
	var base: Dictionary = sys.get("base_element")
	for i in ids:
		var d: Dictionary = sys.call("get_def", str(i))
		d["element"] = int(base.get(str(i), 0))














## 「跑一段后动画静止」的回归测试。
##
## 真因：Mage.glb 导进来的 76 个动画 + kaykit 库那 12 个，`loop_mode` **全是
## LOOP_NONE**。Running_A 只有 0.8 秒，播完 AnimationPlayer 就停住，角色定格在
## 最后一帧 —— 表现就是"跑一段就静止"，时长和剪辑长度完全对得上。
## 修法是 player._ensure_loop_anims() 把该循环的剪辑设成 LOOP_LINEAR。
##
## 这里做两个断言：(1) 白名单里的剪辑都得是循环；(2) 启动约 2.5 秒后动画仍在播。
func _verify_anim_loop() -> void:
	var ap: AnimationPlayer = player.anim_player
	if ap == null:
		print("Verify | [FAIL] 角色没有 AnimationPlayer")
		return
	var bad := PackedStringArray()
	for n in player.LOOP_CLIPS:
		if not ap.has_animation(n):
			continue
		if ap.get_animation(n).loop_mode != Animation.LOOP_LINEAR:
			bad.append(n)
	print("Verify | 应循环的剪辑 %d 个，仍不是循环的：%s"
			% [player.LOOP_CLIPS.size(),
			   ("无" if bad.is_empty() else ", ".join(bad))])
	var cur := str(ap.current_animation)
	var playing := ap.is_playing()
	print("Verify | 启动约 2.5 秒后：当前剪辑=%s 播放中=%s 位置=%.3f"
			% [cur, str(playing), ap.current_animation_position])
	var ok := bad.is_empty() and playing
	print("Verify | %s 移动/待机剪辑会一直循环（不再播完就定格）"
			% ["[OK]" if ok else "[FAIL]"])


func sys_elem_name(e: int) -> String:
	var sys := get_node_or_null("/root/StaffSystem")
	if sys == null:
		return "?"
	return str(sys.call("element_name", e))











## --coltest：把玩家瞬移到世界另一端，等若干帧后统计"碰撞半径内还有多少实例没建碰撞体"。
## 这是"远处物体碰撞失效"的直接判据 —— 不用走过去，也不靠肉眼看。
func _run_coltest_teleport() -> void:
	var target := Vector3(252.0, 0.0, 64.0)     # 村庄（远离出生点）
	if terrain != null and terrain.has_method("get_height_at"):
		target.y = terrain.get_height_at(target.x, target.z)
	player.global_position = target
	print("ColTest | 瞬移到 (%.0f, %.1f, %.0f)" % [target.x, target.y, target.z])


func _run_coltest_report() -> void:
	var anchor: Vector3 = vegetation.call("_collision_anchor")
	var rad := float(vegetation.get("collision_radius"))
	var r2 := rad * rad
	var blocks: Array = vegetation.get("_blocks")
	var need := 0
	var have := 0
	var missing_near := 0
	var missing_far := 0
	var pend: Array = vegetation.get("_pending_blocks")
	for b in blocks:
		var q: Array = b["col_queue"]
		var bodies: Array = b["col_bodies"]
		for i in q.size():
			var pos: Vector3 = (q[i] as Dictionary)["pos"]
			var dx := pos.x - anchor.x
			var dz := pos.z - anchor.z
			var near := (dx * dx + dz * dz) <= r2
			var has := i < bodies.size() and is_instance_valid(bodies[i])
			if near:
				need += 1
				if has:
					have += 1
				else:
					missing_near += 1
			elif not has:
				missing_far += 1
	print("ColTest | 锚点=(%.0f, %.0f) 半径=%.0f 待办块=%d" % [anchor.x, anchor.z, rad, pend.size()])
	print("ColTest | 半径内应建 %d，已建 %d，**缺 %d**；半径外未建 %d（正常）"
			% [need, have, missing_near, missing_far])
	print("ColTest | %s 半径内实例碰撞齐全" % ["[OK]" if missing_near == 0 else "[FAIL]"])




## 解析 --cam=x,y,z / --look=x,y,z
func _parse_vec3(t: String) -> Vector3:
	var p: PackedStringArray = t.split(",")
	if p.size() < 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


## 调试截图：俯视全景（--aerial）或自由机位（--cam/--look）
func _apply_capture_view() -> void:
	if not _capture_aerial and not _capture_free:
		return
	camera_rig.interact_freeze = true
	if _capture_aerial:
		camera.global_position = Vector3(0.0, 430.0, 480.0)
		camera.look_at(Vector3(0.0, 0.0, 40.0), Vector3.UP)
		camera.fov = 58.0
	else:
		camera.global_position = _capture_cam
		# 不给 --look 就**自动对准角色**：角色的落地高度是物理结算出来的，
		# 手填的注视点十有八九对不上（实测差 1.8m，整根杖跑到画面外）。
		var tgt := _capture_look
		if _capture_look == Vector3.ZERO or _capture_look == _capture_cam:
			tgt = player.global_position + Vector3(0.0, 0.95, 0.0)
		camera.look_at(tgt, Vector3.UP)


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
	# 房屋有多套（红顶小屋 / 茅草屋），各自自带基准缩放，见 building_manager.HOUSE_MODELS
	house_mi.mesh = _extract_mesh_merged(buildings.house_scene_at())
	house_mi.scale = Vector3.ONE * buildings.house_base_scale()
	preview_place.add_child(house_mi)
	# 树/花预览：花草树木的整体移除后分类表是空的，`category_model_path()` 会返回 ""，
	# 直接 `load("")` 会在启动时报 `Resource file not found: res://`（实测两条）。
	# 所以这里按"有模型才建预览"处理，新模型做好后自动恢复。
	# 树木预览：由 buildings.tree_scene_at() 提供（图表当前为空 -> tsc==null -> 不建预览）。
	# 接入 Tripo 模型后这里自动生效，不用改。

	_add_plant_preview(preview_place, "FlowerPreview", "flower", 1.1)
	# 家具预览：真实家具模型半透明（scale 与放置一致）
	var furniture_mi := MeshInstance3D.new()
	furniture_mi.name = "FurniturePreview"
	furniture_mi.mesh = _extract_mesh(load(VegetationSystem.FURNITURE_MODELS[0]))
	# 参天大树预览：用 building_manager 的树场景（多材质，和实际放置同一个模型）
	var tree_mi := MeshInstance3D.new()
	tree_mi.name = "TreePreview"
	var tsc := buildings.tree_scene_at()
	if tsc != null:
		tree_mi.mesh = _extract_mesh_merged(tsc)
		tree_mi.scale = Vector3.ONE * buildings.tree_base_scale()
	preview_place.add_child(tree_mi)
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
		if event.keycode == KEY_V:
			_cycle_weather()
			return

	# 鼠标现在默认可见（俯视角不捕获光标），所以不再用"是否捕获"当作放入口开关；
	# 点在哪就放在哪。UI 上的点击会被 Control 消费掉，不会走到 _unhandled_input。
	if event is InputEventMouseButton:
		# 滚轮：**没选任何放置工具时用来缩放场景**（用户要求 75%~200%）；
		# 选了工具才是切模型变体。
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and not (Game.current_tool in _place_tools):
			# 方向：**滚轮上 = 拉近（视野变小 / 百分比变小）**，滚轮下 = 拉远。
			# 上一版写反了（上=拉远），用户实测反馈"滚轮缩放视角弄反了"。
			# 注意 zoom_by 的语义是 dir=+1 拉远，所以这里要取反。
			var dz := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			if camera_rig.zoom_by(dz):
				ui.show_interact_hint("视野 %.0f%%（滚轮缩放，75%%~200%%）"
						% (camera_rig.iso_zoom * 100.0))
				_variant_hint_time = 1.2
			return
		# 滚轮：切换当前放置工具的模型变体（分类下有多个模型时）
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and Game.current_tool in _place_tools:
			_cycle_variant(-1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1)
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and Game.current_tool in _place_tools:
			_place_yaw += deg_to_rad(10.0)
			return
		# 未选任何工具时：**右键按住拖动旋转场景**（俯视角的 yaw/pitch 都是常量，
		# 所以旋转就是改那两个常量）。小地图跟着转、大地图不转，见 minimap.gd。
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = event.pressed
			# 拖动旋转期间**隐藏并锁住光标**：否则鼠标一划就移出窗口，
			# 旋转会突然中断、指针也跑到别的窗口上去（用户实测）。
			# 松开立刻恢复可见 —— 俯视角平时就是要点鼠标的。
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _rotating \
					else Input.MOUSE_MODE_VISIBLE
			return
		# 左键：开始/结束放置。
		# **这两行必须留在"鼠标按钮"分支里面**：上一版我把右键旋转的
		# `if event is InputEventMouseMotion` 块按 1 层缩进插到了这里，
		# 它带着一个 `return` 把整个鼠标按钮分支截断，于是左键放置变成了
		# 运动事件分支里的死代码 —— 表现就是"完全无法放置物品"（用户实测）。
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_begin_tool()
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_tool()
		return
	# 树木笔刷：按住左键拖动时，每走够 spacing 就再种一棵
	if event is InputEventMouseMotion and _tree_brush_active:
		_paint_tree_stroke()
		return
	if event is InputEventMouseMotion and _rotating and not (Game.current_tool in _place_tools):
		# 右键拖动**只做水平旋转**（绕 Y 轴），俯仰角锁定不动。
		# 用户要求："按住鼠标右键只可以旋转场景，但锁定y"。
		# 俯角仍由 camera_rig.iso_pitch_deg 决定（默认 52°），不再被鼠标改。
		camera_rig.iso_yaw_deg = fposmod(camera_rig.iso_yaw_deg
				- event.relative.x * 0.28, 360.0)

## V 键：按顺序切换天气（晴朗 → 多云 → 阴天 → 小雨 → 雷雨 → 大风）
## 切换立即生效（force），并暂停自动天气一段时间，方便观察风摇效果。
## 换杖 / 收杖时的屏幕提示。
##
## `game_ui._on_staff_picked()` 是用 `main.call("_show_staff_hint", id)` 调的 ——
## 这个函数在第 38 轮"整体移除法杖系统"时被删掉了，但那种**字符串形式**的调用
## 没被当时的检查脚本扫出来（它只扫 `xxx.method(` 的直接调用），
## 于是点装备面板里任何一行（包括"空手（收起法杖）"）都会抛
## `Invalid call. Nonexistent function '_show_staff_hint'` 并把游戏中断（用户实测）。
func _show_staff_hint(id: String) -> void:
	if ui == null:
		return
	var sys := get_node_or_null("/root/StaffSystem")
	if id == "":
		ui.show_interact_hint("法杖已收起")
	else:
		var nm := id
		var el := 0
		var el_name := "-"
		if sys != null:
			nm = str(sys.call("display_name", id))
			el = int(sys.call("element_of", id))
			el_name = str(sys.call("element_name", el))
		ui.show_interact_hint("%s · %s（Q / Shift+滚轮 换杖）" % [nm, el_name])
	_variant_hint_time = 1.6


func _cycle_weather() -> void:
	var n := Weather.KIND_NAMES.size()
	var next: int = (Weather.target + 1) % n
	Weather.set_weather(next, true)
	ui.show_interact_hint("天气：%s · 风力 %.2f · 风向 %s"
		% [Weather.weather_name(), Weather.wind, str(Weather.wind_dir)])
	_variant_hint_time = 1.6
	print("Weather | 手动切换 -> %s (wind=%.2f)" % [Weather.weather_name(), Weather.wind])





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
	# **以鼠标为中心**（原来是屏幕正中准星）：俯视角 + 自由鼠标下，准星在屏幕中间
	# 根本指不到想放的地方。
	return camera_rig.get_ground_point_mouse(terrain)

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
			buildings.add_house(p, 1.0, _place_yaw, buildings.house_variant)
			buildings.flush_all()
			player.play_cast_gesture()
		Game.Tool.TREE:
			# TREE_MODELS 为空（等 Tripo 模型）时什么都不做，也不会误回收植被
			if buildings.tree_variant_count() == 0:
				return
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			# 传入滚轮选中的变体；Placement 与半透明预览保证是同一个模型
			# 不再额外抬高：重定位偏移已保证模型底面落在放置点上
			# 3.4：KayKit 树原生约 1.2~1.7m，乘完约 4~6m，与"树是角色 2.5~5 倍高"一致
			buildings.add_tree(p, 1.0, _place_yaw, _current_variant("tree"))
			# 进入"笔刷"状态：接下来拖动鼠标会沿笔迹继续种
			_tree_brush_active = true
			_tree_brush_count = 1
			_last_tree_pos = p
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


## 树木笔刷：在鼠标当前位置种一棵（若离上一棵够远），带随机偏移/朝向/尺寸。
func _paint_tree_stroke() -> void:
	if not _tree_brush_active:
		return
	if Game.current_tool != Game.Tool.TREE or buildings.tree_variant_count() == 0:
		_tree_brush_active = false
		return
	if _tree_brush_count >= tree_brush_max_per_stroke:
		return
	var p: Variant = _get_ground_pos()
	if p == null:
		return
	var pp := p as Vector3
	if _last_tree_pos != Vector3.INF and pp.distance_to(_last_tree_pos) < tree_brush_spacing:
		return                      # 还没走够间距，等鼠标再走一点
	# 在放置点周围抖一下，避免排成一条直线
	var ang := randf() * TAU
	var rad := sqrt(randf()) * tree_brush_radius
	var q := pp + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	q.y = terrain.get_height_at(q.x, q.z)
	if _is_occupied(q):
		return
	_recycle_vegetation(q, PLACE_RECYCLE_RADIUS)
	var sc := 1.0 + randf_range(-tree_brush_scale_jitter, tree_brush_scale_jitter)
	var yaw := randf() * 360.0
	buildings.add_tree(q, sc, yaw, _current_variant("tree"))
	_last_tree_pos = pp
	_tree_brush_count += 1

func _end_tool() -> void:
	# 收笔：无论是否拖动过，都要退出笔刷状态
	if _tree_brush_active:
		_tree_brush_active = false
		_last_tree_pos = Vector3.INF
		buildings.flush_all()
		print("TreeBrush | 本次笔画种了 %d 棵树" % _tree_brush_count)
		_tree_brush_count = 0
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
	# 房屋工具用的是 building_manager 自己的房屋表，不归植被分类管
	if Game.current_tool == Game.Tool.ROOF:
		var hi := buildings.cycle_house_variant(dir)
		_update_house_preview()
		ui.show_interact_hint("房屋 %d/%d · %s" % [hi + 1,
				buildings.house_variant_count(), buildings.house_variant_name()])
		_variant_hint_time = 1.6
		return
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


## 建一个"真实模型半透明"的放置预览。分类表为空（植物已移除）时**不建**，
## 免得 `load("")` 报 res:// 找不到。
func _add_plant_preview(parent: Node3D, node_name: String, cat: String, scale: float) -> void:
	var path := vegetation.category_model_path(cat, 0)
	if path.is_empty():
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _extract_mesh(load(path))
	mi.scale = Vector3.ONE * scale
	parent.add_child(mi)

## 按分类取模型文件名（不含扩展名），用于提示
func _model_basename(cat: String, variant: int) -> String:
	return vegetation.category_model_path(cat, variant).get_file().get_basename()


## 把预览网格换成当前变体的真实模型（保留场景里那套半透明材质）
## 换房屋变体后立刻换预览网格（半透明材质与缩放都要跟着换）
func _update_house_preview() -> void:
	var node := preview_place.get_node_or_null("HousePreview") as MeshInstance3D
	if node == null:
		return
	var sc := buildings.house_scene_at()
	if sc == null:
		return
	var mesh := _extract_mesh_merged(sc)
	if mesh != null:
		node.mesh = mesh
	node.scale = Vector3.ONE * buildings.house_base_scale()
	_apply_place_material(node, PREVIEW_PLACE_OK)


func _set_place_preview_mesh(cat: String) -> void:
	var node := _preview_for_tool(Game.current_tool)
	if node == null:
		return
	_apply_preview_offset(node, cat)
	var mesh: Mesh = vegetation.category_model_mesh(cat, _current_variant(cat))
	if mesh != null:
		node.mesh = mesh
	var base := _preview_base_scale_for(cat)
	if base > 0.0:
		node.scale = Vector3.ONE * base
	# 换模型后立刻把半透明材质挂回去，不等下一帧的落点更新
	node.material_override = PREVIEW_PLACE_OK
	_apply_place_material(node, PREVIEW_PLACE_OK)


## 预览缩放：分类基准缩放。
##
## 原来这里有一句 `if vegetation.is_plant_extra(...): return 1.0` —— 植物系统整体移除时
## 那个函数被删了，但这句调用漏了。后果：**任何放置工具滚轮换模型时都会抛
## "Invalid call. Nonexistent function 'is_plant_extra'"**，在编辑器里直接中断游戏
## （用户反馈的"放置家具时程序中断"）。植物以后要重做的话，这条分支应该加回来，
## 但判据要换成"这个模型是不是按真实尺寸建的"（可以查分类表的 base_scale），
## 不要再依赖植物专属接口。
func _preview_base_scale_for(cat: String) -> float:
	match cat:
		"tree": return 1.0
		"flower": return 1.1
		"furniture": return 1.0
		"mountain": return 4.0
	return -1.0


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
## 把整棵子树的网格合并成一个（**预览用**）。
##
## `_extract_mesh()` 只取**第一个**子网格：KayKit 的房子整栋就是一个网格，所以一直没问题；
## 自制茅草屋有 205 个部件，只取第一个的话预览里就显示成一个木桶（用户实测反馈"预览怎么是个桶"）。
## 合并结果缓存：key = PackedScene 的 resource_path。
## 茅草屋有 213 个部件、GLB 31MB，滚轮切换时每次都重新合并会明显卡一下（用户实测）。
var _merged_mesh_cache := {}


func _extract_mesh_merged(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var key := scene.resource_path
	if not key.is_empty() and _merged_mesh_cache.has(key):
		return _merged_mesh_cache[key]
	var inst := scene.instantiate()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _transform_relative_to(mi, inst)
		for s in mi.mesh.get_surface_count():
			st.append_from(mi.mesh, s, xf)
			any = true
	inst.free()
	var merged: Mesh = st.commit() if any else null
	if not key.is_empty():
		_merged_mesh_cache[key] = merged
	return merged


## node 相对 root 的局部累积变换（不用 global_transform：那是惰性求值的）
func _transform_relative_to(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D()
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


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
	# 只查"贴地那一圈"的**矮圆柱**。原实现是球体，屋檐 / 树冠这些**悬在上方**的
	# 几何也会被算成占位 -> 墙根下、大树下都放不了花草（用户实测就是这个）。
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = PLACE_OCCUPY_RADIUS
	shape.height = PLACE_OCCUPY_HEIGHT
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY,
			p + Vector3(0, PLACE_OCCUPY_HEIGHT * 0.5, 0))
	params.collision_mask = 4
	var hits := space.intersect_shape(params, 8)
	if not hits.is_empty():
		return true
	# 与角色自身碰撞：会插进身体的不允许放置
	if player != null:
		var d := Vector2(p.x - player.global_position.x,
				p.z - player.global_position.z).length()
		if d < PLACE_PLAYER_CLEAR:
			return true
	return false

## UI 回调：切换工具
func set_tool(tool: int) -> void:
	Game.current_tool = tool
	# 关掉创建菜单回滚工具时，半透明预览也要立刻消失（"销毁还没放置的物品"）
	if not (tool in _place_tools):
		preview_place.visible = false
	_is_dragging = false
	_place_yaw = 0.0
	preview_wall.visible = false
	preview_roof.visible = false
	preview_place.visible = false

## UI 回调：撤销
func undo() -> void:
	buildings.undo()
