extends SceneTree
## 火焰特效自检：场景装配是否正确（网格数 / 材质 / 贴地 / 总高 / 灯光）。

var _done := false
var _pass := 0
var _fail := 0


func _ck(label: String, ok: bool, extra: String = "") -> void:
	if ok:
		_pass += 1
		print("  ✓ %s%s" % [label, ("  " + extra) if extra != "" else ""])
	else:
		_fail += 1
		print("  ✗ %s%s" % [label, ("  " + extra) if extra != "" else ""])


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	print("=========== 火焰燃烧特效 自检 ===========")
	var ps: PackedScene = load("res://scenes/法术特效/火焰燃烧特效.tscn")
	_ck("场景能加载", ps != null)
	if ps == null:
		quit(1)
		return true
	var root := ps.instantiate()
	root.set("auto_billboard", false)          # 自检里相机可能为空，关掉免得乱转
	root.set("stretch_gain", 0.0)              # 冻结动画幅度，方便量尺寸
	root.set("flicker_gain", 0.0)
	root.set("sway_gain", 0.0)
	get_root().add_child(root)       # add_child 会自动触发 _ready（别再手动 call 一次）
	root.call("_process", 1.0 / 60.0)

	var meshes: Array[MeshInstance3D] = []
	_gather(root, meshes)
	_ck("火焰网格数量 = 16（5 底层 + 5 中层 + 5 上层 + 1 主焰）", meshes.size() == 16,
			"实际 %d" % meshes.size())

	var with_mat := 0
	for mi in meshes:
		if mi.material_override is ShaderMaterial:
			with_mat += 1
			var m := mi.material_override as ShaderMaterial
			if m.shader == null or m.get_shader_parameter("fire_tex") == null:
				with_mat -= 1
	_ck("每个火焰都装了火焰着色器且贴了火纹理", with_mat == meshes.size(),
			"%d/%d" % [with_mat, meshes.size()])

	# 贴地：整团火的最低点应接近 y=0
	var lo := 1e9
	var hi := -1e9
	for mi in meshes:
		var aabb := mi.mesh.get_aabb()
		var xf := mi.global_transform
		for i in range(8):
			var c := aabb.position + Vector3(
					aabb.size.x if (i & 1) != 0 else 0.0,
					aabb.size.y if (i & 2) != 0 else 0.0,
					aabb.size.z if (i & 4) != 0 else 0.0)
			var w := xf * c
			lo = minf(lo, w.y)
			hi = maxf(hi, w.y)
	_ck("焰卡贴地（最低点 ≈ 0）", absf(lo) < 0.25, "最低 y=%.3f" % lo)
	_ck("这是一团**大火**（总高 ≥ 3.5 米）", (hi - lo) >= 3.5, "总高 %.2f 米" % (hi - lo))

	var light := _find_light(root)
	_ck("有红橙点光", light != null and light.light_energy > 0.0,
			("energy=%.1f 色=%s" % [light.light_energy, str(light.light_color)]) if light != null else "")

	print("通过 %d  |  失败 %d" % [_pass, _fail])
	root.queue_free()
	quit(0 if _fail == 0 else 1)
	return true


func _gather(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		# 核心辉光不是焰卡，单独统计（它挂在 CoreGlow 子节点下）
		if c.name == "CoreGlow":
			continue
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		else:
			_gather(c, out)


func _find_light(n: Node) -> OmniLight3D:
	if n is OmniLight3D:
		return n as OmniLight3D
	for c in n.get_children():
		var r := _find_light(c)
		if r != null:
			return r
	return null
