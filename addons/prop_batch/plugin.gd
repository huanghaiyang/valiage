@tool
extends EditorPlugin
## 【合批选择器】只做一件事：把两个开关加到**节点自己的检查器**里 ✓
##   —— 不再有独立面板 ✗、不再写 `prop_batch.cfg` ✗（开关就是节点自身的 meta ✓）
##
##   ① **模型根节点**（有多个子件时）：「是否允许合批」
##        → 勾上写 meta `allow_batch = true` ✓（默认**不勾** ✗）
##   ② **子网格**（根已允许合批后才显示）：「参与合批」
##        → 取消写 meta `batch = false` ✓（默认**参与** ✓）
##
## 运行时：`scripts/world/prop_merge.gd` 只读这两个 meta 决定合批范围 ✓
##
## ⚠ 勾完记得 **Ctrl+S 保存场景**（meta 存在 .tscn 里 ✓）
const INSPECTOR := preload("res://addons/prop_batch/inspector_batch.gd")

## ★ 用 **static** 跨热重载保留实例 ✓ → 可以先注销上一次的，避免检查器里出现两个复选框 ✗
static var _live_insp: EditorInspectorPlugin = null


func _enter_tree() -> void:
	if _live_insp != null and is_instance_valid(_live_insp):
		remove_inspector_plugin(_live_insp)
		_live_insp = null
	_live_insp = INSPECTOR.new()
	add_inspector_plugin(_live_insp)


func _exit_tree() -> void:
	if _live_insp != null and is_instance_valid(_live_insp):
		remove_inspector_plugin(_live_insp)
		_live_insp = null
