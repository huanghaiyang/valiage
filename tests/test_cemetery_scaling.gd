@tool
extends McpTestSuite
## res://scenes/墓园/ 下 9 个栅栏模型：统一放大 10 倍，且以"模型底部中间"为缩放中心。
## 判定不依赖硬编码数值——直接与原始 .res 网格的包围盒（不受节点变换影响）对比：
##   ① 场景几何包围盒尺寸 = 原始网格尺寸 ×10；
##   ② 几何包围盒的"底部中间"点与原始网格底部中点重合（即缩放中心就是它）。

const CEMETERY_DIR := "res://scenes/墓园"
const SCALE := 10.0
const MODELS := [
	"石质墓园栅栏_01.tscn",
	"石质墓园栅栏_02.tscn",
	"石质墓园栅栏_03.tscn",
	"石质墓园栅栏_04.tscn",
	"石质墓园栅栏_05.tscn",
	"石质墓园栅栏_06.tscn",
	"石质墓园栅栏_07.tscn",
	"石质墓园栅栏_08.tscn",
	"石质墓园栅栏_09.tscn",
]


func suite_name() -> String:
	return "cemetery_scaling"


func _model_paths() -> PackedStringArray:
	var out := PackedStringArray()
	for n in MODELS:
		out.append(CEMETERY_DIR + "/" + n)
	return out


static func _transform_aabb(xf: Transform3D, box: AABB) -> AABB:
	var out := AABB(xf * box.position, Vector3.ZERO)
	for i in 8:
		var corner := box.position + Vector3(
			box.size.x * float(i & 1),
			box.size.y * float((i >> 1) & 1),
			box.size.z * float((i >> 2) & 1)
		)
		out = out.expand(xf * corner)
	return out


## 节点相对场景根的变换（逐级累乘，兼容将来多套一层的情况）
static func _rel_to_root(node: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D()
	var cur: Node3D = node
	while cur != null and cur != root:
		xf = cur.transform * xf
		cur = cur.get_parent() as Node3D
	return xf


static func _bottom_center(box: AABB) -> Vector3:
	return Vector3(box.position.x + box.size.x * 0.5, box.position.y, box.position.z + box.size.z * 0.5)


## {"geo": 场景根空间几何包围盒, "authored": 原始网格包围盒}；测不了返回 {}
static func _measure(path: String) -> Dictionary:
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return {}
	var root := packed.instantiate() as Node3D
	if root == null:
		return {}
	var geo := AABB()
	var authored := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var ma := mi.mesh.get_aabb()
		if first:
			authored = ma
			first = false
		geo = geo.merge(_transform_aabb(_rel_to_root(mi, root), ma))
	root.free()
	if first:
		return {}
	return {"geo": geo, "authored": authored}


func test_models_scaled_10x_around_bottom_center() -> void:
	var missing := PackedStringArray()
	for path in _model_paths():
		if not ResourceLoader.exists(path):
			missing.append(path.get_file())
			continue
		var m := _measure(path)
		if m.is_empty():
			assert_true(false, "%s 测量失败（没有 MeshInstance3D？）" % path.get_file())
			return
		var geo: AABB = m["geo"]
		var authored: AABB = m["authored"]
		assert_true(
			geo.size.distance_to(authored.size * SCALE) < 0.01,
			"%s 几何应为原始尺寸 ×%.0f：期望 %s，实际 %s" % [path.get_file(), SCALE, authored.size * SCALE, geo.size]
		)
		var want := _bottom_center(authored)
		var got := _bottom_center(geo)
		assert_true(
			want.distance_to(got) < 0.01,
			"%s 底部中点应保持不动：期望 %s，实际 %s" % [path.get_file(), want, got]
		)
	if not missing.is_empty():
		skip("缺少模型：" + ", ".join(missing))


## 说明：本套件只做只读断言；模型变换的正确值由 .res 网格包围盒推出：
## 底部中点 c = (0, -size.y/2, 0)，子节点 transform = Transform3D(10,0,0, 0,10,0, 0,0,10, -9c)

