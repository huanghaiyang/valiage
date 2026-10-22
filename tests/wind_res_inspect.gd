extends SceneTree
## 查清 assets/models/树/wind/*.res 里到底存了什么（供回答/文档用）。

const DIR := "res://assets/models/树/wind/"

func _initialize() -> void:
	var files := ["Bark_Trunk", "Bark_Branch_L1", "Bark_Branch_L2", "Bark_Branch_L3",
			"Bark_Branch_L4", "Bark_Branch_L5", "Leaves", "Flowers"]
	var total_v := 0
	var total_tri := 0
	for nm in files:
		var p: String = DIR + String(nm) + ".res"
		var am: ArrayMesh = load(p)
		if am == null:
			print("%-16s LOAD FAIL" % nm)
			continue
		var arr: Array = am.surface_get_arrays(0)
		var fmt: int = am.surface_get_format(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
		var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
		total_v += v.size()
		total_tri += idx.size() / 3
		var present: Array = []
		var names := {0: "VERTEX", 1: "NORMAL", 2: "TANGENT", 3: "COLOR", 4: "TEX_UV",
				6: "CUSTOM0", 7: "CUSTOM1", 12: "INDEX"}
		for k in names.keys():
			if k < arr.size() and arr[k] != null:
				present.append(names[k])
		var fsz := FileAccess.get_file_as_bytes(p).size()
		var prim: String = str(am.surface_get_primitive_type(0))
		var mat: Material = am.surface_get_material(0)
		print("%-16s prim=%s surfaces=%d verts=%6d tris=%6d arrays=%s custom=%d/%d mat=%s file=%d B" % [
			nm, prim, am.get_surface_count(), v.size(), idx.size() / 3, str(present),
			c0.size(), c1.size(), ("null" if mat == null else mat.resource_path + str(mat.get_class())), fsz])
		# 抽样：第 0 个顶点与它归属元素的烘焙数据
		print("                 sample[0] CUSTOM0=(%.3f,%.3f,%.3f, aWind=%.3f)  CUSTOM1=(phase=%.3f, isLeaf=%d, nodeId=%.0f, baked=%d)" % [
			c0[0], c0[1], c0[2], c0[3], c1[0], int(c1[1]), c1[2], int(c1[3])])
	print("TOTAL verts=%d tris=%d" % [total_v, total_tri])
	quit(0)
