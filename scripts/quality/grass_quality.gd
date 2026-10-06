extends Node
## 【画质分级 · 草】让草贴图也按档位降分辨率。
##
## 实测现状（为什么需要这段代码）：
##   · `assets/textures/绿草/textures/` 里 **diff / nor 有 1k/2k/4k** ✓，
##     **alpha / rough 只有 4k** ✗（要补的话用【贴图分档生成器】生成 ✓）；
##   · 但**全项目没有任何代码在用这些分档** ✗ → 运行时永远加载 `_4k`
##     （显存列表里 4 张 4K 草 ≈ 53MB ✗，是当前最大的单项 ✗）。
##
## 贴图挂在两处（都覆盖 ✓）：
##   ① 共用材质 `res://scenes/草/_blend_mat_grass_bermuda_01.tres`（20+ 个草场景都引它 ✓）
##   ② SimpleGrassTextured 节点（`addons/simplegrasstextured/grass.gd`）的
##      `texture_albedo / texture_normal / texture_metallic / texture_roughness` ✓
##
## 安全约束：
##   · **只改内存里的材质实例** ✓（`.tres` / `.tscn` 一个字节都不写 ✓）；
##   · 只有在**确实存在对应档位文件**时才替换 ✓ → 找不到就保持原图 ✓（不会白贴图/变糊 ✗）；
##   · 支持跨扩展名（diff 是 .jpg、nor/rough 是 .png ✓）。
const GRASS_MAT := "res://scenes/草/_blend_mat_grass_bermuda_01.tres"
const SGT_HINT := "simplegrasstextured/grass.gd"
const SGT_PROPS := ["texture_albedo", "texture_normal", "texture_metallic", "texture_roughness"]

## 键：资源/节点 id + "/" + 属性名 → 原始贴图路径（换过之后 resource_path 变体，
## 必须记住原始路径才能在档位间来回切 ✓）
var _base: Dictionary = {}


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
	var tier := 2
	var qm := get_node_or_null("/root/Quality")
	if qm != null:
		tier = int(qm.tier)
	return apply_tier(tier)


func apply_tier(tier: int) -> Dictionary:
	var out := {"tier": tier, "tier_name": QualityTiers.tier_name(tier),
			"changed": 0, "materials": 0, "nodes": 0}
	# ① 共用材质（Standard / Shader 都能处理 ✓）
	if ResourceLoader.exists(GRASS_MAT):
		var m := load(GRASS_MAT)
		if m is Material:
			_swap_material(m as Material, tier, out)
	# ② SGT 节点自身的四个贴图槽
	for n in _sgt_nodes(get_tree().current_scene):
		out["nodes"] = int(out["nodes"]) + 1
		_swap_props(n, SGT_PROPS, tier, out)
	print("[画质] 草贴图已按「%s」应用：%s" % [out["tier_name"], out])
	return out


## 材质：StandardMaterial3D 按属性名换；ShaderMaterial 遍历所有 Texture2D 参数换 ✓
func _swap_material(mat: Material, tier: int, out: Dictionary) -> void:
	out["materials"] = int(out["materials"]) + 1
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var keys: Array = []
		# ★ 不要用 get_shader_parameter_list()：Godot 4.7 的 ShaderMaterial **没有**这个方法 ✗
		#   改用 Object.get_property_list()（一定存在 ✓）里的 `shader_parameter/xxx` 前缀项 ✓
		for p in sm.get_property_list():
			var pn := String(p.get("name", ""))
			if pn.begins_with("shader_parameter/"):
				keys.append(pn.substr("shader_parameter/".length()))
		_swap_props(sm, keys, tier, out)
	else:
		_swap_props(mat, ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture"], tier, out)


## 通用换图：owner 上的每个 prop，若能找到"本档位变体"就换 ✓（否则保持原图 ✓）
func _swap_props(owner: Object, props: Array, tier: int, out: Dictionary) -> void:
	if owner == null:
		return
	var key_base := str(owner.get_instance_id())
	var is_shader := owner is ShaderMaterial
	for prop in props:
		var pname := String(prop)
		if pname.is_empty():
			continue
		var cur: Variant = null
		if is_shader:
			cur = (owner as ShaderMaterial).get_shader_parameter(pname)
		else:
			cur = owner.get(pname)
		# ★ 必须先用 `is` 判断再取：
		#   shader 参数里可能是 float / vec / int 等**非对象值** ✗，
		#   直接写 `cur as Texture2D` 会报 "Invalid cast: can't convert a non-object value" ✗
		#   （`is` 对任何值都安全 ✓，`as` 不行 ✗）
		if not (cur is Texture2D):
			continue
		var tex := cur as Texture2D
		var src := String(tex.resource_path)
		var kk := key_base + "/" + pname
		var orig := src
		if _base.has(kk):
			orig = String(_base[kk])
		if orig.is_empty():
			continue                              # 内嵌/无路径贴图：不碰 ✓
		_base[kk] = orig
		var want := _variant(orig, tier)
		if want.is_empty() or want == src:
			continue                              # 没有该档位文件 → 保持原图 ✓
		var nt := load(want) as Texture2D
		if nt == null:
			continue
		if is_shader:
			(owner as ShaderMaterial).set_shader_parameter(pname, nt)
		else:
			owner.set(pname, nt)
		out["changed"] = int(out["changed"]) + 1
		var arr: Array = out.get("sources", [])
		if not arr.has(orig) and arr.size() < 8:
			arr.append(orig)
			out["sources"] = arr


## 本档位对应的分档路径：先同扩展名（QualityTiers 规则 ✓），再跨扩展名 ✓
func _variant(orig: String, tier: int) -> String:
	var want := QualityTiers.resolve_existing(orig, tier)
	if want != "" and ResourceLoader.exists(want):
		return want
	var stem := (want if want != "" else orig).get_basename()
	for e in [".png", ".jpg", ".jpeg", ".webp"]:
		var cand := stem + String(e)
		if cand != orig and ResourceLoader.exists(cand):
			return cand
	return ""


func _sgt_nodes(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	var st: Array = [root]
	while not st.is_empty():
		var n = st.pop_back()
		var s: Variant = n.get_script()      # ★ 必须显式标注类型：n.get_script() 无法推断 ✗
		if s != null and String((s as Script).resource_path).contains(SGT_HINT):
			out.append(n)
		for c in n.get_children():
			st.append(c)
	return out
