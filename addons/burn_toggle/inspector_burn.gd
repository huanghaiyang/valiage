@tool
extends EditorInspectorPlugin
## ★ 材质检查器：**由用户自己选**燃烧效果 ✓（不做自动判断 ✓）
##
##   [燃烧效果 ▼]  ▸ 无（普通材质）            → 恢复 StandardMaterial3D ✓
##                 ▸ 叶片型（烧完**消失**）     → tree_leaves_burn*.gdshader ✓
##                 ▸ 木质型（烧完**保留焦黑**） → tree_burn_keep*.gdshader ✓
##   [树高(米) 8.0]  → "从下往上烧"的前沿映射 ✓
##
## ★★ 本次修复（用户要求 ✓）：**不再丢属性** ✗ ——
##   以前是"重建材质"✗（cull_mode / albedo_color / 法线 / 粗糙度 全被丢掉 ✓）
##   现在改成**按映射表逐项继承** ✓：
##     cull_mode=2(双面) → 自动选 *_ds 变体 ✓（ShaderMaterial 无法逐材质设 cull ✗）
##     albedo_color      → base_color ✓
##     normal_enabled/normal_texture → has_normal/normal_tex ✓
##     roughness_texture → has_rough/rough_tex ✓（GRAYSCALE 通道与 .r 等价 ✓）
##     metallic          → 两边默认都是 0 ✓（无需传 ✓）
##     ★ 叶片特例：源 albedo 若是 *_alpha_*.png（遮罩图 ✗）→
##        自动改用同前缀的 *_diff_*.png 作 albedo ✓ 并把遮罩图转成 alpha_tex ✓
##
## ★ 改动会立刻写回**同一个 .tres 路径** ✓（uid 保留 ✓ 场景引用不断 ✓）

## ★ 方案 A（用户定稿 ✓）：**每类只用一份 shader** ✓
##   `_ds` 后缀只是历史命名 ✓（内容已统一 ✓ 不再分单/双面变体 ✓）
const SH_LEAF := "res://assets/shaders/tree_leaves_burn_ds.gdshader"
const SH_LEAF_DS := "res://assets/shaders/tree_leaves_burn_ds.gdshader"
const SH_WOOD := "res://assets/shaders/tree_burn_keep_ds.gdshader"
const SH_WOOD_DS := "res://assets/shaders/tree_burn_keep_ds.gdshader"
const META_MODE := "burn_mode"
const META_HEIGHT := "burn_height"

const MODE_NONE := 0
const MODE_LEAF := 1
const MODE_WOOD := 2

## Godot BaseMaterial3D.CullMode：0=背面 1=正面 2=**双面** ✓
const CULL_DISABLED := 2


func _can_handle(object: Object) -> bool:
	return object is Material


func _parse_begin(object: Object) -> void:
	var m := object as Material
	if m == null:
		return
	var mode := String(m.get_meta(META_MODE, ""))
	var idx := MODE_NONE
	if mode == "leaf":
		idx = MODE_LEAF
	elif mode == "wood":
		idx = MODE_WOOD

	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	var lb := Label.new()
	lb.text = "燃烧效果"
	row.add_child(lb)
	var opt := OptionButton.new()
	opt.add_item("无（普通材质）", MODE_NONE)
	opt.add_item("叶片型：从下往上烧 → 烧完消失", MODE_LEAF)
	opt.add_item("木质型：从下往上烧 → 烧完保留焦黑", MODE_WOOD)
	opt.select(idx)
	row.add_child(opt)
	box.add_child(row)

	var row2 := HBoxContainer.new()
	var lb2 := Label.new()
	lb2.text = "树高(米)"
	row2.add_child(lb2)
	var hs := SpinBox.new()
	hs.min_value = 0.2
	hs.max_value = 40.0
	hs.step = 0.5
	hs.value = float(m.get_meta(META_HEIGHT, 8.0))
	hs.tooltip_text = "这株的总高度 ✓ —— 决定火焰「从下往上」的映射 ✓（= shader 的 height_ref ✓）"
	row2.add_child(hs)
	box.add_child(row2)

	var note := Label.new()
	note.clip_text = true
	note.text = "会立刻写回该 .tres ✓（继承 cull_mode/染色/法线/粗糙度 ✓）；改完请重新打开场景 ✓"
	box.add_child(note)
	add_custom_control(box)

	opt.item_selected.connect(func(i: int) -> void:
		var nm := "none"
		if i == MODE_LEAF:
			nm = "leaf"
		elif i == MODE_WOOD:
			nm = "wood"
		_apply(m, nm, hs.value))
	hs.value_changed.connect(func(v: float) -> void:
		var cur := String(m.get_meta(META_MODE, ""))
		if cur == "":
			return
		_apply(m, cur, v))


func _apply(m: Material, mode: String, height: float) -> void:
	var p := String(m.resource_path)
	if p.is_empty() or not p.ends_with(".tres"):
		# ★ 把**实际值**打出来 ✓（用户反馈：branches 报了这条警告 ✗）
		#   常见两种：① 内嵌在场景里（路径形如 xxx.tscn::StandardMaterial3D_xxx ✓）
		#             ② 还没落盘的实例（路径为空 ✓）
		#   处理办法：在 FileSystem 里**双击那份 .tres 文件本身** ✓ 再选燃烧档位 ✓
		push_warning("[燃烧开关] 这份材质没有保存成独立的 .tres ✗ ｜ resource_path=「%s」｜ 类型=%s ｜ 名字=%s"
				% [p, m.get_class(), m.resource_name])
		return
	var fresh: Material = null
	if mode == "leaf" or mode == "wood":
		var double_sided := _is_double_sided(m)
		var sh_path := ""
		if mode == "leaf":
			sh_path = SH_LEAF_DS if double_sided else SH_LEAF
		else:
			sh_path = SH_WOOD_DS if double_sided else SH_WOOD
		var sh: Shader = load(sh_path)
		if sh == null:
			push_warning("[燃烧开关] shader 加载失败 ✗ %s" % sh_path)
			return
		var sm := ShaderMaterial.new()
		sm.resource_name = m.resource_name
		sm.shader = sh

		# ① 颜色：继承 albedo_color ✓（原来硬写白 ✗ = 丢染色）
		sm.set_shader_parameter("base_color", _color_of(m))
		sm.set_shader_parameter("burn", 0.0)
		sm.set_shader_parameter("ash", 0.0)
		sm.set_shader_parameter("height_ref", height)

		# ② 叶片：albedo / 遮罩（含"遮罩被当成 albedo"的纠正 ✓）
		if mode == "leaf":
			var pair := _leaf_textures(m)
			sm.set_shader_parameter("albedo_tex", pair["albedo"])
			sm.set_shader_parameter("alpha_tex", pair["alpha"])
			sm.set_shader_parameter("alpha_scissor", _scissor_of(m))
			sm.set_shader_parameter("wind_enabled", true)
			sm.set_shader_parameter("sway_amt", 0.06)
			sm.set_shader_parameter("edge_jitter", 0.25)
			if pair["albedo"] == null or pair["alpha"] == null:
				push_warning("[燃烧开关] 叶片材质缺少 albedo/alpha ✗ → 可能变实心方块 ✓（建议改用木质型 ✓）")
		else:
			sm.set_shader_parameter("use_albedo", true)
			sm.set_shader_parameter("use_mask", false)
			sm.set_shader_parameter("overlay_mode", false)
			sm.set_shader_parameter("sway_amt", 0.0)
			var al := _albedo_of(m)
			if al == null:
				push_warning("[燃烧开关] 木质材质没有 albedo 贴图 ✗ → 会变白模 ✓ 请检查源材质 ✓")
			sm.set_shader_parameter("albedo_tex", al)

		# ③ 法线 / 粗糙度：有就带 ✓（没有就不带 ✓ 不白花采样 ✓）
		var nt := _normal_of(m)
		if nt != null:
			sm.set_shader_parameter("normal_tex", nt)
			sm.set_shader_parameter("has_normal", true)
		var rt := _rough_of(m)
		if rt != null:
			sm.set_shader_parameter("rough_tex", rt)
			sm.set_shader_parameter("has_rough", true)

		fresh = sm
		print("[燃烧开关] 继承 ✓ 双面=%s ｜ 法线=%s ｜ 粗糙度=%s ｜ 染色=%s" % [
				str(double_sided), str(nt != null), str(rt != null), str(_color_of(m))])
	else:
		var std := StandardMaterial3D.new()
		std.resource_name = m.resource_name
		std.albedo_texture = _albedo_of(m)
		std.albedo_color = _color_of(m)
		fresh = std
	fresh.set_meta(META_MODE, mode if mode != "none" else "")
	fresh.set_meta(META_HEIGHT, height)
	# ★ 留痕（用户要求 ✓）：ShaderMaterial **没有 cull_mode 字段** ✗
	#   → 把源材质的 cull 设置记进 meta ✓ 这样 diff 里能直接看出双面/单面有没有被改 ✓
	#   （真正的双面是靠 *_ds 变体 shader 的 `render_mode cull_disabled` 实现的 ✓）
	if mode == "leaf" or mode == "wood":
		fresh.set_meta("cull_mode", CULL_DISABLED if _is_double_sided(m) else 0)
		fresh.set_meta("cull_shader", "ds(双面)" if _is_double_sided(m) else "单面")
	if ResourceSaver.save(fresh, p) != OK:
		push_warning("[燃烧开关] 写回失败 ✗ %s" % p)
		return
	fresh.take_over_path(p)
	print("[燃烧开关] %s ✓ %s → %s（树高 %.1f 米 ✓）" % [
			"无燃烧" if mode == "none" else ("叶片型" if mode == "leaf" else "木质型"),
			p.get_file(), fresh.get_class(), height])


## ★ 源材质是否双面 ✓（StandardMaterial3D.cull_mode == 2 ✓；ShaderMaterial 看 render_mode 文本 ✓）
func _is_double_sided(m: Material) -> bool:
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).cull_mode == CULL_DISABLED
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		if sm.shader != null:
			return sm.shader.code.contains("cull_disabled")
	return false


func _color_of(m: Material) -> Color:
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).albedo_color
	if m is ShaderMaterial:
		var tv: Variant = (m as ShaderMaterial).get_shader_parameter("base_color")
		if tv is Color:
			return tv as Color
	return Color(1, 1, 1, 1)


func _scissor_of(m: Material) -> float:
	if m is BaseMaterial3D:
		var b := m as BaseMaterial3D
		if b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			return b.alpha_scissor_threshold
		return 0.5
	if m is ShaderMaterial:
		var tv: Variant = (m as ShaderMaterial).get_shader_parameter("alpha_scissor")
		if tv is float:
			return tv as float
	return 0.5


func _albedo_of(m: Material) -> Texture2D:
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).albedo_texture
	if m is ShaderMaterial:
		var tv: Variant = (m as ShaderMaterial).get_shader_parameter("albedo_tex")
		if tv is Texture2D:
			return tv as Texture2D
	return null


func _normal_of(m: Material) -> Texture2D:
	if m is BaseMaterial3D:
		var b := m as BaseMaterial3D
		if b.normal_enabled:
			return b.normal_texture
		return null
	if m is ShaderMaterial:
		var tv: Variant = (m as ShaderMaterial).get_shader_parameter("normal_tex")
		if tv is Texture2D:
			return tv as Texture2D
	return null


func _rough_of(m: Material) -> Texture2D:
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).roughness_texture
	if m is ShaderMaterial:
		var tv: Variant = (m as ShaderMaterial).get_shader_parameter("rough_tex")
		if tv is Texture2D:
			return tv as Texture2D
	return null


## ★ 叶片贴图对（albedo, alpha）✓ —— 并修正"遮罩图被当成 albedo"这个坑 ✓
##   源 albedo 若形如 `..._alpha_4k.png`（其实是遮罩 ✓）→
##     albedo 改成同前缀的 `..._diff_4k.png`（存在才换 ✓）；遮罩交给 alpha_tex ✓
func _leaf_textures(m: Material) -> Dictionary:
	var alb := _albedo_of(m)
	var alp: Texture2D = null
	if m is ShaderMaterial:
		var tv: Variant = (m as ShaderMaterial).get_shader_parameter("alpha_tex")
		if tv is Texture2D:
			alp = tv as Texture2D
	if alb == null:
		return {"albedo": null, "alpha": alp}
	var path := String(alb.resource_path)
	var low := path.to_lower()
	if low.contains("alpha") or low.contains("mask"):
		# ★ 当前 albedo 其实是遮罩 → 它当 alpha_tex ✓，albedo 换成同前缀的 diff ✓
		if alp == null:
			alp = alb
		var diff := path.replace("alpha", "diff").replace("mask", "diff")
		if diff != path and ResourceLoader.exists(diff):
			var dt := load(diff) as Texture2D
			if dt != null:
				return {"albedo": dt, "alpha": alp}
		push_warning("[燃烧开关] 只找到遮罩图、没找到对应的 diff 图 ✗ %s" % path)
	return {"albedo": alb, "alpha": alp}
