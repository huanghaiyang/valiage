@tool
extends RefCounted
## 扫描图片文件 + 解析导入设置。纯逻辑（不碰编辑器 API），便于单元测试。

## 插件**默认只处理这些常规图片格式**（不含 exr/hdr/dds/ktx/psd/tga/bmp/svg）。
## 需要别的格式时，用面板上的「格式过滤」输入框显式加上即可。
const DEFAULT_EXT := ["png", "jpg", "jpeg", "webp"]

## 引擎认识的所有图片扩展名（仅供参考/白名单校验用）
const IMAGE_EXT := ["png", "jpg", "jpeg", "webp", "tga", "bmp", "svg", "exr", "hdr", "dds", "ktx", "psd"]

## Godot 的 compress/mode 取值
const MODE_NAMES := {
	0: "Lossless 无损",
	1: "Lossy 有损",
	2: "VRAM 压缩",
	3: "VRAM 无压缩",
	4: "Basis Universal",
}


## 解析用户输入的格式过滤（" PNG, jpg ,,webp " → ["png","jpg","webp"]）
static func parse_filter(text: String) -> Array:
	var out: Array = []
	for part in text.split(","):
		var e := String(part).strip_edges().to_lower().trim_prefix(".")
		if e != "" and not out.has(e):
			out.append(e)
	return out


## allow 为空 → 用 DEFAULT_EXT（**不含 exr**）；非空 → 只认 allow 里的格式
static func is_image(path: String, allow: Array = []) -> bool:
	var ext := path.get_extension().to_lower()
	var set: Array = allow if not allow.is_empty() else DEFAULT_EXT
	return set.has(ext)


## 扫描 root 下的图片。返回数组，每项见 describe()。
## 先一次性收集 .godot/imported 的前缀集合，避免对每张图都遍历一遍（那是 O(n²)）。
static func scan(root := "res://assets", recursive := true, allow: Array = []) -> Array:
	var out: Array = []
	_walk(root, recursive, out, {}, allow)     # 不再预扫目录：判定改为逐文件查 deps ✓
	out.sort_custom(func(a, b): return String(a["path"]) < String(b["path"]))
	return out


static func _walk(dir_path: String, recursive: bool, out: Array, imported: Dictionary, allow: Array = []) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var full := dir_path.path_join(name)
			if d.current_is_dir():
				if recursive:
					_walk(full, recursive, out, imported, allow)
			elif is_image(full, allow):
				out.append(describe(full, imported))
		name = d.get_next()
	d.list_dir_end()


## 读单个图片的信息：{path, size, has_import, mode, mode_name, mipmaps, imported}
static func describe(res_path: String, imported: Dictionary = {}) -> Dictionary:
	var abs := ProjectSettings.globalize_path(res_path)
	var size := 0
	if FileAccess.file_exists(abs):
		var f := FileAccess.open(abs, FileAccess.READ)
		if f != null:
			size = f.get_length()
			f.close()
	var info := {
		"path": res_path,
		"name": res_path.get_file(),
		"size": size,
		"has_import": FileAccess.file_exists(ProjectSettings.globalize_path(res_path + ".import")),
		"mode": -1,
		"mode_name": "无导入设置",
		"mipmaps": false,
		"imported": false,
	}
	if not bool(info["has_import"]):
		return info
	var t := FileAccess.get_file_as_string(res_path + ".import")
	info["mode"] = _int_of(t, "compress/mode", -1)
	info["mode_name"] = MODE_NAMES.get(int(info["mode"]), "未知(%d)" % int(info["mode"]))
	info["mipmaps"] = _bool_of(t, "mipmaps/generate", false)
	info["imported"] = _imported_ok(res_path, t)
	return info


## 收集 .godot/imported 下所有产物的名字前缀（"xxx.png-<hash>.ctex" → "xxx.png-"）
static func _imported_prefixes() -> Dictionary:
	var set := {}
	var d := DirAccess.open("res://.godot/imported")
	if d == null:
		return set
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not n.begins_with("."):
			var cut := n.find("-")
			if cut > 0:
				set[n.substr(0, cut + 1)] = true
		n = d.get_next()
	d.list_dir_end()
	return set


## 「是否已导入」的**权威判据**：
## 读 .import 的 [deps] dest_files，检查那些产物是否真的存在于磁盘上。
##
## 为什么不再扫 res://.godot/imported 目录 ✗：
## 点开头的目录在 Godot 的资源层**不可见**，DirAccess.open 拿到空 → 曾经导致
## **所有图片都被误报成「未导入」**（用户截图里 48/48 全错 ✗）。
static func _imported_ok(res_path: String, import_text: String) -> bool:
	var re := RegEx.new()
	re.compile("dest_files=\\[(.*?)\\]")
	var m := re.search(import_text)
	if m != null:
		var any := false
		for part in m.get_string(1).split(","):
			var f := String(part).strip_edges().trim_prefix("\"").trim_suffix("\"")
			if not f.begins_with("res://"):
				continue
			any = true
			if not FileAccess.file_exists(ProjectSettings.globalize_path(f)):
				return false
		if any:
			return true
	# 兜底：资源系统认它就算已导入
	return ResourceLoader.exists(res_path)


static func _has_artifact(file_name: String) -> bool:
	return _imported_prefixes().has(file_name + "-")


static func _int_of(text: String, key: String, def: int) -> int:
	var re := RegEx.new()
	re.compile("(?m)^%s=(-?\\d+)" % key)
	var m := re.search(text)
	return int(m.get_string(1)) if m != null else def


static func _bool_of(text: String, key: String, def: bool) -> bool:
	var re := RegEx.new()
	re.compile("(?m)^%s=(true|false)" % key)
	var m := re.search(text)
	return (m.get_string(1) == "true") if m != null else def


## 人类可读的大小
static func human_size(bytes: int) -> String:
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%d B" % bytes