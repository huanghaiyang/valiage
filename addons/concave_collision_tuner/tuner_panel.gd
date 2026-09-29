@tool
extends VBoxContainer
## 凹多边形碰撞调参面板（检查器内）。
##
## 用法：选中 CollisionShape3D（形状为 ConcavePolygonShape3D）→ 面板出现在检查器顶部 →
## 填"系数(%)" → 点「按系数重建」。
##
## 源几何取**往上找到的第一个 MeshInstance3D**（渲染用的那份高模），而不是当前碰撞
## 已经抽过面的形状 —— 所以系数是相对**原始面数**的，反复调不会越调越糊。
## 抽面在外部用 meshoptimizer 做（Godot 自己没有网格简化 API）：
##   Mesh.get_faces() -> 裸 float32 -> tools/mesh_decimate.py -> 裸 float32 -> shape.set_faces()
## 整个过程放在线程里跑，编辑器不会卡死。

const DECIMATE_TOOL := "res://tools/mesh_decimate.py"
const CHECK_TOOL := "res://tools/trimesh_check.py"
const TEMP_DIR := "user://concave_collision_tuner"
## 系数记在**节点自己的 metadata** 上：随场景一起保存，改名/挪节点都不会丢，
## 也不需要"外部表 + 节点唯一 id"那套（metadata 本身就是按节点存的）。
const META_RATIO := &"concave_tuner_ratio"     # 上次重建用的系数（0~1）
const META_SRC := &"concave_tuner_src_faces"   # 记系数时的源网格面数（便于判断模型是否换过）

var _cs: CollisionShape3D = null
var _shape: ConcavePolygonShape3D = null
var _src: MeshInstance3D = null
var _src_faces := 0

var _spin: SpinBox
var _slider: HSlider
var _info: Label
var _est: Label
var _status: Label
var _buttons: Array[Button] = []
var _prefilled := false       # 系数是否已确定（记忆恢复 / 按当前形状预填，只做一次）
var _clean_check: CheckBox

# 线程通信
var _thread: Thread = null
var _busy := false
var _thread_ok := false
var _thread_log := ""
var _thread_faces := PackedVector3Array()
var _thread_ratio := 0.0
var _thread_src_path := ""
var _thread_out_path := ""
var _thread_full_rebuild := false
var _thread_mode := "decimate"     # "decimate" | "check"
var _thread_clean := true
var _thread_summary := ""          # mesh_decimate 输出的 TOPOLOGY 一行
var _thread_report := ""           # 拓扑校验的完整报告


func setup(collision_shape: CollisionShape3D) -> void:
	_cs = collision_shape
	_shape = _cs.shape as ConcavePolygonShape3D
	_build_ui()
	_find_source()
	_restore_ratio()      # 先恢复上次记住的系数（没有就让 _refresh 按当前形状预填）
	_refresh()


# ------------------------------------------------------------------ 系数记忆

## 这个节点上有没有记过系数
func _has_saved_ratio() -> bool:
	return _cs != null and _cs.has_meta(META_RATIO)


## 从节点 metadata 恢复系数；没有就等 _refresh 按"当前形状 / 源网格"预填
func _restore_ratio() -> void:
	if not _has_saved_ratio():
		return
	var r := clampf(float(_cs.get_meta(META_RATIO)), 0.0005, 1.0)
	_spin.set_value_no_signal(r * 100.0)
	_slider.set_value_no_signal(clampf(r * 100.0, _slider.min_value, _slider.max_value))
	_prefilled = true


## 把系数记到节点上（随场景保存）
func _save_ratio(ratio: float) -> void:
	if _cs == null:
		return
	_cs.set_meta(META_RATIO, ratio)
	_cs.set_meta(META_SRC, _src_faces)


# ------------------------------------------------------------------ UI

func _build_ui() -> void:
	add_child(_make_sep())
	var title := Label.new()
	title.text = "凹多边形碰撞调参"
	title.add_theme_font_size_override("font_size", 14)
	add_child(title)

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_info)

	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "系数(%)"
	row.add_child(lab)
	_spin = SpinBox.new()
	_spin.min_value = 0.05
	_spin.max_value = 100.0
	_spin.step = 0.05
	_spin.value = 2.0
	_spin.custom_arrow_step = 0.05
	_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spin.value_changed.connect(_on_spin_changed)
	row.add_child(_spin)
	_est = Label.new()
	row.add_child(_est)
	add_child(row)

	_slider = HSlider.new()
	_slider.min_value = 0.1
	_slider.max_value = 20.0
	_slider.step = 0.1
	_slider.value = 2.0
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)

	var br := HBoxContainer.new()
	br.add_child(_make_button("按系数重建", _on_rebuild_pressed))
	br.add_child(_make_button("恢复全量(100%)", _on_full_pressed))
	br.add_child(_make_button("照当前形状填系数", _on_sync_pressed))
	add_child(br)

	_clean_check = CheckBox.new()
	_clean_check.text = "重建时修拓扑（去重复/退化面 + 统一绕序）"
	_clean_check.button_pressed = true
	_clean_check.tooltip_text = "抽面后常留重复面/退化面；绕序反了的部分在 backface_collision 关闭时会变成单向墙（能从背面穿过去）"
	add_child(_clean_check)

	var cr := HBoxContainer.new()
	cr.add_child(_make_button("拓扑校验（当前形状）", _on_check_pressed))
	add_child(cr)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	add_child(_make_sep())
	set_process(true)


func _make_sep() -> HSeparator:
	return HSeparator.new()


func _make_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	_buttons.append(b)
	return b


func _on_spin_changed(v: float) -> void:
	_slider.set_value_no_signal(clampf(v, _slider.min_value, _slider.max_value))
	_refresh_estimate()


func _on_slider_changed(v: float) -> void:
	_spin.set_value_no_signal(v)
	_refresh_estimate()


func _ratio() -> float:
	return _spin.value / 100.0


# ------------------------------------------------------------------ 源网格

func _find_source() -> void:
	_src = null
	if _cs == null:
		return
	# ① 往上找（本项目包装场景的结构：MeshInstance3D → StaticBody3D → CollisionShape3D）
	var n: Node = _cs.get_parent()
	while n != null:
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			_src = n as MeshInstance3D
			break
		n = n.get_parent()
	# ② 退一步：找同级 StaticBody3D 的兄弟里的网格
	if _src == null:
		var p: Node = _cs.get_parent()
		if p != null and p.get_parent() != null:
			for sib in p.get_parent().get_children():
				if sib is MeshInstance3D and (sib as MeshInstance3D).mesh != null:
					_src = sib as MeshInstance3D
					break
	if _src != null:
		_src_faces = _src.mesh.get_faces().size() / 3


func _refresh() -> void:
	var cur := 0
	if _shape != null:
		cur = _shape.get_faces().size() / 3
	if _src == null:
		_info.text = "当前碰撞 %s 面\n⚠️ 找不到源网格（碰撞体上面没有 MeshInstance3D）" % _fmt(cur)
		for b in _buttons:
			b.disabled = true
	else:
		# 未入树时 get_path() 会报错（单元测试里就是这样），退化成节点名
		var where := String(_src.get_path()) if _src.is_inside_tree() else _src.name
		var memo := ""
		if _has_saved_ratio():
			memo = "  ［已记住 %.2f%%］" % (float(_cs.get_meta(META_RATIO)) * 100.0)
		_info.text = "当前碰撞 %s 面 ／ 源网格 %s（%s 面）%s\n系数是相对**源网格**的" % [
			_fmt(cur), where, _fmt(_src_faces), memo]
		# 没有记忆时，按"当前形状 / 源网格"预填一次（省得手算，也不覆盖用户已填的值）
		if not _prefilled and cur > 0 and _src_faces > 0:
			var r := clampf(100.0 * cur / _src_faces, 0.05, 100.0)
			_spin.set_value_no_signal(r)
			_slider.set_value_no_signal(clampf(r, _slider.min_value, _slider.max_value))
			_prefilled = true
	_refresh_estimate()


func _refresh_estimate() -> void:
	if _src == null:
		_est.text = ""
		return
	_est.text = "→ 约 %s 面" % _fmt(int(_src_faces * _ratio()))


func _fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


# ------------------------------------------------------------------ 重建

func _on_rebuild_pressed() -> void:
	_start(_ratio(), false)


func _on_full_pressed() -> void:
	_start(1.0, true)


func _on_check_pressed() -> void:
	_start_check()


## 只校验当前碰撞形状的拓扑（不重建），报告显示在状态行
func _start_check() -> void:
	if _busy or _cs == null or _shape == null:
		return
	_busy = true
	_thread_mode = "check"
	_thread_ok = false
	_thread_report = ""
	for b in _buttons:
		b.disabled = true
	_status.text = "读当前碰撞面…"
	await get_tree().process_frame

	var faces: PackedVector3Array = _shape.get_faces()
	if faces.is_empty():
		_finish(false, "当前碰撞体没有三角面")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP_DIR))
	var src_path := ProjectSettings.globalize_path(TEMP_DIR.path_join("check_src.f32"))
	if not _dump_faces(faces, src_path):
		_finish(false, "写临时文件失败：%s" % src_path)
		return
	_thread = Thread.new()
	_thread.start(_worker.bind(faces, src_path,
			ProjectSettings.globalize_path(TEMP_DIR.path_join("check_out.f32")),
			ProjectSettings.globalize_path("res://"),
			ProjectSettings.globalize_path(CHECK_TOOL), 0.0, "check", false))
	_status.text = "拓扑校验中…（%s 面）" % _fmt(faces.size() / 3)


func _on_sync_pressed() -> void:
	if _src == null or _src_faces <= 0 or _shape == null:
		return
	var cur := _shape.get_faces().size() / 3
	_spin.value = clampf(100.0 * cur / _src_faces, 0.05, 100.0)


func _start(ratio: float, full: bool) -> void:
	if _busy or _cs == null or _shape == null or _src == null or _src.mesh == null:
		return
	_busy = true
	_thread_ok = false
	_thread_log = ""
	_thread_faces = PackedVector3Array()
	_thread_ratio = ratio
	_thread_full_rebuild = full
	_thread_mode = "decimate"
	_thread_clean = _clean_check != null and _clean_check.button_pressed
	_thread_summary = ""
	for b in _buttons:
		b.disabled = true
	_status.text = "取源网格三角面中…"
	await get_tree().process_frame            # 先把状态刷新出去

	var faces: PackedVector3Array = _src.mesh.get_faces()
	if faces.is_empty():
		_finish(false, "源网格没有三角面")
		return

	# 源网格空间 -> 碰撞体空间（一般就是同一个节点空间，这里按通用情况对齐）
	var xf: Transform3D = _cs.global_transform.affine_inverse() * _src.global_transform
	if not xf.is_equal_approx(Transform3D.IDENTITY):
		var moved := PackedVector3Array()
		moved.resize(faces.size())
		for i in faces.size():
			moved[i] = xf * faces[i]
		faces = moved

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP_DIR))
	if full:
		_apply(faces, "恢复全量（%d 面）" % (faces.size() / 3))
		return

	_thread_src_path = ProjectSettings.globalize_path(TEMP_DIR.path_join("src.f32"))
	_thread_out_path = ProjectSettings.globalize_path(TEMP_DIR.path_join("out.f32"))
	var src_path := _thread_src_path
	var out_path := _thread_out_path
	var project_root := ProjectSettings.globalize_path("res://")
	var tool_path := ProjectSettings.globalize_path(DECIMATE_TOOL)

	_thread = Thread.new()
	_thread.start(_worker.bind(faces, src_path, out_path, project_root, tool_path, ratio,
			"decimate", _thread_clean))
	_status.text = "抽面中…（%s 面 × %.2f%%，1 万面约需几秒）" % [_fmt(faces.size() / 3), ratio]


func _worker(faces: PackedVector3Array, src_path: String, out_path: String,
		project_root: String, tool_path: String, ratio: float,
		mode: String, do_clean: bool) -> void:
	# 线程里只做文件 IO 和外部进程，不碰场景树
	if not FileAccess.file_exists(tool_path):
		_thread_log = "找不到工具脚本：%s" % tool_path
		return
	if not _dump_faces(faces, src_path):
		_thread_log = "写临时文件失败：%s" % src_path
		return
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)

	var report_path := src_path + ".report.txt"
	if FileAccess.file_exists(report_path):
		DirAccess.remove_absolute(report_path)
	var args: Array = [tool_path, "--in", src_path, "--report", report_path]
	if mode != "check":
		args.append_array(["--out", out_path, "--ratio", "%.6f" % ratio,
				"--project", project_root])
		if do_clean:
			args.append_array(["--clean", "--fix-winding"])

	var out: Array = []
	var err := ""
	for cmd in ["python", "python3", "py"]:
		out.clear()
		var rc := OS.execute(cmd, args, out, true)
		if rc == 0:
			err = ""
			break
		err = " ".join(out)
	if not err.is_empty():
		_thread_log = "工具执行失败：%s\n（需要 Python 3 + Node.js/npx）" % err
		return

	# 报告**优先读工具写出的 UTF-8 文件**：Godot 的 OS.execute 在 Windows 上按系统
	# ANSI 代码页解码子进程输出，中文会变乱码（实测 "三角面" 变成 "涓夎闈?"）
	var text := _read_utf8_file(report_path)
	if text.is_empty():
		var fallback := PackedStringArray()
		for raw in out:
			fallback.append(String(raw))
		text = "\n".join(fallback)
	var summary := ""
	for line in text.split("\n"):
		if line.begins_with("TOPOLOGY"):
			summary = line
	_thread_summary = summary

	if mode == "check":
		_thread_report = text.strip_edges()
		_thread_ok = not text.strip_edges().is_empty()
		return

	var faces_out := _load_faces(out_path)
	if faces_out.is_empty():
		_thread_log = "抽面失败（输出为空）"
		return
	_thread_faces = faces_out
	_thread_ok = true


## 按 UTF-8 读文件（不用 get_as_text，免得受系统编码影响）
func _read_utf8_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return bytes.get_string_from_utf8()


func _dump_faces(faces: PackedVector3Array, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	# 纯 float32 流：Python 侧按 <f 逐个解包，不能加任何头
	var buf := PackedFloat32Array()
	buf.resize(faces.size() * 3)
	for i in faces.size():
		var v := faces[i]
		buf[i * 3] = v.x
		buf[i * 3 + 1] = v.y
		buf[i * 3 + 2] = v.z
	f.store_buffer(buf.to_byte_array())
	f.close()
	return true


func _load_faces(path: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var floats := bytes.to_float32_array()
	var n := floats.size() / 3
	out.resize(n)
	for i in n:
		out[i] = Vector3(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2])
	return out


func _process(_delta: float) -> void:
	if _thread == null:
		return
	if _thread.is_alive():
		return
	_thread.wait_to_finish()
	_thread = null
	if _thread_mode == "check":
		_finish(_thread_ok, _thread_report if _thread_ok else _thread_log)
		return
	if _thread_ok:
		_apply(_thread_faces, "按系数 %.2f%% 重建（%d 面）" % [_thread_ratio * 100.0,
				_thread_faces.size() / 3])
	else:
		_finish(false, _thread_log)


func _apply(faces: PackedVector3Array, action_name: String) -> void:
	_save_ratio(_thread_ratio)          # 把这次用的系数记到节点上（随场景保存）
	var old := _shape.get_faces()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action_name)
	ur.add_do_method(_shape, "set_faces", faces)
	ur.add_undo_method(_shape, "set_faces", old)
	ur.commit_action()
	if EditorInterface.has_method("mark_scene_as_unsaved"):
		EditorInterface.call("mark_scene_as_unsaved")
	var tail := ""
	if not _thread_summary.is_empty():
		tail = "\n" + _thread_summary
	_finish(true, "%s ✓（旧 %s 面 → 新 %s 面，Ctrl+Z 可撤销）%s" % [
		action_name, _fmt(old.size() / 3), _fmt(faces.size() / 3), tail])


func _finish(ok: bool, message: String) -> void:
	_busy = false
	_status.text = message
	for b in _buttons:
		b.disabled = _src == null
	_refresh()
