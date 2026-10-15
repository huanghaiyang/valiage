@tool
extends Control
class_name CloudsEditorController

@export_category("Driver Tools")
@export var CloudsStatusLabel : Label
@export var CloudsActiveToggle : CheckButton
@export var CloudsDriverRefresh : Button
@export var CloudsDriverAccordianButton : AccordionButton
@export_category("Mask Tools")
@export var UseMaskToggle : CheckButton
@export var MaskStatusLabel : Label
@export var MaskFilePath : LineEdit
@export var MaskResolution : SpinBox
@export var MaskWidth : SpinBox
@export_category("Draw Tools")
@export var DrawWeightEnable : TextureButton
@export var DrawColorEnable : TextureButton
@export var DrawColorPicker : ColorPicker

@export var DrawTools : Control
@export var DrawSharpness : HSlider
@export var DrawStrength : HSlider

@export var compute_shader : RDShaderFile
@export var DrawingColor : Color
@export var InvertedDrawingColor : Color

@export_range(1,5000,1) var DefaultBrushSize : float = 10.0
@export_range(0,50000,1) var DefaultCloudsHeight : float = 0.0

var driver : FogLayerDriver

var currentRoot : Node

var currentDrawingMask : RID = RID()

enum DRAWINGMODE {none, weight, color, setValue}

var drawScale : float
var currentCloudsHeight : float
var currentDrawMode : DRAWINGMODE = DRAWINGMODE.none
var drawingCurrently : bool = false
# 最后一次收到视口鼠标事件的时刻（用于判断是否已切走工具/鼠标离开视口）
var _last_cursor_msec : int = 0
var drawInverted : bool = false
var drawBrushToolMaterial : BaseMaterial3D = preload("res://addons/fog_layer/Dock/Materials/DrawBrushToolsMaterial.tres")
var drawBrushToolPrefab : PackedScene = preload("res://addons/fog_layer/Dock/CloudsDrawBrush.tscn")
var drawBrushTool : MeshInstance3D

#region Compute Variables
var computeEnabled : bool = false
var rd : RenderingDevice
var shader : RID = RID()
var pipeline : RID = RID()

var uniform_set : RID
var push_constants : PackedByteArray

var last_image_data : PackedByteArray = []
## 掩码落盘路径：编辑器里画完会存这里，**游戏运行时**由 effect 自动加载
#endregion

var pause_updates : bool = false
var _last_mask_width : float = -1.0
var _last_feedback_msec : int = 0
var _last_poslog_msec : int = 0   # 定位打印节流   # 落笔反馈节流（同步回读很贵，不能每帧做）   # 掩码宽度变化检测（变了就清空已画的掩码）


func _enter_tree() -> void:
	drawScale = DefaultBrushSize
	_add_clear_button()   # ★ 代码里补一个"一键清除"按钮（不改 tscn，避免动 node_paths）


## 把"一键清除雾"按钮加到面板的绘制工具区（笔刷按钮下方）
func _add_clear_button() -> void:
	var parent := get_node_or_null("ScrollContainer/VBoxContainer/DrawTools/VBoxContainer/MarginContainer/VBoxContainer")
	if parent == null or parent.has_node("ClearFogButton"):
		return
	var b := Button.new()
	b.name = "ClearFogButton"
	b.text = "一键清除雾（重置掩码）"
	b.tooltip_text = "把内存掩码全部清零：已画的雾立刻消失，之后重新画"
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(ClearMask)

	var b2 := Button.new()
	b2.name = "CleanupMasksButton"
	b2.text = "清理未使用的掩码资源"
	b2.tooltip_text = "把本场景名下、当前驱动未引用的掩码 .tres 移入 data/fog_masks/_trash/（可恢复）"
	b2.focus_mode = Control.FOCUS_NONE
	b2.pressed.connect(_cleanup_unused_masks)
	parent.add_child(b2)

	var b3 := Button.new()
	b3.name = "ExportMaskToTresButton"
	b3.text = "掩码转存为 .tres（去掉场景内联图片）"
	b3.tooltip_text = "把当前掩码像素写成独立 .res，生成 .tres 并把驱动关联到它；之后保存场景只写一行 ExtResource，不再内联图片数据"
	b3.focus_mode = Control.FOCUS_NONE
	b3.pressed.connect(_export_mask_to_tres)
	parent.add_child(b3)
	parent.add_child(b)
	print("Fog Layer: 已添加【一键清除雾】按钮")


## 一键清除：新建一张全 0 掩码换上去，并让渲染侧重绑
## ★ 把当前内存掩码保存成"**本场景专属**的 PNG 文件"（不进场景、不进参数资源）。
##   路径 = driver.mask_dir/<场景名>.png；并把它填进 clouds_resource.runtime_mask_path，
##   游戏运行时据此加载。这样：掩码每场景一份、互不影响，场景文件也不会被撑大。
func _persist_mask_to_file() -> void:
	if rd == null or not currentDrawingMask.is_valid():
		return
	if driver == null or driver.clouds_resource == null:
		return
	var data : PackedByteArray = rd.texture_get_data(currentDrawingMask, 0)
	if data.size() < 16:
		return
	var img := Image.create_from_data(int(MaskResolution.value), int(MaskResolution.value), false, Image.FORMAT_RGBAF, data)
	img.clear_mipmaps()
	# ★ 白掩码护栏：几乎整张纯白通常是误操作（如整片填充强度=1），拒存，避免下次一开就满屏白
	var ma : float = driver.clouds_resource.mask_mean_alpha(img) if driver != null and driver.clouds_resource != null else 0.0
	if ma > 0.98:
		printerr("Fog Layer: 【白掩码护栏】当前掩码几乎整张纯白(%.3f)，已拒存（避免重开满屏白）。想真整片铺满请用较低强度。" % ma)
		return
	var scene_name : String = currentRoot.name if is_instance_valid(currentRoot) else "scene"
	var base : String = driver.mask_dir if driver.mask_dir != "" else "res://data/fog_masks"
	if not DirAccess.dir_exists_absolute(base):
		DirAccess.make_dir_recursive_absolute(base)
	# ★ 写进独立的"掩码资源"（.tres）：既能存图像数据，也能带元数据，且与共享参数资源无关
	var mres : FogMaskResource = driver.mask_resource
	var _created := false
	if mres == null:
		mres = FogMaskResource.new()
		_created = true
	mres.mask = img
	mres.resolution = int(MaskResolution.value)
	mres.width_km = driver.clouds_resource.mask_width_km if driver.clouds_resource != null else 0.0
	mres.base_height = driver.clouds_resource.fog_base_height if driver.clouds_resource != null else 0.0
	mres.thickness = driver.clouds_resource.fog_thickness if driver.clouds_resource != null else 0.0
	var path : String = mres.resource_path
	if path == "":
		# ★ 文件名 = **节点 id**（driver.mask_id，存进场景）：改名不变、每节点唯一，
		#   多个 FogLayerDriver 之间不会互相覆盖。
		path = driver.mask_file_path()
	var err := ResourceSaver.save(mres, path)
	# ★★ 顺序很关键：**先**写盘（资源获得 resource_path），**再**挂到 driver。
	#   反过来会让编辑器把它当成"场景内嵌资源"，把图片数据塞进 main.tscn（几 MB）。
	if _created or driver.mask_resource != mres:
		mres.resource_local_to_scene = false
		driver.mask_resource = mres
	print("Fog Layer: 掩码已保存 %s（err=%d，%dx%d）" % [path, err, img.get_width(), img.get_height()])


## 清理未使用的掩码资源：只处理 **以本场景名开头** 的 .tres，
## 且当前场景里的所有 FogLayerDriver 都没引用它 ⇒ 移入 _trash/（不直接删除，便于恢复）。
##   为什么不自动做：Godot 无法区分"用户删了节点"与"切换/关闭场景"，自动删会在切场景时丢笔迹。
func _cleanup_unused_masks() -> void:
	if not is_instance_valid(currentRoot):
		printerr("Fog Layer: 清理失败 —— 没有当前场景")
		return
	var base : String = "res://data/fog_masks"
	if driver != null and driver.mask_dir != "":
		base = driver.mask_dir
	var scene_name : String = currentRoot.name
	var used := {}
	for n in currentRoot.find_children("*", "", true, false):
		if n.get_script() != null and String(n.get_script().resource_path).ends_with("FogLayerDriver.gd"):
			var mr = n.get("mask_resource")
			if mr != null and mr.resource_path != "":
				used[mr.resource_path] = true
	var dir := DirAccess.open(base)
	if dir == null:
		printerr("Fog Layer: 清理失败 —— 打不开 %s" % base)
		return
	var trash : String = base.path_join("_trash")
	var moved := 0
	for f in dir.get_files():
		if not f.ends_with(".tres") or not f.begins_with(scene_name):
			continue
		var p : String = base.path_join(f)
		if used.has(p):
			continue
		if not DirAccess.dir_exists_absolute(trash):
			DirAccess.make_dir_recursive_absolute(trash)
		var err := DirAccess.rename_absolute(p, trash.path_join(f))
		if err == OK:
			moved += 1
			print("Fog Layer: 已回收未使用的掩码资源 %s -> _trash/" % f)
	print("Fog Layer: 清理完成，共回收 %d 个掩码资源（在 %s/_trash/ 可恢复）" % [moved, base])

## 把掩码资源里的图像置成全 0（一键清除时先做，避免被"续接"重新加载回来）
func _zero_resource_mask() -> void:
	if driver == null or driver.mask_resource == null:
		return
	var res : int = int(MaskResolution.value)
	var img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	img.clear_mipmaps()
	driver.mask_resource.mask = img
	driver.mask_resource.resolution = res

## 【一键转存】把当前掩码像素写成独立的 .res（file-backed Image ✓），生成 .tres 并把驱动关联到它。
##   为什么要这么做：场景里内联图片数据，是因为"节点引用的资源对象没有文件路径"。
##   本操作把像素存成文件、把 .tres 存成文件，再让节点引用**重新 load 回来的** file-backed 对象
##   ⇒ 之后每次 Ctrl+S 只会写一行 ExtResource ✓（图片数据再也不进场景 ✓）
func _export_mask_to_tres() -> void:
	if driver == null:
		printerr("Fog Layer: 转存失败 —— 没有 driver（先在场景里选中 FogLayerDriver）")
		return
	# 1) 取像素：优先面板内存掩码 → 驱动资源里的 mask → 全 0 空图
	var img : Image = null
	if rd != null and currentDrawingMask.is_valid():
		var data : PackedByteArray = rd.texture_get_data(currentDrawingMask, 0)
		if data.size() >= 16:
			img = Image.create_from_data(int(MaskResolution.value), int(MaskResolution.value), false, Image.FORMAT_RGBAF, data)
	if img == null and driver.mask_resource != null and driver.mask_resource.mask != null:
		img = driver.mask_resource.mask.duplicate() as Image
	if img == null:
		img = Image.create(int(MaskResolution.value), int(MaskResolution.value), false, Image.FORMAT_RGBAF)
		img.fill(Color(0.0, 0.0, 0.0, 0.0))
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBAF:
		img.convert(Image.FORMAT_RGBAF)
	if img.has_mipmaps():
		img.clear_mipmaps()

	# 2) 像素写成独立 .res（Image 直接存成文件资源，无需导入 ✓）
	var base : String = driver.mask_dir if driver.mask_dir != "" else "res://data/fog_masks"
	if not DirAccess.dir_exists_absolute(base):
		DirAccess.make_dir_recursive_absolute(base)
	var stem : String = driver.mask_file_path().get_basename()
	var res_path : String = stem + ".res"
	var tres_path : String = stem + ".tres"
	var e1 := ResourceSaver.save(img, res_path)

	# 3) 建 .tres 并指向那份 file-backed Image
	var mres := FogMaskResource.new()
	mres.resolution = int(MaskResolution.value)
	mres.width_km = driver.clouds_resource.mask_width_km if driver.clouds_resource != null else 0.0
	mres.base_height = driver.clouds_resource.fog_base_height if driver.clouds_resource != null else 0.0
	mres.thickness = driver.clouds_resource.fog_thickness if driver.clouds_resource != null else 0.0
	var loaded_img := ResourceLoader.load(res_path)
	mres.mask = loaded_img if loaded_img is Image else img
	var e2 := ResourceSaver.save(mres, tres_path)

	# 4) ★ 关键：save() 不会让内存对象变成文件型 ⇒ 必须重新 load 再挂回节点
	var loaded_res := ResourceLoader.load(tres_path) as FogMaskResource
	driver.mask_resource = loaded_res if loaded_res != null else mres
	print("Fog Layer: 掩码已转存 %s（err=%d,%d）⇒ 之后保存场景只写 ExtResource ✓" % [tres_path, e1, e2])
	_refresh_mask_path_display()
	_add_perf_controls()

## 把性能参数做进左侧面板（4 个滑条，直接读写 clouds_resource 上的导出属性）。
##   为什么：这些属性本来只在资源检查器里（Performance 分组）⇒ 面板上看不到 ✗。
func _add_perf_controls() -> void:
	var parent := get_node_or_null("ScrollContainer/VBoxContainer/MaskSettings/VBoxContainer")
	if parent == null or parent.has_node("PerfControls"):
		return
	var box := VBoxContainer.new()
	box.name = "PerfControls"
	var title := Label.new()
	title.text = "性能（数值越小越快）"
	box.add_child(title)
	_perf_slider(box, "步数上限 max_step_count", 1.0, 512.0, 1.0, "max_step_count")
	_perf_slider(box, "计算分辨率 %", 1.0, 100.0, 1.0, "resolution_percent")
	_perf_slider(box, "光照步数 max_lighting_steps", 1.0, 64.0, 1.0, "max_lighting_steps")
	_perf_slider(box, "光照距离 lighting_travel_distance", 1.0, 500.0, 1.0, "lighting_travel_distance")
	parent.add_child(box)
	print("Fog Layer: 已添加【性能】控件（步数/分辨率/光照步数/光照距离）")


func _perf_slider(parent: Node, label_text: String, mn: float, mx: float, step: float, prop: String) -> void:
	var row := HBoxContainer.new()
	var lb := Label.new()
	lb.text = label_text
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lb)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.custom_minimum_size = Vector2(160, 0)
	if driver != null and driver.clouds_resource != null:
		sl.value = float(driver.clouds_resource.get(prop))
	sl.value_changed.connect(func(v: float) -> void:
		if driver != null and driver.clouds_resource != null:
			driver.clouds_resource.set(prop, v)
			driver.clouds_resource.lights_updated = true     # 让渲染侧下次重建时用上新值
	)
	row.add_child(sl)
	parent.add_child(row)

func ClearMask() -> void:
	if rd == null:
		rd = RenderingServer.get_rendering_device()
	# ★★ 关键：**先**把资源里的掩码图也置成全 0 ★★
	#   否则后面的 InitializeCompute() 会"续接掩码资源"，把旧的那张画重新加载回来
	#   ⇒ 表现就是"一键清除后雾还在"。
	_zero_resource_mask()
	# ★ 面板还没建过掩码（从没进过绘制模式）时，先把它建出来：
	#   InitializeCompute() 会创建一张全 0 掩码（alpha=0 = 没有雾），等于"清除完成"。
	if not currentDrawingMask.is_valid():
		InitializeCompute()
		if currentDrawingMask.is_valid():
			call_deferred(&"_persist_mask_to_file")
			MaskStatusLabel.text = "内存掩码 · 已清空（当前没有雾）"
			print("Fog Layer: 已一键清除（首次创建即为空掩码）")
			return
		# 仍失败 ⇒ 退回让渲染侧用它自己的全 0 掩码（效果一样：没有雾）
		if driver != null and driver.clouds_resource != null and driver.clouds_resource.has_method("refresh_compute"):
			driver.clouds_resource.refresh_compute()
			call_deferred(&"_persist_mask_to_file")
			MaskStatusLabel.text = "内存掩码 · 已重置（当前没有雾）"
			print("Fog Layer: 已通知渲染侧重置掩码")
			return
		printerr("Fog Layer: 一键清除失败 —— 掩码既未创建也无法重置")
		return
	var res : int = int(MaskResolution.value)
	var img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))     # alpha=0 = 没有雾
	img.clear_mipmaps()
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = res
	fmt.height = res
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var new_rid := rd.texture_create(fmt, RDTextureView.new(), [img.get_data()])
	if not new_rid.is_valid():
		printerr("Fog Layer: 一键清除失败 —— 新掩码纹理创建失败")
		return
	currentDrawingMask = new_rid
	last_image_data = []
	if driver != null and driver.clouds_resource != null:
		driver.clouds_resource.update_mask(currentDrawingMask)   # 触发渲染侧重绑
	InitializeCompute()                                          # 重建笔刷 uniform set，指向新掩码
	call_deferred(&"_persist_mask_to_file")
	MaskStatusLabel.text = "内存掩码 · 已清空（当前没有雾）"
	print("Fog Layer: 已一键清除所有雾（掩码重置为全 0）")

func _notification(what):
	if what == NOTIFICATION_PREDELETE and is_instance_valid(self):
		RenderingServer.call_on_render_thread(ClearCompute)

func _process(delta: float) -> void:
	
	if (currentDrawMode != DRAWINGMODE.none):
		
		var selection = EditorInterface.get_selection()
		if (selection.get_selected_nodes().size() == 0):
			if (driver != null):
				selection.add_node(driver)
		
		if (currentDrawMode == DRAWINGMODE.color):
			drawBrushToolMaterial.albedo_color = DrawColorPicker.color
		
		if (drawingCurrently):
			
			RenderingServer.call_on_render_thread(ExecuteCompute.bindv([delta, false, Color.WHITE]))
			call_deferred(&"_update_paint_feedback")
		
		# 切到别的工具 / 鼠标离开 3D 视口后，视口不再派发鼠标事件，也就没人调用
		# DisableDrawMode()，画笔指示器会一直挂着不消失。这里按是否还在收到视口事件判断：
		# 超过 0.5 秒没消息就隐藏。（指示器节点没有 owner，不会被写进场景文件）
		if is_instance_valid(drawBrushTool) and (Time.get_ticks_msec() - _last_cursor_msec) > 500:
			drawBrushTool.visible = false

func InitialSceneLoad() -> void:
	var sceneRoot = await FindSceneNode()
	SceneChanged(sceneRoot)
	print("initial scene load")
	
	await get_tree().create_timer(0.5).timeout
	var version_info = Engine.get_version_info()
	
	var file = FileAccess.open("res://addons/fog_layer/CloudsInc.comp", FileAccess.READ_WRITE)
	var content = file.get_as_text()
	var major_index = content.find("GODOT_VERSION_MAJOR") + 20
	var minor_index = content.find("GODOT_VERSION_MINOR") + 20
	
	if content[major_index] != str(version_info.major) || content[minor_index] != str(version_info.minor):
		print("Version conflict, updating and reimporting...")
		content[major_index] = str(version_info.major)
		content[minor_index] = str(version_info.minor)
		file.store_string(content)
		file.close()
		
		EditorInterface.get_resource_filesystem().reimport_files(["res://addons/fog_layer/SunshineCloudsCompute.glsl", "res://addons/fog_layer/SunshineCloudsPostCompute.glsl", "res://addons/fog_layer/SunshineCloudsPostCompute.msaa.glsl", "res://addons/fog_layer/SunshineCloudsPreCompute.glsl", "res://addons/fog_layer/SunshineCloudsDisplay.glsl", "res://addons/fog_layer/SunshineCloudsDisplay.msaa.glsl"])
		await get_tree().create_timer(0.1).timeout
		if driver != null && driver.clouds_resource != null:
			driver.clouds_resource.refresh_compute()
		
		print("Version change may cause some errors during first load, these should not impact functionality, if there is impacted functionality please report it to the creator of the plugin.")
		print("Version updated, launching normally.")
	else:
		print("Version correct, launching normally.")
		file.close()
	

func RefreshSceneNode() -> void:
	var sceneRoot = await FindSceneNode()
	
	SceneChanged(sceneRoot)

func FindSceneNode() -> Node:
	var editorInterface = EditorPlugin.new().get_editor_interface()
	var sceneRoot = editorInterface.get_edited_scene_root()
	var iterationcount: int = 300 #30 seconds of checking.
	while sceneRoot == null && iterationcount > 0:
		await get_tree().create_timer(0.1).timeout
		iterationcount -= 1
		sceneRoot = editorInterface.get_edited_scene_root()
	
	return sceneRoot

## 把"掩码文件:"那一行变成**真实路径显示**（复用原来的 LineEdit，改成只读 ✓）。
##   为什么：原来它读的是旧的文件路径输入框，从来没填过 ⇒ 一直空白 ✗。
func _refresh_mask_path_display() -> void:
	if not is_instance_valid(MaskFilePath):
		return
	MaskFilePath.editable = false
	MaskFilePath.visible = true
	var p : String = ""
	if driver != null and driver.mask_resource != null:
		p = String(driver.mask_resource.resource_path)
	if MaskFilePath.text != p:
		MaskFilePath.text = p

func SceneChanged(scene_root : Node):
	
	pause_updates = true
	DrawWeightEnable.button_pressed = false
	DrawColorEnable.button_pressed = false
	last_image_data = []
	DisableDrawMode()
	
	currentRoot = scene_root
	driver = RetrieveCloudsDriver(scene_root)
	_refresh_mask_path_display()
	_add_perf_controls()
	# ★ 掩码来源只有一个：驱动上的 FogMaskResource（直接引用，不猜路径/场景名）
	if driver != null and driver.clouds_resource != null and driver.mask_resource != null and driver.mask_resource.mask != null:
		driver.clouds_resource.reload_mask_from_image(driver.mask_resource.mask)
	if (driver != null && driver.clouds_resource != null):
		driver.clouds_resource.maskDrawnRid = RID()
		
		MaskWidth.value = driver.clouds_resource.mask_width_km
		UseMaskToggle.button_pressed = driver.clouds_resource.extra_large_used_as_mask
	
	if ResourceLoader.exists(MaskFilePath.text):
		var image = ResourceLoader.load(MaskFilePath.text) as Image
		if image:
			print("retrieved mask scale")
			MaskResolution.value = image.get_width()
	pause_updates = false
	UpdateStatusDisplay()

func RetrieveCloudsDriver(scene_root : Node) -> FogLayerDriver:
	if (scene_root != null):
		for child in scene_root.get_children():
			if child is FogLayerDriver:
				return child
			
			var newDriver = RetrieveCloudsDriver(child)
			if (newDriver):
				return newDriver
	
	return null

func UpdateStatusDisplay():
	
	if (driver != null):
		CloudsActiveToggle.disabled = false
		CloudsActiveToggle.button_pressed = driver.update_continuously
		CloudsDriverRefresh.visible = false
		CloudsStatusLabel.text = "已找到雾驱动节点"
		
		# ★ 掩码在内存里，不再依赖磁盘文件 ⇒ 只要有驱动节点就显示笔刷区
		MaskStatusLabel.text = "内存掩码（只由笔刷落笔生成，不落盘）"
		DrawTools.visible = true
		
	else:
		CloudsActiveToggle.disabled = true
		CloudsActiveToggle.button_pressed = false
		CloudsDriverRefresh.visible = true
		DrawTools.visible = false
		CloudsDriverAccordianButton.Open()
		CloudsStatusLabel.text = "未找到雾驱动节点"
	
	
	if driver != null && driver.clouds_resource != null:
		UseMaskToggle.disabled = false
	else:
		UseMaskToggle.disabled = true
		UseMaskToggle.button_pressed = false
	

func UpdateMaskSettings():
	if (pause_updates):
		return
	print("更新掩码设置")
	if (driver != null && driver.clouds_resource != null):
		# ★ 掩码宽度改了 ⇒ 已画的笔迹按新尺度失效（看起来像"雾突然消失"）⇒ 自动清空并提示
		if _last_mask_width >= 0.0 and not is_equal_approx(_last_mask_width, MaskWidth.value):
			print("Fog Layer: 掩码覆盖宽度 %s -> %s km，已画的掩码失效，已自动清空" % [_last_mask_width, MaskWidth.value])
			ClearMask()
		_last_mask_width = MaskWidth.value
		driver.clouds_resource.mask_width_km = MaskWidth.value
		driver.clouds_resource.extra_large_used_as_mask = UseMaskToggle.button_pressed
		if (!UseMaskToggle.button_pressed):
			driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load("res://addons/fog_layer/NoiseTextures/ExtraLargeScaleNoise.tres")
		elif ResourceLoader.exists(MaskFilePath.text):
			driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load(MaskFilePath.text)
	
	InitializeMaskTexture()

func InitializeMaskTexture():
	#if (driver == null):
		#return
	
	if not rd:
		rd = RenderingServer.get_rendering_device()
		if not rd:
			return
	#currentDrawingMask = driver.clouds_resource.mask_rid
	#var useDriverData : bool = driver != null && driver.clouds_resource != null
	#
	print("正在初始化掩码")
	# ★ 本项目改造：掩码**不落盘**。需求＝"只有笔刷落下的地方才有雾"。
	#   · 首次进入绘制模式：由 InitializeCompute 建一张 alpha=0 的掩码（0 = 无雾）；
	#   · 再次进入：沿用当前那张（currentDrawingMask 有效就不重建）⇒ 不会清掉已画的笔迹；
	#   · 不再 ResourceLoader.load / save_png / save_exr —— .exr 导入后会丢 alpha，
	#     读回来恒等于"满权重" ⇒ 一进绘制模式就满屏雾（这就是"点击笔刷就出雾"的根因）。
	RenderingServer.call_on_render_thread(InitializeCompute)
	call_deferred("UpdateStatusDisplay")

#region Draw mode

#region Compute

func InitializeCompute():
	computeEnabled = false
	#if driver == null:
		#return
	
	#currentDrawingMask = driver.clouds_resource.mask_rid
	#if !currentDrawingMask.is_valid():
		#return
	
	if not rd:
		rd = RenderingServer.get_rendering_device()
		if not rd:
			computeEnabled = false
			printerr("没有渲染设备（RenderingDevice 不可用）")
			return
	ClearCompute()
	if not compute_shader:
		compute_shader = ResourceLoader.load("res://addons/fog_layer/Dock/MaskDrawingCompute.glsl")
	
	if not compute_shader:
		computeEnabled = false
		printerr("找不到笔刷着色器")
		ClearCompute()
		return
	
	var shader_spirv = compute_shader.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	if shader.is_valid():
		pipeline = rd.compute_pipeline_create(shader)
	else:
		computeEnabled = false
		printerr("笔刷着色器编译失败")
		ClearCompute()
		return
	
	var uniforms_array : Array[RDUniform] = []
	
	var newFormat : RDTextureFormat = RDTextureFormat.new()
	newFormat.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	newFormat.height = MaskResolution.value
	newFormat.width = MaskResolution.value
	newFormat.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	# ★ 纯内存掩码：不读盘、不存盘。
	#   · currentDrawingMask 已有效（本次会话刷过）⇒ 复用，别把笔迹冲掉；
	#   · 否则建一张 RGBAF 全 0 图（alpha=0 = 无雾）上传 ⇒ 未落笔处没有任何雾。
	if not currentDrawingMask.is_valid():

		# ★ 续画：优先加载"本场景已保存的掩码"，这样重开编辑器后之前的笔迹还在
		#   （否则每次进绘制模式都从空白开始 ⇒ 看起来像"雾气消失"）
		var mask_image : Image = null
		# ★ 续接"掩码资源"里的图像（与游戏同一条数据来源）
		if driver != null and driver.mask_resource != null and driver.mask_resource.mask != null:
			mask_image = driver.mask_resource.mask.duplicate() as Image
			print("Fog Layer: 已续接掩码资源（%dx%d）" % [mask_image.get_width(), mask_image.get_height()])
		if mask_image == null:
			mask_image = Image.create(int(MaskResolution.value), int(MaskResolution.value), false, Image.FORMAT_RGBAF)
			mask_image.fill(Color(0.0, 0.0, 0.0, 0.0))
		else:
			if mask_image.is_compressed():
				mask_image.decompress()
			if mask_image.get_format() != Image.FORMAT_RGBAF:
				mask_image.convert(Image.FORMAT_RGBAF)
			if mask_image.has_mipmaps():
				mask_image.clear_mipmaps()
			if mask_image.get_width() != int(MaskResolution.value):
				mask_image.resize(int(MaskResolution.value), int(MaskResolution.value), Image.INTERPOLATE_LANCZOS)

		currentDrawingMask = rd.texture_create(newFormat, RDTextureView.new(), [mask_image.get_data()])

	# ★ 纹理创建失败（尺寸/格式仍不符）时明确报错并退出，否则会连带刷出
	#   "Image (binding: 0) should provide one ID referencing a texture (IDs provided: 0)"
	if not currentDrawingMask.is_valid():
		printerr("Fog Layer: 掩码纹理创建失败（分辨率 %d²，期望 %d 字节）" % [
			int(MaskResolution.value), int(MaskResolution.value) * int(MaskResolution.value) * 16])
		computeEnabled = false
		ClearCompute()
		return
	
	if (driver != null && driver.clouds_resource != null):
		driver.clouds_resource.update_mask(currentDrawingMask)
	
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 0
	mask_uniform.add_id(currentDrawingMask)
	uniforms_array.append(mask_uniform)
	
	uniform_set = rd.uniform_set_create(uniforms_array, shader, 0)
	computeEnabled = true

## 落笔反馈：每次落笔后把掩码里的权重峰值显示在面板上。
## 用途：一眼区分「笔没写进去」(峰值 0) 与「写了但渲染侧没出雾」(峰值 > 0)。
func _update_paint_feedback() -> void:
	# ★★ 节流 ★★ 同步 texture_get_data 会强制 GPU 同步并且回读 4MB，
	#   每帧调用会把编辑器拖到卡死（这就是"编辑器打开卡住"的原因）。
	var _now := Time.get_ticks_msec()
	if _now - _last_feedback_msec < 400:
		return
	_last_feedback_msec = _now
	if rd == null or not currentDrawingMask.is_valid():
		print("Fog Layer: 落笔反馈无法读取（rd 或掩码纹理无效）")
		return
	# ★ 同步读回：原来依赖 texture_get_data_async 的回调（last_image_data），
	#   实际没拿到数据 ⇒ 面板那行从来没出现过。
	var data : PackedByteArray = rd.texture_get_data(currentDrawingMask, 0)
	var stride := 16
	if data.size() < stride:
		print("Fog Layer: 落笔反馈读取为空")
		return
	var count := int(data.size() / stride)
	var peak := 0.0
	var step : int = max(1, int(count / 4096))
	var i := 0
	while i < count:
		var a := data.decode_float(i * stride + 12)
		if a > peak:
			peak = a
		i += step
	MaskStatusLabel.text = "内存掩码 · 权重峰值 = %.3f（0 = 没写进去）" % peak
	print("Fog Layer: 落笔权重峰值 = %.3f（0 = 没写进去）" % peak)

func ClearCompute():
	if rd:
		if shader.is_valid():
			rd.free_rid(shader)
		shader = RID()
		
		# ★★ 卸载/重载插件时会走的路径 ★★
		#   原来这里直接 free 掩码纹理，但场景里的 effect（compositor 里那份）仍持有引用它的
		#   uniform set ⇒ 下一帧就报：
		#     Parameter "uniform_set" is null.
		#     Uniforms were never supplied for set (0) at the time of drawing, …
		#   正确顺序：先让渲染侧解绑（refresh_compute 会清 maskDrawnRid 并触发重建，
		#   重建时用 effect 自己的全 0 掩码），再释放。
		if currentDrawingMask.is_valid():
			if driver != null and driver.clouds_resource != null:
				if driver.clouds_resource.has_method("refresh_compute"):
					driver.clouds_resource.refresh_compute()
				else:
					driver.clouds_resource.maskDrawnRid = RID()
					driver.clouds_resource.last_size = Vector2i.ZERO
			rd.free_rid(currentDrawingMask)
		currentDrawingMask = RID()
		uniform_set = RID()
		computeEnabled = false

func ExecuteCompute(delta : float, setvalue : bool, setvalueColor : Color):
	if (!computeEnabled):
		return
	
	var resolution : float = MaskResolution.value
	var drawPosition : Vector2 = Vector2.ZERO
	var drawRadius = 0.0
	
	if (!setvalue):
		drawPosition = Vector2(drawBrushTool.global_position.x, drawBrushTool.global_position.z) 
		drawPosition = (drawPosition / (MaskWidth.value * 1000.0)) * resolution
		drawPosition += Vector2(resolution * 0.5, resolution * 0.5)
		
		drawRadius = (drawBrushTool.scale.x / (MaskWidth.value * 1000.0)) * resolution
		
		# ★ 定位打印（每 0.5 秒最多一条）：用于定位"笔刷位置 vs 生成位置"偏离
		var now_ms := Time.get_ticks_msec()
		if now_ms - _last_poslog_msec > 500:
			_last_poslog_msec = now_ms
			var res_w : float = MaskWidth.value * 1000.0
			var rsrc_w : float = driver.clouds_resource.mask_width_km * 1000.0 if driver != null and driver.clouds_resource != null else 0.0
			var org : Vector3 = driver.clouds_resource.origin_offset if driver != null and driver.clouds_resource != null else Vector3.ZERO
			print("Fog Layer 定位: 画笔世界=(%.2f, %.2f) 掩码像素=(%.1f, %.1f) 半径px=%.1f | 面板宽度=%.0fm 资源宽度=%.0fm 原点偏移=(%.2f, %.2f) 分辨率=%d"
				% [drawBrushTool.global_position.x, drawBrushTool.global_position.z, drawPosition.x, drawPosition.y, drawRadius,
				   res_w, rsrc_w, org.x, org.z, int(resolution)])
	
	var groups = ceil(resolution / 32) + 1
	var drawSharpness = DrawSharpness.value
	# ★ 落笔速度：原来每帧只加 strength*delta（≈0.008/帧），拖一秒才 0.5 ⇒ 手感很迟钝。
	#   乘 10 后：轻扫一下 ≈ 0.1~0.3，按住一秒 ≈ 1.0（饱和）。
	var drawStrength = DrawStrength.value * delta * 10.0
	if (drawInverted):
		drawStrength = -drawStrength
	
	var editingtype : float = 0.0
	if setvalue:
		editingtype = 2.0
	elif currentDrawMode == DRAWINGMODE.color:
		editingtype = 1.0
	
	var ms = StreamPeerBuffer.new()
	ms.put_float(drawPosition.x)
	ms.put_float(drawPosition.y)
	ms.put_float(drawRadius)
	ms.put_float(drawSharpness)
	
	ms.put_float(drawStrength)
	ms.put_float(editingtype)
	ms.put_float(resolution)
	ms.put_float(0.0)
	
	if (setvalue):
		ms.put_float(setvalueColor.r)
		ms.put_float(setvalueColor.g)
		ms.put_float(setvalueColor.b)
		ms.put_float(setvalueColor.a)
	else:
		ms.put_float(DrawColorPicker.color.r)
		ms.put_float(DrawColorPicker.color.g)
		ms.put_float(DrawColorPicker.color.b)
		ms.put_float(0.0)
	
	push_constants = ms.get_data_array()
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	
	
	await RenderingServer.frame_post_draw
	
	rd.texture_get_data_async(currentDrawingMask, 0, CompleteRetreval)

func CompleteRetreval(data):
	last_image_data = data
	#for byte in data:
		#print(byte)
	#print("RetrevalComplete ", data)
	#var image = Image.create_from_data(MaskResolution.value, MaskResolution.value, false, Image.FORMAT_RGBAF, data)
	##rd.texture_update(RenderingServer.texture_get_rd_texture(currentMask.get_rid()),0, data)
	#image.save_png(MaskFilePath.text)
	
	#var editorFileSystem := EditorInterface.get_resource_filesystem()
	#editorFileSystem.scan()

#endregion

func IterateCursorLocation(viewport_camera: Camera3D, event:InputEventMouse):
	if (is_instance_valid(driver) && driver.clouds_resource != null):
		currentCloudsHeight = driver.clouds_resource.cloud_floor
	else:
		currentCloudsHeight = DefaultCloudsHeight
	_last_cursor_msec = Time.get_ticks_msec()
	var ray_origin = viewport_camera.project_ray_origin(event.position)
	var ray_dir = viewport_camera.project_ray_normal(event.position)
	
	# ★ 与 world_brush 一致：先拿物理射线打**地面**，命中点就是落笔点（跟着地形起伏）。
	#   原来是与水平面求交再把 y 设成 cloud_floor ⇒ 山地上笔位是错的。
	if is_instance_valid(drawBrushTool) and viewport_camera.get_world_3d() != null:
		var space := viewport_camera.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * 8000.0)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			drawBrushTool.visible = true
			drawBrushTool.global_position = hit.position
			return
	
	var result : float = RetrieveTravelDistance(ray_origin, ray_dir)
	if (result == -1.0):
		drawBrushTool.visible = false
	else:
		drawBrushTool.visible = true
		drawBrushTool.global_position = ray_origin + ray_dir * result
		# ★ 原来是 cloud_floor —— 本项目的适配把 cloud_floor 压到 **-5**（埋掉贴地高度淡出），
		#   于是打不到地面碰撞体时画笔会落在**地下 5 米**：视口里看不见，像是"点了没反应"。
		#   回退位置改为不小于 0（地面）。
		drawBrushTool.global_position.y = max(driver.clouds_resource.cloud_floor, 0.0)

func BeginCursorDraw():
	drawingCurrently = true

func EndCursorDraw():
	drawingCurrently = false
	call_deferred(&"_update_paint_feedback")
	call_deferred(&"_persist_mask_to_file")   # ★ 按场景存到项目目录 data/fog_masks/

func ScaleDrawingCircleUp():
	# ★ 原来从 1000 起、上限 10 万，且下限卡在 100 —— 掩码只有 400 米时"一笔刷满、还降不下来"。
	#   改成比例+最小步，范围 1~2000 米。
	drawScale = min(drawScale * 1.15 + 0.5, 2000.0)
	SetDrawScale()

func ScaleDrawingCircleDown():
	drawScale = max(drawScale * 0.85 - 0.5, 1.0)
	SetDrawScale()

func DrawModeCancel():
	DrawWeightEnable.button_pressed = false
	DrawColorEnable.button_pressed = false
	DisableDrawMode()
	

func SetDrawScale():
	# ★ 地面雾的画笔应像"贴在地上的圆盘"：原来高度取 ceiling-floor(=45 米)，在地面上像根柱子
	if driver != null && driver.clouds_resource != null:
		drawBrushTool.scale = Vector3(drawScale, 0.2, drawScale)
	else:
		drawBrushTool.scale = Vector3(drawScale, 0.2, drawScale)

#region Draw Mode Toggles

func FloodFill():
	# ★★ 不可撤销的操作必须二次确认 ★★
	#   它会把**整张掩码**写成"当前颜色 + 落笔强度"的纯色 ⇒ 强度=1 时就是整个 400 米全覆盖，
	#   看起来就是"一点就整屏白"。原代码直接执行，没有任何提示。
	var resultColor : Color = DrawColorPicker.color
	resultColor.a = DrawStrength.value / DrawStrength.max_value
	var dlg := ConfirmationDialog.new()
	dlg.title = "整片填充掩码"
	dlg.dialog_text = "这会把整张掩码填成纯色（当前强度 %.2f），无法撤销。\n强度 1.0 时等于整个雾域铺满，画面会整片发白。\n\n确定要继续吗？" % resultColor.a
	dlg.ok_button_text = "确定填充"
	dlg.cancel_button_text = "取消"
	add_child(dlg)
	dlg.confirmed.connect(func():
		RenderingServer.call_on_render_thread(ExecuteCompute.bindv([0.0, true, resultColor]))
		print("Fog Layer: 已整片填充掩码（alpha=%.2f，可用【一键清除雾】撤销）" % resultColor.a)
		call_deferred("DisableDrawMode")
		# 填充后同样按场景存盘
		await get_tree().create_timer(0.2).timeout
		call_deferred(&"_persist_mask_to_file")
	)
	dlg.canceled.connect(func(): print("Fog Layer: 已取消整片填充"))
	dlg.popup_centered()

func DrawWeightToggled():
	DrawColorEnable.button_pressed = false
	
	if DrawWeightEnable.button_pressed && EnableDrawMode():
		currentDrawMode = DRAWINGMODE.weight
	else:
		DrawWeightEnable.button_pressed = false
		# ★ 原代码这里只把按钮弹回去，没有退出绘制模式 ⇒ 第二次点击无法退出，
		#   画笔指示器继续跟着鼠标、插件继续吞输入（退出只挂在 ESC 上）。
		DisableDrawMode()

func DrawColorToggled():
	DrawWeightEnable.button_pressed = false
	
	if DrawColorEnable.button_pressed && EnableDrawMode():
		currentDrawMode = DRAWINGMODE.color
	else:
		DrawColorEnable.button_pressed = false
		# ★ 同上：取消按下要真正退出绘制模式
		DisableDrawMode()

func EnableDrawMode() -> bool:
	if (!computeEnabled):
		InitializeMaskTexture()
	
	if (!is_instance_valid(currentRoot)):
		printerr("Fog Layer: 进入绘制模式失败 —— currentRoot 无效（先把场景打开/切到该场景）")
		return false
	print("Fog Layer: 绘制模式已开启（currentRoot=%s）" % currentRoot.name)
	drawBrushToolMaterial.albedo_color = DrawingColor
	if (!is_instance_valid(drawBrushTool)):
		drawBrushTool = drawBrushToolPrefab.instantiate() as MeshInstance3D
		currentRoot.add_child(drawBrushTool)
		SetDrawScale()
	
	return true

func DisableDrawMode():
	DrawColorEnable.button_pressed = false
	DrawWeightEnable.button_pressed = false
	currentDrawMode = DRAWINGMODE.none
	drawInverted = false
	print("Fog Layer: 已退出绘制模式")
	# ★ 立刻停止吞输入：插件 _forward_3d_gui_input 第一句就是看 currentDrawMode
	if (drawingCurrently):
		drawingCurrently = false
	
	if (is_instance_valid(drawBrushTool)):
		drawBrushTool.queue_free()
		drawBrushTool = null
	
	# ★★ 这里原来还有一段"退出绘制模式时把最后一次笔迹存盘"的残留代码，它执行：
	#      driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load(MaskFilePath.text)
	#    而掩码已改为内存（那个文件已不存在）⇒ load 返回 null ⇒ 渲染回调的守卫
	#    (… and extra_large_noise_patterns and …) 直接跳过整个 effect ⇒ **画完没雾且没有任何报错**。
	#    已整段移除。
	last_image_data = []

#endregion

func SetDrawInvert(mode : bool):
	if (currentDrawMode == DRAWINGMODE.weight && drawInverted != mode):
		drawInverted = mode
		drawBrushToolMaterial.albedo_color = InvertedDrawingColor if drawInverted else DrawingColor


#region draw tools helpers

func RetrieveTravelDistance(pos : Vector3, dir :Vector3) -> float:
	var t : float = (currentCloudsHeight - pos.y) / dir.y
	if (dir.y == 0 || t < 0.0):
		return -1.0
	
	
	return t * dir.length()

#endregion

#endregion

#Updates
func SetCloudsUpdating():
	if (driver != null):
		driver.update_continuously = CloudsActiveToggle.button_pressed
	
	UpdateStatusDisplay()


#
#
#
#
#@tool
#extends MeshInstance3D
#class_name WanderingTerrainDrawnStamp
#
#
#@export var visibleColorMat : ShaderMaterial = preload("res://addons/WanderingTerrain/Materials/StampMaterials/EraseChunkVisibleColorMat.tres")
#@export var highlightedColorMat : ShaderMaterial = preload("res://addons/WanderingTerrain/Materials/StampMaterials/EraseChunkHighlightedColorMat.tres")
#@export var thisStampIndex : Vector2
#@export var currentHeightmapImageTexture: Texture2D
#@export var currentColormapImageTexture: Texture2D
#@export var currentSplatmapImageTexture: Texture2D
#@export var currentMaterial : ShaderMaterial
#
#var newHeightmapImage : Image
#var newColormapImage : Image
#var newSplatmapImage : Image
#var newHeightmapdrawingDirty : bool = false
#var newColormapdrawingDirty : bool = false
#var newSplatmapdrawingDirty : bool = false
#var pixelChanged : bool = false
#
#enum DrawingUpdateMode {sculpting, colorpainting, splatpainting}
#
#var thisRect : Rect2
#
#
#func InitializeDrawnStamp(resolution : int, indexPosition : Vector2, position : Vector3, currentUpdateType : DrawingUpdateMode):
	#add_to_group("WanderingTerrainSculptingStamps", true);
	#thisStampIndex = indexPosition
	#global_position = position
	#currentMaterial = material_override.duplicate()
	#material_override = currentMaterial
	#
	#UpdateDrawnStamp(resolution, currentUpdateType)
#
#func SetVisible():
	#currentMaterial.next_pass = visibleColorMat
#
#func SetHidden():
	#currentMaterial.next_pass = null
#
#func Highlight():
	#currentMaterial.next_pass = highlightedColorMat
#
#func Unhightlight():
	#currentMaterial.next_pass = visibleColorMat
#
#func CheckHasAnyUpdate() -> bool:
	#
	#if (pixelChanged || currentHeightmapImageTexture != null || currentColormapImageTexture != null || currentSplatmapImageTexture != null):
		#return true
	#
	#return false
#
#func UpdateDrawnStamp(resolution : int, currentUpdateType : DrawingUpdateMode):
	#
	#match currentUpdateType:
		#DrawingUpdateMode.sculpting:
			#
			#if (newHeightmapImage == null || newHeightmapImage.get_width() != resolution):
				#if (currentHeightmapImageTexture != null && currentHeightmapImageTexture.get_width() == resolution):
					#newHeightmapImage = currentHeightmapImageTexture.get_image()
				#else:
					#currentHeightmapImageTexture = null
					#newHeightmapdrawingDirty = true
					#newHeightmapImage = Image.create(resolution, resolution, false, Image.FORMAT_RGF)
					#for x in resolution:
						#for y in resolution:
							#newHeightmapImage.set_pixel(x,y, Color(0.0,0.0,0.0,0.0))
			#
			#
			#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
			#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
		#
		#DrawingUpdateMode.colorpainting:
			#
			#if (newColormapImage == null || newColormapImage.get_width() != resolution):
				#if (currentColormapImageTexture != null && currentColormapImageTexture.get_width() == resolution):
					#newColormapImage = currentColormapImageTexture.get_image()
				#else:
					#currentColormapImageTexture = null
					#newColormapdrawingDirty = true
					#newColormapImage = Image.create(resolution, resolution, false, Image.FORMAT_RGBAF)
					#for x in resolution:
						#for y in resolution:
							#newColormapImage.set_pixel(x,y, Color(0.0,0.0,0.0,0.0))
			#
			#var imageTexture = ImageTexture.create_from_image(newColormapImage)
			#currentMaterial.set_shader_parameter("ColorMap", imageTexture)
			#currentMaterial.set_shader_parameter("HasColorMap", true);
		#
		#DrawingUpdateMode.splatpainting:
			#
			#if (newSplatmapImage == null || newSplatmapImage.get_width() != resolution):
				#if (currentSplatmapImageTexture != null && currentSplatmapImageTexture.get_width() == resolution):
					#newSplatmapImage = currentSplatmapImageTexture.get_image()
				#else:
					#currentSplatmapImageTexture = null
					#newSplatmapdrawingDirty = true
					#newSplatmapImage = Image.create(resolution, resolution, false, Image.FORMAT_RGBAF)
					#for x in resolution:
						#for y in resolution:
							#newSplatmapImage.set_pixel(x,y, Color(0.0,0.0,0.0,0.0))
			#
			#var imageTexture = ImageTexture.create_from_image(newSplatmapImage)
			#currentMaterial.set_shader_parameter("SplatMap", imageTexture)
			#currentMaterial.set_shader_parameter("HasSplatMap", true);
	#
	#
	#thisRect = Rect2(Vector2(global_position.x - resolution / 2, global_position.z - resolution / 2),Vector2(resolution, resolution))
#
#func IsInsideRect(targetPosition : Vector2, stampRadius : float) -> bool:
	#if thisRect.has_point(targetPosition) || thisRect.has_point(targetPosition + (Vector2(global_position.x, global_position.z) - targetPosition).normalized() * stampRadius):
		#return true
	#return false
#
#
#
#func PackStamp(terrainController : WanderingTerrainController):
	#if (newHeightmapdrawingDirty && newHeightmapImage != null):
		#newHeightmapdrawingDirty = false
		#var resultingResource = await terrainController.Editor_SaveImageToOutputFolder(newHeightmapImage, name + "_height_savedstamp", "exr")
		#if (resultingResource != null):
			#currentHeightmapImageTexture = resultingResource
			#currentMaterial.set_shader_parameter("HeightMap", currentHeightmapImageTexture)
	#
	#if (newColormapdrawingDirty && newColormapImage != null):
		#newColormapdrawingDirty = false
		#var resultingResource = await terrainController.Editor_SaveImageToOutputFolder(newColormapImage, name + "_color_savedstamp", "exr")
		#if (resultingResource != null):
			#currentColormapImageTexture = resultingResource
			#currentMaterial.set_shader_parameter("ColorMap", currentColormapImageTexture)
	#
	#if (newSplatmapdrawingDirty && newSplatmapImage != null):
		#newSplatmapdrawingDirty = false
		#var resultingResource = await terrainController.Editor_SaveImageToOutputFolder(newSplatmapImage, name + "_splatmap_savedstamp", "exr")
		#if (resultingResource != null):
			#currentSplatmapImageTexture = resultingResource
			#currentMaterial.set_shader_parameter("SplatMap", currentSplatmapImageTexture)
#
#func ColorPainting_DrawOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, color : Color, layer : DrawingUpdateMode):
	#var localPosition : Vector3 = targetPosition - global_position
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#var currentImage : Image
	#if (layer == DrawingUpdateMode.colorpainting):
		#newColormapdrawingDirty = true
		#currentImage = newColormapImage
	#else:
		#newSplatmapdrawingDirty = true
		#currentImage = newSplatmapImage
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= currentImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= currentImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = currentImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#
			#if (thisColor.a == 0):
				#thisColor.r = color.r
				#thisColor.g = color.g 
				#thisColor.b = color.b
			#
			#thisColor.r = lerpf(thisColor.r, color.r, stampAlpha * power * 0.2)
			#thisColor.g = lerpf(thisColor.g, color.g, stampAlpha * power * 0.2)
			#thisColor.b = lerpf(thisColor.b, color.b, stampAlpha * power * 0.2)
			#
			### Handles opacity, which always goes up.
			#thisColor.a = clampf(thisColor.a + (stampAlpha * abs(power) * 0.2), 0.0, 1.0)
			#currentImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(currentImage)
	#
	#if (layer == DrawingUpdateMode.colorpainting):
		#currentMaterial.set_shader_parameter("ColorMap", imageTexture)
		#newColormapImage = currentImage
	#else:
		#currentMaterial.set_shader_parameter("SplatMap", imageTexture)
		#newSplatmapImage = currentImage
#
#func ColorPainting_EraseOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, layer : DrawingUpdateMode):
	#var localPosition : Vector3 = targetPosition - global_position
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#var currentImage : Image
	#if (layer == DrawingUpdateMode.colorpainting):
		#newColormapdrawingDirty = true
		#currentImage = newColormapImage
	#else:
		#newSplatmapdrawingDirty = true
		#currentImage = newSplatmapImage
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= currentImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= currentImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = currentImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#
			#thisColor.a = clampf(thisColor.a - stampAlpha * power * 0.2, 0.0, 1.0)
			#
			#currentImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
	#
	#var imageTexture = ImageTexture.create_from_image(currentImage)
	#
	#if (layer == DrawingUpdateMode.colorpainting):
		#currentMaterial.set_shader_parameter("ColorMap", imageTexture)
		#newColormapImage = currentImage
	#else:
		#currentMaterial.set_shader_parameter("SplatMap", imageTexture)
		#newSplatmapImage = currentImage
#
#func Sculpt_EraseOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			##thisColor.r += (0.5 - thisColor.r) * stampAlpha * power * 0.2
			#thisColor.g = clampf(thisColor.g - stampAlpha * power * 0.2, 0.0, 1.0)
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
#
#func Sculpt_SmoothOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, worldScale : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var heightValue : float = clamp((targetPosition.y) / worldScale, 0.0, 1.0)
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#thisColor.r = clampf(thisColor.r + ((heightValue - thisColor.r) * stampAlpha * power * 0.2), 0.0, 1.0)
			#thisColor.g = clampf(thisColor.g + ((0.0 - thisColor.g) * stampAlpha * power * 0.05), 0.0, 1.0)
			#
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
#
#
#func Sculpt_DrawOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, worldScale : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var heightValue = clamp(targetPosition.y / worldScale, 0.0, 1.0)
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			### Handles actual value.
			#if (thisColor.g == 0):
				#thisColor.r = heightValue
			#thisColor.r = clampf(thisColor.r + (stampAlpha * power * 0.05), 0.0, 1.0)
			### Handles opacity, which always goes up.
			#thisColor.g = clampf(thisColor.g + (stampAlpha * abs(power) * 0.05), 0.0, 1.0)
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
#
#func Sculpt_SetHeightOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, heightValue : float, power : float, worldScale : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var currentHeight = clamp(targetPosition.y / worldScale, 0.0, 1.0)
	#heightValue = clamp(heightValue / worldScale, 0.0, 1.0)
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#
			#if (thisColor.g == 0):
				#thisColor.r = currentHeight
			#
			#thisColor.r = clampf(thisColor.r + ((heightValue - thisColor.r) * stampAlpha * power), 0.0, 1.0)
			### Handles opacity, which always goes up.
			#thisColor.g = clampf(thisColor.g + (stampAlpha * abs(power) * 0.2), 0.0, 1.0)
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
