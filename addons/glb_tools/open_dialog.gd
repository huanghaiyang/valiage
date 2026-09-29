@tool
extends RefCounted
## 打开插件的两个窗口，三处入口共用（场景树右键 / 3D 工具栏 / 文件系统右键）。

const Dialog := preload("res://addons/glb_tools/export_dialog.gd")
const Preview := preload("res://addons/glb_tools/preview_window.gd")


## 「导出选中节点为 GLB」窗口：导出选中的节点。
## parent 非空时挂到那个节点下（预览窗口右键导出会把自己传进来）——
## 这样确认框是预览窗口的子窗口，不会把预览窗口顶掉/关掉
static func open_for(nodes: Array, parent: Node = null) -> void:
	var picked: Array = []
	for n in nodes:
		if n is Node and is_instance_valid(n):
			picked.append(n)
	if picked.is_empty():
		warn_nothing(PackedStringArray())
		return
	var dlg: ConfirmationDialog = Dialog.new()
	if parent != null and is_instance_valid(parent):
		parent.add_child(dlg)
	else:
		EditorInterface.get_base_control().add_child(dlg)
	dlg.call("setup", picked)
	dlg.popup_centered()
	# 关掉（含取消）就释放，别在编辑器里堆窗口
	dlg.close_requested.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)


## GLB 预览 / 选择性导出窗口：从一个 .glb 里挑节点导出（glb_path 可空，窗口里能再选文件）
static func open_preview(glb_path := "") -> void:
	var win: Window = Preview.new()
	EditorInterface.get_base_control().add_child(win)
	if not glb_path.is_empty():
		win.call("load_glb", glb_path)
	win.popup_centered()
	# 注意：preview_window 的 _init 里已经连了 close_requested -> queue_free，
	# 这里不能再连一次（会报 Signal already connected 错误）


## 什么都没得导出时，弹一个**看得见**的提示（push_warning 只进日志，用户看不到）
static func warn_nothing(raw: PackedStringArray) -> void:
	var dlg := AcceptDialog.new()
	var ed_theme := EditorInterface.get_editor_theme()
	if ed_theme != null:
		dlg.theme = ed_theme          # 不设的话用默认主题，文字对比度差
	dlg.title = "导出 GLB"
	dlg.dialog_text = ("没有可导出的节点。\n\n"
			+ "请先在场景树里选中「带网格的 3D 节点」（或它所在的父节点），再右键/点按钮。\n\n"
			+ "本次右键传入的路径：%s" % (", ".join(raw) if not raw.is_empty() else "<空>"))
	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)