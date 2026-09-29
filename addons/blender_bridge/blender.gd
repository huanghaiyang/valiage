@tool
extends RefCounted
## 让 .glb 在 Blender 里打开。
##
## 做法：写一个很小的 Blender Python 脚本（里面调用 bpy.ops.import_scene.gltf），
## 然后 `blender --python <脚本>` 启动 GUI 并导入。为什么不直接 `blender 文件.glb`：
## Blender 只把命令行上的文件当 **.blend** 打开，喂 glb 会报错。

const CFG := "user://blender_bridge.cfg"

## 找 Blender 的候选安装目录（Windows 上最常见的两个）
const FOUNDATION_DIRS := [
	"C:/Program Files/Blender Foundation",
	"C:/Program Files (x86)/Blender Foundation",
]

## 其它常见位置（Steam 版、手动解压版等）
const DIRECT_EXES := [
	"C:/Program Files (x86)/Steam/steamapps/common/Blender/blender.exe",
	"C:/Program Files/Steam/steamapps/common/Blender/blender.exe",
	"C:/Program Files/Blender Foundation/Blender/blender.exe",
	"D:/Program Files/Blender Foundation/Blender/blender.exe",
	"D:/Blender/blender.exe",
]


# ------------------------------------------------------------------ 路径

## 按优先级找 blender.exe：① 保存过的 ② PATH 里的 ③ 常见安装目录（版本号最大的）
static func find_blender() -> String:
	var saved := get_saved_path()
	if not saved.is_empty() and FileAccess.file_exists(saved):
		return saved

	var out: Array = []
	if OS.execute("where", ["blender"], out, true) == 0:
		for raw in out:
			for line in String(raw).split("\n"):
				var p := line.strip_edges()
				if p.to_lower().ends_with(".exe") and FileAccess.file_exists(p):
					return p

	for exe in DIRECT_EXES:
		if FileAccess.file_exists(exe):
			return exe

	var best := ""
	for dir in FOUNDATION_DIRS:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for sub in d.get_directories():
			var exe := "%s/%s/blender.exe" % [dir, sub]
			if FileAccess.file_exists(exe) and exe > best:
				best = exe          # 目录名带版本号，字符串比较刚好挑到最新版
	return best


static func get_saved_path() -> String:
	var c := ConfigFile.new()
	if c.load(CFG) == OK:
		return String(c.get_value("blender", "path", ""))
	return ""


static func save_path(p: String) -> void:
	var c := ConfigFile.new()
	c.load(CFG)
	c.set_value("blender", "path", p.strip_edges())
	c.save(CFG)


# ------------------------------------------------------------------ 脚本与启动

## 准备一次 Blender 会话，返回 { ok, script, work, export_default, blend_default, source, message }
##
## 三条硬性要求（用户提的）：
##   ① Blender 默认场景里的方块/相机/灯要干掉（先读空场景 homefile）
##   ② **原始 glb 全程只读**：实际导入的是它的一个副本，插件绝不写原始文件
##   ③ 只能"导出"或"另存为"：把 glTF 导出 / .blend 另存为的**默认路径**改成新文件名，
##      手滑回车也覆盖不到原始 glb
static func prepare(glb_path: String) -> Dictionary:
	var src := _abs(glb_path)
	if src.is_empty() or not FileAccess.file_exists(src):
		return {"ok": false, "message": "找不到文件：%s" % src}
	var stem := src.get_file().get_basename()

	var dir := ProjectSettings.globalize_path("user://blender_bridge")
	var session := dir.path_join("session")
	DirAccess.make_dir_recursive_absolute(session)
	var work := session.path_join(stem + "_session.glb")

	# 先清掉上一次的会话副本（每个 glb 可能几十 MB，不清会越堆越多）
	_clean_dir(session)

	# 复制一份给 Blender 用：原始文件不会被 Blender 碰到
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		return {"ok": false, "message": "读取失败：%s" % src}
	var wf := FileAccess.open(work, FileAccess.WRITE)
	if wf == null:
		return {"ok": false, "message": "写副本失败：%s" % work}
	wf.store_buffer(bytes)
	wf.close()

	# 导出 / 另存为的默认落点：原始文件旁边，但换个名字
	var out_dir := src.get_base_dir()
	var export_default := out_dir.path_join(stem + "_edited.glb")
	var blend_default := out_dir.path_join(stem + ".blend")

	var lines := PackedStringArray([
		"# 由 Godot 插件 blender_bridge 自动生成，请勿手改",
		"import bpy",
		"",
		"SOURCE = %s   # 原始文件：只作参考，绝不写它" % _py_string(src),
		"WORK = %s     # 实际导入的是这个副本" % _py_string(work),
		"EXPORT_DEFAULT = %s" % _py_string(export_default),
		"BLEND_DEFAULT = %s" % _py_string(blend_default),
		"",
		"# ① 干掉 Blender 默认场景里的方块/相机/灯（use_empty 只清场景，保留用户的偏好与快捷键）",
		"try:",
		"    bpy.ops.wm.read_homefile(use_empty=True)",
		"except Exception:",
		"    for _o in list(bpy.data.objects):",
		"        bpy.data.objects.remove(_o, do_unlink=True)",
		"",
		"# ② 从副本导入",
		"try:",
		"    bpy.ops.import_scene.gltf(filepath=WORK)",
		"except Exception as e:",
		"    print('[blender_bridge] glTF 导入失败：', e)",
		"",
		"# ③ 把导出 / 另存为的默认路径改成新文件，防止手滑覆盖原始 glb",
		"try:",
		"    _p = bpy.ops.export_scene.gltf.get_rna_type().properties",
		"    if 'filepath' in _p:",
		"        _p['filepath'].default = EXPORT_DEFAULT",
		"except Exception as e:",
		"    print('[blender_bridge] 设置导出默认路径跳过：', e)",
		"try:",
		"    _p2 = bpy.ops.wm.save_as_mainfile.get_rna_type().properties",
		"    if 'filepath' in _p2:",
		"        _p2['filepath'].default = BLEND_DEFAULT",
		"except Exception as e:",
		"    print('[blender_bridge] 设置另存为默认路径跳过：', e)",
		"",
		"print('[blender_bridge] 原始文件（只读参考）:', SOURCE)",
		"print('[blender_bridge] 导出请另存为新文件，默认:', EXPORT_DEFAULT)",
		"",
	])
	var script := dir.path_join("import_glb.py")
	var f := FileAccess.open(script, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "message": "写脚本失败：%s" % script}
	f.store_string("\n".join(lines))
	f.close()
	return {
		"ok": true,
		"script": script,
		"work": work,
		"source": src,
		"export_default": export_default,
		"blend_default": blend_default,
	}


## 把路径包成 Python 字符串字面量（路径已由 _abs 统一成正斜杠，所以只需处理引号）
static func _py_string(s: String) -> String:
	return "\"" + s.replace("\"", "\\\"") + "\""


static func _abs(p: String) -> String:
	if p.begins_with("res://") or p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	return p.replace("\\", "/")

## 命令行参数（单独抽出来，测试可以直接验，不用真的启动 Blender）
static func build_args(script_path: String) -> PackedStringArray:
	return PackedStringArray(["--python", script_path])


## 用 Blender 打开一个 glb。返回 { ok, message, exe, script }
static func open_in_blender(glb_path: String) -> Dictionary:
	if glb_path.is_empty():
		return {"ok": false, "message": "没给 glb 路径"}
	var exe := find_blender()
	if exe.is_empty():
		return {"ok": false, "message": "没找到 Blender。请点工具栏的「Blender 设置」指定 blender.exe 路径。"}
	var prep := prepare(glb_path)
	if not bool(prep.get("ok", false)):
		return {"ok": false, "message": String(prep.get("message", "准备失败"))}
	var script := String(prep["script"])
	var pid := OS.create_process(exe, build_args(script), false)
	if pid <= 0:
		return {"ok": false, "message": "启动 Blender 失败：%s" % exe, "exe": exe, "script": script}
	save_path(exe)          # 调起成功就把路径记下来，下次不用再探测
	return {
		"ok": true,
		"message": "已交给 Blender 打开：%s（原始文件只读，导出默认写到 %s）" % [
				glb_path.get_file(), String(prep["export_default"]).get_file()],
		"exe": exe,
		"script": script,
		"work": String(prep["work"]),
		"export_default": String(prep["export_default"]),
	}


## 清空一个目录里的文件（不删子目录）
static func _clean_dir(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(String(f)))