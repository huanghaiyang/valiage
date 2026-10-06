@tool
extends EditorPlugin
## 【贴图分档生成器】为模型贴图生成低分辨率分档（供画质分级换用）。
##
## 入口：**鼠标右键**（零侵入，绝不改停靠布局）
##   · 场景树选中节点 → 右键 → 生成贴图分档…      （按选中节点/整场景扫材质贴图）
##   · 文件系统选中图片 / **glb/gltf** / 文件夹 → 右键 → 生成贴图分档…
##
## 产物位置（重要）：
##   · 贴图本来就是**独立文件** → 变体生成在**原贴图同目录**（`xxx_diff_4k.jpg` → `_2k`/`_1k`）。
##     必须如此：运行时 `QualityTiers.resolve_existing()` 就是"原路径换后缀"来找分档的。
##   · 贴图**内嵌在 glb 里**（resource_path 为空）→ 先导出到 **glb 所在目录**
##     （`<模型名>_tex_<n>.png`），再在**同一目录**生成分档。
##     ★ 内嵌图导出的文件不会自动被材质引用：要让运行时真的按档换图，请把该 glb 的
##       导入设置 `gltf/embedded_image_handling` 改成 **Extract Textures**（或手动替换材质）。
##
## 安全：只新增文件、绝不覆盖原图；内嵌图导出也绝不覆盖已有文件。

const CtxMenu := preload("res://addons/texture_tier_baker/context_menu.gd")
const RULES := preload("res://addons/texture_tier_baker/tier_rules.gd")
const SIZE_OF := {"4k": 4096, "2k": 2048, "1k": 1024, "512": 512, "256": 256}
const MENU_LABEL := "生成贴图分档…"
const IMG_EXT := ["jpg", "jpeg", "png", "webp", "bmp", "tga"]
const MODEL_EXT := ["glb", "gltf"]

var _ctx_scene: EditorContextMenuPlugin
var _ctx_files: EditorContextMenuPlugin
# 窗口与控件
var _win: Window
var _log: RichTextLabel
var _root_edit: LineEdit
var _tiers_edit: LineEdit
var _only_selected: CheckBox
var _do_extract: CheckBox
var _do_variants: CheckBox
var _stat: Label


func _enter_tree() -> void:
	_ctx_scene = CtxMenu.new()
	_ctx_scene.setup(MENU_LABEL, _menu_scene_tree)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _ctx_scene)
	_ctx_files = CtxMenu.new()
	_ctx_files.setup(MENU_LABEL, _menu_filesystem)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _ctx_files)


func _exit_tree() -> void:
	if _ctx_scene != null:
		remove_context_menu_plugin(_ctx_scene)
		_ctx_scene = null
	if _ctx_files != null:
		remove_context_menu_plugin(_ctx_files)
		_ctx_files = null
	if is_instance_valid(_win):
		_win.queue_free()
		_win = null


# ================================================================ 右键入口
## 待处理的素材（文件系统右键解析出来的），等用户点「生成分档」才真写文件 ✓
var _pending_files: Array = []
var _pending_models: Array = []


## 注意：Godot 以 1 个参数（菜单项 id）调用回调 → 用可选参数接收 ✓
func _menu_scene_tree(_arg: Variant = null) -> void:
	_pending_files.clear()
	_pending_models.clear()
	if _only_selected != null:
		_only_selected.button_pressed = true
	_open_window()
	_say("[b]入口[/b]：场景树右键（模式：按当前选中节点）")
	_on_scan()


## ★ 文件系统右键 = **只扫描并列出清单**，不写任何文件 ✓（生成必须点「生成分档」）
func _menu_filesystem(_arg: Variant = null) -> void:
	_open_window()
	var staged: Dictionary = _stage_from_paths(_ctx_files.last_paths if _ctx_files != null else PackedStringArray())
	_say("[b]入口[/b]：文件系统右键（只扫描，不生成 ✓）")
	# 右键里的 glb/gltf：解析它们**内部材质**引用的贴图（不受当前场景引用限制 ✓）
	var model_tex: Dictionary = {}
	for m in staged["models"]:
		var got := _textures_of_model(String(m))
		for k in got.keys():
			model_tex[k] = true
	if not model_tex.is_empty():
		_say("从 %d 个模型里解析出 %d 张贴图 ✓" % [staged["models"].size(), model_tex.size()])
		for k in model_tex.keys():
			staged["files"].append(k)
	if staged["files"].is_empty() and staged["models"].is_empty():
		_say("[color=orange]选中的里没有图片或 glb/gltf（支持 jpg/jpeg/png/webp/bmp/tga + glb/gltf）[/color]")
		return
	_pending_files = staged["files"].duplicate()
	_pending_models = staged["models"].duplicate()
	for m in staged["models"]:
		_say("  · 模型 %s" % m)
	_list_files(_pending_files)
	_say("[color=orange]以上仅为清单[/color] → 确认后点「生成分档」才会写文件 ✓")
	if _do_extract != null and not staged["models"].is_empty():
		_do_extract.button_pressed = true


## 列出素材与真实尺寸、以及"按当前档位需要生成几个"
func _list_files(paths: Array) -> void:
	var tiers := _tier_list()
	var uniq := {}
	for p in paths:
		uniq[String(p)] = true
	var i := 0
	var all_small := true
	for p in uniq.keys():
		i += 1
		var img := _image_of(String(p))
		var dim := "（读取失败）"
		var need := 0
		if img != null:
			dim = "%dx%d" % [img.get_width(), img.get_height()]
			for t in tiers:
				if img.get_width() > int(SIZE_OF[t]):
					need += 1
			if need > 0:
				all_small = false
		if i <= 60:
			# ★ 先识别「源档位」，再列出**真正需要生成的降档**（不放大原则 ✓）
			var src_tier := "?"
			var will: Array = []
			if img != null:
				var w := img.get_width()
				if w > 2048:
					src_tier = "4k 及以上"
				elif w > 1024:
					src_tier = "2k"
				elif w > 512:
					src_tier = "1k"
				elif w > 256:
					src_tier = "512"
				else:
					src_tier = "256 及以下"
				for t in tiers:
					if w > int(SIZE_OF[t]):
						will.append(t)
			_say("  · %s  [b]%s[/b]（源档 ≈ %s）→ 将生成 %s" % [p, dim, src_tier, str(will)])
	if uniq.size() > 60:
		_say("  …其余 %d 张省略" % (uniq.size() - 60))
	if not uniq.is_empty() and all_small:
		_say("[color=orange]全部原图都已 ≤ 当前最低档位 → 无需生成分档[/color]（这属于「已达标」：贴图本身就在低分辨率档 ✓）")


## 解析一个 glb/gltf 的导入场景，返回它**材质引用的独立贴图文件** {路径: true}
## （内嵌贴图不含在内 —— 那些走 _extract_embedded 导出 ✓）
func _textures_of_model(model_path: String) -> Dictionary:
	var out := {}
	if not ResourceLoader.exists(model_path):
		return out
	var ps := load(model_path) as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D:
			for m in _materials_of(n as MeshInstance3D):
				var bm := m as BaseMaterial3D
				if bm == null:
					continue
				for prop in ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture",
						"emission_texture", "ao_texture", "heightmap_texture", "rim_texture",
						"clearcoat_texture", "anisotropy_texture", "detail_albedo", "detail_normal"]:
					var tex := bm.get(prop) as Texture2D
					if tex == null:
						continue
					var p := String(tex.resource_path)
					if p != "":
						out[p] = true
		for c in n.get_children():
			stack.append(c)
	root.free()
	return out


## 从右键路径里分出「图片文件」与「模型文件」；文件夹取其直接子级
func _stage_from_paths(paths: PackedStringArray) -> Dictionary:
	var files: Array = []
	var models: Array = []
	for p in paths:
		var s := String(p)
		if s.ends_with("/"):
			# ★ 文件夹：**递归**扫描（此前只取直接子级，会漏掉批量资产 ✗）
			_walk_dir(s, files, models)
		elif _ext_in(s, IMG_EXT):
			files.append(s)
		elif _ext_in(s, MODEL_EXT):
			models.append(s)
	return {"files": files, "models": models}


## 递归收集一个目录下的图片与模型
func _walk_dir(dir_path: String, files: Array, models: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		var full := dir_path + f
		if _ext_in(f, IMG_EXT):
			files.append(full)
		elif _ext_in(f, MODEL_EXT):
			models.append(full)
	for sub in d.get_directories():
		_walk_dir(dir_path + sub + "/", files, models)


func _ext_in(path: String, exts: Array) -> bool:
	var low := path.to_lower()
	for e in exts:
		if low.ends_with("." + String(e)):
			return true
	return false


# ================================================================ 窗口 UI
func _open_window() -> void:
	if not is_instance_valid(_win):
		_win = _build_window()
		add_child(_win)
	_win.popup_centered(Vector2i(820, 660))


## ★ 用 AcceptDialog，而不是裸 Window：
##   裸 Window + popup_centered() 在编辑器（子窗口内嵌）里可能**关不掉** ✗；
##   AcceptDialog 自带「关闭」按钮、支持 Esc、点右上角 X 也会 hide ✓。
func _build_window() -> Window:
	var w := AcceptDialog.new()
	w.title = "贴图分档生成器"
	w.ok_button_text = "关闭"
	w.min_size = Vector2i(660, 520)
	w.visible = false
	w.close_requested.connect(func() -> void: w.hide())
	w.confirmed.connect(func() -> void: w.hide())
	w.canceled.connect(func() -> void: w.hide())

	var margin := MarginContainer.new()
	# 放进 AcceptDialog 的内容区（由对话框内部容器排版；不要用 FULL_RECT 锚点，
	# 否则会压到对话框底部的按钮栏 ✗）
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.custom_minimum_size = Vector2(0, 430)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	w.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "模型贴图分档生成器"
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	var sub := Label.new()
	sub.text = "为模型贴图生成低分辨率分档（供画质分级换用）：xxx_diff_4k.jpg → _2k / _1k"
	sub.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	vb.add_child(sub)

	vb.add_child(HSeparator.new())

	# ---- 参数区
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)

	grid.add_child(_label("要生成的档位"))
	var tier_row := VBoxContainer.new()
	_tiers_edit = LineEdit.new()
	_tiers_edit.text = "2k,1k"
	_tiers_edit.custom_minimum_size = Vector2(360, 0)
	tier_row.add_child(_tiers_edit)
	var tier_hint := Label.new()
	tier_hint.text = "逗号分隔，支持 4k / 2k / 1k / 512 / 256（只降采样，原图更小则跳过）"
	tier_hint.add_theme_color_override("font_color", Color(0.6, 0.66, 0.74))
	tier_row.add_child(tier_hint)
	grid.add_child(tier_row)

	grid.add_child(_label("扫描根"))
	_root_edit = LineEdit.new()
	_root_edit.placeholder_text = "/root/Main/墓地遗迹（留空 = 整个编辑场景）"
	grid.add_child(_root_edit)

	grid.add_child(_label("选项"))
	var opts := VBoxContainer.new()
	_only_selected = CheckBox.new()
	_only_selected.text = "场景模式只处理当前选中的节点"
	_only_selected.button_pressed = true
	opts.add_child(_only_selected)
	_do_extract = CheckBox.new()
	_do_extract.text = "glb 内嵌贴图：导出到模型所在目录（再生成分档）"
	_do_extract.button_pressed = true
	opts.add_child(_do_extract)
	_do_variants = CheckBox.new()
	_do_variants.text = "为独立贴图文件生成分档（原图同目录）"
	_do_variants.button_pressed = true
	opts.add_child(_do_variants)
	grid.add_child(opts)

	vb.add_child(HSeparator.new())

	# ---- 按钮
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var b_scan := Button.new()
	b_scan.text = "扫描预览"
	b_scan.custom_minimum_size = Vector2(120, 34)
	b_scan.pressed.connect(_on_scan)
	row.add_child(b_scan)
	var b_bake := Button.new()
	b_bake.text = "生成分档"
	b_bake.custom_minimum_size = Vector2(120, 34)
	b_bake.pressed.connect(_on_bake)
	row.add_child(b_bake)
	var b_clear := Button.new()
	b_clear.text = "清空日志"
	b_clear.pressed.connect(func() -> void: if _log != null: _log.clear())
	row.add_child(b_clear)
	_stat = Label.new()
	_stat.text = ""
	_stat.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
	row.add_child(_stat)
	vb.add_child(row)

	# ---- 日志（占据剩余空间）
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(0, 240)
	var pm := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pm.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(pm)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	pm.add_child(_log)
	vb.add_child(panel)
	return w


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.custom_minimum_size = Vector2(92, 0)
	return l


func _say(t: String) -> void:
	if _log != null and is_instance_valid(_log):
		_log.append_text(t + "\n")
	print("[贴图分档] " + t)


# ================================================================ 扫描
func _target_roots() -> Array:
	var roots: Array = []
	if _only_selected != null and _only_selected.button_pressed:
		for n in get_editor_interface().get_selection().get_selected_nodes():
			roots.append(n)
	if roots.is_empty() and _root_edit != null and _root_edit.text.strip_edges() != "":
		var r := get_editor_interface().get_edited_scene_root()
		if r != null:
			var p := _root_edit.text.strip_edges()
			var n: Node = r.get_node_or_null(p)
			if n != null:
				roots.append(n)
			else:
				_say("[color=orange]找不到扫描根：%s（改用整个编辑场景）[/color]" % p)
	if roots.is_empty():
		var e := get_editor_interface().get_edited_scene_root()
		if e != null:
			roots.append(e)
	return roots


## 返回 { 贴图路径: 使用它的材质数 } 与 { glb路径: 内嵌贴图数 }
func _scan_scene() -> Dictionary:
	var files := {}
	var embedded := {}          # glb 路径 -> 内嵌贴图数量（用于日志提示）
	var stack: Array = _target_roots()
	var guard := 0
	while not stack.is_empty() and guard < 300000:
		guard += 1
		var n = stack.pop_back()
		if n == null:
			continue
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			for m in _materials_of(mi):
				var bm := m as BaseMaterial3D
				if bm == null:
					continue
				# ★ 必须覆盖**所有**贴图插槽：只查 albedo/normal 会漏掉
				#   normal / roughness / metallic / emission / ao / height / rim / clearcoat 等 ✗
				for prop in ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture",
						"emission_texture", "ao_texture", "heightmap_texture", "rim_texture",
						"clearcoat_texture", "anisotropy_texture", "detail_albedo", "detail_normal"]:
					var tex := bm.get(prop) as Texture2D
					if tex == null:
						continue
					var p := String(tex.resource_path)
					if p.is_empty():
						var owner_path := _model_owner_of(mi)
						if owner_path != "":
							embedded[owner_path] = int(embedded.get(owner_path, 0)) + 1
						continue
					files[p] = int(files.get(p, 0)) + 1
		for c in n.get_children():
			stack.append(c)
	return {"files": files, "embedded": embedded}


func _materials_of(mi: MeshInstance3D) -> Array:
	var mats: Array = []
	if mi.material_override != null:
		mats.append(mi.material_override)
	for i in range(mi.get_surface_override_material_count()):
		var sm := mi.get_surface_override_material(i)
		if sm != null:
			mats.append(sm)
	if mi.mesh != null:
		for i in range(mi.mesh.get_surface_count()):
			var m2 := mi.mesh.surface_get_material(i)
			if m2 != null:
				mats.append(m2)
	return mats


## 这个 MeshInstance3D 来自哪个 glb（有则返回 res:// 路径）
func _model_owner_of(node: Node) -> String:
	var cur: Node = node
	while cur != null:
		if cur.scene_file_path != "" and _ext_in(cur.scene_file_path, MODEL_EXT):
			return cur.scene_file_path
		cur = cur.get_parent()
	return ""


func _tier_list() -> Array:
	var out: Array = []
	var txt := _tiers_edit.text if _tiers_edit != null else "2k,1k"
	for s in txt.split(",", false):
		var k := String(s).strip_edges().to_lower()
		if k == "":
			continue
		if SIZE_OF.has(k):
			out.append(k)
		else:
			_say("[color=orange]未知档位「%s」已忽略（支持 4k/2k/1k/512/256）[/color]" % k)
	return out


func _on_scan() -> void:
	var r := _scan_scene()
	var files: Dictionary = r["files"]
	var emb: Dictionary = r["embedded"]
	_say("—— 扫描完成：独立贴图 %d 张（扫描根 %d 个）——" % [files.size(), _target_roots().size()])
	var i := 0
	var tiers := _tier_list()
	var all_small := true
	for p in files.keys():
		i += 1
		var img := _image_of(String(p))
		var dim := "（读取失败）"
		var need := 0
		if img != null:
			dim = "%dx%d" % [img.get_width(), img.get_height()]
			for t in tiers:
				if img.get_width() > int(SIZE_OF[t]):
					need += 1
			if need > 0:
				all_small = false
		if i <= 40:
			_say("  · %s  [b]%s[/b]（%d 个材质使用；按当前档位需要生成 %d 个）" % [p, dim, int(files[p]), need])
	if files.size() > 40:
		_say("  …其余 %d 张省略" % (files.size() - 40))
	if not files.is_empty() and all_small:
		_say("[color=orange]全部原图都已 ≤ 当前最低档位 → 无需生成分档[/color]。")
		_say("这属于「已达标」：贴图本身就在低分辨率档，运行时的 resolve_existing() 也会回退到原图 ✓，")
		_say("想验证机制是否有效，请扫描**更大的**贴图（例如水晶树/建筑群），或把档位调小（如 512,256）。")
	if not emb.is_empty():
		_say("[color=orange]发现内嵌贴图（无独立文件）：[/color]")
		for k in emb.keys():
			_say("  · %s（%d 处）→ 勾选「内嵌贴图导出到模型目录」后可导出并生成分档" % [k, int(emb[k])])
	if files.is_empty() and emb.is_empty():
		_say("[color=orange]没找到可处理的贴图。[/color]")
	_update_stat()


## 生成中标记（`_run` 是协程：每张图 await 一帧 ✓）—— 防止连点造成两批并发 ✗
var _running := false


func _on_bake() -> void:
	if _running:
		_say("[color=orange]正在生成中，等这一批结束再点（进度见日志）[/color]")
		return
	_running = true
	# 文件系统模式：用右键时解析好的清单（**点按钮才真写文件** ✓）
	if not _pending_files.is_empty() or not _pending_models.is_empty():
		_run(_pending_files, _pending_models)
	else:
		# 场景模式：现扫现做
		_run(_scan_scene()["files"].keys(), _models_of_current_scene())


## 当前场景里出现的 glb（用于场景模式下的"内嵌导出"）
func _models_of_current_scene() -> Array:
	var seen := {}
	var stack: Array = _target_roots()
	var guard := 0
	while not stack.is_empty() and guard < 300000:
		guard += 1
		var n = stack.pop_back()
		if n is MeshInstance3D:
			var p := _model_owner_of(n)
			if p != "":
				seen[p] = true
		for c in n.get_children():
			stack.append(c)
	return seen.keys()


# ================================================================ 生成
## 取图（正确姿势）：
##   ① 优先走**导入资源**：load(path) as Texture2D → get_image()
##      —— 这是唯一在**导出后仍有效**的取图方式 ✓，也不会触发
##      "Loaded resource as image file, this will not work on export" 警告 ✗；
##   ② 仅当资源加载不到（例如刚拷进项目、还没导入）才回退 Image.load_from_file ✗（编辑器内可用）。
func _image_of(path: String) -> Image:
	# ★ 照 addons/image_convert 的成熟做法：**按绝对路径直接读文件**
	#   —— 得到的是未压缩、可安全 resize 的 Image ✓。
	#   ✗ 不要用导入纹理：VRAM 压缩纹理取出来是**压缩格式**，resize()/generate_mipmaps()
	#     会静默失败（日志报 "Cannot resize in compressed image formats."），
	#     结果就是 **2k 与 1k 生成出来一样大** ✗。
	#   ✗ 也不要用 "res://…" 调 load_from_file（会警告 will not work on export）；
	#     先 globalize_path() 成绝对路径即可避开 ✓。
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img != null and not img.is_empty():
			return img
	# 兜底：导入资源（压缩格式先解压 ✓）
	var res: Resource = ResourceLoader.load(path)
	var tex := res as Texture2D
	if tex != null:
		var im := tex.get_image()
		if im != null:
			if im.is_compressed():
				im.decompress()
			if im.get_format() != Image.FORMAT_RGB8 and im.get_format() != Image.FORMAT_RGBA8:
				im.convert(Image.FORMAT_RGBA8)
			return im
	return null


func _run(files: Array, models: Array) -> void:
	var tiers := _tier_list()
	if tiers.is_empty():
		_say("[color=orange]没有选档位。[/color]")
		return
	var made := 0
	var skip_small := 0
	var fail := 0
	var extracted := 0

	# ① 内嵌贴图：导出到模型所在目录（再对它生成分档）
	if _do_extract != null and _do_extract.button_pressed:
		for m in models:
			var res := _extract_embedded(String(m))
			extracted += int(res["extracted"])
			for f in res["files"]:
				files.append(f)
			if int(res["extracted"]) > 0:
				_say("  📦 %s → 导出内嵌贴图 %d 张到 %s" % [String(m).get_file(), int(res["extracted"]), String(m).get_base_dir()])
				_say("      [color=orange]注意[/color]：导出的文件不会自动被材质引用；要让运行时按档换图，请把该 glb 的\n      导入设置 `gltf/embedded_image_handling` 设为 Extract Textures（或手动替换材质引用）。")

	# ② 独立贴图 / 刚导出出来的贴图：生成分档（同目录）
	if _do_variants == null or _do_variants.button_pressed:
		var uniq := {}
		for f in files:
			uniq[String(f)] = true
		_say("—— 开始生成：%d 张贴图 × 档位 %s ——" % [uniq.size(), str(tiers)])
		for p in uniq.keys():
			# ★ 关键：每张图之间 `await` 一帧，把主线程让给编辑器
			#   （整批同步跑会"编辑器干死"✗：单张 4K 的解码+缩放+编码就要几百毫秒）
			if _log != null and is_instance_valid(_log):
				_log.append_text("  … 处理中：%s\n" % String(p).get_file())
			await get_tree().process_frame
			var src := String(p)
			var img := _image_of(src)
			if img == null:
				fail += 1
				_say("[color=red]读取失败[/color] %s" % src)
				continue
			for t in tiers:
				var target: int = int(SIZE_OF[t])
				if img.get_width() <= target:
					skip_small += 1
					continue
				var h := int(round(float(img.get_height()) * float(target) / float(img.get_width())))
				# ★ 照 image_convert：先统一到可安全处理的格式，再 resize ✓
				#   （压缩格式直接 resize 会静默失败 → 2k/1k 出来一样大 ✗）
				var out := img.duplicate() as Image
				if out.is_compressed():
					out.decompress()
				if out.get_format() != Image.FORMAT_RGB8 and out.get_format() != Image.FORMAT_RGBA8:
					out.convert(Image.FORMAT_RGBA8)
				out.resize(target, maxi(h, 1), Image.INTERPOLATE_LANCZOS)
				out.generate_mipmaps()
				var dst := RULES.swap_resolution_suffix(src, String(t))
				# ★ 数据类贴图（法线/AO/粗糙度/金属度/高度）**强制存 PNG**（无损）：
				#   有损 JPG 会让法线出现块状/条带状**假凹凸** ✗（法线对压缩最敏感 ✓）。
				#   判断走文件名（glb 抽出来的通常叫 xxx_Normal / xxx_ORM / xxx_rm / xxx_basecolor ✓）
				var low_src := src.to_lower()
				var data_map := low_src.contains("normal") or low_src.contains("_orm") \
						or low_src.contains("_rm.") or low_src.contains("rough") \
						or low_src.contains("metal") or low_src.contains("_ao") \
						or low_src.contains("height") or low_src.contains("mask")
				if data_map:
					dst = dst.get_basename() + ".png"
				if dst == src or dst.is_empty():
					fail += 1
					_say("[color=red]目标路径异常，拒绝写入[/color] %s" % dst)
					continue
				if FileAccess.file_exists(dst):
					# ★ 已存在时**校验尺寸**：尺寸正确才跳过（幂等 ✓）；
					#   尺寸不对（例如早期版本用压缩格式 resize 失败写坏的产物，
					#   会出现"1k 比 2k 还大"✗）→ 直接覆盖修正 ✓
					var old := _image_of(dst)
					if old != null and old.get_width() == target:
						continue
					_say("  · 覆盖旧产物 %s（旧 = %s，应为 宽 %d）" % [dst.get_file(),
							("%dx%d" % [old.get_width(), old.get_height()]) if old != null else "读不出", target])
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
				var ext := dst.get_extension().to_lower()
				var ok := false
				if ext == "jpg" or ext == "jpeg":
					if out.get_format() != Image.FORMAT_RGB8:
						out.convert(Image.FORMAT_RGB8)      # JPG 不支持 alpha ✓
					ok = out.save_jpg(dst, 0.92) == OK
				elif ext == "webp":
					ok = out.save_webp(dst, false, 0.92) == OK
				else:
					ok = out.save_png(dst) == OK
				if ok:
					made += 1
					_say("  ✅ %s → %s  (%dx%d)" % [src.get_file(), dst.get_file(), out.get_width(), out.get_height()])
				else:
					fail += 1
					_say("[color=red]  ❌ 写入失败[/color] %s" % dst)
	_running = false
	_say("—— 完成：新增分档 %d ｜ 内嵌导出 %d ｜ 原图已够小跳过 %d ｜ 失败 %d ——" % [made, extracted, skip_small, fail])
	if made > 0 or extracted > 0:
		_say("Godot 会自动导入新文件；之后切画质档时 prop_texture_quality.gd 就会换用它们。")
		get_editor_interface().get_resource_filesystem().scan()
	_update_stat()


## 把 glb 的内嵌贴图导出到 **glb 所在目录**（`<模型名>_tex_<n>.png`），返回导出文件列表
func _extract_embedded(model_path: String) -> Dictionary:
	var out := {"extracted": 0, "files": []}
	if not ResourceLoader.exists(model_path):
		return out
	var packed := load(model_path)
	var ps := packed as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate()
	if root == null:
		return out
	var dir := model_path.get_base_dir()
	var stem := model_path.get_file().get_basename()
	var idx := 0
	var seen := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D:
			for m in _materials_of(n as MeshInstance3D):
				var bm := m as BaseMaterial3D
				if bm == null:
					continue
				for prop in ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture",
						"emission_texture", "ao_texture", "heightmap_texture", "rim_texture",
						"clearcoat_texture", "anisotropy_texture", "detail_albedo", "detail_normal"]:
					var tex := bm.get(prop) as Texture2D
					if tex == null or String(tex.resource_path) != "":
						continue
					var img := tex.get_image()
					if img == null:
						continue
					var key := str(img.get_width()) + "x" + str(img.get_height()) + "_" + str(img.get_data().size())
					if seen.has(key):
						continue
					seen[key] = true
					var suffix := "albedo" if prop == "albedo_texture" else "normal"
					var dst := dir.path_join("%s_tex_%d_%s.png" % [stem, idx, suffix])
					if FileAccess.file_exists(dst):
						idx += 1
						continue
					if img.save_png(dst) == OK:
						out["extracted"] = int(out["extracted"]) + 1
						out["files"].append(dst)
					idx += 1
		for c in n.get_children():
			stack.append(c)
	root.free()
	return out


func _update_stat() -> void:
	if _stat == null:
		return
	_stat.text = "  就绪（档位 %s）" % (_tiers_edit.text if _tiers_edit != null else "")
