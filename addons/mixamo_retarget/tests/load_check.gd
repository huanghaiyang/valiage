extends SceneTree

## 静态检查：把面板脚本 / 右键菜单脚本 load 一遍，看有没有语法错误
## （面板脚本引用编辑器类 EditorFileDialog，无头环境必然报"编辑器类不存在"——
##   只要报错只提到编辑器类，就说明语法本身没问题 ✓）

const PATHS := [
	"res://addons/mixamo_retarget/core/retarget_core.gd",
	"res://addons/mixamo_retarget/ui/delete_clips_dialog.gd",
	"res://addons/mixamo_retarget/runtime/mix_retarget_node.gd",
	"res://addons/mixamo_retarget/ui/retarget_dock.gd",
	"res://addons/mixamo_retarget/ui/library_context_menu.gd",
	"res://addons/mixamo_retarget/mixamo_retarget_plugin.gd",
]


func _initialize() -> void:
	for p in PATHS:
		var s: Variant = load(p)
		var ok: bool = s is Script
		print("%-52s %s" % [String(p).get_file(), "OK ✓" if ok else "无法加载（看上面的 Parse Error 行）"])
	print("（只提到 EditorFileDialog / EditorContextMenuPlugin 之类的编辑器类 = 语法没问题 ✓）")
	quit()
