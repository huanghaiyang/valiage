@tool
extends EditorContextMenuPlugin
## 场景树右键「随机化变体…」：弹多选对话框挑 .tscn，然后对选中节点的实例做随机替换。

const Randomizer := preload("res://addons/variant_tools/variant_randomizer.gd")

var _added_at := 0
var _dlg: EditorFileDialog = null


func _popup_menu(paths: PackedStringArray) -> void:
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item("随机化变体…", _on_open)
	add_context_menu_item("修复 World Brush 实例标记", _on_repair)


func _on_open(_paths: Variant = null) -> void:
	var sel := EditorInterface.get_selection()
	if sel == null or sel.get_selected_nodes().is_empty():
		push_warning("[变体工具] 先在场景树里选中要处理的节点（比如刷好的草丛容器）")
		return
	_show_picker()


## 多变体选择对话框（可以一次选很多 .tscn）
func _show_picker() -> void:
	if _dlg != null and is_instance_valid(_dlg):
		_dlg.queue_free()
	_dlg = EditorFileDialog.new()
	_dlg.access = EditorFileDialog.ACCESS_RESOURCES
	_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES        # ★ 多选
	_dlg.title = "选择变体（可多选 .tscn）"
	_dlg.add_filter("*.tscn", "场景")
	# 默认目录：优先用当前选中实例所在的目录，方便"就地挑同目录的其它变体"
	var guess := _guess_dir()
	if not guess.is_empty():
		_dlg.current_dir = guess
	if _dlg.has_signal("files_selected"):
		_dlg.files_selected.connect(_on_files_chosen)
	else:
		_dlg.file_selected.connect(_on_one_chosen)
		_dlg.multi_selected.connect(_on_multi_chosen)
	EditorInterface.get_base_control().add_child(_dlg)
	_dlg.popup_centered_ratio(0.6)


func _guess_dir() -> String:
	var sel := EditorInterface.get_selection()
	if sel == null:
		return ""
	for n in sel.get_selected_nodes():
		var root := n.get_tree().edited_scene_root if n.get_tree() != null else null
		if n is Node and not String(n.scene_file_path).is_empty():
			return String(n.scene_file_path).get_base_dir()
		var stack: Array = [n]
		while not stack.is_empty():
			var c: Node = stack.pop_back()
			if not String(c.scene_file_path).is_empty():
				return String(c.scene_file_path).get_base_dir()
			for ch in c.get_children():
				stack.append(ch)
	return ""


func _on_files_chosen(files: PackedStringArray) -> void:
	_apply(_to_array(files))


func _on_multi_chosen(_path: String, files: PackedStringArray) -> void:
	_apply(_to_array(files))


func _on_one_chosen(path: String) -> void:
	_apply([path])


## 修复：早期随机化出来的实例没继承 World Brush 的实例标记 -> 擦不掉。
## 选中那一片（容器）-> 这一项 -> 给所有场景实例补上标记。
func _on_repair(_paths: Variant = null) -> void:
	var sel := EditorInterface.get_selection()
	if sel == null or sel.get_selected_nodes().is_empty():
		_report("变体工具", "先在场景树里选中要修复的节点（比如 WorldBrushInstances 或它下面的那片草）")
		return
	var total_scanned := 0
	var total_fixed := 0
	var lines: Array = []
	for n in sel.get_selected_nodes():
		var r: Dictionary = Randomizer.repair_wb_meta(n)
		total_scanned += int(r.get("scanned", 0))
		total_fixed += int(r.get("fixed", 0))
		lines.append("· %s：%s" % [n.name, String(r.get("message", ""))])
	_report("变体工具 - 修复实例标记",
			"补上 World Brush 实例标记 %d 个（共扫描 %d 个场景实例）\n补完后 World Brush 的擦除/清除就能认出它们了。\n\n%s" % [
					total_fixed, total_scanned, "\n".join(lines)])


func _to_array(v: PackedStringArray) -> Array:
	var out: Array = []
	for p in v:
		out.append(String(p))
	return out


func _apply(paths: Array) -> void:
	var sel := EditorInterface.get_selection()
	if sel == null or sel.get_selected_nodes().is_empty():
		_report("变体工具", "场景树里没有选中任何节点。\n先选中刷好的那一片（容器或实例都行），再重试。")
		return
	if paths.size() < 2:
		_report("变体工具", "只选了 %d 个变体。\n随机化至少需要 2 个不同的 .tscn —— 在弹出的对话框里按住 Ctrl 多选几个。" % paths.size())
		return

	var lines: Array = []
	var total := 0
	var zero_nodes: Array = []
	for n in sel.get_selected_nodes():
		var r: Dictionary = Randomizer.randomize(n, paths)
		if bool(r.get("ok", false)):
			total += int(r.get("changed", 0))
			lines.append("· %s：%s" % [n.name, String(r.get("message", ""))])
			# 完整分布打到 Output（弹框里只放摘要，否则会长到几千像素）
			var full: Dictionary = r.get("dist", {})
			if not full.is_empty():
				print("[变体工具] %s 完整分布: %s" % [n.name, str(full)])
			if int(r.get("changed", 0)) == 0:
				zero_nodes.append(n)
		else:
			lines.append("· %s：%s" % [n.name, String(r.get("message", ""))])

	# 每个节点只留一行摘要，且最多列 10 行（多了就看 Output 面板）
	var shown_lines: Array = []
	for i in range(mini(10, lines.size())):
		shown_lines.append(lines[i])
	if lines.size() > 10:
		shown_lines.append("... 还有 %d 个节点（详见 Output 面板）" % (lines.size() - 10))
	var head := "共替换 %d 个实例%s" % [total, "（Ctrl+Z 可撤销）" if total > 0 else ""]
	var body := head + "\n\n" + "\n".join(shown_lines)
	# 一个都没换 -> 把实例实际用到的场景列出来，方便对照（这是最常见的原因：选的变体和实例不是同一批）
	if total == 0 and not zero_nodes.is_empty():
		body += "\n\n【为什么没生效】选中的节点里，实例实际引用的是下面这些场景：\n"
		var shown := 0
		for n in zero_nodes:
			var survey: Dictionary = Randomizer.survey_scene_paths(n)
			if survey.is_empty():
				body += "· %s：这一支里没有任何场景实例（scene_file_path 为空）\n" % n.name
				continue
			for k in survey.keys():
				if shown < 8:
					body += "   %s ×%d\n" % [String(k).replace("res://", ""), int(survey[k])]
					shown += 1
		body += "\n对照一下你选的：\n"
		for p in paths:
			body += "   %s\n" % String(p).replace("res://", "")
	_report("变体工具 - 结果", body)


## 弹一个结果对话框（光 print 到 Output 面板用户看不到）
func _report(title: String, text: String) -> void:
	print("[变体工具] " + text.replace("\n", " ｜ "))
	# 关键：不要用 dialog_text —— AcceptDialog 的标签**不自动换行**，
	# 内容一长就把窗口撑到几千像素宽（实测 3840px）。这里自己放一个
	# 自动换行的 Label 进 ScrollContainer，并给对话框固定尺寸。
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.ok_button_text = "知道了"
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2i(600, 240)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2i(580, 0)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(lbl)
	dlg.add_child(scroll)
	var base := EditorInterface.get_base_control()
	if base == null:
		dlg.free()
		return
	base.add_child(dlg)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	dlg.popup_centered(Vector2i(640, 380))