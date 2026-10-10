@tool
class_name MixamoRetargetDock
extends VBoxContainer

## Mixamo 动画绑定面板
##   ① 扫描源动画（看每个 fbx 里有几条动画、哪些是静止 take）
##   ② 生成动画库（重定向到目标角色骨架，多个文件汇总成一份 AnimationLibrary）
##   ③ 生成场景（角色 + AnimationPlayer + 动画库）
##
## 算法：把源骨骼的**世界形变** D = G_pose·rest⁻¹ 搬到目标 rest 上（G_tgt = D·rest_tgt），
## 位移按髋高比缩放、朝向自动对齐，因此角色身高/骨架结构不同也能直接用。

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")

const DEFAULT_SRC_DIR := "res://assets/mixamo"
const DEFAULT_TGT := "res://assets/models/characters/森林男.glb"
const DEFAULT_OUT := "res://assets/animations/mixamo.tres"

var src_dir_edit: LineEdit
var tgt_edit: LineEdit
var out_edit: LineEdit
var fps_spin: SpinBox
var pos_mode: OptionButton
var auto_yaw_check: CheckBox
var incremental_check: CheckBox
var prune_check: CheckBox
var yaw_spin: SpinBox
var clip_tree: Tree
var log_view: RichTextLabel
var _host: VBoxContainer
var _confirm: ConfirmationDialog
var _confirm_names := PackedStringArray()


func _ready() -> void:
	name = "Mixamo 动画绑定"
	custom_minimum_size = Vector2(300, 0)
	# 关键：内容放进 ScrollContainer，否则面板的最小高度（约 600+px）会把编辑器的底部面板挤成 0 高度
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scroll)
	_host = VBoxContainer.new()
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 垂直也要 EXPAND：否则内容永远只有最小高度，面板拉高时日志区不会跟着长（ScrollContainer 会按 EXPAND 把内容撑到容器高度）
	_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host.add_theme_constant_override("separation", 6)
	scroll.add_child(_host)
	_build_ui()


# ------------------------------------------------------------------ UI

func _build_ui() -> void:
	var title := Label.new()
	title.text = "Mixamo 动画绑定（FBX/glb → 你的角色骨架）"
	title.add_theme_font_size_override("font_size", 14)
	_host.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host.add_child(grid)
	src_dir_edit = _row(grid, "源目录", DEFAULT_SRC_DIR, func() -> void: _pick_dir(src_dir_edit))
	tgt_edit = _row(grid, "目标角色", DEFAULT_TGT, func() -> void: _pick_file(tgt_edit, false))
	out_edit = _row(grid, "输出库", DEFAULT_OUT, func() -> void: _pick_file(out_edit, true))

	var opt_row := HBoxContainer.new()
	_host.add_child(opt_row)
	var l1 := Label.new()
	l1.text = "采样帧率"
	opt_row.add_child(l1)
	fps_spin = SpinBox.new()
	fps_spin.min_value = 5
	fps_spin.max_value = 60
	fps_spin.step = 1
	fps_spin.value = 30
	fps_spin.custom_minimum_size.x = 70
	opt_row.add_child(fps_spin)
	var l2 := Label.new()
	l2.text = "  位移缩放"
	opt_row.add_child(l2)
	pos_mode = OptionButton.new()
	pos_mode.add_item("自动（按髋高比）", 0)
	pos_mode.add_item("按身高比", 1)
	pos_mode.add_item("不缩放", 2)
	pos_mode.select(0)
	pos_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_row.add_child(pos_mode)

	var yaw_row := HBoxContainer.new()
	_host.add_child(yaw_row)
	auto_yaw_check = CheckBox.new()
	auto_yaw_check.text = "自动对齐朝向"
	auto_yaw_check.button_pressed = true
	yaw_row.add_child(auto_yaw_check)
	var l3 := Label.new()
	l3.text = "  朝向修正°"
	yaw_row.add_child(l3)
	yaw_spin = SpinBox.new()
	yaw_spin.min_value = -180
	yaw_spin.max_value = 180
	yaw_spin.step = 1
	yaw_spin.value = 0
	yaw_spin.custom_minimum_size.x = 70
	yaw_row.add_child(yaw_spin)

	var inc_row := HFlowContainer.new()
	_host.add_child(inc_row)
	incremental_check = CheckBox.new()
	incremental_check.text = "增量更新（只烘焙新增/改动的源）"
	incremental_check.button_pressed = true
	incremental_check.tooltip_text = "已烘焙过且没变化的源会跳过；同名动画被替换而不是重复添加"
	inc_row.add_child(incremental_check)
	prune_check = CheckBox.new()
	prune_check.text = "清理已删除的源"
	prune_check.button_pressed = true
	prune_check.tooltip_text = "源文件被删掉时，把它的动画从库里移除"
	inc_row.add_child(prune_check)

	var btn_row := HFlowContainer.new()
	btn_row.add_theme_constant_override("h_separation", 4)
	_host.add_child(btn_row)
	var scan_btn := Button.new()
	scan_btn.text = "① 扫描源动画"
	scan_btn.pressed.connect(_on_scan)
	btn_row.add_child(scan_btn)
	var bake_btn := Button.new()
	bake_btn.text = "② 生成动画库"
	bake_btn.pressed.connect(_on_bake)
	btn_row.add_child(bake_btn)
	var scene_btn := Button.new()
	scene_btn.text = "③ 生成场景"
	scene_btn.pressed.connect(_on_scene)
	btn_row.add_child(scene_btn)
	var rt_btn := Button.new()
	rt_btn.text = "④ 生成运行时场景"
	rt_btn.tooltip_text = "生成一个不依赖烘焙库的场景：运行时由 MixRetarget 节点把 Mixamo 姿态搬到角色骨架上（同一份动画可给所有角色用）"
	rt_btn.pressed.connect(_on_runtime_scene)
	btn_row.add_child(rt_btn)
	var del_btn := Button.new()
	del_btn.text = "删除选中动画"
	del_btn.tooltip_text = "从动画库里删掉选中的动画（可多选）。源文件还在也没关系，增量更新不会把它加回来。"
	del_btn.pressed.connect(_on_delete_clips)
	btn_row.add_child(del_btn)

	var hint := Label.new()
	hint.text = "提示：源动画要放在 Godot 会扫描的目录（以 . 开头的目录不扫描，比如 assets/.mixamo）；FBX 导入后才会出现。" \
		+ "\n同一个 fbx 里的多条动画都会处理，静止 take（约 0° 变化）自动跳过。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	_host.add_child(hint)

	clip_tree = Tree.new()
	clip_tree.columns = 3
	clip_tree.column_titles_visible = true
	clip_tree.set_column_title(0, "文件")
	clip_tree.set_column_title(1, "动画")
	clip_tree.set_column_custom_minimum_width(0, 90)
	clip_tree.set_column_custom_minimum_width(2, 110)
	clip_tree.set_column_title(2, "时长/轨道/幅度")
	clip_tree.select_mode = Tree.SELECT_MULTI
	clip_tree.custom_minimum_size.y = 170
	clip_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_tree.size_flags_stretch_ratio = 1.0
	_host.add_child(clip_tree)

	log_view = RichTextLabel.new()
	log_view.custom_minimum_size.y = 130
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.size_flags_stretch_ratio = 1.6
	log_view.scroll_following = true
	_host.add_child(log_view)


func _row(grid: GridContainer, label_text: String, default_text: String, on_pick: Callable) -> LineEdit:
	var l := Label.new()
	l.text = label_text
	grid.add_child(l)
	var e := LineEdit.new()
	e.text = default_text
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size.x = 120
	grid.add_child(e)
	var b := Button.new()
	b.text = "…"
	b.pressed.connect(on_pick)
	grid.add_child(b)
	return e


func _pick_dir(edit: LineEdit) -> void:
	# 照抄本项目其它插件：EditorFileDialog + 挂到编辑器主控件 + popup_centered_ratio(0.6)
	var d := EditorFileDialog.new()
	d.title = "选择动画源目录"
	d.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	d.access = EditorFileDialog.ACCESS_RESOURCES
	d.current_dir = edit.text if edit.text != "" else "res://"
	d.dir_selected.connect(func(p: String) -> void: edit.text = p)
	d.close_requested.connect(d.queue_free)
	EditorInterface.get_base_control().add_child(d)
	d.popup_centered_ratio(0.6)


func _pick_file(edit: LineEdit, save_mode: bool) -> void:
	# 照抄本项目其它插件：EditorFileDialog + 挂到编辑器主控件 + popup_centered_ratio(0.6)
	var d := EditorFileDialog.new()
	d.title = "选择保存位置" if save_mode else "选择文件"
	d.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE if save_mode else EditorFileDialog.FILE_MODE_OPEN_FILE
	d.access = EditorFileDialog.ACCESS_RESOURCES
	d.add_filter("*.glb,*.gltf,*.fbx", "模型/动画")
	d.add_filter("*.tres,*.res", "资源")
	d.current_path = edit.text if edit.text != "" else "res://"
	d.file_selected.connect(func(p: String) -> void: edit.text = p)
	d.close_requested.connect(d.queue_free)
	EditorInterface.get_base_control().add_child(d)
	d.popup_centered_ratio(0.6)


func _log(msg: String) -> void:
	log_view.append_text(msg + "\n")
	print("[Mixamo绑定] " + msg)


func _scan_fs() -> void:
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		EditorInterface.get_resource_filesystem().scan()


func _opts() -> Dictionary:
	var psm := "auto"
	if pos_mode.selected == 1:
		psm = "height"
	elif pos_mode.selected == 2:
		psm = "none"
	return {
		"sample_fps": float(fps_spin.value),
		"pos_scale_mode": psm,
		"auto_yaw": auto_yaw_check.button_pressed,
		"yaw_offset_deg": float(yaw_spin.value),
		"skip_static": true,
		"prune_missing": prune_check.button_pressed,
	}


# ------------------------------------------------------------------ ① 扫描

func _on_scan() -> void:
	log_view.clear()
	clip_tree.clear()
	var root_item := clip_tree.create_item()
	var dir := src_dir_edit.text.strip_edges()
	_log("扫描目录：" + dir)
	var res := Core.inspect_sources(dir)
	if String(res["error"]) != "":
		_log("✗ " + String(res["error"]))
		_suggest_dirs()
		return
	var rows: Array = res["rows"]
	if rows.is_empty():
		_log("这个目录里没有 fbx/glb 动画源。")
		_suggest_dirs()
		return
	var scan0 := Core.scan_sources(dir)
	var dups := Core.likely_duplicates(scan0["files"])
	if dups.size() > 0:
		_log("⚠ 看起来是重复的源（会在库里产生重复动画，建议删掉副本）：")
		for dd in dups:
			_log("    " + String(dd))
	var files := {}
	var clips := 0
	var statics := 0
	for r in rows:
		var item := clip_tree.create_item(root_item)
		item.set_text(0, String(r["file"]))
		if String(r.get("error", "")) != "":
			item.set_text(1, "—")
			item.set_text(2, String(r["error"]))
			continue
		files[String(r["file"])] = true
		clips += 1
		var is_static := bool(r["static"])
		if is_static:
			statics += 1
		item.set_text(1, String(r["clip"]))
		item.set_text(2, "%.2fs ｜ %d 轨道 ｜ 幅度 %.1f° ｜ %s" % [
			float(r["length"]), int(r["tracks"]), float(r["motion"]),
			"静止(跳过)" if is_static else "可用"])
	_log("扫描完成：%d 个文件，%d 条动画（其中静止 %d 条会被跳过）" % [files.size(), clips, statics])
	if statics > 0:
		_log("  静止 take 通常来自 Mixamo 的 \"Take 001\"，跳过它就能只保留真实动作。")


# ------------------------------------------------------------------ ② 生成动画库

func _on_bake() -> void:
	log_view.clear()
	clip_tree.clear()
	var root_item := clip_tree.create_item()
	var src_dir := src_dir_edit.text.strip_edges()
	var tgt := tgt_edit.text.strip_edges()
	if not ResourceLoader.exists(tgt):
		_log("✗ 目标角色不存在：" + tgt)
		return
	var out_path := out_edit.text.strip_edges()
	if out_path == "" or not out_path.begins_with("res://"):
		out_path = tgt.get_basename() + "_mixamo.tres"
		out_edit.text = out_path
	var t0 := Time.get_ticks_msec()
	var o := _opts()
	var res: Dictionary
	if incremental_check.button_pressed:
		res = Core.bake_update(out_path, src_dir, tgt, o, _log)
	else:
		res = Core.bake_all(src_dir, tgt, o, _log)
	if String(res["error"]) != "":
		_log("✗ " + String(res["error"]))
		return
	if incremental_check.button_pressed:
		var extra := ""
		if (res["removed"] as Array).size() > 0:
			extra = "、清理已删除源 %d 个" % (res["removed"] as Array).size()
		_log("增量结果：新增 %d 个源、更新 %d 个源、跳过未变 %d 个源%s" % [
			(res["added"] as Array).size(), (res["updated"] as Array).size(),
			(res["skipped"] as Array).size(), extra])
	var lib: AnimationLibrary = res["library"]
	var clips: Array = res["clips"]
	for c in clips:
		var item := clip_tree.create_item(root_item)
		item.set_text(0, String(c["file"]))
		item.set_text(1, String(c["name"]))
		item.set_text(2, "%.2fs ｜ %d 轨道 ｜ 幅度 %.1f°" % [
			float(c["length"]), int(c["tracks"]), float(c["motion"])])
	for s in res["skipped"]:
		var it := clip_tree.create_item(root_item)
		it.set_text(0, "—")
		it.set_text(1, "跳过")
		it.set_text(2, String(s))
	var m: Dictionary = res["measures"]
	_log("测量：源骨骼 %d / 目标骨骼 %d ｜ 髋高 %.3f → %.3f（位移缩放 ×%.4f）｜ 自动 yaw %.1f°" % [
		int(m["src_bones"]), int(m["tgt_bones"]), float(m["src_hips"]), float(m["tgt_hips"]),
		float(m["pos_scale"]), float(m["yaw_deg"])])
	_log("身高 %.3f → %.3f ｜ 朝向 %s → %s" % [
		float(m["src_height"]), float(m["tgt_height"]),
		(m["src_forward"] as Vector3).snapped(Vector3(0.01, 0.01, 0.01)),
		(m["tgt_forward"] as Vector3).snapped(Vector3(0.01, 0.01, 0.01))])
	var err := ResourceSaver.save(lib, out_path)
	if err != OK:
		_log("✗ 保存失败（错误码 %d）：%s" % [err, out_path])
		return
	_log("✓ 已保存 %d 条动画、%d 条轨道 → %s（耗时 %.0f ms）" % [
		lib.get_animation_list().size(), _count_tracks(lib), out_path, float(Time.get_ticks_msec() - t0)])
	for w in res["warnings"]:
		_log("  [!] " + String(w))
	if (res["warnings"] as Array).size() > 0:
		_log("  提示：加载失败通常是该 fbx 还没被 Godot 导入 —— 在 FileSystem 里右键它 → 重新导入，再点一次②。")
	_list_library(lib)
	_scan_fs()


func _count_tracks(lib: AnimationLibrary) -> int:
	var n := 0
	for an in lib.get_animation_list():
		n += lib.get_animation(an).get_track_count()
	return n


# ------------------------------------------------------------------ ③ 生成场景

func _on_scene() -> void:
	var tgt := tgt_edit.text.strip_edges()
	var lib := out_edit.text.strip_edges()
	if not ResourceLoader.exists(lib):
		_log("✗ 动画库不存在，请先点「② 生成动画库」：" + lib)
		return
	var scene_path := tgt.get_basename() + "_scene.tscn"
	var msg := Core.save_scene(tgt, lib, scene_path)
	if msg != "":
		_log("✗ " + msg)
		return
	_log("✓ 已生成场景：%s（角色 + AnimationPlayer + 动画库）" % scene_path)
	_log("  用法：打开它，选中 AnimationPlayer，播放里面的动画名即可。")
	_scan_fs()

func _suggest_dirs() -> void:
	var dirs := Core.find_source_dirs("res://", 3)
	if dirs.size() == 0:
		_log("  项目里没有找到含 fbx/glb 的目录。")
		return
	_log("  项目里这些目录含动画源，点「浏览…」把「源动画目录」切过去：")
	for d in dirs:
		_log("    " + String(d))

# ------------------------------------------------------------------ 库内容 / 删除动画

func _list_library(lib: AnimationLibrary) -> void:
	clip_tree.clear()
	var root := clip_tree.create_item()
	var clips := Core.list_clips(lib)
	for c in clips:
		var item := clip_tree.create_item(root)
		item.set_text(0, "库")
		item.set_text(1, String(c["name"]))
		item.set_text(2, "%.2fs ｜ %d 轨道" % [float(c["length"]), int(c["tracks"])])
	_log("库内动画 %d 条（列表可多选后点「删除选中动画」）" % clips.size())


func _on_delete_clips() -> void:
	var lib_path := out_edit.text.strip_edges()
	if not ResourceLoader.exists(lib_path):
		_log("✗ 找不到动画库，请先点「② 生成动画库」：" + lib_path)
		return
	var names := PackedStringArray()
	var item := clip_tree.get_selected()
	while item != null:
		var nm := item.get_text(1)
		if nm != "" and nm != "—":
			names.append(nm)
		item = clip_tree.get_next_selected(item)
	if names.size() == 0:
		_log("先在下面列表里选中要删除的动画（可按住 Ctrl/Shift 多选）。")
		return
	_confirm_names = names
	if _confirm == null or not is_instance_valid(_confirm):
		_confirm = ConfirmationDialog.new()
		_confirm.title = "删除动画"
		_confirm.ok_button_text = "删除"
		_confirm.cancel_button_text = "取消"
		# 照抄本项目 exr_tools/convert_dialog.gd 的尺寸经验：窗口"宽而矮"，不要 autowrap 的 Label
		_confirm.size = Vector2i(660, 300)
		_confirm.min_size = Vector2i(520, 240)
		if Engine.is_editor_hint():
			var ed := EditorInterface.get_editor_theme()
			if ed != null:
				_confirm.theme = ed
		_confirm.confirmed.connect(_do_delete_clips)
		_add_dialog(_confirm)
	var preview := ", ".join(names.slice(0, mini(3, names.size())))
	if names.size() > 3:
		preview += " …"
	_confirm.dialog_text = "从动画库里删除这 %d 条动画？\n%s" % [names.size(), preview]
	_confirm.popup_centered()


func _do_delete_clips() -> void:
	var lib_path := out_edit.text.strip_edges()
	var lib: AnimationLibrary = ResourceLoader.load(lib_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	if lib == null:
		_log("✗ 载入动画库失败：" + lib_path)
		return
	var n := Core.delete_clips(lib, _confirm_names)
	if n == 0:
		_log("没有删除任何动画（可能已被删过）。")
		return
	if ResourceSaver.save(lib, lib_path) != OK:
		_log("✗ 保存失败：" + lib_path)
		return
	_log("✓ 已删除 %d 条动画：%s" % [n, ", ".join(_confirm_names)])
	_log("  增量更新不会再把它加回来；想恢复：取消勾选「增量更新」再点②（全量重建）。")
	_list_library(lib)
	_scan_fs()

func _on_runtime_scene() -> void:
	var tgt := tgt_edit.text.strip_edges()
	if not ResourceLoader.exists(tgt):
		_log("✗ 目标角色不存在：" + tgt)
		return
	var out := tgt.get_basename() + "_runtime.tscn"
	var msg := Core.save_runtime_scene(tgt, src_dir_edit.text.strip_edges(), out,
		auto_yaw_check.button_pressed, "auto" if pos_mode.selected == 0 else "none")
	if msg != "":
		_log("✗ " + msg)
		return
	_log("✓ 已生成运行时场景：" + out)
	_log("  它不依赖烘焙的 .tres：运行时由 MixRetarget 节点把 Mixamo 姿态搬到你的骨架上。")
	_log("  切换动作（代码）：$MixRetarget.play(\"Standard Walk\")　名字 = 源文件基名")
	_log("  换角色：只改 target_path，任何角色都能用同一份 Mixamo 动画。")
	_scan_fs()

## 对话框挂到编辑器主窗口（而不是我这个窄面板）：否则弹窗会按面板尺寸算，又窄又高
func _add_dialog(w: Window) -> void:
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface") and EditorInterface.get_base_control() != null:
		EditorInterface.get_base_control().add_child(w)
	else:
		add_child(w)