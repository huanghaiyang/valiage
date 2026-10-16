@tool
extends EditorInspectorPlugin
## 蝴蝶群的**检查器批量面板** —— 在 ButterflySwarm 的「素材」分组上插入一排按钮。
##
## ★★ 为什么需要它（这是用户真实痛点）★★
##   `sprites` 是 `Array[Texture2D]`，Godot 默认的数组 UI 只有一个「添加元素」按钮，
##   每次只能加**一张**。20 张蝴蝶素材 = 点 20 次 + 在文件对话框里一张张找，
##   而"换一批蝴蝶"是高频操作 —— 所以要给一个**批量入口**。
##
## ★ 这个面板**不实现业务逻辑**：它只负责按钮与对话框，真正的加载/过滤/去重都在
##   `butterfly_swarm.gd` 的 `add_sprites_from_paths` / `add_all_sprites_from_folder` /
##   `add_random_sprites` 里。这样脚本用户也能用同一套 API。
##
## ★ 另外还提供：把**场景树里选中的节点**当目标（选中蝴蝶子节点时向上找父级），
##   以及一次 `Ctrl+Z` 可撤销（用 EditorUndoRedoManager 包住属性赋值）。
##
## 依赖：addons/butterfly_swarm/butterfly_swarm.gd（preload，避免依赖 global class 缓存）

const BFLY_SWARM := preload("res://addons/butterfly_swarm/butterfly_swarm.gd")
## 素材默认目录（独立写一份常量，避免为了它再多 preload 一个脚本）
const SPRITE_DIR := "res://assets/textures/活体/蝴蝶"

## 目标节点（buttons 的回调里要改它的 sprites）
var _target: Node = null
## 「直接填路径」用的输入框
var _path_edit: LineEdit = null
## 状态标签（"已配 N 张 / 目录里共 M 张"）
var _status: Label = null
## UV 重建的状态标签（显示"上次重建：N 张 ｜ 代数 G"）
var _uv_status: Label = null


func _can_handle(object: Object) -> bool:
	return object != null and object.get_script() == BFLY_SWARM


func _parse_begin(object: Object) -> void:
	_target = object as Node
	var root := VBoxContainer.new()
	root.name = "ButterflyBatchPanel"
	root.add_theme_constant_override("separation", 3)

	# ---- 标题 ----
	var title := Label.new()
	title.text = "素材批量添加"
	title.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	root.add_child(title)

	# ---- ★ 可见的说明行（不靠 hover）----
	# 为什么要有它：按钮上的 `tooltip_text` 只有悬停才看得到，
	# 而"哪几个动作、会不会覆盖、快捷键是什么"是**一眼就该看到**的信息。
	var hint := Label.new()
	hint.text = "点按钮即可批量加入下方 Sprites ｜ 只追加、自动去重 ｜ Ctrl+Z 可撤销"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.68, 0.68, 0.68))
	root.add_child(hint)

	# ---- 按钮区（两行，省纵向空间）----
	var row1 := HBoxContainer.new()
	row1.add_child(_btn("全部", "把素材目录里的蝴蝶 PNG 一次全部加进来（20 张）",
			_on_add_all))
	row1.add_child(_btn("选文件…", "打开文件对话框，可按住 Ctrl / Shift 一次多选若干 PNG",
			_on_pick_files))
	row1.add_child(_btn("随机 8 张", "从素材目录随机**追加** 8 张（追加，不替换已有）",
			_on_add_random))
	row1.add_child(_btn("清空", "清空 sprites（之后退回「按清单兜底 8 张」的行为）",
			_on_clear))
	root.add_child(row1)

	# ---- ★ UV 重建（用户诉求："UV 如果不能动态实现，那么需要一个按钮实现 UV 生成"）----
	#   说明：现在 rebuild 时会**按内容指纹自动**为每张图算裁剪框，换图即失效重算；
	#   这个按钮是**手动兜底** —— 想立刻看到结果、或怀疑裁剪不对时点一下。
	var row_uv := HBoxContainer.new()
	row_uv.add_child(_btn("重建 UV 裁剪", "清缓存并对当前所有素材重新扫描不透明包围盒（换图后点这个）",
			_on_regen_uv))
	_uv_status = Label.new()
	_uv_status.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	row_uv.add_child(_uv_status)
	root.add_child(row_uv)

	# ---- 直接填路径（适合从别处拷一串路径）----
	var row2 := HBoxContainer.new()
	_path_edit = LineEdit.new()
	_path_edit.placeholder_text = "或粘贴路径（多个用 ; 分隔）后回车"
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.tooltip_text = "支持 res:// 路径与绝对路径；多个用分号 / 换行分隔"
	_path_edit.text_submitted.connect(_on_paths_submitted)
	row2.add_child(_path_edit)
	row2.add_child(_btn("添加", "把上面输入的路径批量加进来", func() -> void:
		_on_paths_submitted(_path_edit.text)))
	root.add_child(row2)

	# ---- 状态 ----
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	root.add_child(_status)
	_refresh_status()

	add_custom_control(root)


## 建一个带 tooltip 的小按钮。
func _btn(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


## 刷新状态标签："已配 N 张 / 目录里共 M 张 ｜ 目录：xxx"
func _refresh_status() -> void:
	if _status == null or not is_instance_valid(_status):
		return
	if _target == null or not is_instance_valid(_target):
		_status.text = "（未选中 ButterflySwarm）"
		return
	var s: Dictionary = _target.call("sprite_summary")
	_status.text = "已配 %d 张 ｜ 目录里共 %d 张 ｜ %s" % [
			int(s.get("configured", 0)), int(s.get("available", 0)), String(s.get("dir", ""))]


## 让检查器重新显示这个对象（批量改完素材后刷新数组 UI）。
##
## ★★ 实测：`EditorInspector` 上**没有**任何"刷新"接口 ★★
##   Godot 4.7 实测（`.runtime/bfly_inspector_api.gd` 把 484 个方法全列了一遍）：
##     has_method("refresh")         = false   ← 第一版误用，用户实测报
##                                                `Invalid call. Nonexistent function 'refresh'`
##     has_method("update_property") = false   ← 第二版误用（我按旧记忆写的）
##     has_method("edit")            = true    （滚动到某个对象）
##   `EditorInterface` 侧可用的是 **`inspect_object()`**（重新检视一个对象）。
##
##   这里用 `call_deferred` 调用它：**必须**等 UndoRedo 事务与 `rebuild()` 都走完再重检视，
##   否则在事务中途重建检查器 UI 会干扰撤销栈（而且数组内容是先写好的，重检视只是刷新显示）。
##   顺带：这一步**失败也不影响功能** —— 素材已经真加进去了，只是面板数字要等下次点选才更新。
func _refresh_property() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var obj: Object = _target
	EditorInterface.call_deferred("inspect_object", obj)


## 统一入口：批量改 sprites + 用 UndoRedo 包住（可 Ctrl+Z）+ 重建 + 刷新检查器。
## 参数 before：改动前的素材数组（撤销时还原）。
## 参数 added：本次新增张数（用于日志）。
func _apply_batch(before: Array, added: int, what: String) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	if added <= 0:
		print("[蝴蝶] %s：没有新增（可能全都已经在列表里了）" % what)
		_refresh_status()
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(what)
	ur.add_do_property(_target, "sprites", _target.get("sprites"))
	ur.add_undo_property(_target, "sprites", before)
	ur.commit_action()
	_target.call("rebuild")
	print("[蝴蝶] %s：新增 %d 张 -> 现在共 %d 张" % [what, added, int(_target.call("sprite_count"))])
	_refresh_status()
	_refresh_property()


# ==================== 按钮回调 ====================

## ★ 重建 UV 裁剪：清缓存 + 逐张重扫包围盒 + 写回每只蝴蝶 + 显示统计。
## 参数：无（用户点击触发）。
## 副作用：会真扫像素（20 张大图约 1~3 秒，期间编辑器会卡一下 —— 这是必要的代价）；
##   改每只蝴蝶的 crop 与材质 uniform；**不重建节点**，所以位置/状态不丢。
func _on_regen_uv() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var t0 := Time.get_ticks_msec()
	var res: Dictionary = _target.call("regenerate_uv")
	var ms := Time.get_ticks_msec() - t0
	var msg := "上次重建：%d 张 ｜ 第 %d 代 ｜ %d ms" % [
			int(res.get("count", 0)), int(res.get("generation", 0)), ms]
	if _uv_status != null and is_instance_valid(_uv_status):
		_uv_status.text = msg
	print("[蝴蝶] UV 重建完成：%s（素材 %d 张）" % [msg, int(res.get("sprites", 0))])
	_refresh_status()


func _on_add_all() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var before: Array = (_target.get("sprites") as Array).duplicate()
	var added: int = _target.call("add_all_sprites_from_folder", "", 0)
	_apply_batch(before, added, "批量添加全部蝴蝶素材")


func _on_add_random() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var before: Array = (_target.get("sprites") as Array).duplicate()
	var added: int = _target.call("add_random_sprites", 8, 0)
	_apply_batch(before, added, "随机追加 8 张蝴蝶素材")


func _on_clear() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var before: Array = (_target.get("sprites") as Array).duplicate()
	var cur: Array = _target.get("sprites")
	if cur.is_empty():
		_refresh_status()
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("清空蝴蝶素材")
	ur.add_do_method(_target, "clear_sprites")
	ur.add_undo_property(_target, "sprites", before)
	ur.commit_action()
	_target.call("rebuild")
	print("[蝴蝶] 已清空素材（撤销可恢复 %d 张）" % before.size())
	_refresh_status()
	_refresh_property()


func _on_paths_submitted(text: String) -> void:
	if _target == null or not is_instance_valid(_target) or text.strip_edges().is_empty():
		return
	# 分号 / 换行 / 竖线都能当分隔符（从别处粘贴路径时格式不一）
	var parts: Array = []
	for seg in text.replace("\n", ";").replace("|", ";").split(";"):
		var s := String(seg).strip_edges()
		if not s.is_empty():
			parts.append(s)
	var before: Array = (_target.get("sprites") as Array).duplicate()
	var added: int = _target.call("add_sprites_from_paths", parts)
	_apply_batch(before, added, "按路径批量添加蝴蝶素材")
	if _path_edit != null and is_instance_valid(_path_edit):
		_path_edit.text = ""


func _on_pick_files() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var dlg := EditorFileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dlg.access = FileDialog.ACCESS_RESOURCES
	dlg.title = "选择一张或多张蝴蝶 PNG（按住 Ctrl / Shift 多选）"
	dlg.add_filter("*.png", "PNG 图片")
	dlg.current_dir = SPRITE_DIR
	dlg.files_selected.connect(func(paths: PackedStringArray) -> void:
		if _target == null or not is_instance_valid(_target):
			return
		var before: Array = (_target.get("sprites") as Array).duplicate()
		var added: int = _target.call("add_sprites_from_paths", Array(paths))
		_apply_batch(before, added, "多选添加蝴蝶素材"))
	# ⚠ 本类是 `EditorInspectorPlugin`（RefCounted，**不是 Node**），所以没有 `add_child()`。
	#   对话框必须挂到编辑器自己的节点上：`EditorInterface.get_base_control()`（编辑器主 Control，是 Node）。
	#   挂到它下面既能被正常绘制/居中，也会随编辑器一起销毁。
	var host := EditorInterface.get_base_control()
	if host == null:
		push_warning("[蝴蝶] 拿不到编辑器主 Control，无法弹出文件对话框")
		dlg.free()
		return
	host.add_child(dlg)
	dlg.popup_centered_ratio(0.6)
	dlg.canceled.connect(func() -> void:
		dlg.queue_free())
	# files_selected 之后也必须释放，否则每开一次对话框就多留一个节点
	dlg.files_selected.connect(func(_p: PackedStringArray) -> void:
		dlg.queue_free())
