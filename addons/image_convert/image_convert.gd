@tool
extends RefCounted
## 图片格式 / 分辨率转换核心（纯逻辑，不碰编辑器 API，便于单测）。
##
## 设计要点：
##   · 分辨率后缀命名与画质分级系统**完全一致**（_4k / _2k / _1k，也认 _2048）
##   · 「移除 alpha」走 Image.convert(FORMAT_RGB8) —— 这正是 Terrain3D 纹理数组
##     要求"格式一致"时的关键（PNG 默认 RGBA8，而 JPG 是 RGB8，混用会报格式不一致）

const FMT_KEEP := 0
const FMT_PNG := 1
const FMT_JPG := 2
const FMT_WEBP := 3

const FMT_NAMES := {FMT_KEEP: "保持原格式", FMT_PNG: "PNG", FMT_JPG: "JPG", FMT_WEBP: "WebP"}

const IMAGE_EXT := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]


static func is_image(path: String) -> bool:
	return IMAGE_EXT.has(path.get_extension().to_lower())


static func format_name(f: int) -> String:
	return String(FMT_NAMES.get(f, "未知"))


## 分辨率后缀换算（与 QualityTiers 同一套规则）：
## "…_diff_4k.jpg" + "2k" → "…_diff_2k.jpg"
static func swap_res_suffix(path: String, suffix: String) -> String:
	if path == "" or suffix == "":
		return path
	var base := path.get_basename()
	var ext := path.get_extension()
	var re := RegEx.new()
	re.compile("(?i)^(.*?)[_-]?(\\d+k|1024|2048|4096|8192)$")
	var m := re.search(base)
	if m != null:
		var head := m.get_string(1)
		if head == "":
			head = base
		return "%s_%s.%s" % [head, suffix, ext]
	return "%s_%s.%s" % [base, suffix, ext]


static func _ext_for(fmt: int, src: String) -> String:
	match fmt:
		FMT_PNG:
			return "png"
		FMT_JPG:
			return "jpg"
		FMT_WEBP:
			return "webp"
		_:
			return src.get_extension()


## 按选项算出目标路径。opts: {out_dir, fmt, size_suffix, add_suffix}
static func target_path(src: String, opts: Dictionary) -> String:
	var out_dir := String(opts.get("out_dir", ""))
	var fmt := int(opts.get("fmt", FMT_KEEP))
	var suffix := String(opts.get("size_suffix", ""))
	var dir := out_dir if out_dir != "" else src.get_base_dir()
	var stem := src.get_file().get_basename()
	if suffix != "":
		stem = swap_res_suffix(stem, suffix)      # 主名里若已有 _4k 会被替换掉
	var ext := _ext_for(fmt, src)
	if ext == "":
		ext = "png"
	return dir.path_join("%s.%s" % [stem, ext])


## 「一键生成多分辨率套图」的计划：把 _4k 源换成 _2k / _1k …
## 返回 [{src, dst, suffix}]
static func plan_variants(src: String, sizes: Array = ["2k", "1k"], fmt := FMT_KEEP) -> Array:
	var out: Array = []
	for s in sizes:
		var suffix := String(s)
		# 必须传**完整路径**：传无扩展名的主名会让 get_extension() 为空，结果变成 "..._2k." ✗
		var stem := swap_res_suffix(src, suffix).get_basename().get_file()
		var ext := _ext_for(fmt, src)
		out.append({
			"src": src,
			"dst": src.get_base_dir().path_join("%s.%s" % [stem, ext]),
			"suffix": suffix,
		})
	return out


static func human_size(bytes: int) -> String:
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%d B" % bytes


## 转换单个文件。opts: {fmt, max_size, size_suffix, strip_alpha, jpg_quality}
static func convert_file(src_abs: String, dst_abs: String, opts: Dictionary = {}) -> Dictionary:
	var out := {"ok": false, "message": "", "src": src_abs, "dst": dst_abs, "size": Vector2i.ZERO}
	if not FileAccess.file_exists(src_abs):
		out["message"] = "文件不存在：%s" % src_abs
		return out
	var img := Image.load_from_file(src_abs)
	if img == null or img.is_empty():
		out["message"] = "读不出图像（格式不支持？）：%s" % src_abs.get_file()
		return out
	# 分辨率
	var max_size := int(opts.get("max_size", 0))
	if max_size > 0 and (img.get_width() > max_size or img.get_height() > max_size):
		var scale := float(max_size) / float(maxi(img.get_width(), img.get_height()))
		var nw := maxi(1, int(round(img.get_width() * scale)))
		var nh := maxi(1, int(round(img.get_height() * scale)))
		img.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
	# 移除 alpha（转成 RGB8）—— 这一步决定"格式是否一致"
	if bool(opts.get("strip_alpha", false)):
		img.convert(Image.FORMAT_RGB8)
	var fmt := int(opts.get("fmt", FMT_KEEP))
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var err := OK
	match fmt:
		FMT_PNG:
			if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			err = img.save_png(dst_abs)
		FMT_JPG:
			if img.get_format() != Image.FORMAT_RGB8:
				img.convert(Image.FORMAT_RGB8)     # JPG 不支持 alpha
			err = img.save_jpg(dst_abs, clampi(int(opts.get("jpg_quality", 92)), 1, 100) / 100.0)
		FMT_WEBP:
			err = img.save_webp(dst_abs, false, clampi(int(opts.get("jpg_quality", 92)), 1, 100) / 100.0)
		_:
			# 保持原格式：按**目标扩展名**分派（否则会把 PNG 数据写进 .jpg ✗）
			match dst_abs.get_extension().to_lower():
				"jpg", "jpeg":
					if img.get_format() != Image.FORMAT_RGB8:
						img.convert(Image.FORMAT_RGB8)
					err = img.save_jpg(dst_abs, clampi(int(opts.get("jpg_quality", 92)), 1, 100) / 100.0)
				"webp":
					err = img.save_webp(dst_abs, false, clampi(int(opts.get("jpg_quality", 92)), 1, 100) / 100.0)
				_:
					err = img.save_png(dst_abs)
	if err != OK:
		out["message"] = "写文件失败（错误码 %d）" % err
		return out
	out["ok"] = true
	out["message"] = "OK"
	out["size"] = img.get_size()
	return out


## 批量：对 dir 下的图片逐个转换（可递归）
static func convert_dir(dir: String, opts: Dictionary = {}, progress: Dictionary = {}) -> Dictionary:
	var recursive := bool(opts.get("recursive", false))
	var files := find_images(dir, recursive)
	var lines := PackedStringArray()
	var created: Array = []
	var ok := 0
	var failed: Array = []
	if not progress.is_empty():
		progress["total"] = files.size()
		progress["done"] = 0
	for f in files:
		if not progress.is_empty():
			progress["current"] = String(f).get_file()
		var dst := target_path(String(f), opts)
		var r := convert_file(String(f), dst, opts)
		if bool(r.get("ok", false)):
			ok += 1
			created.append(dst)
			lines.append("✓ %s → %s" % [String(f).get_file(), dst.get_file()])
		else:
			failed.append(f)
			lines.append("✗ %s ｜ %s" % [String(f).get_file(), str(r.get("message", ""))])
		if not progress.is_empty():
			progress["done"] = ok + failed.size()
	return {"total": files.size(), "ok": ok, "failed": failed, "lines": lines, "created": created}


static func find_images(dir: String, recursive := false) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if is_image(String(f)):
			out.append(dir.path_join(String(f)))
	if recursive:
		for d in DirAccess.get_directories_at(dir):
			out.append_array(find_images(dir.path_join(String(d)), true))
	return out