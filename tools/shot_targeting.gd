extends Node
## 临时视觉验证入口：加载主场景，并把一个"持久助手"挂到 root 上（不随场景切换被释放）
const MAIN := "res://scenes/main.tscn"
const HELPER := "res://tools/shot_helper.gd"


func _ready() -> void:
	var helper := Node.new()
	helper.name = "ShotHelper"
	helper.set_script(load(HELPER))
	get_tree().root.add_child.call_deferred(helper)
	get_tree().change_scene_to_packed.call_deferred(load(MAIN))
