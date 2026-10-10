extends SceneTree

## 面板布局自检：
##   1) 最小高度必须很小（否则会挤掉编辑器的底部面板）
##   2) 面板被拉高时，动画列表 / 日志区必须跟着长大（之前是固定 150/110）

const Dock := preload("res://addons/mixamo_retarget/ui/retarget_dock.gd")

var _dock: Control
var _k := 0


func _process(_d: float) -> bool:
	_k += 1
	if _k == 1:
		_dock = Dock.new()
		root.add_child(_dock)
		_dock.size = Vector2(380, 300)          # 先摆一个小尺寸
		return false
	if _k == 2:
		var ms := _dock.get_combined_minimum_size()
		print("① 面板最小尺寸 = %d × %d px → %s" % [
			int(ms.x), int(ms.y), "高度安全 ✓" if ms.y < 260 else "高度过大 ✗"])
		return false
	if _k == 3:
		var tree: Control = _dock.get("clip_tree")
		var logv: Control = _dock.get("log_view")
		print("② 面板高 300 时：列表 %d px｜日志 %d px" % [int(tree.size.y), int(logv.size.y)])
		_dock.size = Vector2(380, 1400)         # 再拉高
		return false
	if _k == 5:
		var tree: Control = _dock.get("clip_tree")
		var logv: Control = _dock.get("log_view")
		print("③ 面板高 1400 时：列表 %d px｜日志 %d px" % [int(tree.size.y), int(logv.size.y)])
		var grew: bool = logv.size.y > 200
		print("④ 日志区随面板变高而变高：%s（%s）" % [
			"是 ✓" if grew else "否 ✗",
			"日志比列表更大 ✓" if logv.size.y > tree.size.y else "列表更大（可调 ratio）"])
		print("【结论】%s" % ("布局正常 ✓" if grew and _dock.get_combined_minimum_size().y < 260 else "仍需调整 ✗"))
		return true
	return false
