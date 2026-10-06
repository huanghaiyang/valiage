extends Node
## 【画质分级 · 阴影】按档位调整平行光的**阴影绘制距离**。
##
## 为什么用"阴影距离"这个旋钮：
##   `directional_shadow_max_distance` 决定**多远的物体要进阴影贴图**。
##   距离越小 → 阴影 pass 需要渲染的物体越少 → GPU 省一大截 ✓
##   （同族杠杆的实测参考：隐藏 Terrain3D → fps 28→39，+39% ✓）
##
## 与项目现有分级的关系：
##   `QualityTiers` 的预设里**本来就有 `shadow_quality` 字段（0~3）**，
##   但之前**没有任何脚本读它** ✗ —— 本脚本把它接上 ✓：
##     0 低 → 40m ｜ 1 中 → 70m ｜ 2 高 → 110m ｜ 3 极高 → 160m
##   只改**距离**，不动阴影贴图分辨率/位深（避免画质突变与额外风险 ✗）。
##   想更激进/更保守：改下面的 `distances` ✓。
@export var distances: PackedFloat32Array = PackedFloat32Array([40.0, 70.0, 110.0, 160.0])
## 编辑器里不动手（切档若改到场景资源引用，保存后档位会被"烤"进场景 ✗ —— 与地表贴图一致）


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var qm := get_node_or_null("/root/Quality")
	if qm != null and qm.has_signal("tier_changed") and not qm.tier_changed.is_connected(_on_tier_changed):
		qm.tier_changed.connect(_on_tier_changed)
	apply_current()


func _on_tier_changed(_t: int) -> void:
	apply_current()


func apply_current() -> Dictionary:
	var tier := 2                       # 默认按"高"
	var qm := get_node_or_null("/root/Quality")
	if qm != null:
		tier = int(qm.tier)
	return apply_tier(tier)


func apply_tier(tier: int) -> Dictionary:
	var idx := clampi(tier, 0, distances.size() - 1)
	var d := float(distances[idx])
	var out := {"tier": tier, "tier_name": QualityTiers.tier_name(tier), "distance": d, "lights": 0}
	for n in _lights(get_tree().current_scene):
		(n as DirectionalLight3D).directional_shadow_max_distance = d
		out["lights"] = int(out["lights"]) + 1
	print("[画质] 阴影距离已按「%s」应用：%s" % [out["tier_name"], out])
	return out


func _lights(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	var st: Array = [root]
	while not st.is_empty():
		var n = st.pop_back()
		if n is DirectionalLight3D:
			out.append(n)
		for c in n.get_children():
			st.append(c)
	return out
