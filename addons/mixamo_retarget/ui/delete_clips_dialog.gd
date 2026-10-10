@tool
class_name MixamoDeleteClipsDialog
extends ConfirmationDialog

## 从 AnimationLibrary(.tres) 里删除选中的动画。
## 结构照抄本项目 addons/blend_tools/preview_window.gd：
##   * _init 里**只做窗口自身设置**（title/按钮/size/min_size）—— 不能读主题、不能建控件：
##     EditorInterface.get_editor_theme() 无头环境一调用，整个 _init 就中断，UI 根本不会生成；
##   * UI 在 _ready 里建（_build_ui），主题单独在 _apply_theme 里用 Engine.is_editor_hint() 守卫；
##   * 不用 autowrap 的 Label（最小高度会爆炸 —— exr_tools/convert_dialog.gd 里踩过）。

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")

var lib_path: String = ""
var _tree: Tree
var _status: Label


func _init() -> void:
	title = "删除动画"
	ok_button_text = "删除勾选的动画"
	cancel_button_text = "关闭"
	dialog_hide_on_ok = false
	confirmed.connect(_on_delete)
	size = Vector2i(760, 420)
	min_size = Vector2i(560, 360)


func _ready() -> void:
	_apply_theme()
	if get_child_count() == 0:
		_build_ui()


func _apply_theme() -> void:
	if not Engine.is_editor_hint():
		return
	var th := EditorInterface.get_editor_theme()
	if th != null:
		theme = th


func _build_ui() -> void:
	var panel := PanelContainer.new()
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var hint := Label.new()
	hint.text = "勾选要删除的动画（只从 .tres 里移除，不删源 fbx）"
	hint.clip_text = true
	vb.add_child(hint)

	_tree = Tree.new()
	_tree.columns = 3
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.set_column_title(0, "动画")
	_tree.set_column_title(1, "时长")
	_tree.set_column_title(2, "轨道")
	_tree.set_column_expand(0, true)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(520, 220)
	_tree.item_edited.connect(_update_status)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 230)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	scroll.add_child(_tree)

	_status = Label.new()
	_status.clip_text = true
	vb.add_child(_status)

	var row := HBoxContainer.new()
	vb.add_child(row)
	var b_all := Button.new()
	b_all.text = "全选"
	b_all.pressed.connect(func() -> void: _check_all(true))
	row.add_child(b_all)
	var b_none := Button.new()
	b_none.text = "全不选"
	b_none.pressed.connect(func() -> void: _check_all(false))
	row.add_child(b_none)
	var b_dup := Button.new()
	b_dup.text = "勾选疑似重复"
	b_dup.pressed.connect(_check_probable_dups)
	row.add_child(b_dup)


## 打开并填充指定库（由右键菜单调用，随后自己 popup_centered()）
func open_library(path: String) -> bool:
	lib_path = path
	var lib: AnimationLibrary = ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_REUSE)
	if lib == null:
		push_error("[Mixamo绑定] 不是 AnimationLibrary 或读取失败：" + path)
		queue_free()
		return false
	if get_child_count() == 0:
		_build_ui()                     # 万一 _ready 还没跑
	title = "删除动画 — %s（共 %d 条）" % [path.get_file(), lib.get_animation_list().size()]
	_fill(lib)
	return true


func _fill(lib: AnimationLibrary) -> void:
	if _tree == null:
		return
	_tree.clear()
	var root := _tree.create_item()
	for c in Core.list_clips(lib):
		var item := _tree.create_item(root)
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_editable(0, true)
		item.set_checked(0, false)
		item.set_text(0, String(c["name"]))
		item.set_text(1, "%.2fs" % float(c["length"]))
		item.set_text(2, str(int(c["tracks"])))
	_update_status()


func _check_all(on: bool) -> void:
	if _tree == null:
		return
	var item := _tree.get_root().get_first_child()
	while item != null:
		item.set_checked(0, on)
		item = item.get_next()
	_update_status()


func _check_probable_dups() -> void:
	if _tree == null:
		return
	var item := _tree.get_root().get_first_child()
	var hit := 0
	while item != null:
		var n := item.get_text(0).to_lower()
		if n.contains(" copy") or n.ends_with("copy") or n.contains("(1)") or n.contains("(2)") or n.contains("- copy"):
			item.set_checked(0, true)
			hit += 1
		item = item.get_next()
	_status.text = "已勾选 %d 条疑似重复" % hit
	get_ok_button().disabled = _checked_names().is_empty()   # 勾选后必须刷新"删除"按钮，否则一直是灰的


func _checked_names() -> PackedStringArray:
	var out := PackedStringArray()
	if _tree == null:
		return out
	var item := _tree.get_root().get_first_child()
	while item != null:
		if item.is_checked(0):
			out.append(item.get_text(0))
		item = item.get_next()
	return out


func _update_status() -> void:
	if _status == null:
		return
	var n := _checked_names().size()
	_status.text = "已勾选 %d 条" % n
	get_ok_button().disabled = n == 0


func _on_delete() -> void:
	var names := _checked_names()
	if names.is_empty():
		return
	var lib: AnimationLibrary = ResourceLoader.load(lib_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_REUSE)
	if lib == null:
		push_error("[Mixamo绑定] 载入失败：" + lib_path)
		return
	var n := Core.delete_clips(lib, names)
	if n == 0:
		print("[Mixamo绑定] 没有动画被删除（可能已不存在）")
		return
	var err := ResourceSaver.save(lib, lib_path)
	if err != OK:
		push_error("[Mixamo绑定] 保存失败（%d）：%s" % [err, lib_path])
		return
	print("[Mixamo绑定] 已从 %s 删除 %d 条动画：%s" % [lib_path.get_file(), n, ", ".join(names)])
	print("[Mixamo绑定] 库内剩余 %d 条" % lib.get_animation_list().size())
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().update_file(lib_path)
	_fill(lib)
