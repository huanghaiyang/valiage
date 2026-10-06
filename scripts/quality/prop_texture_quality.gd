extends Node
## 【画质分级 · 模型贴图】把墓园/道具材质的贴图按当前档位换成"对应分辨率的版本"。
##
## 与 `scripts/quality/terrain_quality.gd`（地表贴图分级）**同一套机制**：
##   · 分辨率后缀由 `QualityTiers` 决定（1k / 2k / 4k）；
##   · 换不到就用 `QualityTiers.resolve_existing()` 回退到存在的最高档
##     -> **永远不会出现"贴图丢失 / 变白"**；
##   · **内嵌贴图（resource_path 为空）直接跳过** —— 与地表贴图完全同一条防护。
##
## ★ 前提：贴图要有分档文件，命名形如 `xxx_diff_4k.jpg / _2k / _1k`（同 QualityTiers 规则）。
##   如果墓园贴图是**嵌在 glb 里**的，它们没有 resource_path -> 会被跳过（日志会报数量），
##   那种情况需要先把贴图导出成文件再分档（我可以再写一个导出工具）。
##
## 用法（main.gd 世界装配后挂上即可，见那里的调用）：
##   var pq := preload("res://scripts/quality/prop_texture_quality.gd").new()
##   add_child(pq)
@export var name_hints: PackedStringArray = []
## ★ 留空 = **处理场景里所有 MeshInstance3D 的材质**（推荐）：
##   没有分档文件的贴图会自动回退到原图 ✓（零风险），所以不必按名字挑节点 ——
##   对 glb_split 生成的那些 .tscn/.res（节点名不归我们控制）尤其重要 ✓。
##   想缩小范围再填关键词（如 "墓园" / "栅栏" / "fence"）。
## 编辑器里默认不动手（切档若改到资源引用，保存后档位就被"烤"进场景了 ✗ —— 与地表贴图一致）
@export var apply_in_editor := false

## 材质实例 id -> { 属性名: 原始路径 }（换过之后 tex.resource_path 变成变体路径，
## 所以必须记住原始路径，否则无法在档位之间来回切换 ✓）
var _base: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint() and not apply_in_editor:
		return
	var qm := get_node_or_null("/root/Quality")
	if qm != null and qm.has_signal("tier_changed") \
			and not qm.tier_changed.is_connected(_on_tier_changed):
		qm.tier_changed.connect(_on_tier_changed)
	apply_current()


func _on_tier_changed(_t: int) -> void:
	apply_current()


func apply_current() -> Dictionary:
	var t: int = QualityTiers.Tier.HIGH
	var qm := get_node_or_null("/root/Quality")
	if qm != null:
		t = int(qm.tier)
	return apply_tier(t)


func apply_tier(t: int) -> Dictionary:
	var out := {"tier": t, "tier_name": QualityTiers.tier_name(t),
			"mats": 0, "changed": 0, "embedded": 0, "missing": 0}
	var mats := _collect_materials()
	out["mats"] = mats.size()
	for m in mats:
		var mat := m as BaseMaterial3D
		var sm := m as ShaderMaterial                  # ★ blend_tools 的 _blend_mat_* 等 ✓
		if mat == null and sm == null:
			continue
		var id := (mat if mat != null else sm).get_instance_id()
		if not _base.has(id):
			_base[id] = {}
		# ★ 覆盖**全部贴图插槽**（与生成器的 12 个插槽对齐 ✓）：
		#   之前只换 albedo/normal ✗ → 4K 的 roughness/metallic/ao/height/emission 等
		#   仍然占着显存 ✗（例如 `..._rm.jpg` 4096 单独就 21MB ✗）。
		#   没有分档的贴图会走 resolve_existing 回退到原图 ✓ → 不会白贴图 ✓
		# ★ ShaderMaterial（如 `_blend_mat_石质墓园栅栏*.tres`）**也必须处理** ✗：
		#   它的贴图是 shader 参数，参数名从 Object.get_property_list() 的
		#   `shader_parameter/xxx` 前缀里取 ✓
		#   （不要用 ShaderMaterial.get_shader_parameter_list() —— Godot 4.7 没有这个方法 ✗）
		var props: Array = ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture",
				"emission_texture", "ao_texture", "heightmap_texture", "rim_texture",
				"clearcoat_texture", "anisotropy_texture", "detail_albedo", "detail_normal"]
		if mat == null and sm != null:
			props = []
			for p in sm.get_property_list():
				var pn := String(p.get("name", ""))
				if pn.begins_with("shader_parameter/"):
					props.append(pn.substr("shader_parameter/".length()))
		for prop in props:
			# ★ 先 is 再 as：shader 参数可能是 float/vec 等**非对象值** ✗
			#   （`as` 对非对象值会报 "Invalid cast: can't convert a non-object value" ✗）
			var cur: Variant = null
			if mat != null:
				cur = mat.get(prop)
			else:
				cur = sm.get_shader_parameter(String(prop))
			if not (cur is Texture2D):
				continue
			var tex := cur as Texture2D
			var src := String(tex.resource_path)
			var orig := src
			if _base[id].has(prop):
				orig = String(_base[id][prop])
			if orig.is_empty():
				out["embedded"] = int(out["embedded"]) + 1
				continue                      # 内嵌贴图：不碰 ✓
			_base[id][prop] = orig
			var want := QualityTiers.resolve_existing(orig, t)
			# ★ 关键修正：`resolve_existing()` 在找不到本档位文件时会**回退到原图** ✓
			#   → 此时 want == orig ✗，但磁盘上可能确实存在"本档位后缀 + 别的扩展名" ✓
			#   （例如生成端对数据类贴图强制存 `..._rm_1k.png`，而本档位规则找的是
			#     `..._rm_1k.jpg` ✗）—— 旧写法只判 "not exists" ✗ 会把这种情况漏掉 ✗，
			#   表现就是"磁盘上明明有 _1k 文件，切档却没换" ✓
			if want.is_empty() or want == orig or not ResourceLoader.exists(want):
				var stem := QualityTiers.texture_for_tier(orig, t).get_basename()
				want = ""
				for e in [".png", ".jpg", ".jpeg", ".webp"]:
					var cand := stem + String(e)
					if cand != orig and ResourceLoader.exists(cand):
						want = cand
						break
			if want.is_empty():
				out["missing"] = int(out["missing"]) + 1
				continue
			if want == src:
				continue
			var nt := load(want) as Texture2D
			if nt == null:
				out["missing"] = int(out["missing"]) + 1
				continue
			# ★ 写回也要分类型：BaseMaterial3D 用属性，ShaderMaterial 用 shader 参数
			#   （blend 材质下 `mat` 是 null ✗，直接 mat.set(...) 会崩 ✓）
			if mat != null:
				mat.set(prop, nt)
			else:
				sm.set_shader_parameter(String(prop), nt)
			out["changed"] = int(out["changed"]) + 1
			out[prop] = int(out.get(prop, 0)) + 1        # 细分计数：albedo_texture / normal_texture ✓
			# ★ 诊断：记录"被改的材质来自哪个资源文件"——这样日志里能直接看到
			#   res://scenes/墓园/石质墓园栅栏_01.res 这种**打包在 .res 里**的材质也被换掉了 ✓
			#   （材质是 load() 出来的共享实例 ✓ 只改内存 ✓ 不会写回 .res ✓）
			# ★ mat 在 ShaderMaterial 分支里是 null ✗ → 取非空的那个的 resource_path ✓
			#   （三元表达式结果是 Variant ✗ 推断不出类型 → 先落到 Resource 再取 String ✓）
			var owner_res: Resource = mat if mat != null else sm
			var src_res := String(owner_res.resource_path)
			if src_res != "":
				var arr: Array = out.get("sources", [])
				if not arr.has(src_res) and arr.size() < 8:
					arr.append(src_res)
					out["sources"] = arr
	print("[画质] 模型贴图已按「%s」应用：%s" % [out["tier_name"], out])
	return out


## 收集关注子树下的所有材质（material_override + surface override + 网格自带材质）
func _collect_materials() -> Array:
	var out: Array = []
	var st: Array = [get_tree().current_scene]
	while not st.is_empty():
		var n = st.pop_back()
		if n == null:
			continue
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if _matches(mi):
				if mi.material_override != null:
					out.append(mi.material_override)
				for i in range(mi.get_surface_override_material_count()):
					var sm := mi.get_surface_override_material(i)
					if sm != null:
						out.append(sm)
				if mi.mesh != null:
					for i in range(mi.mesh.get_surface_count()):
						var m2 := mi.mesh.surface_get_material(i)
						if m2 != null:
							out.append(m2)
		elif n is MultiMeshInstance3D:
			# ★ 关键补充：`MultiMeshInstance3D` **不是** `MeshInstance3D` 的子类 ✗
			#   （散置的围栏/草丛/石块常走它 ✓）→ 之前完全没被收集到 ✗
			#   表现为"明明有 _1k 文件，切档却没换" ✓
			var mmi := n as MultiMeshInstance3D
			if _matches(mmi):
				if mmi.material_override != null:
					out.append(mmi.material_override)
				var mm: MultiMesh = mmi.multimesh
				if mm != null and mm.mesh != null:
					for i in range(mm.mesh.get_surface_count()):
						var m3 := mm.mesh.surface_get_material(i)
						if m3 != null:
							out.append(m3)
		for c in n.get_children():
			st.append(c)
	return out


## 自己或任一祖先的名字命中关键词；★ 关键词为空 = **全部匹配**（默认行为 ✓）
func _matches(n: Node) -> bool:
	if name_hints.is_empty():
		return true
	var cur: Node = n
	var depth := 0
	while cur != null and depth < 6:
		var nm := String(cur.name)
		for h in name_hints:
			if nm.contains(String(h)):
				return true
		cur = cur.get_parent()
		depth += 1
	return false
