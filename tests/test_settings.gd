@tool
extends McpTestSuite
## 设置菜单系统自检（schema / store / apply / menu）。

const SCHEMA := "res://scripts/settings/settings_schema.gd"
const STORE := "res://scripts/settings/settings_store.gd"
const APPLY := "res://scripts/settings/settings_apply.gd"
const MENU := "res://scripts/settings/settings_menu.gd"


func suite_name() -> String:
	return "settings"


func _load(p: String) -> GDScript:
	return ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _tmp_cfg() -> String:
	var rel := "user://settings_test/cfg.cfg"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://settings_test"))
	var abs := ProjectSettings.globalize_path(rel)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)
	return rel


func test_schema_is_complete() -> void:
	var s := _load(SCHEMA)
	assert_true(s != null, "schema 加载失败")
	if s == null:
		return
	var cats: Array = s.ORDER
	assert_eq(cats.size(), 7, "应有 7 个分类")
	var all: Array = s.call("all_items")
	var seen := {}
	var todos := 0
	var by_cat := {}
	for it in all:
		var d: Dictionary = it
		for req in ["key", "label", "kind", "category"]:
			assert_true(d.has(req), "条目缺字段 %s：%s" % [req, str(d)])
		var key := String(d["key"])
		assert_true(not seen.has(key), "key 重复：%s" % key)
		seen[key] = true
		var cat := String(d["category"])
		by_cat[cat] = int(by_cat.get(cat, 0)) + 1
		if bool(d.get("todo", false)):
			todos += 1
		# 非 INFO 的条目必须有默认值，否则"恢复默认"会写成 null ✗
		if int(d["kind"]) != 3:
			assert_true(d.has("default"), "非信息条目缺 default：%s" % key)
		# 下拉必须有可选项
		if int(d["kind"]) == 2:
			assert_true((d.get("choices", []) as Array).size() > 0, "下拉没有选项：%s" % key)
	print("[设置] 共 %d 项，分布在 %d 个分类；占位（待开发）%d 项" % [all.size(), by_cat.size(), todos])
	for c in cats:
		print("[设置]   %s → %d 项" % [c, int(by_cat.get(String(c), 0))])
	assert_true(todos > 0, "应当有占位项（按需求：没有的功能先空着 ✓）")
	assert_true(all.size() >= 30, "设置项太少（应有 30+ 项）")


func test_store_defaults_roundtrip_and_persistence() -> void:
	var s := _load(SCHEMA)
	var st := _load(STORE)
	if s == null or st == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	# 默认值
	assert_eq(int(store.get_value("graphics/tier")), 2, "画质档位默认应为「高」")
	assert_true(bool(store.get_value("graphics/vsync")), "垂直同步默认应为开")
	assert_true(absf(float(store.get_value("audio/master")) - 1.0) < 0.001, "主音量默认应为 1.0")
	# 信号
	var got := {"key": "", "value": null}
	store.changed.connect(func(k, v): got["key"] = k; got["value"] = v)
	store.set_value("audio/music", 0.35)
	assert_eq(String(got["key"]), "audio/music", "改动应当发出 changed 信号")
	# 落盘 + 重读
	store.save()
	var store2 = st.new()
	store2.cfg_path = store.cfg_path
	var loaded := int(store2.load_from_disk())
	print("[设置] 落盘后重读 %d 项 ｜ music=%.2f" % [loaded, float(store2.get_value("audio/music"))])
	assert_true(loaded > 0, "重读没有读到任何设置 ✗")
	assert_true(absf(float(store2.get_value("audio/music")) - 0.35) < 0.001, "音乐音量没有持久化 ✗")
	assert_true(store.modified_keys().size() >= 1, "应当能报出与默认不同的项")


func test_apply_creates_audio_buses_and_sets_volume() -> void:
	var st := _load(STORE)
	var ap := _load(APPLY)
	if st == null or ap == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	var created: Array = ap.call("ensure_buses")
	print("[设置] 本次新建音频总线：%s" % str(created))
	for name in ["Music", "SFX", "UI"]:
		assert_true(AudioServer.get_bus_index(name) != -1, "总线 %s 应当存在 ✗" % name)
	# 半音量 → 约 -6 dB
	store.set_value("audio/music", 0.5)
	assert_true(bool(ap.call("apply_bus", store, "audio/music")), "设置音乐音量失败")
	var idx := AudioServer.get_bus_index("Music")
	var db := AudioServer.get_bus_volume_db(idx)
	print("[设置] Music 音量 0.5 → %.1f dB（期望约 -6.0）｜ mute=%s" % [db, str(AudioServer.is_bus_mute(idx))])
	assert_true(absf(db - (-6.02)) < 0.5, "0.5 线性音量应约等于 -6 dB")
	assert_true(not AudioServer.is_bus_mute(idx), "非零音量不应静音")
	# 归零 → 静音（linear_to_db(0) 是负无穷 ✗，所以走 mute ✓）
	store.set_value("audio/music", 0.0)
	ap.call("apply_bus", store, "audio/music")
	print("[设置] Music 音量 0.0 → mute=%s" % str(AudioServer.is_bus_mute(idx)))
	assert_true(AudioServer.is_bus_mute(idx), "音量为 0 时应当静音 ✗")
	store.set_value("audio/music", 0.5)
	ap.call("apply_bus", store, "audio/music")


func test_display_applies_are_editor_guarded() -> void:
	# 最重要的一条：编辑器里**绝不能**去改窗口模式/帧率 ✗（那会改掉编辑器自己的窗口 ✗）
	var st := _load(STORE)
	var ap := _load(APPLY)
	if st == null or ap == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	for key in ["graphics/window_mode", "graphics/vsync", "graphics/fps_limit", "access/ui_scale"]:
		var r := String(ap.call("apply_one", store, key))
		print("[设置] 编辑器内 %s → %s" % [key, r])
		assert_eq(r, "editor-skip", "编辑器内不该改显示设置：%s" % key)


func test_todo_items_return_todo() -> void:
	var st := _load(STORE)
	var ap := _load(APPLY)
	if st == null or ap == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	for key in ["language/locale", "gameplay/difficulty", "controls/sensitivity", "access/colorblind"]:
		var r := String(ap.call("apply_one", store, key))
		print("[设置] 占位项 %s → %s" % [key, r])
		assert_eq(r, "todo", "标注 todo 的项应当返回 todo：%s" % key)
		assert_eq(String(ap.call("apply_one", store, "不存在的键")), "unknown", "未知键应返回 unknown")


func test_quality_tier_wiring() -> void:
	var st := _load(STORE)
	var ap := _load(APPLY)
	if st == null or ap == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	store.set_value("graphics/tier", 0)
	var r := String(ap.call("apply_one", store, "graphics/tier"))
	print("[设置] 画质档位应用 → %s" % r)
	assert_true(r == "ok" or r == "queued", "档位应用应成功或排队，而不是 %s" % r)
	if QualityManager.instance != null:
		assert_eq(QualityManager.instance.tier, 0, "Quality 单例的档位没有跟着变 ✗")
		print("[设置] 已确认 Quality.tier = %d ✓（画质分级系统联通了 ✓）" % QualityManager.instance.tier)
		QualityManager.instance.set_tier(2)


func test_about_info_is_real() -> void:
	var ap := _load(APPLY)
	if ap == null:
		return
	var info: Dictionary = ap.call("about_info")
	for k in info.keys():
		print("[设置] 关于 · %s = %s" % [k, str(info[k])])
		assert_true(String(info[k]) != "", "%s 不该为空 ✗" % k)
	assert_true(String(info["about/engine"]).begins_with("Godot"), "引擎版本不对 ✗")
	assert_true(DirAccess.dir_exists_absolute(String(info["about/save_dir"])), "存档目录不存在 ✗")


func test_menu_builds_and_toggles() -> void:
	var MENUS := _load(MENU)
	var st := _load(STORE)
	if MENUS == null or st == null:
		return
	var menu = MENUS.new()
	menu.store = st.new()
	menu.store.cfg_path = _tmp_cfg()
	menu.store.reset_all()
	# 注意：McpTestSuite 不是 Node ✗ → 没有 get_tree() ✓，要用 Engine.get_main_loop()
	var tree := Engine.get_main_loop() as SceneTree
	assert_true(tree != null, "拿不到 SceneTree")
	if tree == null:
		return
	tree.root.add_child(menu)
	# 用菜单自己报出来的分类按钮文字 ✓（别在测试里硬猜 UI 层级，太脆 ✗）
	var cats: Array = menu.call("category_names")
	print("[设置] 菜单实际建出分类：%s" % str(cats))
	assert_eq(cats.size(), 7, "分类按钮数不对")
	assert_eq(String(cats[0]), "画质", "第一个分类应是画质")
	assert_true(cats.has("音频") and cats.has("语言"), "缺分类 ✗")
	assert_true(not menu.is_open(), "初始应是关闭状态")
	menu.call("open")
	assert_true(menu.is_open(), "open() 后应为打开 ✗")
	menu.call("close")
	assert_true(not menu.is_open(), "close() 后应为关闭 ✗")
	menu.queue_free()

const INPUT_ := "res://scripts/settings/settings_input.gd"


func test_input_rebind_end_to_end() -> void:
	# 端到端：真改 InputMap ✓ → 真存盘 ✓ → 新会话读回 ✓
	# ★ 编辑器测试环境里**没有**项目自定义动作 ✗（autoload 与项目 InputMap 都不加载 ✗）
	#   → 所以这里**自己造一个临时动作** ✓，做到完全不依赖外部状态 ✓
	var si := _load(INPUT_)
	var st := _load(STORE)
	if si == null or st == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()

	assert_true(not bool(si.call("is_rebindable", "ui_cancel")), "ui_cancel 不该允许改键")
	assert_true(bool(si.call("is_rebindable", "__settings_test_action")), "自定义动作应允许改键")

	var k := InputEventKey.new()
	k.physical_keycode = KEY_K
	k.ctrl_pressed = true
	assert_eq(String(si.call("event_text", k)), "Ctrl+K", "组合键文字不对")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_RIGHT
	assert_eq(String(si.call("event_text", mb)), "鼠标右键", "鼠标键文字不对")

	# 造临时动作（测试结束会删掉 ✓）
	var action := "__settings_test_action"
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action)
	var first := InputEventKey.new()
	first.physical_keycode = KEY_J
	InputMap.action_add_event(action, first)
	assert_eq(String(si.call("current_text", action)), "J", "临时动作初始绑定不对")

	var nr := InputEventKey.new()
	nr.physical_keycode = KEY_F9
	var r: Dictionary = si.call("rebind", store, action, nr)
	print("[设置] 改键：J → %s ｜ %s" % [String(si.call("current_text", action)), str(r)])
	assert_true(bool(r.get("ok", false)), "改键失败")
	assert_eq(String(si.call("current_text", action)), "F9", "InputMap 没有被真的改掉 ✗")
	assert_true(store.get_value("input/bindings") is Dictionary, "绑定没有被存进设置 ✗")

	# 持久化：新会话读回来还应当是 F9 ✓
	store.save()
	var store2 = st.new()
	store2.cfg_path = store.cfg_path
	store2.load_from_disk()
	InputMap.action_erase_events(action)              # 抹掉 → 再由绑定还原 ✓
	var raw = store2.get_value("input/bindings")
	print("[设置] 落盘后读到的绑定表：%s" % str(raw).substr(0, 160))
	var restored := int(si.call("load_bindings", store2))
	print("[设置] 新会话还原按键：%d 个 → 现为 %s" % [restored, String(si.call("current_text", action))])
	assert_eq(String(si.call("current_text", action)), "F9", "重开之后按键没有还原 ✗")

	InputMap.erase_action(action)                     # 收尾：删掉临时动作 ✓


func test_tier_drives_project_settings() -> void:
	# "合并"的证明：一个档位同时驱动 项目原有 Settings（MSAA/LOD/草丛/雾）与 新增 Quality（地表贴图/地形 LOD）
	# ★ 编辑器里 autoload 不加载 ✗ → 这里**手动实例化项目原有的 settings.gd** ✓
	var st := _load(STORE)
	var ap := _load(APPLY)
	var proj_script := _load("res://scripts/settings.gd")
	if st == null or ap == null or proj_script == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	var tree := Engine.get_main_loop() as SceneTree
	assert_true(tree != null, "拿不到 SceneTree")
	if tree == null:
		return
	var proj = proj_script.new()
	proj.name = "Settings"                             # ★ 必须取名 Settings：apply_tier 按这个名字找 autoload ✓
	tree.root.add_child(proj)                          # 加进树让 _ready 跑 ✓
	for tier in [0, 3, 2]:
		store.set_value("graphics/tier", tier)
		var r := String(ap.call("apply_one", store, "graphics/tier"))
		var got := int(proj.get("quality"))
		print("[设置] 档位 %d → Settings.quality=%d ｜ 返回 %s" % [tier, got, r])
		assert_eq(got, tier, "项目原有 Settings.quality 没跟着变 ✗（合并失败）")
	proj.queue_free()


func test_new_appliers_are_editor_guarded() -> void:
	var st := _load(STORE)
	var ap := _load(APPLY)
	if st == null or ap == null:
		return
	var store = st.new()
	store.cfg_path = _tmp_cfg()
	store.reset_all()
	for key in ["graphics/aa", "graphics/shadow"]:
		var r := String(ap.call("apply_one", store, key))
		print("[设置] 编辑器内 %s → %s" % [key, r])
		assert_eq(r, "editor-skip", "编辑器内不该改显示设置：%s" % key)
	assert_eq(String(ap.call("apply_one", store, "language/subtitle")), "ok", "字幕应当已转正 ✗")
	for key in ["language/subtitle", "graphics/aa", "graphics/shadow"]:
		assert_true(not bool(SettingsSchema.is_todo(key)), "%s 不该还是占位 ✗" % key)


func test_subtitle_system() -> void:
	# ★ 手动实例化总控（编辑器里 autoload 不加载 ✗），完全自给自足 ✓
	var gs_script := _load("res://scripts/settings/game_settings.gd")
	if gs_script == null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	assert_true(tree != null, "拿不到 SceneTree")
	if tree == null:
		return
	var gs = gs_script.new()
	gs.name = "GameSettingsTest"
	tree.root.add_child(gs)
	gs.store.cfg_path = _tmp_cfg()
	gs.store.reset_all()
	assert_true(bool(gs.call("subtitles_enabled")), "默认应当允许字幕")
	gs.call("show_subtitle", "这是一条测试字幕 ✓", 2.0)
	var layer = gs.get("_sub_layer")
	assert_true(layer != null, "字幕层没有创建 ✗")
	if layer != null:
		print("[设置] 字幕层 visible=%s" % str(layer.visible))
		assert_true(bool(layer.visible), "字幕显示后层应当可见 ✗")
	var lab = gs.get("_sub_label")
	if lab != null:
		assert_eq(String(lab.text), "这是一条测试字幕 ✓", "字幕文字不对 ✗")
	# 关掉开关 → 不再显示 ✓
	gs.store.set_value("language/subtitle", false)
	gs.call("hide_subtitle")
	gs.call("show_subtitle", "不该出现", 2.0)
	if layer != null:
		assert_true(not bool(layer.visible), "关闭开关后不该再显示字幕 ✗")
	gs.queue_free()

func test_menu_input_priority() -> void:
	# 背景：项目里 camera_rig.gd:156 与 game_ui.gd:645 都直接处理 ESC ✗，
	# 菜单原来用 _unhandled_input（输入链最后一站 ✗）会被它们抢掉 ✗。
	# 现在改成 _input（最早一站 ✓）+ F10 兜底键 ✓ + 有焦点时不抢 ESC ✓。
	var MENUS := _load(MENU)
	var st := _load(STORE)
	if MENUS == null or st == null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	assert_true(tree != null, "拿不到 SceneTree")
	if tree == null:
		return
	var menu = MENUS.new()
	menu.store = st.new()
	menu.store.cfg_path = _tmp_cfg()
	menu.store.reset_all()
	tree.root.add_child(menu)

	# 先释放焦点 ✓：上一个用例可能留下输入框焦点 ✗，会污染本用例（测试必须互相隔离 ✓）
	tree.root.gui_release_focus()
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	var f10 := InputEventKey.new()
	f10.physical_keycode = KEY_F10
	f10.pressed = true

	# ① 无焦点：ESC 打开 ✓
	menu.call("_input", esc)
	assert_true(menu.is_open(), "无焦点时 ESC 应当打开菜单 ✗")
	# ② 开着：ESC 关闭 ✓
	menu.call("_input", esc)
	assert_true(not menu.is_open(), "菜单开着时 ESC 应当关闭 ✗")
	# ③ 关掉 ESC 开关后：ESC 无效 ✓、F10 仍可用 ✓（这是不被抢占的兜底 ✓）
	menu.open_with_escape = false
	menu.call("_input", esc)
	assert_true(not menu.is_open(), "关掉开关后 ESC 不该再打开 ✗")
	menu.call("_input", f10)
	print("[设置] F10 兜底 → open=%s（应 true ✓）" % str(menu.is_open()))
	assert_true(menu.is_open(), "F10 备用键必须能打开菜单 ✗")
	menu.call("_input", esc)
	menu.open_with_escape = true
	# ④ 普通控件（按钮）有焦点时：ESC **仍应能打开** ✓
	# （早期规则是"只要有焦点就让路" ✗ → HUD 上一点残留焦点就会让 ESC 永久失效 ✗）
	var hud_btn := Button.new()
	hud_btn.text = "HUD"
	tree.root.add_child(hud_btn)
	hud_btn.grab_focus()
	menu.call("_input", esc)
	print("[设置] 按钮有焦点时按 ESC → open=%s（应 true ✓）" % str(menu.is_open()))
	assert_true(menu.is_open(), "残留焦点不该让 ESC 失灵 ✗")
	menu.call("_input", esc)
	hud_btn.queue_free()
	# ⑤ 正在输入文字（LineEdit 有焦点）时：ESC **必须让路** ✓
	var edit := LineEdit.new()
	tree.root.add_child(edit)
	edit.grab_focus()
	menu.call("_input", esc)
	print("[设置] 输入框有焦点时按 ESC → open=%s（应 false ✓）" % str(menu.is_open()))
	assert_true(not menu.is_open(), "正在输入文字时不该抢 ESC ✗")
	edit.queue_free()
	tree.root.gui_release_focus()      # 收尾释放焦点 ✓ 别污染后面的用例
	menu.queue_free()

func test_every_category_builds_without_error() -> void:
	# ★ 回归：音频页曾经一点就运行时报错 ✗ ——
	#   根因：HSlider **没有** disabled 属性 ✗（那是 BaseButton 才有的 ✓）。
	#   为什么之前没抓到 ✗：菜单测试只数了分类按钮，**从没真正构建过每一页** ✗。
	#   所以这里把**每一页都构建一遍** ✓（这才是真正的覆盖 ✓）。
	var MENUS := _load(MENU)
	var st := _load(STORE)
	if MENUS == null or st == null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	assert_true(tree != null, "拿不到 SceneTree")
	if tree == null:
		return
	var menu = MENUS.new()
	menu.store = st.new()
	menu.store.cfg_path = _tmp_cfg()
	menu.store.reset_all()
	tree.root.add_child(menu)
	var built := 0
	for cat in SettingsSchema.ORDER:
		menu.call("_show_category", String(cat))
		built += 1
		var content = menu.get("_content")
		var rows := 0
		if content != null:
			rows = (content as Node).get_child_count()
		print("[设置] 构建 %s 页 → 顶层行 %d 个" % [cat, rows])
		assert_true(rows > 0, "%s 页没有构建出任何内容 ✗" % cat)
	assert_eq(built, 7, "应当逐页构建 7 次")
	menu.queue_free()