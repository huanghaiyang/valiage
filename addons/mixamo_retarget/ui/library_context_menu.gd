@tool
class_name MixamoLibraryContextMenu
extends EditorContextMenuPlugin

## FileSystem 右键菜单（对 AnimationLibrary 的 .tres 生效）
## 写法照抄本项目 addons/exr_tools/filesystem_menu.gd、addons/image_convert/filesystem_menu.gd：
##   * EditorContextMenuPlugin 是 RefCounted，没有 add_child —— 对话框必须挂到 EditorInterface.get_base_control()；
##   * 对话框缓存复用（is_instance_valid 判断），弹出就一句 popup_centered()，不自己设尺寸；
##   * _popup_menu 同一次右键可能被多次调用 → 250ms 节流，避免重复菜单项；
##   * 回调路径参数用 Variant = null 兜底。

const Dlg := preload("res://addons/mixamo_retarget/ui/delete_clips_dialog.gd")
const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")

const ITEM_DELETE := "删除动画…（Mixamo 绑定）"
const ITEM_DUPS := "删除重复动画（Mixamo 绑定）"
const ITEM_REPORT := "动画列表输出到控制台（Mixamo 绑定）"

const DUP_SUFFIXES := [" copy", " - copy", "- copy", "_copy", " (1)", "(1)", " (2)", "(2)", " (3)", "(3)"]

var _last_paths := PackedStringArray()
var _added_at := 0
var _dlg: ConfirmationDialog = null


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if _animation_libraries(paths).is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item(ITEM_DELETE, _on_delete)
	add_context_menu_item(ITEM_DUPS, _on_delete_dups)
	add_context_menu_item(ITEM_REPORT, _on_report)


func _on_delete(paths: Variant = null) -> void:
	var libs := _animation_libraries(_to_paths(paths))
	if libs.is_empty():
		libs = _animation_libraries(_last_paths)
	if libs.is_empty():
		return
	if _dlg == null or not is_instance_valid(_dlg):
		_dlg = Dlg.new()
		EditorInterface.get_base_control().add_child(_dlg)
	if not _dlg.open_library(String(libs[0])):
		_dlg = null
		return
	_dlg.popup_centered()


func _to_paths(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is PackedStringArray:
		for p in (value as PackedStringArray):
			out.append(String(p))
	elif value is Array:
		for p in (value as Array):
			out.append(String(p))
	elif value is String:
		out.append(String(value))
	return out


## 只挑出 .tres 里的 AnimationLibrary（读第一行判断，不加载整个文件）
func _animation_libraries(paths: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for p in paths:
		var path := String(p)
		var lf := path.to_lower()
		if not lf.ends_with(".tres"):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var head := f.get_line()
		f.close()
		if not head.contains("AnimationLibrary"):
			continue
		out.append(path)
	return out


func _base_of(clip: String) -> String:
	var s := clip.to_lower()
	for suf in DUP_SUFFIXES:
		s = s.replace(suf, "")
	return s.strip_edges()


## 直接删除重复动画（不弹窗）：去掉 copy/(1) 之类后缀后同名的只保留一个
func _on_delete_dups(paths: Variant = null) -> void:
	var libs := _animation_libraries(_to_paths(paths))
	if libs.is_empty():
		libs = _animation_libraries(_last_paths)
	for p in libs:
		var path := String(p)
		var lib: AnimationLibrary = ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_REUSE)
		if lib == null:
			print("[Mixamo绑定] 读取失败：" + path)
			continue
		var groups := {}
		for an in lib.get_animation_list():
			var key := _base_of(String(an))
			if not groups.has(key):
				groups[key] = []
			(groups[key] as Array).append(String(an))
		var kill := PackedStringArray()
		var report := PackedStringArray()
		for key in groups.keys():
			var names: Array = groups[key]
			if names.size() < 2:
				continue
			names.sort_custom(func(a, b): return String(a).length() < String(b).length())
			for i in range(1, names.size()):
				kill.append(String(names[i]))
			report.append("保留「%s」，删除 %s" % [
				String(names[0]), ", ".join(PackedStringArray(names.slice(1)))])
		if kill.is_empty():
			print("[Mixamo绑定] %s：没有发现重复动画（共 %d 条）" % [
				path.get_file(), lib.get_animation_list().size()])
			continue
		var n := Core.delete_clips(lib, kill)
		var err := ResourceSaver.save(lib, path)
		if err != OK:
			print("[Mixamo绑定] 保存失败（%d）：%s" % [err, path])
			continue
		print("[Mixamo绑定] %s：删除 %d 条重复动画 —— %s" % [path.get_file(), n, ", ".join(kill)])
		for line in report:
			print("   " + String(line))
		print("   剩余 %d 条" % lib.get_animation_list().size())
		EditorInterface.get_resource_filesystem().update_file(path)


func _on_report(paths: Variant = null) -> void:
	var libs := _animation_libraries(_to_paths(paths))
	if libs.is_empty():
		libs = _animation_libraries(_last_paths)
	for p in libs:
		var path := String(p)
		var lib: AnimationLibrary = ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_REUSE)
		if lib == null:
			print("[Mixamo绑定] 读取失败：" + path)
			continue
		var man: Dictionary = lib.get_meta("mixamo_sources", {})
		print("[Mixamo绑定] %s：动画 %d 条，清单记录 %d 个源" % [
			path.get_file(), lib.get_animation_list().size(), man.size()])
		for c in Core.list_clips(lib):
			print("   %s（%.2fs / %d 轨道）" % [String(c["name"]), float(c["length"]), int(c["tracks"])])
