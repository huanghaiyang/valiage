@tool
extends EditorPlugin
## 蝴蝶飞舞插件 —— 编辑器入口。
##
## ★★ 这个插件给编辑器加了什么 ★★
##   · 菜单「项目 -> 工具 -> 蝴蝶：添加飞舞蝴蝶群」：往当前场景插一个配好素材的 ButterflySwarm
##   · 菜单「项目 -> 工具 -> 蝴蝶：重新扫描蝴蝶素材」：重扫 20 张 PNG 的透明包围盒，写 sprite_manifest.json
##   · 菜单「项目 -> 工具 -> 蝴蝶：选择蝴蝶素材…」：弹出多选列表（**这是"可选一个或多个 PNG"的实际入口**）
##   · 工具栏一个「蝴蝶」文字按钮：等价于"添加飞舞蝴蝶群"（少点两层菜单）
##
## ★★ 为什么核心逻辑不在插件里，而在 ButterflySwarm 节点里 ★★
##   节点是 `@tool` 的，检查器里改参数就立刻重建，运行时也直接可用；
##   插件入口只是**快捷键**。这样即使用户把插件停用了，场景里的蝴蝶照样飞。
##
## ★ 注意：本脚本只做编辑器集成，**不碰渲染**。所有渲染/行为都在
##   butterfly_swarm.gd / butterfly.gd / butterfly_wings.gdshader 里。

## 与 ButterflySwarm 里同名常量保持一致（这里独立写一份，避免插件依赖节点脚本的类型）
const MANIFEST_PATH := "res://addons/butterfly_swarm/sprite_manifest.json"
## 插件自带的预览场景（由 tools/make_demo_scene.gd 生成）。
const DEMO_SCENE := "res://addons/butterfly_swarm/butterfly_swarm_demo.tscn"
const BFLY_IO := preload("res://addons/butterfly_swarm/butterfly_io.gd")
const BFLY_SWARM := preload("res://addons/butterfly_swarm/butterfly_swarm.gd")
## 检查器「素材批量添加」面板（挂在 ButterflySwarm 的属性上方）
const BATCH_INSPECTOR := preload("res://addons/butterfly_swarm/inspector_batch.gd")

var _toolbar_btn: Button = null
var _sprite_dialog: ConfirmationDialog = null
var _sprite_list: ItemList = null
var _dialog_hint: Label = null
## 检查器批量面板实例（用 static 保存，热重载时才能正确反注册）
static var _batch_inspector: EditorInspectorPlugin = null


func _enter_tree() -> void:
	add_tool_menu_item("蝴蝶：添加飞舞蝴蝶群", _on_add_swarm)
	add_tool_menu_item("蝴蝶：注入到当前场景（自动找地面）", _on_inject_into_scene)
	add_tool_menu_item("蝴蝶：打开预览场景", _on_open_demo)
	add_tool_menu_item("蝴蝶：选择蝴蝶素材…", _on_open_sprite_picker)
	add_tool_menu_item("蝴蝶：重新扫描蝴蝶素材", _on_rescan)
	add_tool_menu_item("蝴蝶：重建 UV 裁剪（换图后用）", _on_regen_uv)
	# ★ 检查器批量面板：选中 ButterflySwarm 时，在 Sprites 上方出现一排批量按钮。
	#   防重复注册（热重载会让 _enter_tree 再跑一次 -> 检查器里出现两组面板）
	if _batch_inspector != null:
		remove_inspector_plugin(_batch_inspector)
		_batch_inspector = null
	_batch_inspector = BATCH_INSPECTOR.new()
	add_inspector_plugin(_batch_inspector)
	# 工具栏按钮：图标省掉（本仓库没准备 svg 图标），用文字，稳。
	_toolbar_btn = Button.new()
	_toolbar_btn.text = "蝴蝶"
	_toolbar_btn.tooltip_text = "在当前场景添加一个蝴蝶群（ButterflySwarm）"
	_toolbar_btn.focus_mode = Control.FOCUS_NONE
	_toolbar_btn.pressed.connect(_on_add_swarm)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _toolbar_btn)
	print("[蝴蝶] 插件已启用：菜单「项目 -> 工具」5 个入口 ｜ 工具栏「蝴蝶」按钮 ｜ 选中 ButterflySwarm 时检查器里有「素材批量添加」面板")


func _exit_tree() -> void:
	remove_tool_menu_item("蝴蝶：添加飞舞蝴蝶群")
	remove_tool_menu_item("蝴蝶：注入到当前场景（自动找地面）")
	remove_tool_menu_item("蝴蝶：打开预览场景")
	remove_tool_menu_item("蝴蝶：选择蝴蝶素材…")
	remove_tool_menu_item("蝴蝶：重新扫描蝴蝶素材")
	remove_tool_menu_item("蝴蝶：重建 UV 裁剪（换图后用）")
	if _batch_inspector != null:
		remove_inspector_plugin(_batch_inspector)
		_batch_inspector = null
	if _toolbar_btn != null and is_instance_valid(_toolbar_btn):
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _toolbar_btn)
		_toolbar_btn.queue_free()
		_toolbar_btn = null
	if _sprite_dialog != null and is_instance_valid(_sprite_dialog):
		_sprite_dialog.queue_free()
		_sprite_dialog = null
	print("[蝴蝶] 插件已停用")


# ==================== 菜单动作 ====================

## 「添加飞舞蝴蝶群」：往当前编辑场景的根节点下插一个 ButterflySwarm。
## 行为：
##   ① 自动补全素材（清单里最多 8 张，避免一次 load 20 张大图）
##   ② 用 UndoRedo 包装，Ctrl+Z 能撤销
##   ③ 选中新节点，方便接着调参数
## 副作用：改当前场景（可撤销）、可能写 _selected。
func _on_add_swarm() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("[蝴蝶] 当前没有打开的场景，无法添加蝴蝶群")
		return
	var swarm := BFLY_SWARM.new()
	swarm.name = "ButterflySwarm"
	# 先在树外把素材备好（load 贴图），再入树 —— 避免入树瞬间触发一次空构建
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	var take: int = mini(8, paths.size())
	var textures: Array = []
	for i in range(take):
		var t := load(String(paths[i])) as Texture2D
		if t != null:
			textures.append(t)
	# ★ 走公开方法：`sprites` 是 Array[Texture2D]，直接赋无类型 Array 会被拒（见 _configure_defaults 注释）
	swarm.call("add_sprite_textures", textures)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("添加飞舞蝴蝶群")
	ur.add_do_method(root, "add_child", swarm)
	ur.add_do_method(swarm, "set_owner", root)
	ur.add_do_method(swarm, "set_meta", "butterfly_swarm_added", true)
	ur.add_undo_method(root, "remove_child", swarm)
	ur.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(swarm)
	print("[蝴蝶] 已添加 ButterflySwarm（素材 %d 张，可到检查器里继续调）" % swarm.sprites.size())


## 「注入到当前场景」：**一键**在当前场景放一群蝴蝶 —— 自动找玩家、找地面、定区域。
## 这是"我只想赶紧看到蝴蝶在飞"的路径；比「添加蝴蝶群」多做了三件事：
##   ① 位置：站在玩家（分组 "player"）**面前 4 米**；找不到玩家就用编辑相机前方
##   ② 高程：从该点向下 raycast 找地面，把区域抬到离地 0.4 m 以上（不做就能看到蝴蝶埋在地里）
##   ③ 素材/数量/区域：一次配好（6 张素材、14 只、6×2.6×6 米）
## 可撤销（UndoRedo）。副作用：改当前场景。
func _on_inject_into_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("[蝴蝶] 当前没有打开的场景，无法注入")
		return
	var swarm := BFLY_SWARM.new()
	swarm.name = "ButterflySwarm"
	_configure_defaults(swarm)
	# ① 锚点：玩家 -> 编辑相机前方 5 米 -> 场景原点
	var anchor := Vector3.ZERO
	var found := ""
	var player: Node = _find_player_in_scene(root)
	if player is Node3D:
		anchor = (player as Node3D).global_position
		found = "玩家 %s" % player.name
	else:
		var vp := EditorInterface.get_editor_viewport_3d(0)
		if vp != null:
			anchor = vp.get_camera_3d().global_position + (-vp.get_camera_3d().global_transform.basis.z) * 5.0
			found = "编辑相机前方"
		else:
			found = "场景原点"
	# ② 地面：向下 60 米 raycast（用场景的物理空间；编辑器里可能拿不到 -> 跳过）
	#    ★ 距离用 7 米而不是 4 米：蝴蝶的"受惊半径"是 4 米，站在 4 米处整群一出生就在逃
	#      （实测 90 帧后 12 只里 10 只 FLEE）。7 米刚好在受惊半径之外，看得见又不会被吓跑。
	var place := anchor + _forward_of(player) * 7.0
	var ground_y := place.y
	var space: PhysicsDirectSpaceState3D = null
	if root.get_world_3d() != null:
		space = root.get_world_3d().direct_space_state
	var got_ground := false
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(place + Vector3(0, 3.0, 0), place - Vector3(0, 60.0, 0))
		q.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(q)
		if not hit.is_empty() and hit.has("position"):
			ground_y = (hit["position"] as Vector3).y
			got_ground = true
	swarm.global_position = Vector3(place.x, ground_y, place.z)
	if not got_ground:
		swarm.global_position = place
	# 区域中心：地面上方 1.5 m（不自动贴地，避免和上面的手算打架）
	swarm.set("region_offset", Vector3(0, 1.5, 0))
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("注入飞舞蝴蝶群")
	ur.add_do_method(root, "add_child", swarm)
	ur.add_do_method(swarm, "set_owner", root)
	ur.add_undo_method(root, "remove_child", swarm)
	ur.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(swarm)
	print("[蝴蝶] 已注入：锚点=%s ｜ 位置=%s ｜ 地面%s ｜ 素材 %d 张" % [
			found, str(swarm.global_position), ("命中 %.2f" % ground_y) if got_ground else "未命中(用原高度)",
			swarm.sprites.size()])


## 在场景里找玩家（与 scripts/wind.gd 同一套约定：先分组 "player"，再按名字含 player）。
func _find_player_in_scene(root: Node) -> Node:
	var g := root.get_tree().get_first_node_in_group("player")
	if g != null:
		return g
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and String(n.name).to_lower().contains("player"):
			return n
		for c in n.get_children():
			stack.append(c)
	return null


## 玩家/锚点的"面朝方向"（水平）。拿不到就返回 +X。
func _forward_of(player: Node) -> Vector3:
	if player is Node3D:
		var f := -(player as Node3D).global_transform.basis.z
		f.y = 0.0
		if f.length_squared() > 1e-6:
			return f.normalized()
	return Vector3(1, 0, 0)


## 给新建的蝴蝶群套一套稳妥默认值（素材从清单补，数量/区域给"一眼能看见"的量）。
## ★ 用 `add_sprite_textures()` 而不是 `get("sprites").append(...)`：
##   `sprites` 是 `Array[Texture2D]`，先 get 出来再 append 会拿到无类型 Array 的视图，
##   在 Godot 4 里对强类型数组这么做是脆的（会静默无效或报类型错）。公开方法内部做过滤，最稳。
func _configure_defaults(swarm: Node) -> void:
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	var textures: Array = []
	for i in range(mini(6, paths.size())):
		var t := load(String(paths[i])) as Texture2D
		if t != null:
			textures.append(t)
	swarm.call("add_sprite_textures", textures)
	swarm.set("count", 14)
	swarm.set("region_size", Vector3(6.0, 2.6, 6.0))
	swarm.set("seed_value", 20261016)
	swarm.set("wind_influence", 1.3)
	swarm.set("debug_draw_region", true)


## 「打开预览场景」：直接开插件自带的 butterfly_swarm_demo.tscn（含地面/花/蝴蝶/相机）。
## 用途：不想动 main.tscn 就想看效果时的入口。找不到场景文件会给出明确提示。
func _on_open_demo() -> void:
	if not ResourceLoader.exists(DEMO_SCENE):
		push_warning("[蝴蝶] 预览场景不存在：%s（可跑 tools/make_demo_scene.gd 重新生成）" % DEMO_SCENE)
		return
	EditorInterface.open_scene_from_path(DEMO_SCENE)
	print("[蝴蝶] 已打开预览场景：", DEMO_SCENE)


## 「重新扫描蝴蝶素材」：逐像素量 20 张 PNG 的透明包围盒，写 sprite_manifest.json。
## 成本：约 1~3 秒（真的解码像素），所以做成手动菜单项而不是自动。
func _on_rescan() -> void:
	var host := BFLY_SWARM.new()
	var n := host.regenerate_manifest()
	host.free()
	if n < 0:
		push_error("[蝴蝶] 素材清单写入失败（详见 Output 里的警告）")
		return
	print("[蝴蝶] 素材扫描完成：%d 张 -> %s" % [n, MANIFEST_PATH])
	# ★ 顺手把**当前选中的蝴蝶群**的 UV 裁剪也重建一遍：
	#   用户换图的典型流程就是"换图 -> 重新扫描"，如果只更新清单不改场景里的群，
	#   还得再点一次检查器按钮，多一步没意义。
	var sw := _current_swarm()
	if sw != null:
		var res: Dictionary = sw.regenerate_uv()
		print("[蝴蝶] 同时重建了选中蝴蝶群的 UV 裁剪：%d 张（第 %d 代）"
				% [int(res.get("count", 0)), int(res.get("generation", 0))])
	# 重新打开对话框时用新清单
	if _sprite_list != null and is_instance_valid(_sprite_list):
		_fill_sprite_list()


## ★ 菜单入口：只重建选中蝴蝶群的 UV 裁剪（不重写清单文件）。
## 为什么单独给一个入口：清单是"素材目录的缓存"，而 UV 裁剪是"这个群现在用的每张图的裁剪框"。
##   用户换掉素材、或手动往 sprites 里塞了任意 PNG 之后，只需要重建 UV —— 不必动清单。
func _on_regen_uv() -> void:
	var sw := _current_swarm()
	if sw == null:
		push_warning("[蝴蝶] 请先在场景树里选中一个 ButterflySwarm 节点，再执行「重建 UV 裁剪」")
		return
	var t0 := Time.get_ticks_msec()
	var res: Dictionary = sw.regenerate_uv()
	var ms := Time.get_ticks_msec() - t0
	print("[蝴蝶] UV 裁剪已重建：%d 张（第 %d 代，耗时 %d ms）"
			% [int(res.get("count", 0)), int(res.get("generation", 0)), ms])


# ==================== 多选素材对话框 ====================

## 打开「选择蝴蝶素材」对话框。
## 它会：
##   · 从清单（或现场扫目录）列出全部蝴蝶 PNG
##   · 勾选当前场景里**被选中的 ButterflySwarm** 已经配好的那几张
##   · 确认后把勾选项**整体写进**该节点的 sprites（可撤销）
func _on_open_sprite_picker() -> void:
	var swarm := _current_swarm()
	if swarm == null:
		push_warning("[蝴蝶] 请先在场景树里选中一个 ButterflySwarm 节点，再执行「选择蝴蝶素材…」")
		return
	if _sprite_dialog == null or not is_instance_valid(_sprite_dialog):
		_build_sprite_dialog()
	_fill_sprite_list()
	_sprite_dialog.title = "选择蝴蝶素材 —— 目标：%s" % swarm.name
	_sprite_dialog.popup_centered(Vector2i(560, 520))


## 取当前被选中的 ButterflySwarm（在选中的节点里找，找不到再找选中节点的父级）。
## 返回值：Node 或 null（返回 Node 而不是强类型，避免脚本类型依赖）。
func _current_swarm() -> Node:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	for n in sel:
		if n != null and n.get_script() == BFLY_SWARM:
			return n
	# 宽容一点：选中了蝴蝶子节点时，向上找父级里的 ButterflySwarm
	for n2 in sel:
		var p := n2.get_parent() if n2 != null else null
		while p != null:
			if p.get_script() == BFLY_SWARM:
				return p
			p = p.get_parent()
	return null


## 建对话框（只建一次，之后复用）。
func _build_sprite_dialog() -> void:
	_sprite_dialog = ConfirmationDialog.new()
	_sprite_dialog.name = "ButterflySpritePicker"
	_sprite_dialog.ok_button_text = "用这些蝴蝶"
	_sprite_dialog.cancel_button_text = "取消"
	_sprite_dialog.confirmed.connect(_on_sprite_picker_confirmed)
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 6)
	_dialog_hint = Label.new()
	_dialog_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialog_hint.text = "可多选。选中的会被整体写进 ButterflySwarm.sprites（可 Ctrl+Z 撤销）。"
	vb.add_child(_dialog_hint)
	_sprite_list = ItemList.new()
	_sprite_list.select_mode = ItemList.SELECT_MULTI
	_sprite_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sprite_list.custom_minimum_size = Vector2(0, 380)
	# 缩略图：直接给 ItemList 图标太小看不清，这里只列文件名 + 尺寸，
	# 但把纹理当 icon（IconMode 不启用，所以是小图标 + 文字，够辨认）
	_sprite_list.icon_mode = ItemList.ICON_MODE_LEFT
	_sprite_list.max_text_lines = 1
	vb.add_child(_sprite_list)
	var row := HBoxContainer.new()
	var b_all := Button.new()
	b_all.text = "全选"
	b_all.pressed.connect(func() -> void:
		for i in range(_sprite_list.item_count):
			_sprite_list.select(i, false))
	var b_none := Button.new()
	b_none.text = "全不选"
	b_none.pressed.connect(func() -> void:
		_sprite_list.deselect_all())
	var b_rand := Button.new()
	b_rand.text = "随机 8 张"
	b_rand.pressed.connect(func() -> void:
		_sprite_list.deselect_all()
		var n: int = mini(8, _sprite_list.item_count)
		var used: Array = []
		while used.size() < n:
			var i := randi() % _sprite_list.item_count
			if used.has(i):
				continue
			used.append(i)
			_sprite_list.select(i, false))
	row.add_child(b_all)
	row.add_child(b_none)
	row.add_child(b_rand)
	vb.add_child(row)
	_sprite_dialog.add_child(vb)
	add_child(_sprite_dialog)


## 填列表：每项 = 一个蝴蝶 PNG；图标用已加载的小图（若还没导入则跳过图标）。
## 已配好的那几张会被预勾选。
func _fill_sprite_list() -> void:
	if _sprite_list == null or not is_instance_valid(_sprite_list):
		return
	_sprite_list.clear()
	var swarm := _current_swarm()
	var owned: Array = []
	if swarm != null:
		for t in swarm.get("sprites"):
			if t is Texture2D:
				owned.append(String((t as Texture2D).resource_path))
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	for p in paths:
		var sp := String(p)
		var idx := _sprite_list.add_item(sp.get_file())
		_sprite_list.set_item_tooltip(idx, sp)
		var tex := load(sp) as Texture2D
		if tex != null:
			_sprite_list.set_item_icon(idx, tex)
		_sprite_list.set_item_metadata(idx, sp)
		if owned.has(sp):
			_sprite_list.select(idx, false)
	if _dialog_hint != null:
		_dialog_hint.text = "共 %d 张。可多选；选中的会整体写进目标节点的 sprites（可 Ctrl+Z 撤销）。" % paths.size()


## 确认：把勾选的 PNG 整体写进目标 swarm 的 sprites，并用 UndoRedo 包住。
func _on_sprite_picker_confirmed() -> void:
	var swarm := _current_swarm()
	if swarm == null:
		push_warning("[蝴蝶] 目标 ButterflySwarm 已不在，取消写入")
		return
	if _sprite_list == null or not is_instance_valid(_sprite_list):
		return
	var picked: Array = []
	for i in _sprite_list.get_selected_items():
		var meta: Variant = _sprite_list.get_item_metadata(i)
		if meta != null:
			var t := load(String(meta)) as Texture2D
			if t != null:
				picked.append(t)
	if picked.is_empty():
		push_warning("[蝴蝶] 一张都没选，保持原样")
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("设置蝴蝶素材（%d 张）" % picked.size())
	# 用属性赋值而不是改数组（UndoRedo 需要"属性名 + 旧值/新值"才能正确回滚）
	ur.add_do_property(swarm, "sprites", picked)
	ur.add_undo_property(swarm, "sprites", swarm.get("sprites"))
	ur.commit_action()
	swarm.call("rebuild")
	print("[蝴蝶] 已为 %s 配 %d 张蝴蝶素材" % [swarm.name, picked.size()])


# ==================== 工具 ====================

## 读清单里的素材路径（没有清单就返回空，调用方回落到现场扫目录）。
func _manifest_paths() -> Array:
	var out: Array = []
	if not FileAccess.file_exists(MANIFEST_PATH):
		return out
	var txt := FileAccess.get_file_as_string(MANIFEST_PATH)
	if txt.is_empty():
		return out
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return out
	var arr: Variant = (parsed as Dictionary).get("sprites", [])
	if arr is Array:
		for e in arr:
			if e is Dictionary and (e as Dictionary).has("path"):
				out.append(String((e as Dictionary)["path"]))
	return out
