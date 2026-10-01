@tool
extends RefCounted
## 预览窗口的懒加载入口（避免 plugin.gd <-> preview_window.gd 互相 preload）

const WINDOW_PATH := "res://addons/blend_tools/preview_window.gd"

static var _win: Window = null


static func open_preview(blend_path: String) -> void:
	if _win != null and is_instance_valid(_win) and _win.visible:
		# 已经开着的同一个窗口就复用；关掉的会立刻销毁（见下），所以不会拿到过期脚本
		_win.call("open_with", blend_path)
		_win.popup_centered()
		return
	_win = null
	# 每次都从磁盘重读脚本：改完插件代码关掉窗口再开就生效，不必重启编辑器
	var script: GDScript = ResourceLoader.load(WINDOW_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null or not script.can_instantiate():
		push_error("[Blender 预览导出] 无法加载 %s" % WINDOW_PATH)
		return
	var win: Window = script.new()
	var base := EditorInterface.get_base_control()
	if base == null:
		push_error("[Blender 预览导出] 拿不到编辑器根控件")
		return
	base.add_child(win)
	_win = win
	# 关闭就**销毁**：否则实例一直被复用，脚本永远是第一次加载的那份，
	# 改插件代码后重开窗口也不会生效（这个坑踩过）。
	win.close_requested.connect(_on_closed)
	win.call("open_with", blend_path)
	win.popup_centered()


static func _on_closed() -> void:
	if _win != null and is_instance_valid(_win):
		_win.queue_free()
	_win = null