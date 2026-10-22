@tool
extends SceneTree
## RES 查看器 · 解析核心无头自检
## 用法：godot --headless --path <工程> --script res://addons/res_inspector/tests/format_test.gd
##
## 覆盖：二进制头部（类型/格式版本/flags/uid/保留区）、字符串表、外部依赖、内部子资源、
##       文本 .tres、压缩 RSCC、缺失文件降级、属性树/子项展开、报告生成、全工程扫描。
##
## 夹具由 tests/fixtures.gd 现造（产物在 __probe__/，已 gitignore），不依赖仓库里的大样本；
## 如果工程里存在 `.runtime/inline_test/A.res`（6.3 MB）会额外跑一遍大文件断言。

const Fmt := preload("res://addons/res_inspector/res_format.gd")
const Fixtures := preload("res://addons/res_inspector/tests/fixtures.gd")

var _fail := 0
var _pass := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ %s" % msg)


func _section(title: String) -> void:
	print("\n── %s ──" % title)


func _initialize() -> void:
	print("===== RES 查看器 · 解析核心自检 =====")
	var fx: Dictionary = Fixtures.ensure()

	# ---------- 1. 二进制：Gradient ----------
	_section("二进制 gradient.res")
	var g: Dictionary = Fmt.inspect(fx["gradient"], true)
	_check(bool(g["ok"]), "ok 应为 true（err=%s）" % str(g["error"]))
	_check(str(g["format"]) == "binary", "format 应为 binary")
	var gb: Dictionary = g["binary"]
	_check(str(gb["type"]) == "Gradient", "类型应为 Gradient，实际 %s" % str(gb["type"]))
	var ver := str(gb["format_version"])
	_check(ver.count(".") == 2, "格式版本应形如 4.7.6，实际 %s" % ver)
	_check(not bool(gb["big_endian"]), "应为小端")
	_check(int(gb["flags_guess"]) == 3, "flags 应为 3（4.7.2 实测），实际 %d" % int(gb["flags_guess"]))
	_check(str(gb["uid"]) == "无", "uid 应为无，实际 %s" % str(gb["uid"]))
	var gs: PackedStringArray = gb["strings"]
	_check(gs.size() == 7, "字符串表应 7 项，实际 %d" % gs.size())
	_check(gs.has("offsets"), "字符串表应含 offsets")
	var gi: Array = gb["internal"]
	_check(gi.size() == 1, "内部子资源应 1 项，实际 %d" % gi.size())
	if gi.size() > 0:
		_check(int(gi[0]["offset"]) == int(gb["data_offset"]), "内部表首项偏移应等于数据起点")
	_check((gb["external"] as Array).is_empty(), "外部依赖应 0 项")
	_check(str(g["resource_class"]) == "Gradient", "载入类应为 Gradient，实际 %s" % str(g["resource_class"]))
	_check(g["resource"] != null, "资源应载入成功")
	_check(int(gb["header_unknown_len"]) == 40, "头部保留区应 40 字节（4.7.2 实测），实际 %d" % int(gb["header_unknown_len"]))
	_check(str(g["confidence"]) == "exact", "保留区吻合时置信度应为 exact")

	# ---------- 2. 二进制：ArrayMesh ----------
	_section("二进制 mesh.res")
	var m: Dictionary = Fmt.inspect(fx["mesh"], true)
	var mb: Dictionary = m["binary"]
	_check(str(mb["type"]) == "ArrayMesh", "类型应为 ArrayMesh")
	_check((mb["strings"] as PackedStringArray).has("_surfaces"), "字符串表应含 _surfaces")
	var mesh: Mesh = m["resource"] as Mesh
	_check(mesh != null, "应载入为 Mesh（%s）" % str(m["load_error"]))
	if mesh != null:
		_check(mesh.get_surface_count() == 1, "表面数应 1，实际 %d" % mesh.get_surface_count())
		var arrays: Array = mesh.surface_get_arrays(0)
		_check(arrays.size() > 0, "surface_get_arrays 应非空")
		if arrays.size() > 0:
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			_check(verts.size() == 3, "顶点数应 3，实际 %d" % verts.size())

	# ---------- 3. 多内部资源 ----------
	_section("二进制 grad_texture.res（含 2 个内部资源）")
	var gt: Dictionary = Fmt.inspect(fx["grad_texture"], false)
	var gtb: Dictionary = gt["binary"]
	_check(int((gtb["internal"] as Array).size()) == 2, "内部子资源应 2 项，实际 %d" % int((gtb["internal"] as Array).size()))
	_check(gt["resource"] == null, "load_resource=false 时不应载入")
	_check(str(gt["load_error"]) != "", "跳过载入时应有说明")
	var gt_loaded: Dictionary = Fmt.inspect(fx["grad_texture"], true)
	_check(gt_loaded["resource"] is GradientTexture2D, "载入后应为 GradientTexture2D")

	# ---------- 4. 大文件（可选，.runtime 不入库） ----------
	_section("大样本（可选）")
	var big := Fixtures.big_sample()
	if big == "":
		print("    （跳过：工程里没有 .runtime 大样本）")
	else:
		var t0 := Time.get_ticks_msec()
		var a: Dictionary = Fmt.inspect(big, true)
		var cost := Time.get_ticks_msec() - t0
		var ab: Dictionary = a["binary"]
		_check(bool(a["ok"]), "%s ok 应为 true（err=%s）" % [big.get_file(), str(a["error"])])
		_check(str(ab["type"]) == "ArrayMesh", "大样本类型应为 ArrayMesh，实际 %s" % str(ab["type"]))
		var aints: Array = ab["internal"]
		_check(aints.size() >= 1, "内部表至少 1 项")
		if aints.size() > 0:
			_check(int(aints[0]["offset"]) == int(ab["data_offset"]), "内部表首项偏移应等于数据起点")
		var sl: PackedByteArray = Fmt.read_slice(big, 0, 4)
		_check(sl.size() == 4 and sl.get_string_from_ascii() == "RSRC", "read_slice 应读到 RSRC 魔数")
		var size := int(a["size"])
		var tail := Fmt.read_slice(big, size - 100, 8192)
		_check(tail.size() == 100, "尾页切片应被裁剪到 100 字节，实际 %d" % tail.size())
		_check(a["resource"] is Mesh, "大样本应载入为 Mesh（%s）" % str(a["load_error"]))
		print("    %s：%s，%d ms，外部依赖 %d 项，字符串表 %d 项" % [
			big.get_file(), Fmt.human_size(size), cost,
			(ab["external"] as Array).size(), (ab["strings"] as PackedStringArray).size()])
		if big.contains("inline_test"):
			_check(size > 6000000, "A.res 应 > 6 MB，实际 %d" % size)
			_check((ab["external"] as Array).size() == 3, "A.res 外部依赖应 3 项，实际 %d" % (ab["external"] as Array).size())
			_check((ab["strings"] as PackedStringArray).size() == 132, "A.res 字符串表应 132 项，实际 %d" % (ab["strings"] as PackedStringArray).size())
		_check(cost < 4000, "大样本解析耗时 %d ms（应 < 4000）" % cost)

	# ---------- 5. 文本 .tres ----------
	_section("文本 sample.tres")
	var t: Dictionary = Fmt.inspect(fx["text"], true)
	_check(str(t["format"]) == "text", "format 应为 text，实际 %s" % str(t["format"]))
	var tt: Dictionary = t["text"]
	_check(str(tt["header_tag"]) == "gd_resource", "头标签应为 gd_resource")
	_check(str(tt["type"]) == "Resource", "类型应为 Resource，实际 %s" % str(tt["type"]))
	_check(int(tt["format"]) == 3, "format 应为 3，实际 %d" % int(tt["format"]))
	_check((tt["external"] as Array).size() == 1, "外部依赖应 1 项")
	if (tt["external"] as Array).size() == 1:
		var e: Dictionary = (tt["external"] as Array)[0]
		_check(str(e["path"]) == "res://icon.svg", "外部依赖路径应为 res://icon.svg，实际 %s" % str(e["path"]))
		_check(str(e["id"]) == "1_tex", "外部依赖 id 应为 1_tex，实际 %s" % str(e["id"]))
	_check((tt["sub_resources"] as Array).size() == 1, "子资源应 1 项，实际 %d" % (tt["sub_resources"] as Array).size())
	if (tt["sub_resources"] as Array).size() == 1:
		var s: Dictionary = (tt["sub_resources"] as Array)[0]
		_check(str(s["id"]) == "Gradient_main", "子资源 id 应为 Gradient_main，实际 %s" % str(s["id"]))
		_check(str(s["type"]) == "Gradient", "子资源类型应为 Gradient，实际 %s" % str(s["type"]))
		_check(int(s["properties"]) == 2, "子资源属性应 2 项，实际 %d" % int(s["properties"]))
	_check(int(tt["root_properties"]) >= 2, "根属性应 >= 2，实际 %d" % int(tt["root_properties"]))
	_check(int(tt["line_count"]) > 5, "行数应 > 5，实际 %d" % int(tt["line_count"]))
	_check(t["resource"] != null, "文本资源应能载入（%s）" % str(t["load_error"]))

	# ---------- 6. 压缩 RSCC ----------
	_section("压缩 RSCC（.godot/imported/*.scn）")
	var scn_path := _first_file(ProjectSettings.globalize_path("res://.godot/imported"), ".scn")
	if scn_path != "":
		var r: Dictionary = Fmt.inspect(scn_path, false)
		_check(str(r["format"]) == "binary", "RSCC 也应归为 binary")
		_check(not bool(r["ok"]), "RSCC 结构解析应为不支持")
		_check(str(r["error"]).contains("RSCC"), "应提示 RSCC：%s" % str(r["error"]))
		print("    %s → %s" % [scn_path.get_file(), r["error"]])
	else:
		print("    （跳过：没有 .scn 样本）")

	# ---------- 7. 降级：不存在 / 垃圾文件 ----------
	_section("异常输入降级")
	var miss: Dictionary = Fmt.inspect(fx["missing"], false)
	_check(not bool(miss["ok"]), "不存在的文件 ok 应为 false")
	_check(str(miss["error"]).contains("不存在"), "应提示文件不存在")
	var junk: Dictionary = Fmt.inspect(fx["junk"], false)
	_check(not bool(junk["ok"]), "垃圾文件 ok 应为 false")
	_check(str(junk["format"]) == "unknown", "垃圾文件 format 应为 unknown，实际 %s" % str(junk["format"]))
	print("    垃圾文件 → %s" % str(junk["error"]))

	# ---------- 8. 属性树 / 子项展开 ----------
	_section("属性树与懒展开")
	if mesh != null:
		var props: Array = Fmt.property_entries(mesh)
		_check(props.size() > 0, "属性条目应非空")
		var names: PackedStringArray = []
		for p in props:
			names.append(str(p["name"]))
		_check(names.has("resource_name"), "应含 resource_name：%s" % str(names.slice(0, 8)))
		var filtered: Array = Fmt.property_entries(mesh, "surface")
		_check(filtered.size() > 0, "按 surface 过滤应有结果")
		var verts2 := PackedVector3Array([Vector3.ZERO, Vector3.ONE])
		var kids: Array = Fmt.child_entries(verts2)
		_check(kids.size() == 2, "PackedVector3Array 展开应 2 项，实际 %d" % kids.size())
		_check(str(kids[0]["name"]) == "[0]", "子项名应为 [0]")
		var dict_kids: Array = Fmt.child_entries({"a": 1, "b": "x"})
		_check(dict_kids.size() == 2, "字典展开应 2 项")
		_check(Fmt.type_label(TYPE_VECTOR3) == "Vector3", "type_label(Vector3)")
		_check(Fmt.type_label(TYPE_PACKED_STRING_ARRAY) == "PackedStringArray", "type_label(PackedStringArray)")
		_check(Fmt.human_size(6303972) == "6.0 MB", "human_size：%s" % Fmt.human_size(6303972))
		_check(Fmt.human_size(512) == "512 B", "human_size(512)：%s" % Fmt.human_size(512))
		_check(Fmt.value_text(Color.RED).begins_with("#"), "Color 摘要应为 #rrggbb：%s" % Fmt.value_text(Color.RED))
		var entry: Dictionary = Fmt.entry_of("test", TYPE_OBJECT, mesh)
		_check(str(entry["type_name"]) == "Object", "entry_of 的 type_name 应来自 TYPE_NAMES")

	# ---------- 9. 报告 ----------
	_section("文本报告")
	var rep: String = Fmt.format_report(g)
	_check(rep.contains("RES 文件报告"), "报告应有标题")
	_check(rep.contains("Gradient"), "报告应含类型")
	_check(rep.contains("字符串表"), "报告应含字符串表段")
	print("    报告长度 %d 字符" % rep.length())

	# ---------- 10. 全工程扫描 ----------
	_section("全工程扫描")
	var files: PackedStringArray = []
	_walk(ProjectSettings.globalize_path("res://"), files, [".res", ".tres"], 0)
	var use: PackedStringArray = files.duplicate()
	var scn_samples: PackedStringArray = []
	_walk(ProjectSettings.globalize_path("res://.godot/imported"), scn_samples, [".scn"], 0)
	for i in range(mini(scn_samples.size(), 5)):
		use.append(scn_samples[i])

	var ok_cnt := 0
	var bad: Array = []
	var kinds := {}
	for path in use:
		var info: Dictionary = Fmt.inspect(path, false)
		var fmt := str(info["format"])
		kinds[fmt] = int(kinds.get(fmt, 0)) + 1
		if bool(info["ok"]):
			ok_cnt += 1
			if fmt == "binary":
				var b: Dictionary = info["binary"]
				var ints: Array = b["internal"]
				if ints.size() > 0 and int(ints[0]["offset"]) != int(b["data_offset"]):
					bad.append([path, "内部表不变量失败"])
		elif fmt == "binary" and str((info.get("binary", {}) as Dictionary).get("magic", "")) == "RSCC":
			pass  # RSCC 预期不支持结构解析
		else:
			bad.append([path, str(info["error"])])

	print("    扫描 %d 个文件：解析成功 %d，失败 %d，格式分布 %s" % [use.size(), ok_cnt, bad.size(), str(kinds)])
	_check(ok_cnt > 0, "应至少解析成功一个文件")
	_check(bad.size() == 0, "不应有解析失败：%s" % str(bad.slice(0, 8)))

	# ---------- 汇总 ----------
	print("\n===== 结果：通过 %d，失败 %d =====" % [_pass, _fail])
	if _fail > 0:
		print("❌ 自检未通过")
		quit(1)
	else:
		print("✅ 全部通过")
		quit(0)


## 递归收集指定后缀的文件（限深 + 限量，跳过 .git）。
func _walk(dir_path: String, out: PackedStringArray, suffixes: Array, depth: int) -> void:
	if depth > 12 or out.size() >= 20000:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.include_hidden = true
	d.include_navigational = true
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name == "." or name == "..":
			name = d.get_next()
			continue
		if d.current_is_dir():
			if name != ".git":
				_walk(dir_path.path_join(name), out, suffixes, depth + 1)
		else:
			for sfx in suffixes:
				if name.ends_with(str(sfx)):
					out.append(dir_path.path_join(name))
					break
		name = d.get_next()
	d.list_dir_end()


func _first_file(dir_path: String, suffix: String) -> String:
	var list: PackedStringArray = []
	_walk(dir_path, list, [suffix], 0)
	return "" if list.is_empty() else list[0]
