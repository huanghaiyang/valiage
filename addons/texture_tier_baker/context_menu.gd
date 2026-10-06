@tool
extends EditorContextMenuPlugin
## 右键菜单入口（场景树 / 文件系统各一个实例，由 plugin.gd 注册并持有引用）。
##
## ★ 两个坑（实测）：
##   1. Godot 调用菜单回调时会带 **1 个参数**（菜单项 id）。所以回调必须写成
##      `func cb(_arg = null)` —— 声明成 `func cb(paths: PackedStringArray)` 会报
##      "Method expected 1 argument(s), but called with 2" ✗（再叠加 bind 就成了 2 个 ✗）。
##   2. 因此**不能用 `callable.bind(paths)`** 传路径；改为在这里把 paths 记下来，
##      由 plugin.gd 的回调通过 `last_paths` 取用 ✓。

var _label := "生成贴图分档…"
var _cb: Callable = Callable()
## 最近一次右键选中的路径（场景树的节点路径 / 文件系统的 res:// 路径）
var last_paths := PackedStringArray()


## 可见性判定（收到右键选中的 paths，返回是否显示入口 ✓）
var _show_if: Callable = Callable()


## `show_if`：可选。不给则始终显示 ✓
func setup(label: String, cb: Callable, show_if: Callable = Callable()) -> void:
	_label = label
	_cb = cb
	_show_if = show_if


func _popup_menu(paths: PackedStringArray) -> void:
	last_paths = paths
	# ★ 条件不满足 → **不加入右键菜单** ✓（这样文件夹/多选/其它类型右键时根本看不到入口 ✓）
	if _show_if.is_valid() and not bool(_show_if.call(paths)):
		return
	if _cb.is_valid():
		add_context_menu_item(_label, _cb)
