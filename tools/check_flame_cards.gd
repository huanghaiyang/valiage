extends SceneTree
## 量一下火焰卡片模型的几何：哪个轴是"厚度"轴（法线方向）。
## 薄片模型必须按法线来定 yaw，否则会侧着看（几乎看不见）或全糊在一起。
func _init() -> void:
	print("=== 火焰卡片几何（AABB）===")
	var scene := load("res://scenes/法术特效/火焰燃烧特效.tscn") as PackedScene
	if scene == null:
		print("  场景加载失败")
		quit(1)
		return
	var root := scene.instantiate()
	var n := 0
	for ch in _walk(root):
		var mi := ch as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		var s := aabb.size
		var thin := "X"
		if s.y <= s.x and s.y <= s.z:
			thin = "Y"
		elif s.z <= s.x and s.z <= s.y:
			thin = "Z"
		# 局部基的 Z 轴（模型"前方"）在世界里的方向
		print("  %-22s 尺寸=(%.3f, %.3f, %.3f)  最薄轴=%s  基Z=(%.2f, %.2f, %.2f)" % [
				mi.name, s.x, s.y, s.z, thin,
				mi.global_transform.basis.z.x, mi.global_transform.basis.z.y,
				mi.global_transform.basis.z.z])
		n += 1
	print("  共 %d 个网格" % n)
	root.free()
	quit(0)


func _walk(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_walk(c))
	return out
