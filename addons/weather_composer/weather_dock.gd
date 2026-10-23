@tool
extends ScrollContainer
## ============================================================================
## weather_dock.gd —— 天气组合器（编辑器停靠面板）
## ============================================================================
## 【职责】把 SKIN 数据写进 res://data/weather/custom_weathers.json，让天气系统多出
##   "自定义天气"（编号 >= 6）。两条组合路径，用户两种都想要，所以两条都做：
##     · 按比例混合：选基础 A、基础 B、B 的权重，把 7 个连续参数线性插值后落到面板
##       —— 用在"梅雨 = 小雨 0.6 + 阴天 0.4"这类中间态上；
##     · 复制后微调：选基础 A，一键把 A 的 7 个参数搬到面板，再逐项拖滑杆
##       —— 用在"雷雨但风更大、阳光更暗"这类偏离预设的天气上。
##   两条路径最后都只是"把面板上的当前值存成一条新记录"，所以可以混用：
##   先混合再微调也成立。
##
## 【数据契约】（与 scripts/world/weather.gd 的 reload_definitions 逐字对应）
##   {"version": 1,
##    "weathers": [{"id": 6, "name": "梅雨",
##                  "params": {"wind": .., "gust": .., "turb": ..,
##                             "cloud": .., "rain": .., "fog": .., "light": ..},
##                  "icon": 3,
##                  "mix": {"a": 3, "b": 2, "weight": 0.6}}]}
##   · id 必须 >= 6（0..5 是内置，weather.gd 会拒绝覆盖）。
##   · icon 是 0..5 的内置图标种类，只用于小地图叠加层显示。
##   · mix 只记录来源，方便回看；运行期不读它。
##
## 【为什么面板不直接改运行中的 Weather 节点】
##   weather.gd 不是 @tool，编辑器里它只是占位实例（placeholder），方法调不到；
##   而且面板的目的是"改数据文件"，不是"改内存里的当前天气"。保存后重载场景/重启游戏生效。
##
## 【布局】
##   ScrollContainer（根，横向不滚）
##     └ VBoxContainer
##         · 标题 + 一行说明
##         · 编辑目标下拉 + A/B 权重 + 两个组合按钮
##         · 7 行参数（EditorSpinSlider，带中文标签）
##         · 名称 / 图标 / 保存 / 更新 / 删除 / 重新载入
##         · 状态标签（错误用红字）
## ============================================================================

## 内置天气数据（名称表 + 预设参数表）的唯一来源。直接读常量，避免在面板里再抄一份
## 数值 —— 两边抄两份的话，改了一处另一处会静默不一致。
const WEATHER_SCRIPT := preload("res://scripts/world/weather.gd")
## 自定义天气数据文件。与 weather.gd 的 CUSTOM_DEFS_PATH 必须一致。
const DEFS_PATH := "res://data/weather/custom_weathers.json"
## 自定义天气编号的起点（0..5 留给内置天气）
const FIRST_CUSTOM_ID := 6

## 面板上的 7 个连续参数。顺序即 UI 从上到下的顺序。
## min/max 与 weather.gd 的 clampf 口径一致（wind 允许到 1.5，其余 0..1，light 到 1.5）。
const PARAMS := [
	{"key": "wind",  "label": "风力",     "min": 0.0, "max": 1.5, "step": 0.01},
	{"key": "gust",  "label": "阵风",     "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "turb",  "label": "湍流",     "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "cloud", "label": "云量",     "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "rain",  "label": "雨量",     "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "fog",   "label": "雾浓度",   "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "light", "label": "阳光系数", "min": 0.0, "max": 1.5, "step": 0.01},
]

# ==================== 运行时状态 ====================
## 面板内容容器（根是 ScrollContainer，所有控件都挂在它下面）
var _body: VBoxContainer
## _build() 是否已经跑过（_ready 可能被编辑器重复触发）
var _built := false
## 从 JSON 读出来的自定义天气条目（id / name / params / icon / mix）。按 id 升序。
var _custom: Array[Dictionary] = []
## "编辑目标"下拉：内置 + 自定义，用来把某条天气的数值载入面板
var _target_opt: OptionButton
## 基础 A（混合 / 复制来源）
var _a_opt: OptionButton
## 基础 B（混合的另一端；第一项是"无（只用 A）"，id = -1）
var _b_opt: OptionButton
## B 的权重滑杆（0 = 完全是 A，1 = 完全是 B）
var _weight: HSlider
## 权重百分比标签
var _weight_lbl: Label
## key -> EditorSpinSlider
var _spins: Dictionary = {}
var _name_edit: LineEdit
var _icon_opt: OptionButton
var _status: Label
var _btn_update: Button
var _btn_delete: Button
## 程序化改控件值时置 true，避免 select/value 触发的回调把面板重置成半成品
var _loading := false


# ==================== 生命周期 ====================
## 面板进入编辑器停靠区时搭 UI、读数据、刷新。
## 这里才建控件（而不是 _init），因为 _init 阶段 get_tree() 还不成立，
## 而 OptionButton / EditorSpinSlider 的部分行为依赖已进入场景树。
func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_build()
	_load_defs()
	_refresh_all()


## 一次性搭出整个面板。重复调用会直接返回（编辑器重开面板时 _ready 可能再来一次）。
func _build() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	add_child(_body)

	# --- 标题与说明 ---
	var title := Label.new()
	title.text = "天气组合器"
	title.add_theme_font_size_override("font_size", 15)
	_body.add_child(title)

	var hint := Label.new()
	hint.text = "混合两个现有天气，或复制一个再逐项微调；保存后写入 data/weather/custom_weathers.json。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(1, 1, 1, 0.7)
	_body.add_child(hint)

	_body.add_child(HSeparator.new())

	# --- 编辑目标 ---
	_target_opt = OptionButton.new()
	_target_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_opt.tooltip_text = "把这条天气的数值载入下方面板（内置天气只能当来源，不能更新/删除）"
	_target_opt.item_selected.connect(_on_target_selected)
	_add_row("编辑目标", _target_opt)

	# --- 基础 A / B + 权重 ---
	_a_opt = OptionButton.new()
	_a_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_a_opt.tooltip_text = "混合的起点，也是「复制 A」的来源"
	_add_row("基础 A", _a_opt)

	_b_opt = OptionButton.new()
	_b_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_b_opt.tooltip_text = "混合的另一端。选「无」时按纯 A 处理"
	_add_row("基础 B", _b_opt)

	_weight = HSlider.new()
	_weight.min_value = 0.0
	_weight.max_value = 1.0
	_weight.step = 0.01
	_weight.value = 0.5
	_weight.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weight.tooltip_text = "B 的占比：0 = 完全取 A，1 = 完全取 B（中间值 = 线性插值）"
	_weight.value_changed.connect(_on_weight_changed)
	_weight_lbl = Label.new()
	_weight_lbl.custom_minimum_size = Vector2(40, 0)
	_weight_lbl.text = "50%"
	var weight_row := HBoxContainer.new()
	weight_row.add_child(_weight)
	weight_row.add_child(_weight_lbl)
	var weight_title := Label.new()
	weight_title.text = "B 占比"
	weight_title.custom_minimum_size = Vector2(64, 0)
	weight_row.add_child(weight_title)
	weight_row.move_child(weight_title, 0)
	_body.add_child(weight_row)

	var blend_btn := Button.new()
	blend_btn.text = "按比例混合到面板"
	blend_btn.tooltip_text = "params = lerp(A, B, B占比)"
	blend_btn.pressed.connect(_on_blend_pressed)
	_body.add_child(blend_btn)

	var copy_btn := Button.new()
	copy_btn.text = "复制 A 到面板"
	copy_btn.tooltip_text = "把 A 的 7 个参数与图标原样搬到面板，再逐项微调"
	copy_btn.pressed.connect(_on_copy_pressed)
	_body.add_child(copy_btn)

	_body.add_child(HSeparator.new())

	# --- 7 个连续参数 ---
	for entry in PARAMS:
		var key: String = String(entry["key"])
		var spin := EditorSpinSlider.new()
		spin.min_value = float(entry["min"])
		spin.max_value = float(entry["max"])
		spin.step = float(entry["step"])
		spin.label = String(entry["label"])
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.tooltip_text = "参数 %s（写入天气 JSON 的 params.%s）" % [entry["label"], key]
		_spins[key] = spin
		_body.add_child(spin)

	_body.add_child(HSeparator.new())

	# --- 名称与图标 ---
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "天气名称（例如：梅雨）"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_row("名称", _name_edit)

	_icon_opt = OptionButton.new()
	_icon_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_icon_opt.tooltip_text = "小地图上使用哪个内置图标（自定义天气没有自己的画法）"
	for id in _builtin_ids():
		_icon_opt.add_item("%s 图标" % _builtin_name(id), id)
	_add_row("图标", _icon_opt)

	# --- 保存 / 更新 / 删除 / 重新载入 ---
	var save_btn := Button.new()
	save_btn.text = "保存为新天气"
	save_btn.tooltip_text = "用面板当前值新建一条自定义天气（编号自动取下一个空闲值 >= 6）"
	save_btn.pressed.connect(_on_save_new_pressed)
	_body.add_child(save_btn)

	_btn_update = Button.new()
	_btn_update.text = "更新选中天气"
	_btn_update.tooltip_text = "把面板当前值写回「编辑目标」里的那条自定义天气"
	_btn_update.pressed.connect(_on_update_pressed)
	_body.add_child(_btn_update)

	_btn_delete = Button.new()
	_btn_delete.text = "删除选中天气"
	_btn_delete.tooltip_text = "从 JSON 里删掉「编辑目标」里的那条自定义天气"
	_btn_delete.pressed.connect(_on_delete_pressed)
	_body.add_child(_btn_delete)

	var reload_btn := Button.new()
	reload_btn.text = "重新载入文件"
	reload_btn.tooltip_text = "重新读一遍 custom_weathers.json（手工改过文件后点它）"
	reload_btn.pressed.connect(_on_reload_pressed)
	_body.add_child(reload_btn)

	_body.add_child(HSeparator.new())

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 48)
	_status.add_theme_font_size_override("font_size", 11)
	_body.add_child(_status)
	_set_status("就绪。", false)


## 造一行"标题 + 控件"，标题固定宽度，控件占满剩余宽度。
func _add_row(title: String, ctrl: Control) -> void:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = title
	lbl.custom_minimum_size = Vector2(64, 0)
	row.add_child(lbl)
	row.add_child(ctrl)
	_body.add_child(row)


# ==================== 内置数据读取（只读常量，不做副本） ====================
## 内置天气编号（0..5），按常量表的键升序。
func _builtin_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in WEATHER_SCRIPT.KIND_NAMES:
		ids.append(int(id))
	ids.sort()
	return ids


## 内置天气的中文名。查不到时返回 fallback，不让 UI 出现空标签。
func _builtin_name(id: int) -> String:
	var names: Dictionary = WEATHER_SCRIPT.KIND_NAMES
	return str(names.get(id, "天气%d" % id))


## 内置天气的参数预设。返回**副本**，避免面板把常量表改脏。
func _builtin_params(id: int) -> Dictionary:
	var presets: Dictionary = WEATHER_SCRIPT.PRESETS
	var p: Variant = presets.get(id, null)
	return (p as Dictionary).duplicate() if p is Dictionary else {}


# ==================== 自定义天气读写 ====================
## 读 custom_weathers.json。文件缺失 = 正常状态（还没有任何自定义天气）；
## 解析失败时给出红字提示，但面板继续可用（用户可以直接保存覆盖）。
func _load_defs() -> void:
	_custom.clear()
	if not FileAccess.file_exists(DEFS_PATH):
		return
	var f := FileAccess.open(DEFS_PATH, FileAccess.READ)
	if f == null:
		_set_status("无法打开 %s（只读？）" % DEFS_PATH, true)
		return
	var text := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		_set_status("%s 不是合法 JSON；保存时会整个覆盖它" % DEFS_PATH, true)
		return
	var arr: Variant = (data as Dictionary).get("weathers", [])
	if not (arr is Array):
		_set_status("JSON 缺少 weathers 数组；保存时会重建", true)
		return
	for e in arr:
		if not (e is Dictionary):
			continue
		var id := int((e as Dictionary).get("id", -1))
		# 编号 < 6 的条目是脏数据（内置编号不允许被覆盖），直接忽略，
		# 与 weather.gd 的 reload_definitions 保持同一套过滤规则。
		if id < FIRST_CUSTOM_ID:
			continue
		var raw: Variant = (e as Dictionary).get("params", {})
		var params := {}
		for entry in PARAMS:
			var key: String = String(entry["key"])
			params[key] = float((raw as Dictionary).get(key, 0.0)) if raw is Dictionary else 0.0
		var mix: Variant = (e as Dictionary).get("mix", {})
		_custom.append({
			"id": id,
			"name": str((e as Dictionary).get("name", "自定义%d" % id)),
			"params": params,
			"icon": clampi(int((e as Dictionary).get("icon", 0)), 0, 5),
			"mix": (mix as Dictionary).duplicate() if mix is Dictionary else {},
		})
	_custom.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))


## 把 _custom 写回 JSON。成功后返回 true。
## 目录不存在时先建（data/ 存在，weather/ 可能是第一次用这个面板才出现）。
func _save_defs() -> bool:
	var abs_dir := ProjectSettings.globalize_path(DEFS_PATH.get_base_dir())
	var err := DirAccess.make_dir_recursive_absolute(abs_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		_set_status("建目录失败（%s，错误 %d）" % [abs_dir, err], true)
		return false
	var out := {"version": 1, "weathers": []}
	for e in _custom:
		(out["weathers"] as Array).append({
			"id": int(e["id"]),
			"name": String(e["name"]),
			"params": (e["params"] as Dictionary).duplicate(),
			"icon": int(e["icon"]),
			"mix": (e["mix"] as Dictionary).duplicate(),
		})
	var f := FileAccess.open(DEFS_PATH, FileAccess.WRITE)
	if f == null:
		_set_status("写入 %s 失败（%s）" % [DEFS_PATH, error_string(FileAccess.get_open_error())], true)
		return false
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	return true


# ==================== 下拉框刷新 ====================
## 把"编辑目标 / 基础 A / 基础 B"三张下拉都按当前数据重建，并尽量保留原选择。
func _refresh_all() -> void:
	var keep_target := _id_of(_target_opt)
	var keep_a := _id_of(_a_opt)
	var keep_b := _id_of(_b_opt)
	_loading = true
	_fill_weather_options(_target_opt, false)
	_fill_weather_options(_a_opt, false)
	_fill_weather_options(_b_opt, true)
	_loading = false
	# 选择恢复：目标/A 找不到原编号就退到第一项；B 找不到就退到"无"。
	if keep_target >= 0:
		_select_option(_target_opt, keep_target)
	_select_option(_a_opt, keep_a if keep_a >= 0 else _id_of_index(_a_opt, 0))
	_select_option(_b_opt, keep_b if keep_b >= 0 else -1)
	_sync_buttons()
	if _target_opt.item_count > 0:
		_load_into_controls(_id_of(_target_opt))


## 填一张天气下拉：内置在前、自定义在后。
## with_none = true 时先加一项"无（只用 A）"，item_id = -1。
func _fill_weather_options(opt: OptionButton, with_none: bool) -> void:
	opt.clear()
	if with_none:
		opt.add_item("无（只用 A）", -1)
	for id in _builtin_ids():
		opt.add_item("%s（内置 %d）" % [_builtin_name(id), id], id)
	for e in _custom:
		opt.add_item("%s（自定义 %d）" % [String(e["name"]), int(e["id"])], int(e["id"]))


## 当前选项的 item_id（天气编号；-1 = 无）。空下拉返回 -1。
func _id_of(opt: OptionButton) -> int:
	if opt == null or opt.selected < 0 or opt.selected >= opt.item_count:
		return -1
	return opt.get_item_id(opt.selected)


## 第 idx 项的 item_id（用于"恢复到第一项"）
func _id_of_index(opt: OptionButton, idx: int) -> int:
	if opt == null or idx < 0 or idx >= opt.item_count:
		return -1
	return opt.get_item_id(idx)


## 选中 item_id == id 的那一项；找不到就选中第 0 项（B 下拉的第 0 项是"无"）。
func _select_option(opt: OptionButton, id: int) -> void:
	if opt == null:
		return
	for i in opt.item_count:
		if opt.get_item_id(i) == id:
			opt.select(i)
			return
	if opt.item_count > 0:
		opt.select(0)


# ==================== 数据查询 ====================
## 编号对应的中文名（内置查常量表，自定义查 _custom）
func _name_of(id: int) -> String:
	if id < FIRST_CUSTOM_ID:
		return _builtin_name(id)
	var e := _custom_entry(id)
	return String(e.get("name", "自定义%d" % id)) if not e.is_empty() else "未知"


## 编号对应的参数副本
func _params_of(id: int) -> Dictionary:
	if id < FIRST_CUSTOM_ID:
		return _builtin_params(id)
	var e := _custom_entry(id)
	if e.is_empty():
		return {}
	return (e.get("params", {}) as Dictionary).duplicate()


## 编号对应的图标种类（0..5）
func _icon_of(id: int) -> int:
	if id < FIRST_CUSTOM_ID:
		return clampi(id, 0, 5)
	var e := _custom_entry(id)
	return int(e.get("icon", 0)) if not e.is_empty() else 0


## 在 _custom 里按 id 找条目，找不到返回空字典
func _custom_entry(id: int) -> Dictionary:
	for e in _custom:
		if int(e["id"]) == id:
			return e
	return {}


## 下一个可用的自定义编号（max(已有 id)+1，至少 6）
func _next_custom_id() -> int:
	var next := FIRST_CUSTOM_ID
	for e in _custom:
		next = maxi(next, int(e["id"]) + 1)
	return next


# ==================== 面板 <-> 数据 ====================
## 把某条天气载入面板：7 个参数、名称、图标，并把基础 A 同步成它。
func _load_into_controls(id: int) -> void:
	if id < 0:
		return
	_loading = true
	var params := _params_of(id)
	for entry in PARAMS:
		var key: String = String(entry["key"])
		if _spins.has(key):
			_set_spin(key, float(params.get(key, 0.0)))
	_name_edit.text = _name_of(id)
	_select_option(_icon_opt, _icon_of(id))
	_select_option(_a_opt, id)
	_loading = false
	_sync_buttons()


## 面板上的 7 个参数（保存时用）
func _collect_params() -> Dictionary:
	var d := {}
	for entry in PARAMS:
		var key: String = String(entry["key"])
		var spin: EditorSpinSlider = _spins[key]
		d[key] = float(spin.value)
	return d


## 写一个参数（带范围夹紧，防止手工编辑 JSON 后越界值把滑杆撑爆）
func _set_spin(key: String, v: float) -> void:
	if not _spins.has(key):
		return
	var spin: EditorSpinSlider = _spins[key]
	spin.value = clampf(v, spin.min_value, spin.max_value)


## 按"编辑目标是否自定义"启用/禁用更新与删除按钮
func _sync_buttons() -> void:
	var id := _id_of(_target_opt)
	var is_custom := id >= FIRST_CUSTOM_ID and not _custom_entry(id).is_empty()
	_btn_update.disabled = not is_custom
	_btn_delete.disabled = not is_custom


# ==================== 交互回调 ====================
## 切换"编辑目标"：把该条天气载入面板
func _on_target_selected(_idx: int) -> void:
	if _loading:
		return
	_load_into_controls(_id_of(_target_opt))


## 权重滑杆：更新百分比文字
func _on_weight_changed(v: float) -> void:
	if _weight_lbl != null:
		_weight_lbl.text = "%d%%" % roundi(v * 100.0)


## 按比例混合：params = lerp(A, B, weight)。B 选"无"时退化成纯 A。
func _on_blend_pressed() -> void:
	var a := _id_of(_a_opt)
	var b := _id_of(_b_opt)
	if a < 0:
		_set_status("先在「基础 A」里选一个天气。", true)
		return
	var pa := _params_of(a)
	var pb := _params_of(b) if b >= 0 else pa
	var w := float(_weight.value)
	_loading = true
	for entry in PARAMS:
		var key: String = String(entry["key"])
		_set_spin(key, lerpf(float(pa.get(key, 0.0)), float(pb.get(key, 0.0)), w))
	_loading = false
	# 名称也顺着来源给一个默认值，用户可直接改；图标取 A 的（混合没有"中间的图标"）
	_name_edit.text = "%s＋%s" % [_name_of(a), _name_of(b)] if b >= 0 and b != a else "%s·改" % _name_of(a)
	_select_option(_icon_opt, _icon_of(a))
	_set_status("已按 %.0f%% : %.0f%% 混合到面板，确认后点「保存为新天气」。" % [(1.0 - w) * 100.0, w * 100.0], false)


## 复制 A：把 A 的 7 个参数、图标搬到面板（名称加个后缀便于区分）
func _on_copy_pressed() -> void:
	var a := _id_of(_a_opt)
	if a < 0:
		_set_status("先在「基础 A」里选一个天气。", true)
		return
	var pa := _params_of(a)
	_loading = true
	for entry in PARAMS:
		var key: String = String(entry["key"])
		_set_spin(key, float(pa.get(key, 0.0)))
	_name_edit.text = "%s·改" % _name_of(a)
	_select_option(_icon_opt, _icon_of(a))
	_loading = false
	_set_status("已复制「%s」到面板，逐项微调后点「保存为新天气」。" % _name_of(a), false)


## 保存为新天气：编号自动取下一个空闲值
func _on_save_new_pressed() -> void:
	var id := _next_custom_id()
	var nm := _name_edit.text.strip_edges()
	if nm.is_empty():
		nm = "自定义%d" % id
	var entry := {
		"id": id,
		"name": nm,
		"params": _collect_params(),
		"icon": _id_of(_icon_opt),
		"mix": {"a": _id_of(_a_opt), "b": _id_of(_b_opt), "weight": float(_weight.value)},
	}
	_custom.append(entry)
	_custom.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return int(x["id"]) < int(y["id"]))
	if not _save_defs():
		_custom.erase(entry)
		_refresh_all()
		return
	_set_status("已保存「%s」，编号 %d。重载场景或重启游戏后生效。" % [nm, id], false)
	_refresh_all()
	_select_option(_target_opt, id)
	_sync_buttons()


## 更新选中的自定义天气
func _on_update_pressed() -> void:
	var id := _id_of(_target_opt)
	var e := _custom_entry(id)
	if e.is_empty():
		_set_status("「编辑目标」不是自定义天气，无法更新。", true)
		return
	var nm := _name_edit.text.strip_edges()
	if nm.is_empty():
		nm = String(e["name"])
	e["name"] = nm
	e["params"] = _collect_params()
	e["icon"] = _id_of(_icon_opt)
	e["mix"] = {"a": _id_of(_a_opt), "b": _id_of(_b_opt), "weight": float(_weight.value)}
	if not _save_defs():
		return
	_set_status("已更新「%s」（编号 %d）。重载场景或重启游戏后生效。" % [nm, id], false)
	_refresh_all()
	_select_option(_target_opt, id)


## 删除选中的自定义天气
func _on_delete_pressed() -> void:
	var id := _id_of(_target_opt)
	var e := _custom_entry(id)
	if e.is_empty():
		_set_status("「编辑目标」不是自定义天气，无法删除。", true)
		return
	_custom.erase(e)
	if not _save_defs():
		_custom.append(e)
		_custom.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
			return int(x["id"]) < int(y["id"]))
		return
	_set_status("已删除编号 %d 的天气。若场景里正好在用它会回退到晴朗。" % id, false)
	_refresh_all()


## 从磁盘重新读一遍（手工改过 JSON 后使用）
func _on_reload_pressed() -> void:
	_load_defs()
	_refresh_all()
	_set_status("已重新载入 %d 条自定义天气。" % _custom.size(), false)


# ==================== 状态标签 ====================
## 写状态文字；is_error = true 时用红字，便于一眼看出保存失败。
func _set_status(msg: String, is_error: bool) -> void:
	if _status == null:
		return
	_status.text = msg
	_status.add_theme_color_override("font_color",
		Color(0.96, 0.42, 0.38) if is_error else Color(0.72, 0.86, 0.70))
