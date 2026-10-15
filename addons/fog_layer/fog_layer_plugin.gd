@tool
extends EditorPlugin

var dock : CloudsEditorController
var _input_hits : int = 0   # 定向打印用：进入绘制模式后只打印前 3 次视口输入

## 注册本插件的中文翻译（让 Inspector 里的属性名/分组显示中文）
func _register_translations() -> void:
	for suffix in ["zh_CN", "zh"]:
		var path := "res://addons/fog_layer/translations/fog_layer.%s.translation" % suffix
		if ResourceLoader.exists(path):
			var tr := ResourceLoader.load(path)
			if tr is Translation:
				TranslationServer.add_translation(tr)
				print("Fog Layer: 已加载中文翻译（%s）" % suffix)
				return


func _handles(object: Object) -> bool:
	return object is FogLayerDriver

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	# ★ 防御式调用：控制器脚本若被编辑器以"写了一半"的状态缓存过（尾部函数丢失），
	#   非防御的调用会在这里抛 "Nonexistent function" 并**中断整个回调** ⇒ 画笔不跟手。
	#   这里逐个 has_method 检查：脚本不完整时安静放行，不刷错误、也不影响其它输入。
	if dock == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not dock.has_method("IterateCursorLocation"):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if dock.get("currentDrawMode") == CloudsEditorController.DRAWINGMODE.none:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	
	if (Input.is_key_pressed(KEY_ESCAPE)):
		if dock.has_method("DrawModeCancel"):
			dock.DrawModeCancel()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	
	# ★ 掩码极性：白(1)=出雾、黑(0)=无雾（原版行为）。
	#   所以**左键拖拽就是画雾**（加 alpha/变白）；按住 Ctrl 反向 = 擦除。
	if dock.has_method("SetDrawInvert"):
		dock.SetDrawInvert(Input.is_key_pressed(KEY_CTRL))
	
	if event is InputEventMouse:
		# ★ 定向打印：只在进入绘制模式后打印前几行，用来确认"视口输入到底有没有送到插件"
		if _input_hits < 3:
			_input_hits += 1
			print("Fog Layer: 收到 3D 视口输入（第 %d 次）mode=%d" % [_input_hits, int(dock.get("currentDrawMode"))])
		dock.IterateCursorLocation(viewport_camera, event)
	
	if (event is InputEventMouseButton):
		if (event.button_index == MOUSE_BUTTON_LEFT):
			if event.is_pressed():
				if dock.has_method("BeginCursorDraw"):
					dock.BeginCursorDraw()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			elif dock.get("drawingCurrently"):
				if dock.has_method("EndCursorDraw"):
					dock.EndCursorDraw()
				# (已移除：编辑器插件不应改鼠标模式)
		elif !Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			if (event.button_index == MOUSE_BUTTON_WHEEL_UP):
				if dock.has_method("ScaleDrawingCircleUp"):
					dock.ScaleDrawingCircleUp()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			elif (event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				if dock.has_method("ScaleDrawingCircleDown"):
					dock.ScaleDrawingCircleDown()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
	
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func _enter_tree() -> void:
	_register_translations()

	dock = preload("res://addons/fog_layer/Dock/CloudsEditorDock.tscn").instantiate() as CloudsEditorController
	add_control_to_dock(DOCK_SLOT_LEFT_UR, dock)
	
	# ★ 防御式：dock.SceneChanged 是直接取方法引用，脚本一旦只加载了一半（编辑器缓存/写坏缩进）
	#   这里就会抛 "Invalid access to property or key 'SceneChanged'" 并让插件加载失败。
	if dock != null and dock.has_method("SceneChanged"):
		scene_changed.connect(dock.SceneChanged)
	else:
		printerr("Fog Layer: 面板脚本未完整加载（缺 SceneChanged），场景切换联动被跳过")
	dock.call_deferred(&"InitialSceneLoad")
	set_input_event_forwarding_always_enabled()


func _exit_tree() -> void:
	# ★ 同样防御：未连上就不断开（否则退出时再报一次同样的错）
	if dock != null and dock.has_method("SceneChanged") and scene_changed.is_connected(dock.SceneChanged):
		scene_changed.disconnect(dock.SceneChanged)
	
	# ★★ 卸载顺序（这个顺序错了就会报 uniform_set is null）★★
	#   场景里的 effect 还在 compositor 里渲染，而它引用的掩码纹理属于本面板。
	#   所以必须在释放面板资源**之前**让渲染侧解绑掩码引用。
	if dock != null and dock.get("driver") != null:
		var drv = dock.get("driver")
		if drv != null and drv.clouds_resource != null and drv.clouds_resource.has_method("refresh_compute"):
			drv.clouds_resource.refresh_compute()
			print("Fog Layer: 卸载前已解绑掩码引用")
	
	# ★ 卸载插件时顺手回收画笔指示器（CloudsDrawBrush）。
	#   否则它会作为普通节点留在被编辑的场景里 —— 表现就是视口里一个巨大的黑圆，
	#   而且插件一旦加载失败就没人清它。
	if dock != null and dock.has_method("DisableDrawMode"):
		dock.DisableDrawMode()
	
	if dock != null:
		remove_control_from_docks(dock)
		dock.free()
