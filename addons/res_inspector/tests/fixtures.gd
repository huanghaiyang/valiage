@tool
extends RefCounted
## 测试夹具：**现造现用**。
##
## 为什么不直接引用仓库里的 .res：
##   · 工程里那些样本都在 `.runtime/` 下，而 `.runtime/` 是 gitignore 的，换台机器就没有；
##   · 夹具内容必须是「已知的」，才能断言解析结果（类型 / 字符串表项数 / 内部子资源数…）。
##
## 产物目录 `addons/res_inspector/__probe__/` 已加入 .gitignore（与 addons/exr_tools/__probe__/ 同一约定），
## 每次跑测试都会重建，不会进版本库。

const DIR := "res://addons/res_inspector/__probe__"

## 造好全部夹具并返回 { 名字: res:// 路径 }。
static func ensure() -> Dictionary:
	var abs_dir := ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	var out := {}

	# 1) Gradient：字符串表 7 项，1 个内部子资源（根自身）
	var g_path := DIR + "/gradient.res"
	if not FileAccess.file_exists(g_path):
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
		g.colors = PackedColorArray([Color.RED, Color.GREEN, Color.BLUE])
		ResourceSaver.save(g, g_path)
	out["gradient"] = g_path

	# 2) ArrayMesh：单表面三角片，用于预览/属性断言
	var m_path := DIR + "/mesh.res"
	if not FileAccess.file_exists(m_path):
		var am := ArrayMesh.new()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.resource_name = "tri"
		ResourceSaver.save(am, m_path)
	out["mesh"] = m_path

	# 3) GradientTexture2D：2 个内部子资源，用来验证内部表多项解析
	var gt_path := DIR + "/grad_texture.res"
	if not FileAccess.file_exists(gt_path):
		var g2 := Gradient.new()
		g2.colors = PackedColorArray([Color.BLACK, Color.WHITE])
		var gt := GradientTexture2D.new()
		gt.gradient = g2
		gt.width = 32
		gt.height = 8
		ResourceSaver.save(gt, gt_path)
	out["grad_texture"] = gt_path

	# 4) Animation：轨道属性名进字符串表
	var a_path := DIR + "/anim.res"
	if not FileAccess.file_exists(a_path):
		var an := Animation.new()
		an.length = 1.5
		an.add_track(Animation.TYPE_VALUE)
		an.track_set_path(0, NodePath("Sprite:modulate"))
		ResourceSaver.save(an, a_path)
	out["anim"] = a_path

	# 5) 文本资源：直接写 .tres 文本（不走 ResourceSaver，保证内容可控）
	var t_path := DIR + "/sample.tres"
	var text := """[gd_resource type="Resource" format=3 uid="uid://resinspectorsample"]

[ext_resource type="Texture2D" uid="uid://abc123" path="res://icon.svg" id="1_tex"]

[sub_resource type="Gradient" id="Gradient_main"]
offsets = PackedFloat32Array(0, 1)
colors = PackedColorArray(0, 0, 0, 1, 1, 1, 1, 1)

[resource]
resource_name = "样本"
script = null
"""
	var tf := FileAccess.open(t_path, FileAccess.WRITE)
	if tf != null:
		tf.store_string(text)
		tf.close()
	out["text"] = t_path

	# 6) 垃圾字节：非任何已知格式
	var junk_path := DIR + "/junk.bin"
	if not FileAccess.file_exists(junk_path):
		var jf := FileAccess.open(junk_path, FileAccess.WRITE)
		if jf != null:
			jf.store_buffer(PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 1, 2, 3]))
			jf.close()
	out["junk"] = junk_path

	# 7) 不存在的路径（不需要造文件）
	out["missing"] = DIR + "/绝对不存在的文件.res"

	return out


## 工程里可能存在的大样本（.runtime 不入库，所以只能「有就测，没有就跳过」）。
static func big_sample() -> String:
	for p in ["res://.runtime/inline_test/A.res", "res://.runtime/res_probe/mesh.res"]:
		if FileAccess.file_exists(p):
			return p
	return ""
