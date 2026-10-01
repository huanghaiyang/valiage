@tool
extends EditorPlugin
## 变体工具：
##   * 场景树右键「随机化变体…」—— 对已放好的实例做批量随机替换
##   * World Brush 每个场景行里的「随机变体」开关 + 「选变体…」—— **按笔刷单独设置**
##   * 开启的笔刷在**放置时**就被随机替换（hook 放置动作，不改 World Brush 源码）
##
## 变体表存在项目设置 variant_tools/sets 里，WB 重建界面也不会丢。

const VariantMenu := preload("res://addons/variant_tools/variant_menu.gd")
const WbRows := preload("res://addons/variant_tools/wb_rows.gd")
const WbHook := preload("res://addons/variant_tools/wb_hook.gd")

const META_KEY := &"variant_tools_menu_plugins"

var _scene_menu: EditorContextMenuPlugin = null
var _menu: VariantMenu = null
var _hook = null
var _timer: Timer = null
var _inject_tries := 0


func _enter_tree() -> void:
	_remove_stale_menus()
	_menu = VariantMenu.new()
	_scene_menu = _menu
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _scene_menu)

	_hook = WbHook.new()
	_timer = Timer.new()
	_timer.wait_time = 0.5
	_timer.autostart = true
	_timer.timeout.connect(_on_tick)
	add_child(_timer)

	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null:
		tree_root.set_meta(META_KEY, [_scene_menu])
	print("[变体工具] 已启用：场景树右键「随机化变体…」+ World Brush 每行「随机变体」")


func _process(_delta: float) -> void:
	if _hook != null:
		_hook.poll(get_tree())


func _on_tick() -> void:
	# 给 WB 的每个场景行注入控件（面板懒加载，所以轮询；注入过的会跳过）
	_inject_tries += 1
	var added := WbRows.inject_all(EditorInterface.get_base_control())
	if added > 0:
		_inject_tries = 0
	# 试够久还没 WB 面板就降低频率（但不停，用户可能后面才打开面板）
	if _inject_tries > 120 and _timer != null:
		_timer.wait_time = 3.0


func _exit_tree() -> void:
	if _scene_menu != null:
		remove_context_menu_plugin(_scene_menu)
		_scene_menu = null
	_menu = null
	_hook = null
	if _timer != null:
		_timer.queue_free()
		_timer = null
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null and tree_root.has_meta(META_KEY):
		tree_root.remove_meta(META_KEY)


func _remove_stale_menus() -> void:
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root == null or not tree_root.has_meta(META_KEY):
		return
	var stale: Array = tree_root.get_meta(META_KEY)
	for m in stale:
		if m is EditorContextMenuPlugin:
			remove_context_menu_plugin(m)
	tree_root.remove_meta(META_KEY)