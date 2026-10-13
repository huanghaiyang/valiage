# grass.gd
# This file is part of: SimpleGrassTextured
# Copyright (c) 2023 IcterusGames
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the 
# "Software"), to deal in the Software without restriction, including 
# without limitation the rights to use, copy, modify, merge, publish, 
# distribute, sublicense, and/or sell copies of the Software, and to 
# permit persons to whom the Software is furnished to do so, subject to 
# the following conditions: 
#
# The above copyright notice and this permission notice shall be 
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

@tool
extends MultiMeshInstance3D

## Define your custom mesh per grass, you can open a .obj, .mesh, etc, or can 
## copy paste your own mesh from any mesh component. Set as null for default 
## SimpleGrassTextured mesh.
@export var mesh : Mesh = null : set = _on_set_mesh
## ★ 本项目改动：内置草叶的**面数**（1~6 面）。仅在 `mesh` 为空（用内置网格）时生效。
##   1 面 = 单片（最省，适合超远/密植）；2 面 = 十字（插件原始行为，默认）；
##   3 面 = 互成 60° 的三片；4/5/6 面 = 更密的扇形分布（俯视/斜视时草更"厚"）。
##   顶点数：每面 4 个顶点（2 个三角形），所以 1~6 面对应 4~24 个顶点。
##   面数越多，同一株草在各观察方向上的覆盖越均匀，但顶点/填充开销也越大。
##   ⚠ 提示串与标签都写在这里，Inspector 里才会显示中文（与工具栏下拉一致）。
@export_enum("1 面", "2 面", "3 面", "4 面", "5 面", "6 面") var mesh_planes := 2 : set = _on_set_mesh_planes

## ★★ 本项目改动：内置草叶的 **V 字张开**（解决"从顶部看还是纸片"）
##
## 【为什么平卡从上面看是纸片】
##   原来的每面是**竖直平面**（平面里同时含 UP）。从正上方看时视线就是 -UP，
##   而 -UP **躺在这个平面内** -> 正好侧对视线 -> 投影面积 = 0，只剩一条线。
##
## 【做法：每面变成两片、从底部向两侧张开成 V】
##   两片都从同一个底边（nrm 偏移 0）出发，顶部沿 ±法线 各偏开 spread 米，
##   于是每片的平面变成 span(right, UP ± spread·nrm) —— **不再包含 UP**，
##   从上方投影就有面积了。两片从侧面看正好是一个 V。
##
## 【等价性】spread = 0（或关掉开关）时退化为原来的单片竖直卡，逐值一致。
## 【代价】每面 2 片 -> 顶点/三角形翻倍（1~6 面对应 8~48 顶点）。
##   ⚠ 名字**不带 `sgt_` 前缀**是故意的：插件在 _get_property_list() 里把所有 `sgt_`
##     变量设成 PROPERTY_USAGE_NO_EDITOR，带前缀就会从 Inspector 里消失、没法调。
##     与 `mesh_planes` 保持一致（它也是无前缀 + @export）。
@export var v_fold := true : set = _on_set_v_fold
## 顶部水平张开量（米）：0 = 原平卡；越大从上方看越"厚"，侧面越张开。
##   0.4~0.6 比较自然（草高 1 米时约张开 22°~31°）。
@export_range(0.0, 1.5, 0.05) var v_spread := 0.45 : set = _on_set_v_spread

@export_category("Material settings")
## Color albedo for mesh material
@export_color_no_alpha var albedo := Color.WHITE : set = _on_set_albedo
## Texture albedo for mesh, you can apply normal, metallic and roughness 
## textures on the "Material parameters" section
@export var texture_albedo : Texture = preload("res://addons/simplegrasstextured/textures/grassbushcc008.png") : set = _on_set_texture_albedo
@export_group("Material parameters")
## Lets you setup a multi texture image by frames
@export var texture_frames : Vector2i = Vector2i(1, 1) : set = _on_set_texture_frames;
## Defines the texture image alpha threshold
@export_range(0.0, 1.0) var alpha_scissor_threshold := 0.5 : set = _on_set_alpha_scissor_threshold
## Ilumination mode[br]
## [b]Lambert[/b][br]Recomended for complex meshes such as flowers[br][br]
## [b]Normal grass[/b][br]The lighting will be calculated by the inclination of 
## the grass, recommended for very simple meshes[br][br]
## [b]Unshaded[/b][br]No lighting will affect the grass
@export_enum("Lambert", "Normal grass", "Unshaded") var light_mode := 1 : set = _on_set_light_mode
@export_enum("Nearest", "Linear", "Nearest mipmap", "Linear mipmap") var texture_filter := 3 : set = _on_set_texture_filter
@export_subgroup("Normal")
@export var texture_normal : Texture = null : set = _on_set_texture_normal
@export_range(-16.0, 16.0) var normal_scale := 1.0 : set = _on_set_normal_scale
@export_subgroup("Metallic")
@export var texture_metallic : Texture = null : set = _on_set_texture_metallic
@export_enum("Red","Green","Blue","Alpha","Gray") var metallic_texture_channel : int = 0 : set = _on_set_metallic_texture_channel
@export_range(0.0, 1.0) var metallic := 0.0 : set = _on_set_metallic
@export_range(0.0, 1.0) var specular := 0.5 : set = _on_set_specular
@export_subgroup("Roughness")
@export var texture_roughness : Texture = null : set = _on_set_texture_roughness
@export_enum("Red","Green","Blue","Alpha","Gray") var roughness_texture_channel : int = 0 : set = _on_set_roughness_texture_channel
@export_range(0.0, 1.0) var roughness := 1.0 : set = _on_set_roughness
@export_group("")
@export_category("Grass settings")
## Scale height factor of all the grass
@export var scale_h := 1.0 : set = _on_set_scale_h
## Scale width factor of all the grass
@export var scale_w := 1.0 : set = _on_set_scale_w
## Scale variable factor, scale of random grasses will be affected by this 
## factor
@export var scale_var := -0.25 : set = _on_set_scale_var
## Defines the strength of this grass, with large values ​​the grass will not be 
## moved by the wind, for example a bamboo can be 0.9 (it will almost not be 
## affected by the wind), and a tall grass can be 0.2 (very affected by the 
## wind)
@export_range(0.0, 1.0) var grass_strength := 0.55 : set = _on_set_grass_strength
## If true, this grass will be in "interactive mode", that means if an object 
## is near the grass, the grass will react and move.[br][br]
## [b]To setup the "interactive mode":[/b][br]
## 1. You must enable by code on the begin of your scene by call 
## [code]SimpleGrass.set_interactive(true)[/code][br]
## 2. Setup your objects to be visible on the Visual Layer 17[br]
## 3. Update the SimpleGrassTexture camera position by calling 
## [code]SimpleGrass.set_player_position()[/code] regulary (on your _process 
## function by example)[br][br]
## [b]You can see how to enable "interactive mode" on:[/b][br]
## [url]https://github.com/IcterusGames/SimpleGrassTextured?tab=readme-ov-file#how-to-enable-interactive-mode[/url]
@export var interactive : bool = true : set = _on_set_interactive
@export_group("Advanced")
## Allows you to define how much the grass will react to objects on axis X and Z
@export var interactive_level_xz : float = 3.0 : set = _on_set_interactive_level_xz
## Allows you to define how much the grass will react to objects on axis Y
@export var interactive_level_y : float = 0.3 : set = _on_set_interactive_level_y
## Locks the scale node of SimpleGrassTextured to 1
@export var disable_node_scale := true : set = _on_set_disable_node_scale
## Disable the ability to rotate the SimpleGrassTextured node
@export var disable_node_rotation := true : set = _on_set_disable_node_rotation
@export_group("Optimization")
@export var optimization_by_distance := false : set = _on_set_optimization_by_distance
@export var optimization_level := 7.0 : set = _on_set_optimization_level
@export var optimization_dist_min := 10.0 : set = _on_set_optimization_dist_min
@export var optimization_dist_max := 50.0 : set = _on_set_optimization_dist_max
@export_group("Height Map Data")
## This is the baked height map of this grass, this will speed up the load of 
## the scene. To setup this variable use the menu 
## SimpleGrassTextured->"Bake height map" on the Editor 3D
@export var baked_height_map : Image = null
@export_group("Draw Collision Mask")
## This is the collision mask for drawing, this allows you to define what your 
## terrain collision mask is, that way it will be easier to draw your grass.
@export_flags_3d_physics var collision_mask :int = 4294967295

var sgt_radius := 2.0
var sgt_density := 25
var sgt_scale := 1.0
var sgt_rotation := 0.0
var sgt_rotation_rand := 1.0
var sgt_dist_min := 0.25
## ★★ 本项目新增：跨节点去重开关。
##   多个 SGT 节点覆盖同一片区域时，各自独立放置 -> 草会叠加（密度/drawcall 翻倍、z-fighting）。
##   打开后，放置时会把"与**场景树中排在本节点之前**的其他 SGT 节点重复"的实例剔掉。
##   树序优先：前面的节点说了算，后面的让路 —— 结果稳定、可预测。
var sgt_cross_node_dedup := true
## ★ 跨节点去重**日志开关**：只有真的剔掉了草才打印，且累计节流（见 XN_LOG_INTERVAL_MS）。
##   拖拽涂抹时嫌刷屏就把它设 false。
var sgt_cross_node_dedup_log := true
## 日志节流间隔（毫秒）：拖拽时 add_grass_batch 每帧都调，不节流会刷屏
const XN_LOG_INTERVAL_MS := 500

var sgt_follow_normal := false
var sgt_slope := Vector2(0, 45)
var sgt_tool_shape := {}

var temp_dist_min := 0.0

var _default_mesh : Mesh = load("res://addons/simplegrasstextured/default_mesh.tres")
## ★ 本项目改动：插件原版内置网格（2 面十字），供生成与比对使用
const BUILTIN_MESH_PATH := "res://addons/simplegrasstextured/default_mesh.tres"
## ★ 生成网格的**共享资源路径**。必须落盘成资源文件，不能在代码里 new 一个内联网格：
##   外部 MultiMesh（maps/*_grass.res）保存时会把内联网格**复制进自己文件里**
##   （表现为 res://maps/xxx_grass.res::ArrayMesh_yyyy），于是每换一次面数，
##   所有引用它的 .res 都被改写、体积按"网格副本"膨胀。
const GENERATED_MESH_DIR := "res://addons/simplegrasstextured/generated"
var _buffer_add : Array[Transform3D] = []
## ★ 跨节点去重：本节点实例的**世界坐标** + xz 网格索引（惰性构建，只作为候选筛）
var _xn_world := PackedVector3Array()
var _xn_grid : Dictionary = {}
var _xn_cell := 0.0
var _xn_built_count := -1
var _xn_dirty := true
## ★ 缓存的"排在本节点之前的 SGT 节点"列表（树序优先用）
var _xn_earlier : Array = []
## ★ 跨节点去重日志的累计量（节流用）
var _xn_log_removed := 0
var _xn_log_batches := 0
var _xn_log_blockers : Dictionary = {}
var _xn_log_last_ms := 0
var _material := load("res://addons/simplegrasstextured/materials/grass.tres").duplicate() as ShaderMaterial
var _force_update_multimesh := false
var _properties : Array[Dictionary] = []
var _node_height_map = null
var _singleton = null


func _init():
	if Engine.is_editor_hint():
		if collision_mask == pow(2, 32) - 1:
			collision_mask = ProjectSettings.get_setting("SimpleGrassTextured/General/default_terrain_physics_layer", pow(2, 32) -1)
		for var_i in get_property_list():
			if not var_i.name.begins_with("sgt_"):
				continue
			_properties.append({
				"name": var_i.name,
				"type": var_i.type,
				"usage": PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_SCRIPT_VARIABLE,
			})


## ★ 本项目改动：统一在这里创建 MultiMesh，并在**创建时**打开 use_custom_data ——
##   这是 INSTANCE_CUSTOM 能送进着色器的前提（运行时再改会被 Godot 拒绝）。
##   逐实例燃烧（火焰灼烧烧草丛）依赖它，见 scripts/vfx/foliage_burn.gd。
func _new_multimesh() -> MultiMesh:
	var mm := MultiMesh.new()
	mm.use_custom_data = true
	return mm


func _ready():
	# ★ 本项目改动（不属于插件原版）：把每一片草丛注册到 "burnable" 组，
	#   让「火焰灼烧」能按组找到植被并点燃（见 scripts/spells/flame_scorch.gd::_find_vegetation）。
	#   将来升级/重装这个插件时，这一行需要重新补上。
	if not is_in_group("burnable"):
		add_to_group("burnable")
	if Engine.is_editor_hint():
		set_process(true)
	else:
		set_process(false)
	_singleton = get_node("/root/SimpleGrass")
	# ★ 本项目改动：按 mesh_planes 生成内置网格（场景里存的 mesh_planes 在这里生效）
	_rebuild_default_mesh()
	if not has_meta(&"SimpleGrassTextured"):
		set_meta(&"SimpleGrassTextured", "2.0.5")
	else:
		if get_meta(&"SimpleGrassTextured") == "1.0.2":
			# New default mesh update tangents
			set_meta(&"SimpleGrassTextured", "2.0.3")
			_force_update_multimesh = true
			if multimesh != null:
				if mesh != null:
					multimesh.mesh = mesh
				else:
					multimesh.mesh = _default_mesh
		if get_meta(&"SimpleGrassTextured") == "2.0.3":
			set_meta(&"SimpleGrassTextured", "2.0.5")
			disable_node_scale = false
			disable_node_rotation = false
	
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
	if mesh != null:
		# 用户自定义网格：尊重它（只在没网格时补上）
		if multimesh.mesh == null:
			multimesh.mesh = mesh
	elif _v_active() or multimesh.mesh == null:
		# ★ 开 V 字时必须**强制同步**内置网格：
		#   场景 / 外部 maps/*_grass.res 里存的是**旧网格（平卡）**，
		#   只判 `multimesh.mesh == null` 的话永远不会覆盖 -> V 字不生效。
		multimesh.mesh = _default_mesh
	_update_material_shader()
	
	if Engine.is_editor_hint():
		if _material.get_reference_count() > 1:
			_material = _material.duplicate()
	
	material_override = _material
	
	set_disable_scale(disable_node_scale)
	if disable_node_rotation:
		set_notify_transform(true)
	update_all_material()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		if disable_node_rotation and global_rotation != Vector3.ZERO:
			var prev_scale := scale
			global_rotation = Vector3.ZERO
			scale = prev_scale


func update_all_material():
	_on_set_albedo(albedo)
	_on_set_texture_albedo(texture_albedo)
	_on_set_alpha_scissor_threshold(alpha_scissor_threshold)
	_on_set_light_mode(light_mode)
	_on_set_texture_normal(texture_normal)
	_on_set_normal_scale(normal_scale)
	_on_set_texture_metallic(texture_metallic)
	_on_set_metallic_texture_channel(metallic_texture_channel)
	_on_set_metallic(metallic)
	_on_set_specular(specular)
	_on_set_texture_roughness(texture_roughness)
	_on_set_roughness_texture_channel(roughness_texture_channel)
	_on_set_roughness(roughness)
	_on_set_scale_h(scale_h)
	_on_set_scale_w(scale_w)
	_on_set_scale_var(scale_var)
	_on_set_grass_strength(grass_strength)
	_on_set_interactive(interactive)
	_on_set_interactive_level_xz(interactive_level_xz)
	_on_set_interactive_level_y(interactive_level_y)
	_on_set_optimization_by_distance(optimization_by_distance)
	_on_set_optimization_level(optimization_level)
	_on_set_optimization_dist_min(optimization_dist_min)
	_on_set_optimization_dist_max(optimization_dist_max)


func _enter_tree():
	if interactive:
		_update_height_map.call_deferred()


func _exit_tree():
	if _node_height_map:
		_node_height_map.queue_free()
		_node_height_map = null


func _process(_delta : float):
	if _buffer_add.size() != 0 or _force_update_multimesh:
		_force_update_multimesh = false
		_update_multimesh()


## ★★ 本项目改动：按面数生成内置草叶网格。
##   沿用插件默认网格的约定（已实测 default_mesh.tres 的逐顶点数据）：
##     · 单片竖直 1×1，底面在 y=0，水平居中（AABB = (-0.5,0,-0.5,1,1,1)）
##     · 面片 k 绕 Y 轴旋转 θk = k·π/planes，法线朝向面片正面
##     · 切线取"面片被旋转后的右方向"，UV 与默认网格逐值一致
##     · 索引绕序沿用默认网格（着色器都是 cull_disabled，绕序不影响可见性）
##   面数 2 时与插件自带 default_mesh.tres 等价。
func _build_plane_mesh(planes: int) -> ArrayMesh:
	planes = clampi(planes, 1, 6)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	var v_on := _v_active()
	var spread := clampf(v_spread, 0.0, 2.0)
	for k in range(planes):
		# 面片 k：绕 Y 轴旋转 θk = 2π·k/planes（面片是"直线"，所以 2 面时就是十字）
		# ⚠ Godot 的 Vector3.cross() 是**左手系**：UP.cross((1,0,0)) == (0,0,-1)，
		#   与数学上的右手叉乘符号相反（已实测确认）。所以要拿"朝正面"的法线必须写
		#   right.cross(UP) —— 这也正好与插件自带 default_mesh 的约定逐值一致：
		#   自带网格 面1 的 n=(-1,0,0) / right=(0,0,-1) 满足 right.cross(UP)=(-1,0,0) ✓
		var ang := TAU * float(k) / float(planes)
		var right := Vector3(cos(ang), 0.0, -sin(ang))    # 面片被旋转后的"右"
		var nrm := right.cross(Vector3.UP)                # 面片正面法线
		if not v_on:
			# ── 原行为：单片竖直卡（spread=0 时与下面 V 路径逐值一致）
			_add_card(verts, normals, tangents, uv, indices,
					right, nrm, Vector3.ZERO)
		else:
			# ── V 字：两片从同一底边向 ±法线 张开
			#   片 A 顶部偏向 +nrm，片 B 偏向 -nrm；两片在底部重合 -> 侧看是个 V
			#   法线取**朝外**那一侧（远离另一片），否则张开后两片一侧会变暗
			_add_card(verts, normals, tangents, uv, indices,
					right, nrm, nrm * spread)
			_add_card(verts, normals, tangents, uv, indices,
					right, nrm, -nrm * spread)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## ★ 往数组里追加"一片卡"。
##   top_shift：顶部相对底部的水平偏移（米）。0 = 竖直片（原行为）；
##              ±nrm*spread = 向该侧张开的一片。
##   顶点顺序 / UV / 绕序都沿用插件自带网格的约定（默认网格逐值一致）。
##
##   高度恒为 1.0：顶点的 y 只取 0 与 1（top_shift 是**水平**偏移，不含 y 分量）。
##   这点很重要 —— 高度闸门 / 脚底圈都依赖 get_aabb().size.y == 1.0。
func _add_card(verts : PackedVector3Array, normals : PackedVector3Array,
		tangents : PackedFloat32Array, uv : PackedVector2Array,
		indices : PackedInt32Array, right : Vector3, nrm : Vector3,
		top_shift : Vector3) -> void:
	var base := verts.size()
	# 从底到顶的方向：竖直 + 顶部水平偏移
	var up_dir := Vector3.UP + top_shift
	# 该片法线：垂直于 (right, up_dir)，朝"外侧"
	#   ⚠ 不能直接用 right.cross(up_dir) 的正负：张开后两片朝向相反，
	#     必须显式取外侧，否则有一片会背光变暗。
	#   top_shift 沿 nrm 的符号就是"往哪边张"，据此选法线。
	var lean := signf(nrm.dot(top_shift))
	var n := (nrm if lean >= 0.0 else -nrm) - Vector3.UP * top_shift.length()
	n = n.normalized()
	if n.length_squared() < 0.5:
		n = nrm                       # 兜底（理论到不了）
	verts.append(-right * 0.5 + up_dir)   # 0 左上
	verts.append( right * 0.5)            # 1 右下
	verts.append(-right * 0.5)            # 2 左下
	verts.append( right * 0.5 + up_dir)   # 3 右上
	for _i in range(4):
		normals.append(n)
	for _i in range(4):
		tangents.append(right.x); tangents.append(right.y); tangents.append(right.z); tangents.append(1.0)
	uv.append(Vector2(0, 0)); uv.append(Vector2(1, 1)); uv.append(Vector2(0, 1)); uv.append(Vector2(1, 0))
	# 与默认网格相同的两个三角形绕序
	indices.append(base + 0); indices.append(base + 1); indices.append(base + 2)
	indices.append(base + 3); indices.append(base + 1); indices.append(base + 0)


## V 字是否生效（开关打开且张开量 > 0）
func _v_active() -> bool:
	return v_fold and absf(v_spread) > 0.001


## ★ 应用面数：重建内置网格，并让已存在的 MultiMesh 立刻用上新网格
func apply_mesh_planes() -> void:
	_rebuild_default_mesh()
	if _default_mesh == null:
		return
	if mesh != null:
		return    # 用户自定义 mesh 时不覆盖
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
	if multimesh != null:
		multimesh.mesh = _default_mesh
		# ⚠ 不要在这里 surface_set_material()：_default_mesh 可能是**共享资源文件**
		#   （default_mesh.tres / generated/plane_N.tres），那样会把材质写进共享文件、污染其他节点。
		#   用节点级 material_override 就够了（优先级也高于 mesh 自带表面材质）。


func _rebuild_default_mesh() -> void:
	# ⚠ 只有"2 面 + 不张开"才能直接用插件自带网格 —— 那是**平卡**。
	#   开了 V 字还去 load 它，等于白改（这份 .tres 里没有张开后的顶点）。
	if mesh_planes == 2 and not _v_active():
		# 2 面：直接用插件自带的网格，保证与升级前逐值一致（也不产生任何副本）
		_default_mesh = load(BUILTIN_MESH_PATH)
		if _default_mesh == null:
			_default_mesh = _get_shared_plane_mesh(2)
	else:
		_default_mesh = _get_shared_plane_mesh(mesh_planes)


## ★ 共享网格的**缓存路径**：必须把 V 字参数编进去。
##   否则开了 V 字仍会命中旧的平卡 plane_N.tres -> 改了等于没改。
##   不张开时保持老文件名，与已有文件兼容。
func _mesh_cache_path(planes: int) -> String:
	if not _v_active():
		return "%s/plane_%d.tres" % [GENERATED_MESH_DIR, planes]
	return "%s/plane_%d_v%03d.tres" % [
			GENERATED_MESH_DIR, planes, int(round(clampf(v_spread, 0.0, 2.0) * 1000.0))]


## ★ 取"按面数生成"的共享网格资源：优先从磁盘 .tres 载入，没有再生成并保存。
##   这样做是为了让所有草节点引用**同一个资源文件**，外部 MultiMesh（maps/*_grass.res）
##   存的是资源引用而不是内联副本 —— 否则每换一次面数，那些 .res 都会被整体改写。
func _get_shared_plane_mesh(planes: int) -> Mesh:
	planes = clampi(planes, 1, 6)
	var path: String = _mesh_cache_path(planes)
	# 磁盘上已有就直接用（所有节点共享同一资源）
	if ResourceLoader.exists(path):
		var cached = ResourceLoader.load(path)
		if cached is Mesh:
			return cached
	# 没有：生成一份。编辑器里落盘成资源文件，让后续引用都指向它而不是内联副本
	var built := _build_plane_mesh(planes)
	if not Engine.is_editor_hint():
		return built
	var dir := DirAccess.open("res://addons/simplegrasstextured")
	if dir != null and not dir.dir_exists("generated"):
		dir.make_dir("generated")
	var err := ResourceSaver.save(built, path)
	if err == OK:
		# ⚠ EditorInterface 在部分上下文（--script 直接跑等）里不可用，
		#   get_resource_filesystem() 会返回 null -> 直接 .scan() 会报错刷屏。必须判空。
		var efs := EditorInterface.get_resource_filesystem()
		if efs != null:
			efs.scan()
		var saved = ResourceLoader.load(path)
		if saved is Mesh:
			return saved
	push_warning("SimpleGrassTextured: 无法保存共享网格 %s（err=%d），本次用内联网格" % [path, err])
	return built


func _on_set_mesh_planes(value: int) -> void:
	mesh_planes = clampi(value, 1, 6)
	apply_mesh_planes()
	if Engine.is_editor_hint() and is_inside_tree():
		update_configuration_warnings()
		notify_property_list_changed()


## ★ V 字参数一变就重建网格（否则要重开场景才生效）
##   ⚠ setter 里**必须自己赋值**：GDScript 的 `set = f` 只调用 f，不会替你写回字段。
##     两个变量也不能共用同一个 setter —— setter 只拿得到值，分不清是谁被改了。
func _on_set_v_fold(value) -> void:
	v_fold = bool(value)
	_after_v_changed()


func _on_set_v_spread(value) -> void:
	v_spread = clampf(float(value), 0.0, 2.0)
	_after_v_changed()


func _after_v_changed() -> void:
	apply_mesh_planes()
	if Engine.is_editor_hint() and is_inside_tree():
		notify_property_list_changed()


func _get_property_list() -> Array[Dictionary]:
	if _properties == null:
		return []
	return _properties


func eval_grass_transform(pos : Vector3, normal : Vector3, scaled : Vector3, rotated : float) -> Transform3D:
	var trans := Transform3D()
	if abs(normal.z) == 1:
		trans.basis.x = Vector3(1,0,0)
		trans.basis.y = Vector3(0,0,normal.z)
		trans.basis.z = Vector3(0,normal.z,0)
		trans.basis = trans.basis.orthonormalized()
	else:
		trans.basis.y = normal
		trans.basis.x = normal.cross(trans.basis.z)
		trans.basis.z = trans.basis.x.cross(normal)
		trans.basis = trans.basis.orthonormalized()
	trans = trans.rotated_local(Vector3.UP, rotated)
	trans = trans.scaled(scaled)
	trans = trans.translated(pos)
	return trans


func add_grass(pos : Vector3, normal : Vector3, scaled : Vector3, rotated : float):
	var trans := eval_grass_transform(pos, normal, scaled, rotated)
	if sgt_dist_min > 0:
		for trans_prev in _buffer_add:
			if trans.origin.distance_to(trans_prev.origin) <= sgt_dist_min:
				return
		# ★ 跨节点去重（同一套判据）
		if sgt_cross_node_dedup and _is_dup_in_earlier(global_transform * trans.origin, sgt_dist_min):
			return
	_buffer_add.append(trans)


func add_grass_batch(transforms : Array):
	var distmin = temp_dist_min
	if temp_dist_min == 0:
		distmin = sgt_dist_min
	# ★ ① 批次内部先去重（原先没有这一步：同一批里随机撒出的点可能互相重叠）
	#   ⚠ 原实现是"for x in array 的同时 array.erase(x)" —— GDScript 的 for-in 按下标遍历，
	#     删掉当前元素会让后面元素前移、下标继续 +1，于是**跳过下一个元素**（实测漏检）。
	#     这里统一改成"重建数组"，绝不在迭代中改动被迭代的数组。
	if distmin > 0 and transforms.size() > 1:
		transforms = _dedup_self(transforms, distmin)
	# ★ ② 与本节点未提交缓冲去重（同样是重建数组，不边遍历边删）
	if _buffer_add.size() > 0 and distmin > 0:
		transforms = _dedup_against_buffer(transforms, distmin)
	# ★ ③ 跨节点去重：把与"场景树中排在本节点之前"的 SGT 节点重复的实例剔掉
	if sgt_cross_node_dedup and distmin > 0 and transforms.size() > 0:
		transforms = _dedup_across_nodes(transforms, distmin)
	_buffer_add.append_array(transforms)


## 批次内部去重：保留先出现的（重建数组，不在迭代中改动被迭代对象）
func _dedup_self(transforms : Array, distmin : float) -> Array:
	var kept : Array = []
	for trans in transforms:
		var dup := false
		for prev in kept:
			if trans.origin.distance_to(prev.origin) <= distmin:
				dup = true
				break
		if not dup:
			kept.append(trans)
	return kept


## 与本节点 `_buffer_add` 去重
func _dedup_against_buffer(transforms : Array, distmin : float) -> Array:
	var kept : Array = []
	for trans in transforms:
		var dup := false
		for prev in _buffer_add:
			if trans.origin.distance_to(prev.origin) <= distmin:
				dup = true
				break
		if not dup:
			kept.append(trans)
	return kept


# ---------------------------------------------------------------- 跨节点去重
# 目标：多个 SGT 节点覆盖同一区域时，不要让草在同一个位置放两份。
# 规则：**场景树顺序优先** —— 排在前面的节点说了算，后面的节点让路。
#        于是"先建的草地"保留，后建的节点自动避开它，结果稳定可预测。
# 坐标：本节点的实例是**局部**坐标，其他节点也是各自的局部坐标，
#        所以一律先换算到**世界坐标**再比较。

## 把与"树序在本节点之前"的其他 SGT 节点重复的实例剔除
func _dedup_across_nodes(transforms : Array, distmin : float) -> Array:
	var others := _get_earlier_grass_nodes()
	if others.is_empty():
		return transforms
	var xf := global_transform
	var kept : Array = []
	var removed := 0
	var blockers : Dictionary = {}          # 哪个节点挡下了多少株
	for trans in transforms:
		var w : Vector3 = xf * trans.origin
		var blocker := _dup_blocker_in_earlier(w, distmin)
		if blocker == null:
			kept.append(trans)
		else:
			removed += 1
			var bn : String = str((blocker as Node).name)
			blockers[bn] = int(blockers.get(bn, 0)) + 1
	# ★ 只有**真的剔掉了**才记日志（没错就完全不打印，免得拖拽时刷屏）
	if removed > 0:
		_xn_log_accumulate(removed, blockers)
	return kept


## 世界坐标 w 附近是否已有"树序更早"的 SGT 节点放置了草
func _is_dup_in_earlier(w : Vector3, distmin : float) -> bool:
	return _dup_blocker_in_earlier(w, distmin) != null


## 找出"挡下"这株草的更早节点（没有则返回 null）。日志要报告是谁挡的，所以返回节点本身。
func _dup_blocker_in_earlier(w : Vector3, distmin : float) -> Variant:
	for other in _get_earlier_grass_nodes():
		if not is_instance_valid(other):
			continue
		if other.has_method("has_instance_near_world") and other.has_instance_near_world(w, distmin):
			return other
	return null


## ★ 跨节点去重日志：累计到 XN_LOG_INTERVAL_MS 才刷一条。
##   拖拽时 add_grass_batch 每帧都会被调，不节流的话一秒能刷 20 行。
func _xn_log_accumulate(removed : int, blockers : Dictionary) -> void:
	if not sgt_cross_node_dedup_log:
		return
	_xn_log_removed += removed
	_xn_log_batches += 1
	for k in blockers:
		_xn_log_blockers[k] = int(_xn_log_blockers.get(k, 0)) + int(blockers[k])
	var now := Time.get_ticks_msec()
	if _xn_log_last_ms == 0:
		_xn_log_last_ms = now
		return                      # 第一次只记账，满一个间隔再刷
	if now - _xn_log_last_ms < XN_LOG_INTERVAL_MS:
		return
	_xn_log_last_ms = now
	var parts : Array = []
	for k in _xn_log_blockers:
		parts.append("%s×%d" % [k, int(_xn_log_blockers[k])])
	print("[SGT 跨节点去重] %s：%d 批共剔掉 %d 株（与树序更早的节点重复）｜ 挡下它们的是：%s" % [
			name, _xn_log_batches, _xn_log_removed, ", ".join(parts)])
	_xn_log_removed = 0
	_xn_log_batches = 0
	_xn_log_blockers.clear()


## 收集"场景树深度优先顺序中排在本节点之前"的 SGT 节点（缓存）
func _get_earlier_grass_nodes() -> Array:
	# 缓存失效条件：不在树里 / 缓存空 / 缓存里有节点已被释放
	if not is_inside_tree() or get_tree() == null:
		_xn_earlier = []
		return _xn_earlier
	var need_rebuild := _xn_earlier.is_empty()
	if not need_rebuild:
		for nd in _xn_earlier:
			if not is_instance_valid(nd):
				need_rebuild = true
				break
	if not need_rebuild:
		return _xn_earlier
	_xn_earlier = []
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	# 深度优先，遇到自己就停 -> 只留下"排在自己前面"的
	# ⚠ 逆序压栈：pop_back 弹出顺序才与场景树顺序一致
	var stack : Array = [root]
	while not stack.is_empty():
		var nd : Node = stack.pop_back()
		if nd == self:
			break
		if nd is MultiMeshInstance3D and nd != self and nd.has_meta(&"SimpleGrassTextured"):
			_xn_earlier.append(nd)
		var ch := nd.get_children()
		for i in range(ch.size() - 1, -1, -1):
			stack.append(ch[i])
	return _xn_earlier


## ★ 供其他 SGT 节点查询：世界坐标 w 的 dist 半径内，本节点是否已有实例。
##   xz 网格只做**候选筛选**，最终用真实 3D 距离确认（所以陡崖上同 xz 不同高度不会被误判）。
func has_instance_near_world(w : Vector3, dist : float) -> bool:
	_ensure_xn_cache()
	if _xn_cell <= 0.0 or _xn_grid.is_empty():
		return false
	var r : float = maxf(dist, _xn_cell)
	var x0 := floori((w.x - r) / _xn_cell)
	var x1 := floori((w.x + r) / _xn_cell)
	var z0 := floori((w.z - r) / _xn_cell)
	var z1 := floori((w.z + r) / _xn_cell)
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var key := Vector3i(cx, 0, cz)
			if not _xn_grid.has(key):
				continue
			var bucket : PackedInt32Array = _xn_grid[key]
			for idx in bucket:
				if idx < _xn_world.size() and _xn_world[idx].distance_to(w) <= dist:
					return true
	return false


## 标记本节点的实例缓存需要重建（实例被增删后调用）
func invalidate_xn_cache() -> void:
	_xn_dirty = true


## 惰性构建：实例世界坐标 + xz 网格
func _ensure_xn_cache() -> void:
	var n := 0
	if multimesh != null:
		n = multimesh.instance_count
	if not _xn_dirty and _xn_built_count == n:
		return
	_xn_reset_grid(n)
	var xf := global_transform
	for i in range(n):
		# ⚠ headless（dummy 渲染后端）下 MultiMesh 不存实例变换，读回全是原点，
		#   所以自检走 _xn_add_point 直接注入世界坐标来测这套网格。
		_xn_add_point(xf * multimesh.get_instance_transform(i).origin, i)
	_xn_built_count = n
	_xn_dirty = false


## 清空并准备网格（与数据来源解耦，便于自检注入）
func _xn_reset_grid(n: int) -> void:
	_xn_world.resize(n)
	_xn_grid.clear()
	# 网格边长取 dist_min（查询时向四周扩 1 格，正好覆盖 dist_min 半径）
	_xn_cell = maxf(sgt_dist_min, 0.05)


## 把一个实例的世界坐标放进网格
func _xn_add_point(w : Vector3, i : int) -> void:
	_xn_world[i] = w
	var key := Vector3i(floori(w.x / _xn_cell), 0, floori(w.z / _xn_cell))
	if _xn_grid.has(key):
		# ⚠ PackedInt32Array 是**值类型**：从 Dictionary 取出来的是副本，
		#   必须 append 之后**写回**字典，否则同一格子里第 2 个以后的实例全丢
		#   （实测表现：跨节点去重只生效一部分，格子越密漏得越多）。
		var bucket : PackedInt32Array = _xn_grid[key]
		bucket.append(i)
		_xn_grid[key] = bucket
	else:
		var nb := PackedInt32Array()
		nb.append(i)
		_xn_grid[key] = nb


func erase(pos: Vector3, radius: float) -> void:
	if not multimesh.get_aabb().intersects(AABB(pos - Vector3(radius, radius, radius), Vector3(radius, radius, radius) * 2)):
		return
	_apply_erase_tool(func(array: Array[Transform3D]) -> int:
			var num_to_erase := 0
			for i in range(multimesh.instance_count):
				var trans := multimesh.get_instance_transform(i)
				if trans.origin.distance_to(pos) > radius:
					array.append(trans)
				else:
					num_to_erase += 1
			return num_to_erase
	)


func erase_cylinder(rx: float, height: float, rz: float, shape_transform: Transform3D) -> void:
	var aabb := AABB(Vector3(-rx, -height / 2, -rz), Vector3(rx, height / 2, rz) * 2)
	aabb = shape_transform * aabb
	if not (global_transform * multimesh.get_aabb()).intersects(aabb):
		return
	_apply_erase_tool(func(array: Array[Transform3D]) -> int:
			var num_to_erase := 0
			for i in range(multimesh.instance_count):
				var trans := multimesh.get_instance_transform(i)
				var point := global_transform * trans.origin * shape_transform
				var r = (point.x * point.x) / (rx * rx) + (point.z * point.z) / (rz * rz)
				if point.y < -height or point.y > height or r >= 1:
					array.append(trans)
				else:
					num_to_erase += 1
			return num_to_erase
	)


func erase_box(size: Vector3, shape_transform: Transform3D) -> void:
	var aabb := AABB(-size / 2, size)
	if not (global_transform * multimesh.get_aabb()).intersects(shape_transform * aabb):
		return
	_apply_erase_tool(func(array: Array[Transform3D]) -> int:
			var num_to_erase := 0
			for i in range(multimesh.instance_count):
				var trans := multimesh.get_instance_transform(i)
				if not aabb.has_point(global_transform * trans.origin * shape_transform):
					array.append(trans)
				else:
					num_to_erase += 1
			return num_to_erase
	)


## ★ 本项目改动：给「草地实例」停靠面板用的只读接口。
##   面板只读取 MultiMesh 实例数据来统计数量 / 列出坐标，不修改任何东西。
func get_instance_count() -> int:
	if multimesh == null:
		return 0
	return multimesh.instance_count


## 单株草的世界坐标（multimesh 的 transform 是相对本节点的局部坐标）
func get_instance_position(index : int) -> Vector3:
	if multimesh == null:
		return Vector3.ZERO
	if index < 0 or index >= multimesh.instance_count:
		return Vector3.ZERO
	return _instance_local_to_world(multimesh.get_instance_transform(index).origin)


## 越界安全的 transform 读取（面板分帧建行时实例可能已被删除）
func get_instance_transform_safe(index : int) -> Transform3D:
	if multimesh == null:
		return Transform3D()
	if index < 0 or index >= multimesh.instance_count:
		return Transform3D()
	return multimesh.get_instance_transform(index)


## 所有实例的世界坐标（面板一次读回，避免逐株跨脚本查询）
func get_instance_positions() -> Array:
	var out : Array = []
	if multimesh == null:
		return out
	out.resize(multimesh.instance_count)
	for i in range(multimesh.instance_count):
		out[i] = _instance_local_to_world(multimesh.get_instance_transform(i).origin)
	return out


## 节点不在场景树里时 to_global() 会报错，这里统一兜底
func _instance_local_to_world(local_origin : Vector3) -> Vector3:
	if not is_inside_tree():
		return local_origin
	return to_global(local_origin)


## 所有实例的局部 transform 快照（面板需要完整的缩放 / 旋转信息时使用）
func get_instance_snapshot() -> Array:
	var out : Array = []
	if multimesh == null:
		return out
	out.resize(multimesh.instance_count)
	for i in range(multimesh.instance_count):
		out[i] = multimesh.get_instance_transform(i)
	return out


## ★ 本项目改动：按实例下标删除（面板右键删除用）。
##   返回 **[存活实例的 transform 快照, 删除前的 baked_height_map]**，供撤销使用。
##   ★ 为什么存快照而不是存旧的 MultiMesh 对象：
##     当 multimesh 是**外挂资源**（resource_path 非空，例如 res://.../grass_instances.res）时，
##     Godot 的资源缓存对同一路径只保留一个对象 —— 旧的 MultiMesh 和节点替换后的新对象
##     会指向同一个实例，replace_multimesh_with() 里的 take_over_path() 又可能把它同步成
##     节点当前内容，于是「撤销」会退化成「什么都没变」。存成值快照后，撤销时用
##     restore_multimesh_from_snapshot() 重建一个全新对象，就与磁盘/缓存脱钩了。
func delete_instances_by_indices(indices : PackedInt32Array) -> Array:
	if multimesh == null or indices.is_empty():
		return []
	var prev_height_map : Image = baked_height_map
	var remove := {}
	for index in indices:
		remove[index] = true
	var kept : Array[Transform3D] = []
	for i in range(multimesh.instance_count):
		if not remove.has(i):
			kept.append(multimesh.get_instance_transform(i))
	_replace_multimesh_with_transforms(kept)
	return [kept, prev_height_map]


## 用「实例 transform 快照」重建 MultiMesh（撤销用的安全路径：永远新建对象）
func restore_multimesh_from_snapshot(transforms : Array, height_map : Image) -> void:
	_replace_multimesh_with_transforms(transforms)
	baked_height_map = height_map
	if Engine.is_editor_hint():
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO


## 用一个已经建好的 MultiMesh 替换当前 MultiMesh（撤销 / 重做都走这里）
func replace_multimesh_with(multi_new : MultiMesh, height_map : Image) -> void:
	if not is_instance_valid(multi_new):
		return
	if multi_new.instance_count > 0 and multi_new.mesh == null:
		# 罕见：撤销数据里的 MultiMesh 丢了 mesh，退回当前/默认 mesh
		if multimesh != null and multimesh.mesh != null:
			multi_new.mesh = multimesh.mesh
		else:
			multi_new.mesh = mesh if mesh != null else _default_mesh
	if multi_new.instance_count == 0:
		# 空的 MultiMesh 可以安全指定格式（有多实例时不允许改）
		multi_new.transform_format = MultiMesh.TRANSFORM_3D
	if Engine.is_editor_hint() and multimesh != null and multimesh.resource_path.length():
		var path := multimesh.resource_path
		multimesh = multi_new
		multimesh.take_over_path(path)
	else:
		multimesh = multi_new
	baked_height_map = height_map
	if Engine.is_editor_hint():
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO


func _replace_multimesh_with_transforms(transforms : Array) -> void:
	var multi_new := _new_multimesh()
	multi_new.transform_format = MultiMesh.TRANSFORM_3D
	multi_new.mesh = mesh if mesh != null else _default_mesh
	multi_new.instance_count = transforms.size()
	for i in range(transforms.size()):
		multi_new.set_instance_transform(i, transforms[i])
	# ★ 实例被整体替换 -> 跨节点查询缓存失效
	invalidate_xn_cache()
	if Engine.is_editor_hint() and multimesh != null and multimesh.resource_path.length():
		var path := multimesh.resource_path
		multimesh = multi_new
		multimesh.take_over_path(path)
	else:
		multimesh = multi_new
	if Engine.is_editor_hint():
		baked_height_map = null
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO


func snap_to_terrain() -> void:
	await get_tree().physics_frame
	for i in multimesh.instance_count:
		var trans := multimesh.get_instance_transform(i)
		var origin_ws := to_global(trans.origin)
		var rc = _raycast(self, origin_ws + Vector3.UP * 100, Vector3.DOWN, 1000, collision_mask)
		if not rc:
			continue
		trans.origin = to_local(rc["position"])
		var normal : Vector3 = rc["normal"] if sgt_follow_normal else Vector3.UP
		if abs(normal.z) == 1:
			trans.basis.x = Vector3(1, 0, 0)
			trans.basis.y = Vector3(0, 0, normal.z)
			trans.basis.z = Vector3(0, normal.z, 0)
			trans.basis = trans.basis.orthonormalized()
		else:
			trans.basis.y = normal
			trans.basis.x = normal.cross(trans.basis.z)
			trans.basis.z = trans.basis.x.cross(normal)
		multimesh.set_instance_transform(i, trans)
	recalculate_custom_aabb()


static func _raycast(from: Node3D, pos: Vector3, dir: Vector3, dist: float, mask: int) -> Dictionary:
	var space_state = from.get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(pos, pos + dir * dist, mask, [from])
	return space_state.intersect_ray(query)


func _apply_erase_tool(func_tool: Callable):
	var multi_new := _new_multimesh()
	var array : Array[Transform3D] = []
	multi_new.transform_format = MultiMesh.TRANSFORM_3D
	if mesh != null:
		multi_new.mesh = mesh
	else:
		multi_new.mesh = _default_mesh
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	if func_tool.call(array) == 0:
		return
	multi_new.instance_count = array.size()
	for i in range(array.size()):
		multi_new.set_instance_transform(i, array[i])
	if Engine.is_editor_hint() and multimesh.resource_path.length():
		var path := multimesh.resource_path
		multimesh = multi_new
		multimesh.take_over_path(path)
	else:
		multimesh = multi_new
	if Engine.is_editor_hint():
		baked_height_map = null
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO


func auto_center_position():
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	var aabb : AABB = multimesh.get_aabb()
	var center : Vector3 = global_position + aabb.position + (aabb.size / 2)
	var align : Vector3 = global_position - center
	if center == global_position:
		return
	global_position = center
	var multi_new := _new_multimesh()
	multi_new.transform_format = MultiMesh.TRANSFORM_3D
	if mesh != null:
		multi_new.mesh = mesh
	else:
		multi_new.mesh = _default_mesh
	multi_new.instance_count = multimesh.instance_count
	for i in range(multimesh.instance_count):
		var trans := multimesh.get_instance_transform(i)
		trans.origin += align
		multi_new.set_instance_transform(i, trans)
	if Engine.is_editor_hint() and multimesh.resource_path.length():
		var path := multimesh.resource_path
		multimesh = multi_new
		multimesh.take_over_path(path)
	else:
		multimesh = multi_new
	if Engine.is_editor_hint():
		if baked_height_map != null:
			baked_height_map = null
			bake_height_map()
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO
	else:
		baked_height_map = null


func recalculate_custom_aabb():
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	var start := Vector3.ONE * 0x7FFFFFFF
	var end := start * -1
	var mesh_end := multimesh.mesh.get_aabb().end * Vector3(scale_w, scale_h, scale_w)
	for i in range(multimesh.instance_count):
		var trans := multimesh.get_instance_transform(i)
		var point : Vector3 = trans * mesh_end
		if point.x < start.x: start.x = point.x
		if point.y < start.y: start.y = point.y
		if point.z < start.z: start.z = point.z
		point = trans * mesh_end
		if point.x > end.x: end.x = point.x
		if point.y > end.y: end.y = point.y
		if point.z > end.z: end.z = point.z
	custom_aabb.position = start
	custom_aabb.end = end


func _update_multimesh() -> void:
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	var multi_new := _new_multimesh()
	var count_prev := multimesh.instance_count
	multi_new.transform_format = MultiMesh.TRANSFORM_3D
	if mesh != null:
		multi_new.mesh = mesh
	else:
		multi_new.mesh = _default_mesh
	if count_prev > 0 and _buffer_add.size() > 0 and (sgt_dist_min > 0 or temp_dist_min > 0):
		var pos_min := Vector3(10000000, 10000000, 10000000)
		var pos_max := pos_min * -1
		for trans in _buffer_add:
			if pos_min.x > trans.origin.x: pos_min.x = trans.origin.x
			if pos_min.y > trans.origin.y: pos_min.y = trans.origin.y
			if pos_min.z > trans.origin.z: pos_min.z = trans.origin.z
			if pos_max.x < trans.origin.x: pos_max.x = trans.origin.x
			if pos_max.y < trans.origin.y: pos_max.y = trans.origin.y
			if pos_max.z < trans.origin.z: pos_max.z = trans.origin.z
		pos_min -= Vector3.ONE
		pos_max += Vector3.ONE
		var dist_min := temp_dist_min
		if dist_min == 0:
			dist_min = sgt_dist_min
		# ⚠ 原实现是"外层遍历 multimesh、内层 `for trans_add in _buffer_add` 且边遍历边 erase"。
		#   GDScript 的 for-in 按下标遍历：删掉当前元素后后面元素整体前移、下标继续 +1，
		#   于是**跳过下一个元素** -> 该被拒的重复草残留（实测：本批 2 株都该被拒，实际留下 1 株）。
		#   改成"逐株判断、重建保留列表"，绝不在迭代中改动被迭代的数组。
		var keep : Array[Transform3D] = []
		for trans_add in _buffer_add:
			var dup := false
			# 先用批次包围盒把明显不相干的已有实例一次性排掉（原实现用来省时间的加速）
			var ax := trans_add.origin
			if ax.x >= pos_min.x and ax.x <= pos_max.x \
					and ax.y >= pos_min.y and ax.y <= pos_max.y \
					and ax.z >= pos_min.z and ax.z <= pos_max.z:
				for i in range(multimesh.instance_count):
					var trans := multimesh.get_instance_transform(i)
					if trans.origin.x < pos_min.x or trans.origin.x > pos_max.x: continue
					if trans.origin.y < pos_min.y or trans.origin.y > pos_max.y: continue
					if trans.origin.z < pos_min.z or trans.origin.z > pos_max.z: continue
					if trans_add.origin.distance_to(trans.origin) <= dist_min:
						dup = true
						break
			if not dup:
				keep.append(trans_add)
		_buffer_add = keep
		if _buffer_add.size() == 0:
			return
	multi_new.instance_count = count_prev + _buffer_add.size()
	for i in range(multimesh.instance_count):
		multi_new.set_instance_transform(i, multimesh.get_instance_transform(i))
	for i in range(_buffer_add.size()):
		multi_new.set_instance_transform(i + count_prev, _buffer_add[i])
	if Engine.is_editor_hint() and multimesh.resource_path.length():
		var path := multimesh.resource_path
		multimesh = multi_new
		multimesh.take_over_path(path)
	else:
		multimesh = multi_new
	_buffer_add.clear()
	temp_dist_min = 0
	# ★ 实例数变了 -> 跨节点查询缓存失效
	invalidate_xn_cache()
	if Engine.is_editor_hint():
		baked_height_map = null
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO


func _create_height_map_image(local : bool) -> Image:
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	var aabb : AABB = multimesh.get_aabb()
	var img_size := Vector2i(
			clamp(snappedi(aabb.size.x * 4, 32), 32, 128),
			clamp(snappedi(aabb.size.z * 4, 32), 32, 128)
	)
	var img := Image.create(img_size.x, img_size.y, false, Image.FORMAT_RGBA8)
	var relx := float(img_size.x) / aabb.size.x
	var relz := float(img_size.y) / aabb.size.z
	
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	for i in range(multimesh.instance_count):
		var trans : Transform3D = multimesh.get_instance_transform(i)
		trans.origin -= aabb.position
		var x := clampi(int(trans.origin.x * relx), 0, img_size.x)
		var y := clampi(int(trans.origin.z * relz), 0, img_size.y)
		var posy := trans.origin.y + aabb.position.y + 16200.0
		if local:
			posy += global_position.y
		var r := (floorf(posy / 180.0) + 75.0) / 255.0
		var g := (floorf(posy - ((roundf(r * 255.0) - 75.0) * 180.0)) + 75.0) / 255.0
		var b := fmod(absf(posy), 1.0)
		var color := Color(r, g, b, 1.0)
		img.set_pixel(x, y, color)
		for n in range(1, 3):
			if x - n >= 0 and img.get_pixel(x - n, y).a == 0:
				img.set_pixel(x - n, y, color)
				if y - n >= 0 and img.get_pixel(x - n, y - n).a == 0:
					img.set_pixel(x - n, y - n, color)
				if y + n < img_size.y and img.get_pixel(x - n, y + n).a == 0:
					img.set_pixel(x - n, y + n, color)
			if x + n < img_size.x and img.get_pixel(x + n, y).a == 0:
				img.set_pixel(x + n, y, color)
				if y - n >= 0 and img.get_pixel(x + n, y - n).a == 0:
					img.set_pixel(x + n, y - n, color)
				if y + n < img_size.y and img.get_pixel(x + n, y + n).a == 0:
					img.set_pixel(x + n, y + n, color)
			if y - n >= 0 and img.get_pixel(x, y - n).a == 0:
				img.set_pixel(x, y - n, color)
			if y + n < img_size.y and img.get_pixel(x, y + n).a == 0:
				img.set_pixel(x, y + n, color)
	return img


func _local_height_map_to_global(img : Image) -> Image:
	var result : Image = Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	result.fill(Color(0, 0, 0, 0))
	for y in img.get_height():
		for x in img.get_width():
			var color : Color = img.get_pixel(x, y)
			if color.a == 0:
				continue
			var posy : float = (((roundf(color.r * 255.0) - 75.0) * 180.0) + (roundf(color.g * 255.0) - 75.0) + color.b)
			posy += global_position.y
			color.r = (floorf(posy / 180.0) + 75.0) / 255.0
			color.g = (floorf(posy - ((roundf(color.r * 255.0) - 75.0) * 180.0)) + 75.0) / 255.0
			color.b = fmod(absf(posy), 1.0)
			result.set_pixel(x, y, color)
	return result


func bake_height_map() -> void:
	if not Engine.is_editor_hint():
		return
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	await get_tree().process_frame
	var _dummy = multimesh.buffer.size()
	await get_tree().process_frame
	var img : Image = _create_height_map_image(false)
	baked_height_map = img


func clear_all() -> void:
	if multimesh == null:
		multimesh = _new_multimesh()
	if Engine.is_editor_hint() and multimesh.resource_path.length():
		var path := multimesh.resource_path
		multimesh = _new_multimesh()
		multimesh.take_over_path(path)
	else:
		multimesh = _new_multimesh()
	multimesh.mesh = mesh if mesh != null else _default_mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	if Engine.is_editor_hint():
		if baked_height_map != null:
			baked_height_map = null
			bake_height_map()
		custom_aabb.position = Vector3.ZERO
		custom_aabb.end = Vector3.ZERO


func _update_height_map() -> void:
	if Engine.is_editor_hint() or _singleton == null:
		return
	if multimesh == null:
		multimesh = _new_multimesh()
		multimesh.mesh = mesh if mesh != null else _default_mesh
	
	var img : Image = null
	
	if baked_height_map == null:
		await get_tree().process_frame
		var _dummy = multimesh.buffer.size()
		await get_tree().process_frame
		img = _create_height_map_image(true)
	else:
		img = _local_height_map_to_global(baked_height_map)
	
	var aabb : AABB = multimesh.get_aabb()
	var texture := ImageTexture.create_from_image(img)
	if _node_height_map != null:
		_node_height_map.queue_free()
	_node_height_map = MeshInstance3D.new()
	_node_height_map.mesh = PlaneMesh.new()
	_node_height_map.mesh.size = Vector2(aabb.size.x, aabb.size.z)
	var mat = load("res://addons/simplegrasstextured/materials/position.tres").duplicate(true)
	mat.set_shader_parameter("texture_albedo", texture)
	_node_height_map.material_override = mat
	_singleton._height_view.add_child(_node_height_map)
	var align := Vector3(
		(aabb.position.x + (aabb.size.x / 2.0)),
		0,
		(aabb.position.z + (aabb.size.z / 2.0))
	)
	_node_height_map.global_position = global_position + align
	_node_height_map.visible = visible


func _update_material_shader() -> bool:
	var shader_name := "grass"
	if light_mode == 2:
		shader_name += "_unshaded"
	# "Nearest" = 0, "Linear" = 1, "Nearest mipmap" = 2, "Linear mipmap" = 3
	if texture_filter == 0:
		shader_name += "_nearest"
	elif texture_filter == 1:
		shader_name += "_linear"
	elif texture_filter == 2:
		shader_name += "_nearest_mipmap"
	elif texture_filter == 3:
		shader_name += "" # Linear mipmap is the default filter
	if _material.get_shader().resource_path != "res://addons/simplegrasstextured/shaders/" + shader_name + ".gdshader":
		_material.shader = load("res://addons/simplegrasstextured/shaders/" + shader_name + ".gdshader")
		if _material.get_shader() == null:
			_material.shader = load("res://addons/simplegrasstextured/shaders/grass.gdshader")
			_material.shader.take_over_path("res://addons/simplegrasstextured/shaders/" + shader_name + ".gdshader")
		return true
	return false


func _on_set_mesh(value : Mesh):
	mesh = value
	if _material != null:
		if mesh != null:
			_material.set_shader_parameter("grass_size_y", mesh.get_aabb().size.y)
		else:
			_material.set_shader_parameter("grass_size_y", 1.0)
	if Engine.is_editor_hint() and is_inside_tree():
		_update_multimesh()


func _on_set_albedo(value : Color):
	albedo = value;
	if _material != null:
		_material.set_shader_parameter("albedo", albedo)


func _on_set_texture_albedo(value : Texture):
	texture_albedo = value
	if _material != null:
		_material.set_shader_parameter("texture_albedo", texture_albedo)


func _on_set_texture_frames(value : Vector2i):
	texture_frames = value
	if texture_frames.x <= 0:
		texture_frames.x = 1
	if texture_frames.y <= 0:
		texture_frames.y = 1
	if _material != null:
		_material.set_shader_parameter("texture_frames", Vector2(texture_frames.x, texture_frames.y))


func _on_set_light_mode(value : int):
	light_mode = value
	if _material == null:
		return
	if _update_material_shader():
		if multimesh == null:
			multimesh = _new_multimesh()
			multimesh.mesh = mesh if mesh != null else _default_mesh
		if multimesh.mesh != null:
			for isur in range(multimesh.mesh.get_surface_count()):
				multimesh.mesh.surface_set_material(isur, _material)
		update_all_material()
	_material.set_shader_parameter("light_mode", light_mode)


func _on_set_texture_filter(value : int) -> void:
	texture_filter = value
	if _material == null:
		return
	if _update_material_shader():
		if multimesh == null:
			multimesh = _new_multimesh()
			multimesh.mesh = mesh if mesh != null else _default_mesh
		if multimesh.mesh != null:
			for isur in range(multimesh.mesh.get_surface_count()):
				multimesh.mesh.surface_set_material(isur, _material)
		update_all_material()


func _on_set_texture_normal(value : Texture):
	texture_normal = value
	if _material != null:
		_material.set_shader_parameter("texture_normal", texture_normal)


func _on_set_normal_scale(value : float):
	normal_scale = value
	if _material != null:
		_material.set_shader_parameter("normal_scale", normal_scale)


func _on_set_texture_metallic(value : Texture):
	texture_metallic = value
	if _material != null:
		_material.set_shader_parameter("texture_metallic", texture_metallic)


func _on_set_metallic_texture_channel(value : int):
	metallic_texture_channel = value
	if _material != null:
		var channel : Vector4
		if value == 0:
			channel = Vector4(1,0,0,0)
		elif value == 1:
			channel = Vector4(0,1,0,0)
		elif value == 2:
			channel = Vector4(0,0,1,0)
		elif value == 3:
			channel = Vector4(0,0,0,1)
		elif value == 4:
			channel = Vector4(1,1,1,1)
		_material.set_shader_parameter("metallic_texture_channel", channel)


func _on_set_metallic(value : float):
	metallic = value
	if _material != null:
		_material.set_shader_parameter("metallic", metallic)


func _on_set_specular(value : float):
	specular = value
	if _material != null:
		_material.set_shader_parameter("specular", specular)


func  _on_set_texture_roughness(value : Texture):
	texture_roughness = value
	if _material != null:
		_material.set_shader_parameter("texture_roughness", texture_roughness)


func  _on_set_roughness_texture_channel(value : int):
	roughness_texture_channel = value
	if _material != null:
		var channel : Vector4
		if value == 0:
			channel = Vector4(1,0,0,0)
		elif value == 1:
			channel = Vector4(0,1,0,0)
		elif value == 2:
			channel = Vector4(0,0,1,0)
		elif value == 3:
			channel = Vector4(0,0,0,1)
		elif value == 4:
			channel = Vector4(1,1,1,1)
		_material.set_shader_parameter("roughness_texture_channel", channel)


func  _on_set_roughness(value : float):
	roughness = value
	if _material != null:
		_material.set_shader_parameter("roughness", roughness)


func _on_set_alpha_scissor_threshold(value : float):
	alpha_scissor_threshold = value
	if _material != null:
		_material.set_shader_parameter("alpha_scissor_threshold", alpha_scissor_threshold)


func _on_set_scale_h(value : float):
	scale_h = value
	if _material != null:
		_material.set_shader_parameter("scale_h", scale_h)


func _on_set_scale_w(value : float):
	scale_w = value
	if _material != null:
		_material.set_shader_parameter("scale_w", scale_w)


func _on_set_scale_var(value : float):
	scale_var = value
	if _material != null:
		_material.set_shader_parameter("scale_var", scale_var)


func _on_set_grass_strength(value : float):
	grass_strength = value
	if _material != null:
		_material.set_shader_parameter("grass_strength", grass_strength)


func _on_set_interactive(value : bool):
	if interactive == value:
		return
	interactive = value
	if Engine.is_editor_hint():
		return
	if interactive:
		_update_height_map()
	else:
		if _node_height_map != null:
			_node_height_map.queue_free()
			_node_height_map = null
	if _material != null:
		_material.set_shader_parameter("interactive_mode", interactive)


func _on_set_interactive_level_xz(value : float):
	interactive_level_xz = value
	if _material != null:
		_material.set_shader_parameter("interactive_level_xz", interactive_level_xz)


func _on_set_interactive_level_y(value : float):
	interactive_level_y = value
	if _material != null:
		_material.set_shader_parameter("interactive_level_y", interactive_level_y)


func _on_set_disable_node_scale(value : bool) -> void:
	disable_node_scale = value
	if disable_node_scale:
		scale = Vector3.ONE
	set_disable_scale(disable_node_scale)


func _on_set_disable_node_rotation(value : bool) -> void:
	disable_node_rotation = value
	if disable_node_rotation:
		var prev_scale := scale
		global_rotation = Vector3.ZERO
		scale = prev_scale
		set_notify_transform(true)


func _on_set_optimization_by_distance(value : bool):
	optimization_by_distance = value
	if _material != null:
		_material.set_shader_parameter("optimization_by_distance", optimization_by_distance)


func _on_set_optimization_level(value : float):
	optimization_level = value
	if _material != null:
		_material.set_shader_parameter("optimization_level", optimization_level)


func _on_set_optimization_dist_min(value : float):
	optimization_dist_min = value
	if _material != null:
		_material.set_shader_parameter("optimization_dist_min", optimization_dist_min)


func _on_set_optimization_dist_max(value : float):
	optimization_dist_max = value
	if _material != null:
		_material.set_shader_parameter("optimization_dist_max", optimization_dist_max)
