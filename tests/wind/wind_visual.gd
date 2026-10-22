extends Node3D
## ============================================================================
## fast-tree 风摆 · 视觉证据（真渲染，0.5 秒三帧截图）
## ============================================================================
## 场景：一棵 big_sakura_tree + Camera3D + DirectionalLight3D + 本脚本。
## 做法：
##   1) 找出树的所有 ShaderMaterial（树皮/叶/花，树冠分块后共用同一材质实例）
##   2) 写入**固定**风参（不读 Weather / 不读 wind.gd，保证可复现）
##   3) 相机按树 AABB 自动取景（整棵树在画面内：树冠在上半部、树干根在底部窄条）
##   4) 等真实时间 0 / 0.25 / 0.5 秒各截一帧 -> res://.runtime/wind_port/shots/
##      ⚠ 着色器里的动画时钟是内置 `TIME`（不是 uniform），所以只能靠**真实经过时间**推进；
##        每次截帧都 await RenderingServer.frame_post_draw，保证截到的是当前帧。
##
## 用法（必须**非 headless**，dummy 渲染器截不到图）：
##   & 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --path . \
##       res://tests/wind/wind_visual.tscn --quit-after 1200
## 产物：.runtime/wind_port/shots/t0.png / t0_25.png / t0_5.png
## 之后由 tests/wind/diff_visual.py 做像素差分统计。
## ============================================================================

## 截帧时刻（秒，相对场景就绪）
const CAPTURE_TIMES := [0.0, 0.25, 0.5]
const OUT_DIR := "res://.runtime/wind_port/shots"

## 固定风场（量级：wind_force 单位是米，这里取 0.5 m 让肉眼/像素差分都明确）
const WIND := {
	"wind_enabled": true,
	"wind_direction": Vector2(0.8660254, 0.5),   # 30°
	"wind_force": 0.5,
	"wind_speed": 1.4,
	"wind_frequency": 1.0,
	"wind_gust": 0.2,
	"wind_turbulence": 0.25,
	"wind_gust_speed": 0.16,
	"wind_spatial_scale": 0.22,
	"wind_bias": 0.3,
	"wind_flex_falloff": 1.5,
	"wind_seed": 0.0,
}

const BARK_WIND := {"wind_is_leaf": false, "wind_sway": 0.8, "wind_leaf_flutter": 0.0, "wind_leaf_twist": 0.0}
const LEAF_WIND := {"wind_is_leaf": true, "wind_sway": 1.0, "wind_leaf_flutter": 0.6, "wind_leaf_twist": 0.5}

## 取景距离倍率：1.0 = 保守地让整个 AABB 都在画面内（树只占 ~58% 高度）；
## 0.68 = 放大到树几乎撑满画面（树冠在上半部、树干根部贴近底部窄条），
## 边缘会裁掉少量垂枝，但**树干根部必须完整可见**（像素差分要用）。
@export var camera_distance_scale := 0.68

var _materials: Array[ShaderMaterial] = []
var _shots: Array = []


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("[visual] 当前是 headless（dummy 渲染器），截不到画面；请去掉 --headless 再跑")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_setup_light()
	# 树冠分块（CanopyCull）在子节点 _ready 里完成，等两帧后再取景/收材质
	_run.call_deferred()


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var aabb := _tree_aabb()
	_setup_camera(aabb)
	_apply_fixed_wind()
	print("[visual] viewport=%s  tree_aabb(pos=%s size=%s)" % [
			str(get_viewport().get_visible_rect().size), str(aabb.position), str(aabb.size)])
	print("[visual] camera pos=%s fov=%.0f  materials=%d  shots=%s" % [
			str($Camera3D.global_position), $Camera3D.fov, _materials.size(), str(CAPTURE_TIMES)])

	var t0 := Time.get_ticks_msec()
	for i in CAPTURE_TIMES.size():
		var target := float(CAPTURE_TIMES[i])
		# 用帧轮询等到"真实经过时间 >= 目标"，比 SceneTreeTimer 更准（不会提前 1~2 帧）
		while float(Time.get_ticks_msec() - t0) / 1000.0 < target:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if img == null:
			push_error("[visual] viewport.get_image() 返回 null（渲染器不可用？）")
			get_tree().quit(3)
			return
		var shot_name := String(["t0", "t0_25", "t0_5"][i])
		var path := OUT_DIR + "/" + shot_name + ".png"
		var t_shot := float(Time.get_ticks_msec() - t0) / 1000.0
		var err := img.save_png(ProjectSettings.globalize_path(path))
		if err != OK:
			push_error("[visual] save_png 失败 %s err=%d" % [path, err])
			get_tree().quit(4)
			return
		var c_mid := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
		var c_top := img.get_pixel(img.get_width() / 2, 8)
		var c_bot := img.get_pixel(img.get_width() / 2, img.get_height() - 8)
		_shots.append({"name": shot_name, "path": path, "t": t_shot,
				"size": img.get_size(), "center": str(c_mid), "top": str(c_top), "bottom": str(c_bot)})
		print("[visual] shot %-6s t=%.3fs  %dx%d  mid=%s top=%s bottom=%s -> %s" % [
				shot_name, t_shot, img.get_width(), img.get_height(), str(c_mid), str(c_top), str(c_bot), path])
	print("[visual] done: %d shots" % _shots.size())
	await get_tree().process_frame
	get_tree().quit(0)


# ============================================================================
# 场景配置
# ============================================================================

func _setup_light() -> void:
	var l := $DirectionalLight3D as DirectionalLight3D
	l.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	l.light_energy = 1.25
	# 关阴影：树冠动起来的阴影会投到树干上，把"树干没动"这个结论搅浑（只关心几何位移）
	l.shadow_enabled = false


## 按整棵树 AABB 自动取景（解析求解最小距离：所有角点的水平/垂直视角都进画面）
func _setup_camera(aabb: AABB) -> void:
	var cam := $Camera3D as Camera3D
	var center := aabb.get_center()
	var mn := aabb.position
	var mx := aabb.end
	var dir := Vector3(0.38, 0.03, 1.0).normalized()   # 从右前方、几乎水平地看
	var forward := -dir
	var right := forward.cross(Vector3.UP).normalized()
	var up := right.cross(forward).normalized()
	var aspect := get_viewport().get_visible_rect().size.x / get_viewport().get_visible_rect().size.y
	var tan_v := tan(deg_to_rad(cam.fov * 0.5))
	var tan_h := tan_v * aspect
	var margin := 1.06   # 四周留 6% 边
	var dist := 0.0
	var span_w := 0.0
	var span_h := 0.0
	for i in 8:
		var c := Vector3(
			mn.x if (i & 1) == 0 else mx.x,
			mn.y if (i & 2) == 0 else mx.y,
			mn.z if (i & 4) == 0 else mx.z)
		var r := c - center
		var along := r.dot(dir)              # >0 表示在中心靠相机一侧
		var x := absf(r.dot(right))
		var y := absf(r.dot(up))
		span_w = maxf(span_w, x)
		span_h = maxf(span_h, y)
		dist = maxf(dist, x * margin / tan_h + along)
		dist = maxf(dist, y * margin / tan_v + along)
	dist = maxf(dist * camera_distance_scale, 1.0)
	cam.position = center + dir * dist
	cam.look_at(center, Vector3.UP)
	cam.far = maxf(400.0, dist * 4.0)
	print("[visual] camera fit distance=%.2f  角点半宽=%.2f 半高=%.2f  tan_v=%.3f tan_h=%.3f" % [
			dist, span_w, span_h, tan_v, tan_h])


## 收集树的所有 ShaderMaterial（分块树冠共用同一实例，按 instance_id 去重），
## 写入固定风参 + 材质级开关（树皮 / 叶花分开）。
func _apply_fixed_wind() -> void:
	var seen := {}
	var bark_n := 0
	var leaf_n := 0
	for mi in _all_mesh_instances($Tree):
		var mat: Material = mi.material_override
		if mat == null and mi.get_surface_override_material_count() > 0:
			mat = mi.get_surface_override_material(0)
		if mat == null:
			mat = mi.mesh.surface_get_material(0) if (mi.mesh != null and mi.mesh.get_surface_count() > 0) else null
		if not (mat is ShaderMaterial):
			continue
		var sm := mat as ShaderMaterial
		if seen.has(sm.get_instance_id()):
			continue
		seen[sm.get_instance_id()] = true
		# 材质级参数（isLeaf / sway / flutter / twist）由材料自身语义决定：
		#   树皮 -> BARK_WIND；叶/花 -> LEAF_WIND。判定依据是 shader 路径：
		var is_leaf_mat := String(sm.shader.resource_path).contains("tree_leaves_burn")
		var per := LEAF_WIND if is_leaf_mat else BARK_WIND
		for k in WIND.keys():
			sm.set_shader_parameter(k, WIND[k])
		for k in per.keys():
			sm.set_shader_parameter(k, per[k])
		_materials.append(sm)
		if is_leaf_mat:
			leaf_n += 1
		else:
			bark_n += 1
	print("[visual] materials: bark=%d leaf=%d (unique=%d)" % [bark_n, leaf_n, _materials.size()])


# ============================================================================
# 小工具
# ============================================================================

func _all_mesh_instances(root: Node) -> Array:
	var out: Array = []
	var st: Array = [root]
	while not st.is_empty():
		var n: Node = st.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			st.append(c)
	return out


func _tree_aabb() -> AABB:
	var aabb := AABB()
	var first := true
	for mi in _all_mesh_instances($Tree):
		if mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		if first:
			aabb = b
			first = false
		else:
			aabb = aabb.merge(b)
	return aabb
