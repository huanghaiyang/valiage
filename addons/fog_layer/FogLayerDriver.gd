@tool
@icon("res://addons/fog_layer/CloudsDriverIcon.svg")
extends Node
class_name FogLayerDriver

@export var update_continuously: bool = false:
	get:
		return update_continuously
	set(value):
		update_continuously = value
		retrieve_texture_data()

@export_tool_button("生成雾资源（新建一份）", "Add") var generate_action = build_new_clouds
#@export_tool_button("Test Clouds Position Sample", "Add") var position_sample = sample_clouds


@export_group("合成器资源")
@export var clouds_resource: FogLayerEffect:
	get:
		return clouds_resource
	set(value):
		clouds_res_removed()
		clouds_resource = value
		clouds_res_added()
@export_group("可选世界环境")
@export var ambience_sample_environment: Environment
@export_group("光照控制")
@export var tracked_directional_lights: Array[DirectionalLight3D] = []:
	get:
		return tracked_directional_lights
	set(value):
		tracked_directional_lights = value
		retrieve_texture_data()

@export var tracked_directional_light_shadow_steps: Array[int] = []:
	get:
		return tracked_directional_light_shadow_steps
	set(value):
		tracked_directional_light_shadow_steps = value
		retrieve_texture_data()

@export var tracked_point_lights: Array[OmniLight3D] = []:
	get:
		return tracked_point_lights
	set(value):
		tracked_point_lights = value
		retrieve_texture_data()

@export var tracked_point_effectors: Array[FogLayerEffector] = []:
	get:
		return tracked_point_effectors
	set(value):
		tracked_point_effectors = value
		retrieve_texture_data()

@export var directional_light_power_multiplier: float = 1.0
@export var point_light_power_multiplier: float = 1.0
# ★★ 转发属性：直接在本节点上就能调（值存在 clouds_resource 上）★★
#   为什么加：这两个旋钮原本只存在于"雾资源"里，必须点进 Clouds Resource 才看得到。
@export_range(0.0, 100.0, 0.01) var fog_base_height : float = 0.1:
	get:
		if clouds_resource != null:
			return clouds_resource.fog_base_height
		return 0.1
	set(value):
		if clouds_resource != null:
			clouds_resource.fog_base_height = value
			clouds_resource._sync_fog_layer()

@export_range(0.1, 100.0, 0.05) var fog_thickness : float = 1.2:
	get:
		if clouds_resource != null:
			return clouds_resource.fog_thickness
		return 1.2
	set(value):
		if clouds_resource != null:
			clouds_resource.fog_thickness = value
			clouds_resource._sync_fog_layer()

# ==================== 天气接线 ====================
# ★ 本项目已有 /root/Weather（风场/植被/雾都在读它的 wind_dir / wind / fog），这里同样接上：
#   天气的"雾量" -> 雾浓度；天气的"风" -> 四层结构风速与风向（雾会随之飘）
@export var auto_weather : bool = true
## weather.wind = 1.0 对应的风速（m/s），与 fog_field.gd 保持一致
@export var wind_speed_mps : float = 4.0
## 晴天底雾系数：Clear 天气也留一层薄雾（0 = 完全跟随天气）
@export_range(0.0, 2.0, 0.01) var idle_density : float = 0.35
## 天气"雾量"= 1.0 时的浓度基准
@export_range(0.0, 2.0, 0.01) var base_density : float = 1.0

@export_group("风控制")
@export var origin_offset : Vector3 = Vector3.ZERO
@export var wind_direction: Vector3 = Vector3(1.0, 0.0, 1.0)
@export var extra_large_structures_wind_speed: float = 2.5
@export var large_structures_wind_speed: float = 1.8
@export var medium_structures_wind_speed: float = 1.0
@export var small_structures_wind_speed: float = 0.5
## 掩码文件目录：每个场景一份 PNG（`<场景名>.png`），互不影响
## ★★ 掩码资源（每场景一份 .tres）★★ 直接引用 ⇒ 游戏里不用按名字找文件，绝不会错位。
##   在编辑器里画一笔会自动创建并写盘；之后只要保存场景，游戏就用到它。
## ★ 本节点的掩码 id（存进场景；**节点改名不变**）★★
##   掩码文件名 = <mask_id>_fogmask.tres ⇒ 每节点唯一、改名不换文件、多个 driver 不互相覆盖。
@export var mask_id : String = ""
@export var mask_resource : FogMaskResource = null
## 兼容用：没有掩码资源时，回退按 <场景名>.png 找
@export_dir var mask_dir : String = "res://data/fog_masks"

@export_group("内部使用")
var extra_large_clouds_pos: Vector3 = Vector3.ZERO
var large_clouds_pos: Vector3 = Vector3.ZERO
var medium_clouds_pos: Vector3 = Vector3.ZERO
var small_clouds_pos: Vector3 = Vector3.ZERO

var _extralarge_clouds_domain: float = 0.0
var _large_clouds_domain: float = 0.0
var _medium_clouds_domain: float = 0.0
var _small_clouds_domain: float = 0.0

var _updating_settings: bool = false

# --- Multi-threaded rendering fix (thread_model = 2) --------------------------
# clouds_resource IS the compositor effect: its fields are written here from
# _process (main thread) and read in _render_callback (render thread). In Safe
# mode that is the same thread and all is well; in threaded mode, the clear()
# followed by the append()s in retrieve_texture_data opened a window where the
# render thread could read an EMPTY light array — black clouds with a fringe
# along the edge of the geometry.
#
# Fix: build the arrays in locals (node access has to stay on the main thread),
# then hand them over to the effect from the render thread. The swap is thereby
# serialised against _render_callback. In Safe mode call_on_render_thread runs
# immediately: behaviour unchanged.
#
# The copies below are what _process compares against, so the main thread never
# reads clouds_resource's arrays at all.
var _dir_data_cache : Array[Vector4] = []
var _point_data_cache : Array[Vector4] = []
var _effector_data_cache : Array[Vector4] = []

func _apply_lights_data(dir_data : Array[Vector4], point_data : Array[Vector4], effector_data : Array[Vector4]):
	if clouds_resource == null:
		return
	clouds_resource.directional_lights_data = dir_data
	clouds_resource.point_lights_data = point_data
	clouds_resource.point_effector_data = effector_data
	clouds_resource.lights_updated = true

var _weather : Node = null
## 这个 Compositor 是本驱动建的（删除节点时应当一并撤掉）
var _created_compositor : bool = false
var _w_cached_dir := Vector2(2.0, 2.0)   # 缓存：只有天气真的变了才写属性（每帧写会触发重建/卡顿）
var _w_cached_speed := -1.0


## 把掩码推给渲染侧：**只认掩码资源**（直接引用），不看路径、不猜场景名。
## 自动认领本场景的掩码资源：在 mask_dir 里找"以本场景名开头"的 *_fogmask.tres，**唯一匹配**才认领。
##   为什么需要：文件名只在首次创建时按节点路径生成，之后靠场景里的引用（节点改名不受影响）。
##   但引用丢失（手改场景、误删引用、旧版本数据）时，这一层能把笔迹自动接回来。
## 确保本节点有掩码 id（没有就生成一个并存进场景；由落笔/_ready 调用）
func ensure_mask_id() -> String:
	if mask_id == "":
		mask_id = "%08x%08x" % [Time.get_ticks_usec() & 0xFFFFFFFF, randi() & 0xFFFFFFFF]
	return mask_id


## 本节点的掩码文件路径：mask_dir/<mask_id>_fogmask.tres
func mask_file_path() -> String:
	var base : String = mask_dir if mask_dir != "" else "res://data/fog_masks"
	return base.path_join(ensure_mask_id() + "_fogmask.tres")

## 内嵌掩码资源 ⇒ 自动迁移成文件（禁止把图片数据留在 .tscn 里）。
##   触发条件：mask_resource 存在但 resource_path == ""（= 它被当作场景内嵌资源）。
##   处理：写到 mask_dir/<mask_id>_fogmask.tres，然后重新挂载（此后场景只存引用）。
## 本节点的 effect 文件路径（与掩码同一目录）：用于把"还没写盘的新资源"先落盘，
##   否则第一次 Ctrl+S 会把它**内嵌进 .tscn**（场景体积暴涨 / 之后每次保存都带着）。
func effect_file_path() -> String:
	var base : String = mask_dir if mask_dir != "" else "res://data/fog_masks"
	return base.path_join(ensure_mask_id() + "_effect.tres")


## 编辑器专用：如果 clouds_resource 还没写盘（新建的），先写盘避免被内嵌进场景。
func _ensure_effect_on_disk() -> void:
	if not Engine.is_editor_hint():
		return
	if clouds_resource == null or clouds_resource.resource_path != "":
		return
	var base : String = mask_dir if mask_dir != "" else "res://data/fog_masks"
	if not DirAccess.dir_exists_absolute(base):
		DirAccess.make_dir_recursive_absolute(base)
	var p : String = effect_file_path()
	var err := ResourceSaver.save(clouds_resource, p)
	if err == OK:
		print("FogLayerDriver: 新 effect 已写盘 %s（避免第一次 Ctrl+S 内嵌进场景）" % p)
	else:
		printerr("FogLayerDriver: 新 effect 写盘失败（err=%d）⇒ 保存场景时可能被内嵌" % err)

func _migrate_inline_mask() -> void:
	if mask_resource == null or mask_resource.resource_path != "":
		return
	var base : String = mask_dir if mask_dir != "" else "res://data/fog_masks"
	if not DirAccess.dir_exists_absolute(base):
		DirAccess.make_dir_recursive_absolute(base)
	var p : String = mask_file_path()
	var err := ResourceSaver.save(mask_resource, p)
	if err == OK:
		mask_resource.resource_local_to_scene = false
		print("FogLayerDriver: 已把内嵌掩码资源迁移为文件 %s（避免图片数据留在 .tscn 里）" % p)
	else:
		printerr("FogLayerDriver: 内嵌掩码资源迁移失败（err=%d）" % err)

func _find_scene_mask_resource() -> FogMaskResource:
	var base : String = mask_dir if mask_dir != "" else "res://data/fog_masks"
	var dir := DirAccess.open(base)
	if dir == null:
		return null
	var scene_name := ""
	if is_inside_tree() and get_tree() != null:
		if get_tree().current_scene != null:
			scene_name = get_tree().current_scene.name
		elif get_tree().edited_scene_root != null:
			scene_name = get_tree().edited_scene_root.name
	# ★ 首选：按本节点 id 精确匹配（改名也不变）
	var own : String = base.path_join(ensure_mask_id() + "_fogmask.tres")
	if FileAccess.file_exists(own):
		return ResourceLoader.load(own) as FogMaskResource
	# 兼容旧数据：按 <场景名>_ 前缀，唯一匹配才认领
	var matches : Array[String] = []
	for f in dir.get_files():
		if f.ends_with("_fogmask.tres") and (scene_name == "" or f.begins_with(scene_name + "_")):
			matches.append(base.path_join(f))
	if matches.size() != 1:
		return null
	return ResourceLoader.load(matches[0]) as FogMaskResource

func _setup_mask_path() -> void:
	if clouds_resource == null:
		return
	_migrate_inline_mask()   # ★ 内嵌资源先迁移成文件（禁止把图片数据留在场景里）
	if mask_resource == null or mask_resource.mask == null:
		var found : FogMaskResource = _find_scene_mask_resource()
		if found != null:
			mask_resource = found
			print("FogLayerDriver: 已自动认领掩码资源 %s（节点改名/引用丢失后也能接回笔迹）" % found.resource_path)
	if mask_resource != null and mask_resource.mask != null:
		clouds_resource.reload_mask_from_image(mask_resource.mask)
		print("FogLayerDriver: 使用掩码资源（%dx%d）" % [mask_resource.mask.get_width(), mask_resource.mask.get_height()])
		return
	printerr("FogLayerDriver: Mask Resource 为空 ⇒ 没有雾（在编辑器里画一笔会自动创建并写盘）")


## 节点被移除时只**提示**，不自动删文件。
##   原因：NOTIFICATION_PREDELETE / _exit_tree 在"用户删节点"、"关闭/切换场景"、"关编辑器"
##   时都会触发 ⇒ 自动删文件会在切换场景时把你的笔迹删掉，且不可撤销。
##   清理请用面板上的【清理未使用的掩码资源】（移入 _trash/，可恢复）。
func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		return
	# ★ 只在"节点被从**活动**场景里移除"时清理；切换/关闭场景时不碰（避免误改别的场景）
	var p := get_parent()
	if p != null and p.is_inside_tree():
		_release_fog_scene_resources()
	if mask_resource != null and mask_resource.resource_path != "":
		print("FogLayerDriver: 掩码资源仍保留在 %s（用面板【清理未使用的掩码资源】可回收）" % mask_resource.resource_path)


## 撤掉本驱动加进场景的东西：
##   · 从 WorldEnvironment 的 Compositor 里移除雾 effect
##   · 若这个 Compositor 是**本驱动创建的**、且移除后已没有其它 effect ⇒ 连同 Compositor 一起移除
##   · 释放 clouds_resource 引用 ⇒ 内嵌的 effect 资源不再被场景保留
func _release_fog_scene_resources() -> void:
	if not is_inside_tree():
		return
	var env : WorldEnvironment = recursively_find_env(get_tree().root)
	if env == null:
		return
	if env.compositor != null:
		var effects : Array[CompositorEffect] = []
		for e in env.compositor.compositor_effects:
			if clouds_resource != null and e == clouds_resource:
				continue
			effects.append(e)
		env.compositor.compositor_effects = effects
		if _created_compositor and effects.is_empty():
			env.compositor = null
			_created_compositor = false
			print("FogLayerDriver: 已移除本驱动创建的 Compositor（含其中 effect）")
		else:
			print("FogLayerDriver: 已从 Compositor 移除雾 effect（Compositor 与其它 effect 保留）")
	clouds_resource = null      # 释放引用 ⇒ 内嵌 effect 资源不再被场景保存

func _bind_weather() -> void:
	_setup_mask_path()
	_weather = get_node_or_null("/root/Weather")
	if _weather == null:
		print("FogLayerDriver: 没有 /root/Weather，天气接线跳过")


## 每帧读天气：雾量 -> 浓度；风 -> 风向与四层风速
func _apply_weather() -> void:
	if _weather == null or not auto_weather or clouds_resource == null:
		return
	var wd = _weather.get("wind_dir")
	var wind_amount : float = float(_weather.get("wind"))
	var fog_amount : float = clampf(float(_weather.get("fog")), 0.0, 1.0)
	var speed : float = maxf(wind_amount * wind_speed_mps, 0.0)
	var dir2 := Vector2(wd.x, wd.y) if wd is Vector2 else Vector2.ZERO
	if dir2.is_equal_approx(_w_cached_dir) and is_equal_approx(speed, _w_cached_speed):
		return                      # ★ 天气没变 ⇒ 什么都不写（避免每帧触发重建）
	_w_cached_dir = dir2
	_w_cached_speed = speed
	if wd is Vector2:
		wind_direction = Vector3(wd.x, 0.0, wd.y)
	extra_large_structures_wind_speed = speed
	large_structures_wind_speed = speed * 0.72
	medium_structures_wind_speed = speed * 0.4
	small_structures_wind_speed = speed * 0.2
	# ★ 漂移强度也跟随天气：Clear（wind=0）时雾完全静止，符合直觉
	clouds_resource.wind_swept_strength = clampf(speed * 1.5, 0.0, 20.0)
	clouds_resource.clouds_density = clampf(base_density * (idle_density + (1.0 - idle_density) * minf(1.0, fog_amount * 3.0)), 0.0, 1.0)


func _ready():
	_bind_weather()
	
	# ★ 适配本项目：tracked_directional_lights 里只要有**废路径**（复制场景/手填很容易留下，
	#   形如 "../../../../…"）或漏了灯，driver 喂出去的太阳数据就是错的/空的 ⇒ 体渲染输出全黑。
	#   这里先清洗（丢掉无效项）再把场景里的平行光补齐。
	if is_inside_tree():
		sanitize_directional_lights()
	
	# ★ 风速同样是云层尺度（140/100/40/12 m/s）：400 米世界里 0.35 秒就穿越全场。
	#   场景里若存着旧值，这里自动压到地面尺度。
	if extra_large_structures_wind_speed > 20.0:
		extra_large_structures_wind_speed = 2.5
		large_structures_wind_speed = 1.8
		medium_structures_wind_speed = 1.0
		small_structures_wind_speed = 0.5
		print("FogLayerDriver: 风速是云层尺度 -> 已适配为地面尺度 (2.5/1.8/1.0/0.5 m/s)")
		# ★ 场景加载时属性 setter 可能在未入树时被调用 ⇒ 这里补一次挂载（clouds_res_added 已幂等）
	clouds_res_added()
	
	# ★ 原来是 `if update_continuously:` 才喂数据，而它的默认值是 **false**
	#   ⇒ 没有太阳/风/相机数据 ⇒ 体渲染输出全黑（听起来像"雾是黑的"，其实是没数据）。
	#   本项目的适配：只要有资源就强制开更新并立刻喂一次。
	if clouds_resource != null:
		if not update_continuously:
			update_continuously = true
		call_deferred("retrieve_texture_data")


## 清洗 + 补齐平行光列表：
##   ① 丢掉指向不存在节点/已不在场景树里的项（NodePath 解析失败时这里是 null）；
##   ② 步数数组与灯一一对应，缺的补 4；
##   ③ 再把场景里所有 DirectionalLight3D 追加进来（collect 内部判重）。
func sanitize_directional_lights() -> void:
	var valid: Array[DirectionalLight3D] = []
	var steps: Array[int] = []
	for i in range(tracked_directional_lights.size()):
		var light: DirectionalLight3D = tracked_directional_lights[i]
		if is_instance_valid(light) and light.is_inside_tree():
			valid.append(light)
			steps.append(tracked_directional_light_shadow_steps[i] \
					if i < tracked_directional_light_shadow_steps.size() else 4)
	var dropped := tracked_directional_lights.size() - valid.size()
	tracked_directional_lights = valid
	tracked_directional_light_shadow_steps = steps
	collect_directional_lights(get_tree().root)
	if dropped > 0:
		print("FogLayerDriver: 丢弃 %d 个无效光源路径，现有 %d 盏平行光"
				% [dropped, tracked_directional_lights.size()])


## 递归收集场景里的平行光（填进 tracked_directional_lights ⇒ driver 才会喂太阳数据）
func collect_directional_lights(node: Node) -> void:
	for child in node.get_children():
		if child is DirectionalLight3D:
			if not tracked_directional_lights.has(child):
				tracked_directional_lights.append(child)
				tracked_directional_light_shadow_steps.append(4)
		collect_directional_lights(child)


func _process(delta : float):
	_apply_weather()   # ★ 每帧跟随天气（雾量/风）
	if clouds_resource != null:
		clouds_resource.current_time = wrap(clouds_resource.current_time + delta * clouds_resource.dither_speed, 0.0, clouds_resource.dither_speed * 64.0)
		
		if update_continuously:
			_updating_settings = false
			extra_large_clouds_pos += wind_direction * extra_large_structures_wind_speed * delta
			extra_large_clouds_pos = wrap_vector(extra_large_clouds_pos, _extralarge_clouds_domain)
			large_clouds_pos += wind_direction * large_structures_wind_speed * delta
			large_clouds_pos = wrap_vector(large_clouds_pos, _large_clouds_domain)
			medium_clouds_pos += wind_direction * medium_structures_wind_speed * delta
			medium_clouds_pos = wrap_vector(medium_clouds_pos, _medium_clouds_domain)
			small_clouds_pos += ((wind_direction * small_structures_wind_speed) + (Vector3.UP * abs(small_structures_wind_speed))) * delta
			small_clouds_pos = wrap_vector(small_clouds_pos, _small_clouds_domain)
			
			clouds_resource.origin_offset = origin_offset
			clouds_resource.extra_large_scale_clouds_position = origin_offset + extra_large_clouds_pos
			clouds_resource.large_scale_clouds_position = origin_offset + large_clouds_pos
			clouds_resource.medium_scale_clouds_position = origin_offset + medium_clouds_pos
			clouds_resource.detail_clouds_position = origin_offset + small_clouds_pos
			
			clouds_resource.wind_direction = wind_direction
			
			if clouds_resource.use_environment_fog > 0.0 and ambience_sample_environment != null:
				clouds_resource.sampled_environment_fog_color = ambience_sample_environment.fog_light_color
				#clouds_resource.cloud_ambient_color = ambience_sample_environment.fog_light_color
			
			# Comparisons run against the driver's own copies, never against
			# clouds_resource's arrays: those now belong to the render thread.
			if (tracked_directional_lights.size() * 2.0 != _dir_data_cache.size() \
			or tracked_point_lights.size() * 2.0 != _point_data_cache.size()\
			or tracked_directional_lights.size() != tracked_directional_light_shadow_steps.size()):
				
				retrieve_texture_data()
				return
			
			for i in range(tracked_directional_lights.size()):
				if tracked_directional_lights[i] == null:
					continue
				if direction_light_data_changed(tracked_directional_lights[i], tracked_directional_light_shadow_steps[i], _dir_data_cache[i * 2], _dir_data_cache[i * 2 + 1]):
					retrieve_texture_data()
					return
			
			for i in range(tracked_point_lights.size()):
				if tracked_point_lights[i] == null:
					continue
				if point_light_data_changed(tracked_point_lights[i], _point_data_cache[i * 2], _point_data_cache[i * 2 + 1]):
					retrieve_texture_data()
					return
			
			for i in range(tracked_point_effectors.size()):
				if tracked_point_effectors[i] == null:
					continue
				if point_effector_data_changed(tracked_point_effectors[i], _effector_data_cache[i * 2], _effector_data_cache[i * 2 + 1]):
					retrieve_texture_data()
					return
			
	else:
		update_continuously = false

func sample_clouds():
	for i in range(64):
		clouds_resource.add_sample(return_data.bind(), Vector3(i * 1000, 6000.0, 0.0))

func return_data(position : Vector3, sampledensity : float):
	print(position, " ", sampledensity)
	pass

func build_new_clouds():
	if (is_inside_tree()):
		var env : WorldEnvironment = recursively_find_env(get_tree().root)
		if (env):
			if not ambience_sample_environment:
				ambience_sample_environment = env.environment
			
			clouds_resource = FogLayerEffect.new()
			_ensure_effect_on_disk()   # ★ 立刻写盘，避免它成为场景内嵌资源
			
			#if not env.compositor:
				#env.compositor = Compositor.new()
			#env.compositor.compositor_effects = [clouds_resource]
			
			update_continuously = true
		else:
			printerr("场景里没有找到 WorldEnvironment 节点")

#Disables the previous clouds when removing them.
func clouds_res_removed():
	if clouds_resource && is_inside_tree():
		var env : WorldEnvironment = recursively_find_env(get_tree().root)
		if env && env.compositor != null:
			var effects = env.compositor.compositor_effects
			effects.erase(clouds_resource)
			env.compositor.compositor_effects = effects

#Enables new clouds when adding them
func clouds_res_added():
	_ensure_effect_on_disk()   # ★ 新资源先落盘，否则第一次 Ctrl+S 会把整个 effect 内嵌进场景
	if clouds_resource && is_inside_tree():
		var env : WorldEnvironment = recursively_find_env(get_tree().root)
		if env:
			if not env.compositor:
				env.compositor = Compositor.new()
				_created_compositor = true   # ★ 我们建的 ⇒ 删除节点时要一并撤掉
				env.compositor.compositor_effects = [clouds_resource]
			else:
				# ★ 去重 + 幂等：编辑器里很容易往 Compositor 数组再加一份同类 effect，
				#   两份叠加会导致画面异常/看不见。这里在挂载时清掉其它"同脚本"的 effect，
				#   只保留 driver 自己这一份（= 面板/笔刷写入掩码的那一份）。
				var my_script = clouds_resource.get_script()
				var filtered : Array[CompositorEffect] = []
				var removed := 0
				for e in env.compositor.compositor_effects:
					if e is CompositorEffect and my_script != null and e.get_script() == my_script:
						removed += 1
						continue
					filtered.append(e)
				if not filtered.has(clouds_resource):
					filtered.append(clouds_resource)
				env.compositor.compositor_effects = filtered
				if removed > 0:
					print("FogLayerDriver: 已移除 %d 份重复的雾 effect，只保留 driver 这一份" % removed)


func recursively_find_env(thisNode: Node) -> WorldEnvironment:
	for child in thisNode.get_children():
		if child is WorldEnvironment:
			return child
		else:
			var result = recursively_find_env(child)
			if (result):
				return result
	
	return null

func retrieve_texture_data():
	if _updating_settings || !is_inside_tree():
		return
	_updating_settings = true
	if clouds_resource != null:
		_extralarge_clouds_domain = clouds_resource.extra_large_noise_scale / 2.0
		_large_clouds_domain = clouds_resource.large_noise_scale / 2.0
		_medium_clouds_domain = clouds_resource.medium_noise_scale / 2.0
		_small_clouds_domain = clouds_resource.small_noise_scale / 2.0
		
		# Arrays built LOCALLY: until they are handed over to the effect, the render
		# thread keeps seeing the old, complete ones. No empty window.
		var new_dir_data : Array[Vector4] = []
		var new_point_data : Array[Vector4] = []
		var new_effector_data : Array[Vector4] = []
		
		if not tracked_directional_light_shadow_steps:
			tracked_directional_light_shadow_steps = []
		
		if tracked_directional_light_shadow_steps.size() < tracked_directional_lights.size():
			for i in range(tracked_directional_lights.size() - tracked_directional_light_shadow_steps.size()):
				tracked_directional_light_shadow_steps.append(12)
		
		for i in range(tracked_directional_lights.size()):
			if tracked_directional_lights[i] != null:
				var light = tracked_directional_lights[i]
				var look_dir = light.global_transform.basis.z.normalized()
				new_dir_data.append(Vector4(look_dir.x, look_dir.y, look_dir.z, tracked_directional_light_shadow_steps[i]))
				new_dir_data.append(Vector4(light.light_color.r, light.light_color.g, light.light_color.b, round(light.light_color.a * light.light_energy * directional_light_power_multiplier * 10.0) / 10.0))
		
		for i in range(tracked_point_lights.size()):
			if tracked_point_lights[i] != null:
				var light = tracked_point_lights[i]
				var light_pos = light.global_position
				new_point_data.append(Vector4(light_pos.x, light_pos.y, light_pos.z, light.omni_range))
				new_point_data.append(Vector4(light.light_color.r, light.light_color.g, light.light_color.b, round(light.light_color.a * light.light_energy * point_light_power_multiplier * 10.0) / 10.0))
		
		
		for i in range(tracked_point_effectors.size()):
			if tracked_point_effectors[i] != null:
				var node = tracked_point_effectors[i]
				var node_pos = node.global_position
				new_effector_data.append(Vector4(node_pos.x, node_pos.y, node_pos.z, node.Radius))
				new_effector_data.append(Vector4(node.Power, 0.0, 0.0, 0.0))
		
		
		# Driver-side copies, for _process's comparisons (main thread).
		_dir_data_cache = new_dir_data.duplicate()
		_point_data_cache = new_point_data.duplicate()
		_effector_data_cache = new_effector_data.duplicate()

		# Handed to the effect from the render thread: serialised with _render_callback.
		RenderingServer.call_on_render_thread(_apply_lights_data.bind(new_dir_data, new_point_data, new_effector_data))
	
	_updating_settings = false

func wrap_vector(target, domain_size):
	if target.x > domain_size:
		target.x -= domain_size * 2.0
	elif target.x < -domain_size:
		target.x += domain_size * 2.0

	if target.y > domain_size:
		target.y -= domain_size * 2.0
	elif target.y < -domain_size:
		target.y += domain_size * 2.0

	if target.z > domain_size:
		target.z -= domain_size * 2.0
	elif target.z < -domain_size:
		target.z += domain_size * 2.0

	return target

func direction_light_data_changed(light : DirectionalLight3D, shadowCount : int, dirData : Vector4, colorData : Vector4):
	return light.global_transform.basis.z.x != dirData.x \
		or light.global_transform.basis.z.y != dirData.y \
		or light.global_transform.basis.z.z != dirData.z \
		or float(shadowCount) != dirData.w \
		or light.light_color.r != colorData.x \
		or light.light_color.g != colorData.y \
		or light.light_color.b != colorData.z \
		or round(light.light_color.a * light.light_energy * directional_light_power_multiplier * 10.0) / 10.0 != round(colorData.w * 10.0) / 10.0


func point_light_data_changed(light : OmniLight3D, dirData : Vector4, colorData : Vector4):
	return light.global_position.x != dirData.x \
		or light.global_position.y != dirData.y \
		or light.global_position.z != dirData.z \
		or light.omni_range != dirData.w \
		or light.light_color.r != colorData.x \
		or light.light_color.g != colorData.y \
		or light.light_color.b != colorData.z \
		or round(light.light_color.a * light.light_energy * point_light_power_multiplier * 10.0) / 10.0 != round(colorData.w * 10.0) / 10.0

func point_effector_data_changed(node : FogLayerEffector, dirData : Vector4, colorData : Vector4):
	return node.global_position.x != dirData.x \
		or node.global_position.y != dirData.y \
		or node.global_position.z != dirData.z \
		or node.Radius != dirData.w \
		or node.Power != colorData.x