@tool
extends EditorPlugin
## 材质燃烧开关插件 ✓
##
## 作用：在**材质资源（.tres）**的检查器顶部加一组控件 ✓
##   「燃烧效果」下拉 = 无 / 叶片型（烧完消失）/ 木质型（烧完保留焦黑）✓
##   「树高(米)」= 决定"从下往上烧"的前沿映射（= shader 的 height_ref ✓）✓
##
## ★ 按要求**已去掉 FileSystem 右键入口** ✗（只保留检查器这一个入口 ✓）
##   `fs_menu.gd` 已不再被 preload/注册 ✓ → 完全不生效 ✓（留着或删掉都可以 ✓）
##
## 为什么用"资源检查器"而不是导出时处理 ✓（用户要求 ✓）：
##   · per 材质可控 ✓ 看得见状态 ✓ 重新导出也不会丢 ✓
##   · 导出器保持"只产出普通材质" ✓（干净 ✓）
##
## 注意：改动会**立即写回该 .tres 文件** ✓
##   → 已经打开的**场景**需要重新加载一次 ✓（场景里引用的是旧资源对象 ✓）

const INSP := preload("res://addons/burn_toggle/inspector_burn.gd")
static var _live: EditorInspectorPlugin = null


func _enter_tree() -> void:
	# ★ 防重复注册 ✓（热重载会让 _enter_tree 再跑一次 ✗ → 检查器里出现两组控件 ✓）
	if _live != null:
		remove_inspector_plugin(_live)
		_live = null
	_live = INSP.new()
	add_inspector_plugin(_live)
	print("[燃烧开关] 已启用 ✓：双击 .tres → 检查器顶部选「燃烧效果」✓")


func _exit_tree() -> void:
	if _live != null:
		remove_inspector_plugin(_live)
		_live = null
	print("[燃烧开关] 已停用")
