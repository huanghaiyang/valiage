@tool
extends RefCounted
## EXR → PNG 转换核心。
##
## 为什么需要：Godot 的 .import 纹理管线**不认 EXR**（编辑器里显示为普通文件、拖不进材质），
## 但引擎的 Image **能解码 EXR**（load_exr_from_buffer）。所以用引擎自己转一次成 PNG 即可，
## 不需要装 ffmpeg / ImageMagick / Pillow（实测本机都没装）。
##
## 另一个常见翻车点：法线贴图被当颜色（sRGB）处理。转 PNG 后请在材质里挂
## **Normal Map** 槽，让引擎按线性采样；Blender 的贴图是 OpenGL(+Y)，
## 若拿到 DirectX(-Y) 的贴图，用 flip_green 翻一下绿通道即可。

## 转单个文件。返回 {ok, message, src, dst, size}
static func convert_file(src: String, dst: String, flip_green := false, allow_blender := true) -> Dictionary:
	var out := {"ok": false, "message": "", "src": src, "dst": dst, "size": Vector2i.ZERO}
	if not FileAccess.file_exists(src):
		out["message"] = "找不到文件：%s" % src
		return out
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		out["message"] = "文件读取为空：%s" % src
		return out
	# 先读 EXR 头判断压缩类型。引擎的 tinyexr 只支持 NONE/RLE/ZIP/ZIPS，
	# 遇到 DWAA/DWAB/PIZ/B44 会直接抛 ERROR（"Unknown compression type"）——
	# 提前判断就能**根本不去踩它**：既不刷吓人的错误日志，也省一次无用的解码。
	var comp := exr_compression(src)
	if allow_blender and comp >= 0 and not engine_supports(comp):
		var via0 := convert_via_blender(src, dst, flip_green)
		if bool(via0.get("ok", false)):
			via0["message"] = "OK（%s 压缩引擎不支持，已用 Blender）" % compression_name(comp)
			return via0
	var img := Image.new()
	# 显式用 EXR 解码器：load_from_file 按扩展名分派，对 exr 不保证支持
	var err := img.load_exr_from_buffer(bytes)
	if err != OK:
		var hint := exr_hint(src)
		# 引擎只支持 NONE/RLE/ZIP/ZIPS；DWAA/DWAB/PIZ/B44 这类解不了 ——
		# 交给 Blender 无头模式转（本机实测 Blender 5.2 可行，4K 图约 6 秒）
		if allow_blender:
			var via := convert_via_blender(src, dst, flip_green)
			if bool(via.get("ok", false)):
				return via
			hint += " ｜ Blender 兜底也未成功：" + str(via.get("message", ""))
		out["message"] = "解码 EXR 失败（错误码 %d）｜ %s" % [err, hint]
		return out
	img.convert(Image.FORMAT_RGBA8)          # EXR 常是 32 位浮点；PNG 是 8 位
	if flip_green:
		flip_green_channel(img)
	var e2 := img.save_png(dst)
	if e2 != OK:
		out["message"] = "写 PNG 失败（错误码 %d）" % e2
		return out
	out["ok"] = true
	out["message"] = "OK"
	out["size"] = img.get_size()
	return out


## 翻转绿通道（DirectX -Y ↔ OpenGL +Y）。
## 走字节数组批量改，比 get_pixel/set_pixel 快一到两个数量级。
static func flip_green_channel(img: Image) -> void:
	var data := img.get_data()
	var n := data.size()
	var i := 1                                  # FORMAT_RGBA8：R=0,G=1,B=2,A=3
	while i < n:
		data[i] = 255 - data[i]
		i += 4
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


## 批量：扫 dir 下的 *.exr（可递归），转成同名 .png。
## opts: {recursive, flip_green, delete_source}
static func convert_dir(dir: String, opts: Dictionary = {}, progress: Dictionary = {}) -> Dictionary:
	var recursive := bool(opts.get("recursive", true))
	var flip := bool(opts.get("flip_green", false))
	var del := bool(opts.get("delete_source", false))
	# 输出位置："" = 转成 PNG 放在原 EXR 旁边；否则放进指定目录
	var out_dir := String(opts.get("out_dir", ""))
	# 回收：成功后把原 EXR 移进 .runtime 回收站（不是删除，可还原）
	var to_recycle := bool(opts.get("recycle_source", false))
	# 回收目标可配置（测试用临时箱，免得污染真实回收站）
	var recycle_dir := String(opts.get("recycle_dir", RECYCLE_DIR))
	var files := find_exr(dir, recursive)
	var lines := PackedStringArray()
	var created: Array = []
	var ok := 0
	var failed: Array = []
	# progress 是"引用类型"的字典：后台线程往里写，主线程读来显示进度（仅供显示，不做同步用途）
	if not progress.is_empty():
		progress["total"] = files.size()
		progress["done"] = 0
	for f in files:
		if not progress.is_empty():
			progress["current"] = f.get_file()
		var dst := "%s.png" % f.get_basename()
		if out_dir != "":
			var abs_out := ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir
			DirAccess.make_dir_recursive_absolute(abs_out)
			dst = abs_out.path_join("%s.png" % f.get_file().get_basename())
		var r := convert_file(f, dst, flip)
		if bool(r.get("ok", false)):
			ok += 1
			created.append(dst)
			lines.append("✓ %s" % f.get_file())
			if to_recycle:
				var rc := recycle(f, recycle_dir)
				lines.append((("  ↳ 已回收" if bool(rc.get("ok", false)) else "  ↳ 回收失败") + "：%s") % f.get_file())
			elif del:
				DirAccess.remove_absolute(f)
		else:
			failed.append(f)
			lines.append("✗ %s ｜ %s" % [f.get_file(), str(r.get("message", ""))])
		if not progress.is_empty():
			progress["done"] = ok + failed.size()
	return {"total": files.size(), "ok": ok, "failed": failed, "lines": lines, "created": created}


## 找出目录下的所有 .exr（绝对路径）
static func find_exr(dir: String, recursive := true) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if String(f).to_lower().ends_with(".exr"):
			out.append(dir.path_join(String(f)))
	if recursive:
		for d in DirAccess.get_directories_at(dir):
			out.append_array(find_exr(dir.path_join(String(d)), true))
	return out

## 读 EXR 头部，尽量判断出"为什么解不了"。
## 引擎用的 tinyexr **只支持 NONE / RLE / ZIP / ZIPS** 压缩；
## DWAA / DWAB / PIZ / B44 都不支持 —— 而纹理站下载的 4K EXR 常常正是这些
## （Poly Haven 的 exr 就是 oiiotool --compression dwaa 生成的，实测解不了）。
## 压缩类型在 EXR 头里是 4 字节枚举而不是文本，所以这里同时看头部文本里的
## 制作历史（很多资产的 ImageHistory 里写着用了什么压缩）。
static func exr_hint(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "读不到文件"
	var head := f.get_buffer(8192)
	f.close()
	var text := head.get_string_from_ascii().to_lower()
	for name in ["dwab", "dwaa", "piz", "b44a", "b44"]:
		if text.contains(name):
			return "这个 EXR 是 %s 压缩，引擎不支持（只支持 NONE/RLE/ZIP/ZIPS）—— 用 Blender 打开后另存为 PNG，或另存为 ZIP 压缩的 EXR 再转" % name.to_upper()
	return "引擎解码失败。常见原因：EXR 用了 DWAA/DWAB/PIZ 等不支持的压缩，或分块 / 多部件 EXR —— 用 Blender 另存为 PNG 最省事"

# ------------------------------------------------------------------ Blender 兜底

## 引擎解不了的 EXR（DWAA/DWAB/PIZ/B44 等压缩）交给 Blender 转。
## 实测（Blender 5.2 LTS）三个必须注意的点：
##   ① 解压/读缓冲：必须先访问一次 img.pixels，否则 save() 报"图像未包含任何图像数据"
##   ② 位深：img.save() 无视场景设置，会存成 16 位（4K 法线图 67MB）；
##      要用 img.save_render(dst, scene=sc) + 场景 color_depth='8' 才得到 8 位（约 32MB）
##   ③ 色彩：图像设 Non-Color、场景 view_transform 设 Standard，否则法线会被色彩管理改掉
const PY_LINES := [
	"import bpy, sys, os",
	"import numpy as np",
	"argv = sys.argv[sys.argv.index('--') + 1:]",
	"src, dst, flip = argv[0], argv[1], (len(argv) > 2 and argv[2] == '1')",
	"sc = bpy.context.scene",
	"sc.render.image_settings.file_format = 'PNG'",
	"sc.render.image_settings.color_mode = 'RGB'",
	"sc.render.image_settings.color_depth = '8'",
	"sc.view_settings.view_transform = 'Standard'",
	"sc.view_settings.look = 'None'",
	"img = bpy.data.images.load(src)",
	"img.colorspace_settings.name = 'Non-Color'",
	"w, h = img.size",
	"px = np.empty(w * h * 4, dtype=np.float32)",
	"img.pixels.foreach_get(px)",
	"if flip:",
	"    px[1::4] = 1.0 - px[1::4]",
	"    img.pixels.foreach_set(px)",
	"_ = img.pixels[0]",
	"img.save_render(dst, scene=sc)",
	"print('DONE %s %sx%s' % (dst, w, h))",
]


## 找 blender.exe：复用 Blender 桥插件已有的探测（含用户保存过的路径）
static func blender_path() -> String:
	var s := load("res://addons/blender_bridge/blender.gd")
	if s == null:
		return ""
	var p = s.call("find_blender")
	return String(p) if p != null else ""


static func write_py() -> String:
	var path := ProjectSettings.globalize_path("user://exr_tools_blender.py")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(PackedStringArray(PY_LINES)) + "\n")
		f.close()
	return path


## 用 Blender 无头模式转一个文件。注意：这是**同步**调用，4K 图约 6 秒（期间编辑器会卡住）
static func convert_via_blender(src: String, dst: String, flip := false) -> Dictionary:
	var exe := blender_path()
	if exe.is_empty():
		return {"ok": false, "message": "没找到 blender.exe"}
	if not FileAccess.file_exists(exe):
		return {"ok": false, "message": "blender.exe 路径不存在：%s" % exe}
	var py := write_py()
	var out: Array = []
	var args := ["-b", "--python", py, "--", src, dst, "1" if flip else "0"]
	var code := OS.execute(exe, args, out, true)
	if code != 0 or not FileAccess.file_exists(dst):
		var log := " ".join(PackedStringArray(out))
		if log.length() > 300:
			log = log.right(300)
		return {"ok": false, "message": "Blender 退出码 %d：%s" % [code, log]}
	return {"ok": true, "message": "OK（经由 Blender）", "src": src, "dst": dst,
			"size": Vector2i(0, 0)}

# ------------------------------------------------------------------ EXR 压缩类型

## OpenEXR 的压缩枚举：0 NONE / 1 RLE / 2 ZIPS / 3 ZIP / 4 PIZ /
## 5 PXR24 / 6 B44 / 7 B44A / 8 DWAA / 9 DWAB
const EXR_NAMES := ["NONE", "RLE", "ZIPS", "ZIP", "PIZ", "PXR24", "B44", "B44A", "DWAA", "DWAB"]


## 引擎（tinyexr）实际只支持这四种
static func engine_supports(code: int) -> bool:
	return code == 0 or code == 1 or code == 2 or code == 3


static func compression_name(code: int) -> String:
	if code >= 0 and code < EXR_NAMES.size():
		return EXR_NAMES[code]
	return "未知(%d)" % code


## 解析 EXR 头里的压缩类型（-1 = 没解析出来）。
## 头里格式是：name\0 type\0 <int32 长度> <数据>；压缩属性的值就是 1 字节枚举。
static func exr_compression(src: String) -> int:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return -1
	var head := f.get_buffer(8192)
	f.close()
	# 注意：PackedByteArray.find() 只能找单个字节（int），不能找子数组 ——
	# 所以先转成 ASCII 字符串来找位置（头部是纯 ASCII，字符索引与字节索引一一对应）。
	# 关键：不能只搜 "compression" —— Poly Haven 这类资产的 ImageHistory 里就写着
	# "oiiotool … --compression dwaa"，会把第一处匹配抢走。属性在头部是
	# name\0type\0 的形式，所以按字节搜 "compression\0compression\0" 才唯一可靠。
	# （不要用 String.chr(0) 拼 NUL —— 实测它不可靠；直接拼字节最稳。）
	var pat := PackedByteArray()
	pat.append_array("compression".to_ascii_buffer())
	pat.append(0)
	pat.append_array("compression".to_ascii_buffer())
	pat.append(0)
	var at := -1
	for i in range(0, head.size() - pat.size()):
		if head.slice(i, i + pat.size()) == pat:
			at = i
			break
	if at < 0:
		return -1
	# 布局实测：模式串之后是 4 字节长度(=1)，紧接着 1 字节压缩枚举
	var val_at := at + pat.size() + 4
	if val_at >= head.size():
		return -1
	return int(head[val_at])

# ------------------------------------------------------------------ 回收站（不删除）

## 回收站放在 .runtime 下 —— 点开头的目录 Godot 会**完全忽略**，
## 所以放进去的 EXR 不会再被导入/生成缩略图（这也顺带避免它拖慢启动）。
const RECYCLE_DIR := "res://.runtime/exr_recycle"
const RECYCLE_INDEX := RECYCLE_DIR + "/index.json"


static func recycle_dir_abs(custom := "") -> String:
	var rel := custom if custom != "" else RECYCLE_DIR
	return ProjectSettings.globalize_path(rel)


static func _index_path(dir_abs: String) -> String:
	return dir_abs.path_join("index.json")


static func _read_index(dir_abs: String) -> Array:
	var p := _index_path(dir_abs)
	if not FileAccess.file_exists(p):
		return []
	var v = JSON.parse_string(FileAccess.get_file_as_string(p))
	return v if v is Array else []


static func _write_index(dir_abs: String, arr: Array) -> void:
	var f := FileAccess.open(_index_path(dir_abs), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(arr, "  "))
		f.flush()
		f.close()


## 把一个 EXR **移进**回收站（不是删除 ✓），并登记原始位置以便还原。
static func recycle(src_abs: String, dir_rel := RECYCLE_DIR) -> Dictionary:
	if not FileAccess.file_exists(src_abs):
		return {"ok": false, "message": "文件不存在：%s" % src_abs}
	var dir := recycle_dir_abs(dir_rel)
	DirAccess.make_dir_recursive_absolute(dir)
	var base := src_abs.get_file()
	var dst := dir.path_join(base)
	if FileAccess.file_exists(dst):                       # 重名 → 加时间戳
		var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
		dst = dir.path_join("%s_%s" % [stamp, base])
	var err := _move_with_sidecars(src_abs, dst)
	if err != OK:
		return {"ok": false, "message": "移动到回收站失败（错误码 %d）" % err}
	var fsz := 0
	if FileAccess.file_exists(dst):
		var f := FileAccess.open(dst, FileAccess.READ)
		if f != null:
			fsz = f.get_length()
			f.close()
	var entry := {
		"name": dst.get_file(),
		"from": src_abs,
		"to": dst,
		"size": fsz,
		"ts": Time.get_datetime_string_from_system(),
	}
	var arr := _read_index(dir)
	arr.append(entry)
	_write_index(dir, arr)
	return {"ok": true, "message": "已移入回收站（可还原）", "entry": entry}


## 列出回收站里的 EXR（自动跳过已被手动删掉的）
static func list_recycled(dir_rel := RECYCLE_DIR) -> Array:
	var dir := recycle_dir_abs(dir_rel)
	var out: Array = []
	for e in _read_index(dir):
		if e is Dictionary and FileAccess.file_exists(String(e.get("to", ""))):
			out.append(e)
	out.sort_custom(func(a, b): return String(a.get("ts", "")) > String(b.get("ts", "")))
	return out


## 还原到原始位置
static func restore(entry: Dictionary, dir_rel := RECYCLE_DIR) -> Dictionary:
	var src := String(entry.get("to", ""))
	var dst := String(entry.get("from", ""))
	if not FileAccess.file_exists(src):
		return {"ok": false, "message": "回收站里已经没有这个文件了"}
	if dst == "":
		return {"ok": false, "message": "记录里没有原始位置，无法还原"}
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	if FileAccess.file_exists(dst):
		return {"ok": false, "message": "原位置已有同名文件：%s" % dst}
	var err := _move_with_sidecars(src, dst)
	if err != OK:
		return {"ok": false, "message": "还原失败（错误码 %d）" % err}
	_drop_entry(dir_rel, src)
	return {"ok": true, "message": "已还原到 %s" % dst, "to": dst}


## 从回收站彻底删除（这一步才真的删）
static func purge(entry: Dictionary, dir_rel := RECYCLE_DIR) -> Dictionary:
	var src := String(entry.get("to", ""))
	if FileAccess.file_exists(src):
		var err := DirAccess.remove_absolute(src)
		if err != OK:
			return {"ok": false, "message": "删除失败（错误码 %d）" % err}
	_drop_entry(dir_rel, src)
	return {"ok": true, "message": "已彻底删除"}


## 移动文件，**连同它的伴随文件**（.import / .uid）一起搬。
## 为什么必须这样：只搬走 .exr 会把 .import 留成"孤儿"，
## 文件系统 dock 随后就报 "!FileAccess::exists(p_path)"（用户实测报过这个错）。
static func _move_with_sidecars(src_abs: String, dst_abs: String) -> int:
	var first := OK
	for suffix: String in ["", ".import", ".uid"]:
		var s: String = src_abs + suffix
		if not FileAccess.file_exists(s):
			continue
		var d: String = dst_abs + suffix
		var err := DirAccess.rename_absolute(s, d)
		if err != OK:                       # 跨卷等异常 → 复制再删
			err = DirAccess.copy_absolute(s, d)
			if err == OK:
				err = DirAccess.remove_absolute(s)
		if err != OK and first == OK:
			first = err
	return first


static func _drop_entry(dir_rel: String, to_abs: String) -> void:
	var dir := recycle_dir_abs(dir_rel)
	var arr := _read_index(dir)
	var kept: Array = []
	for e in arr:
		if e is Dictionary and String(e.get("to", "")) != to_abs:
			kept.append(e)
	_write_index(dir, kept)


## 回收站占用（合计字节）
static func recycle_usage(dir_rel := RECYCLE_DIR) -> int:
	var total := 0
	for e in list_recycled(dir_rel):
		total += int((e as Dictionary).get("size", 0))
	return total


## 人类可读的大小（管理器面板要用）
static func human_size(bytes: int) -> String:
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%d B" % bytes
