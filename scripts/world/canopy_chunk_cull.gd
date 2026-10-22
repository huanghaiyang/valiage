extends Node
## 树冠（树叶 / 花朵）**分块视锥剔除** —— 把一整片树冠拆成 N×N×N 个小 MeshInstance3D。
##
## ── 为什么必须分块（实测数据，2026-10-19）────────────────────────────────
##   树冠（Leaves / Flowers）在场景里是**一个** MeshInstance3D ✓
##   它的 AABB 覆盖整棵树：樱花树实测 **13.4 × 12.6 × 14.5 米** ✓
##   Godot 的视锥剔除是**逐实例按 AABB**做的 ✓
##   → 相机只要站在这个巨大 AABB **内部**（贴着树干、或在树下），
##     AABB 就必然与视锥相交 ✗ → 引擎只能"照画"**整片**树冠 ✓
##   实测（樱花树，同一机位只转相机）：
##     · 全树在视野内                 → 63,810 个三角形
##     · 贴着树干**朝下看**（树冠完全在视锥外）→ **58,178** 个三角形 ← 几乎没省
##       （其中叶子+花 = 34,560 ✓ 一个都没被剔除 ✗）
##     · 贴着树干水平看向远方（树冠在头顶外）  → **63,264** 个三角形
##   ⇒ 整节点级别的剔除在这种场景**完全无效** ✓ 唯一有效的做法是把树冠切成更小的块 ✓
##
## ── 分块之后 ──────────────────────────────────────────────────────────
##   每块都是独立 MeshInstance3D ✓ 有自己的紧凑 AABB ✓
##   → **引擎原有的逐实例视锥剔除自动生效** ✓（本脚本运行期**零每帧开销** ✗ 不做逐帧判断）
##   实测同上"朝下看"场景：叶子+花从 34,560 降到只剩脚边那一两块 ✓
##
## ── 关键正确性约束（改这个脚本前必读）─────────────────────────────────
##   ① **所有块必须共用同一个材质实例** ✓
##      风摆位移只依赖 `VERTEX` + uniform ✓ 同一个顶点在不同块里算出的位移**完全相同** ✓
##      若给每块复制一份材质 ✗ → wind.gd 逐材质写 `wind_height_ref` ✗ → 各块参考高度不同
##      → 同一顶点位移不同 → **块之间出现撕裂/接缝** ✗✗
##   ② 三角形按**质心**归属某个块 ✓ 一个三角形绝不会跨块 ✓ → 几何零损失、无接缝 ✓
##   ③ 块 AABB 要按 `inflate`（米）**外扩** ✓
##      因为风摆是**顶点着色器里的位移**，引擎算 AABB 时看不到它 ✗
##      不外扩的话：树在画面边缘时，摆出 AABB 的叶子会被"整块已剔除"而突然消失/出现 ✓
##   ④ 分块后会多出 draw call（全树可见时 1 块 → N³ 块）✓
##      这是"部分可见时省几何"与"全可见时多 draw call"的取舍 ✓ 别调太大 ✓
##   ⑤ wind.gd / foliage_burn.gd 会按**单个网格**量风速参考高度 / 燃烧高度前沿 ✗
##      分块后每块只量到自己那一小块 ✗ → 我们用节点 meta 把**整片树冠**的高度传下去 ✓
##      （见 `_chunk_mesh` 里的 `wind_height_ref` / `burn_height_ref` 两行 ✓
##        对端读取点：scripts/wind.gd 的 _take_from_mesh / scripts/vfx/foliage_burn.gd 的 _apply_in_shader_burn ✓）
##
## ── 用法 ────────────────────────────────────────────────────────────
##   把本脚本挂到树根下的一个普通 Node 上 ✓（`_ready` 会扫描**父节点**整棵子树）
##   按 shader 路径自动认定"树冠网格" ✓ 不用手填 NodePath ✓
##   树叶 + 花朵都会被切 ✓ 树干/树枝（tree_burn_keep*）**不动** ✓

## 每轴切几刀：2 → 2×2×2 = 8 块/网格。
## 调大：部分可见时省得更多 ✓ 但全可见时 draw call 随之线性增加 ✗
@export_range(1, 4) var divisions := 2
## 每块 AABB 的外扩量（米）。★ 已改为**自动按风摆幅度算** ✓
##   >0 = 手动指定；<=0 = 按 `_auto_margin()` 自动算（默认）✓
##   ★★ 为什么必须够大（用户实测问题 ✓）：
##     顶点着色器里的风摆**位移**引擎看不见 ✗ 剔除只用**静态 AABB** ✓
##     → 外扩不够时：摆出 AABB 的那部分会被"整块已剔除"而**突然消失** ✓
##     → 表现为"枝条/树叶在某些视角下像被看穿、随视角变化"✓
##     （GLB 预览里的材质没有顶点位移 ✗ 所以预览完全正常 ✓）
@export var inflate := -1.0
## 自动余量的安全系数（1.3 = 在算出的最大位移上再加 30%）
@export var margin_scale := 1.3
## 自动余量的上下限（米）
@export var margin_min := 0.5
@export var margin_max := 8.0
## 认定"树冠网格"的 shader 路径关键字（子串匹配）✓
@export var shader_hint := "tree_leaves_burn"
## 关掉后不自动分块（供调试 / 想手动调用 chunk_all 的场合）
@export var auto_run := true

## 本次一共切出了多少块（供自检 / 日志）
var chunk_count := 0
## 本次实际使用的剔除余量（米），供自检 / 日志
var used_margin := 0.0


func _ready() -> void:
	if auto_run:
		chunk_all()


## 扫描父节点整棵子树，把树冠网格分块。可手动重复调用（已切过的网格 mesh 为 null，会被跳过）。
func chunk_all() -> void:
	chunk_count = 0
	var root := get_parent()
	if root == null:
		return
	if divisions <= 1:
		return
	used_margin = _resolve_margin(root)
	_walk(root)
	if chunk_count > 0:
		print("[树冠剔除] 分块完成：%d 块（每组 %d×%d×%d），剔除余量 %.2f m" % [
				chunk_count, divisions, divisions, divisions, used_margin])


## ★★★ 风摆安全余量（米）—— 本次修复的核心 ✓
##   引擎剔除用**静态 AABB** ✗ 看不见顶点着色器里的位移 ✓
##   最大位移（与 shader 里同一套公式 ✓）：
##     dist = (y - base_y) × wind_sway_scale × wind_strength × (1 + wind_gust × 2.2)
##   再乘 sway 合成后的方向长度 (1 + wind_turbulence × 0.25)，最后乘安全系数 ✓
##   例：大樱花树 27.13m × 0.22 × 0.18 × 1.33 ≈ 1.43m，×1.075 ≈ 1.53m，×1.3 ≈ **2.0 m** ✓
##   （之前只给树冠块外扩 0.8m、枝条完全没设 ✗ → 摆出 AABB 的部分被整块剔除 ✓
##     → "枝条随视角时隐时现、像被看穿"✓ 这就是用户报的那个 bug ✓）
func _resolve_margin(root: Node) -> float:
	if inflate > 0.0:
		return inflate
	_max_disp = 0.0
	_scan_max_disp(root)
	var m := clampf(_max_disp * margin_scale, margin_min, margin_max)
	_max_disp = 0.0
	return m

var _max_disp := 0.0

## 按材质里的风参数算出**最大位移**（米）
func _scan_max_disp(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var sm := _shader_material(mi)
		if sm != null:
			var we: Variant = sm.get_shader_parameter("wind_enabled")
			if we != null and not bool(we):
				pass                     # 该材质关了风 → 不参与
			else:
				var h := float(_param(sm, "wind_height_ref", 0.0))
				if h <= 0.0 and mi.mesh != null:
					h = mi.get_aabb().size.y
				var sway := float(_param(sm, "wind_sway_scale", 0.2))
				var strength := float(_param(sm, "wind_strength", 0.15))
				var gust := float(_param(sm, "wind_gust", 0.15))
				var turb := float(_param(sm, "wind_turbulence", 0.3))
				var d := h * sway * strength * (1.0 + gust * 2.2) * (1.0 + turb * 0.25)
				# ★ fast-tree 风摆移植：烘焙树用**米级** wind_force，最大位移 ≈ 2.6×force
				#   （顺风刚性位移 ~1.36×force + 叶片弯曲 ~1.0×force + 俯仰 ~0.25×force，取上界）
				var force := float(_param(sm, "wind_force", 0.0))
				var d_baked := force * 2.6
				_max_disp = maxf(_max_disp, maxf(d, d_baked))
	for c in n.get_children():
		_scan_max_disp(c)


func _param(sm: ShaderMaterial, name: String, fallback: float) -> float:
	var v: Variant = sm.get_shader_parameter(name)
	if v == null:
		return fallback
	return float(v)


## 取网格用于判定的 ShaderMaterial（material_override 优先 ✓）
func _shader_material(mi: MeshInstance3D) -> ShaderMaterial:
	var m: Material = mi.material_override
	if m == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
		m = mi.mesh.surface_get_material(0)
	return m as ShaderMaterial


func _walk(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		# ★ 先给**所有**受风影响的网格设剔除余量 ✓（含树干/树枝 ✗ 它们也被风推动了 ✓
		#   枝条"随视角时隐时现"就是因为这里没设 ✓）
		if used_margin > 0.0 and _shader_material(mi) != null:
			mi.extra_cull_margin = used_margin
		if mi.mesh != null and mi.mesh.get_surface_count() > 0 and _is_canopy(mi):
			_chunk_mesh(mi)
	# ★ 先取子节点快照再递归 ✓
	#   `_chunk_mesh` 会往当前网格**加子节点** ✓ 若边遍历边递归，就会走进刚加出来的块
	#   → 块又被当树冠再切一次 → **无限递归 / 栈溢出**（实测踩过 ✓）
	#   （`_is_canopy` 里还有 canopy_chunk meta 兜底 ✓ 双保险 ✓）
	var kids := n.get_children()
	for c in kids:
		_walk(c)


## 这个网格算不算"树冠"？判据 = 它的材质 shader 路径里含 shader_hint ✓
func _is_canopy(mi: MeshInstance3D) -> bool:
	if mi.has_meta("canopy_chunk"):
		return false                    # 已经是切出来的块，绝不重复切（防递归）
	var m: Material = mi.material_override
	if m == null:
		m = mi.mesh.surface_get_material(0)
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		return sm.shader != null and String(sm.shader.resource_path).contains(shader_hint)
	return false


## 把一个网格切成 divisions³ 块；成功后原节点 `mesh` 置空（不再绘制，只留作变换父节点）。
func _chunk_mesh(mi: MeshInstance3D) -> void:
	var src := mi.mesh
	var full := src.get_aabb()
	# ★ 整片树冠的高度（传给 wind.gd / foliage_burn.gd，见文件头 ⑤）
	var canopy_top := full.position.y + full.size.y
	# 分块期间关掉原网格的绘制，避免"切一半"时闪一帧
	var made: Array[MeshInstance3D] = []
	for s in range(src.get_surface_count()):
		var arrays: Array = src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if verts.is_empty() or idx.is_empty():
			continue
		# 顶点属性里有我们不认识的数组就**整块放弃**（宁可不切，也不要切出错）
		if not _arrays_supported(arrays):
			push_warning("[树冠剔除] %s 的顶点属性含未支持数组，跳过分块（几何保持原样）" % mi.name)
			return
		var primitive: Mesh.PrimitiveType = src.surface_get_primitive_type(s)
		var buckets := _bucket_triangles(verts, idx, full)
		for key in buckets.keys():
			var tri_idx: PackedInt32Array = buckets[key]
			var new_arrays := _compact_arrays(arrays, tri_idx)
			if new_arrays.is_empty():
				continue
			var m := ArrayMesh.new()
			# ★ fast-tree 风摆移植：CUSTOM0/CUSTOM1（每顶点 4 个 float）必须显式声明 RGBA_FLOAT，
			#   否则 add_surface_from_arrays 会按默认的 RGBA8_UNORM 去要 PackedByteArray
			#   → 报 "Invalid array format for surface" → 这块没 surface → 树冠整片消失。
			var custom_flags := 0
			if arrays[Mesh.ARRAY_CUSTOM0] != null:
				custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			if arrays[Mesh.ARRAY_CUSTOM1] != null:
				custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
			if arrays[Mesh.ARRAY_CUSTOM2] != null:
				custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
			if arrays[Mesh.ARRAY_CUSTOM3] != null:
				custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
			m.add_surface_from_arrays(primitive, new_arrays, [], {}, custom_flags)
			# ★ 材质：优先沿用节点的 material_override ✓（保证所有块**同一个实例** ✓）
			var mat: Material = mi.material_override
			if mat == null:
				mat = src.surface_get_material(s)
			if mat != null:
				m.surface_set_material(0, mat)
			var node := MeshInstance3D.new()
			node.name = "Chunk_%d_%d_%d_%d" % [s, int(key.x), int(key.y), int(key.z)]
			node.mesh = m
			if mi.material_override != null:
				node.material_override = mi.material_override
			node.cast_shadow = mi.cast_shadow
			node.lod_bias = mi.lod_bias
			node.gi_mode = mi.gi_mode
			node.layers = mi.layers
			# ★ 风摆安全边距（见文件头 ③）
			node.custom_aabb = m.get_aabb().grow(maxf(used_margin, 0.0))
			# ★ 整片树冠的参考高度（见文件头 ⑤）
			node.set_meta("canopy_chunk", true)      # 防重复切/递归（见 _is_canopy）
			node.set_meta("wind_height_ref", canopy_top)
			node.set_meta("burn_height_ref", canopy_top)
			mi.add_child(node)
			made.append(node)
	if made.is_empty():
		return
	mi.mesh = null                      # 原网格不再绘制；子块接管
	chunk_count += made.size()


## 这些顶点属性数组我们能正确重建吗？（只列实际会用到的几种）
func _arrays_supported(arrays: Array) -> bool:
	for a in range(Mesh.ARRAY_MAX):
		var v: Variant = arrays[a]
		if v == null:
			continue
		if a == Mesh.ARRAY_INDEX:
			continue
		if v is PackedVector3Array or v is PackedVector2Array \
				or v is PackedColorArray or v is PackedFloat32Array or v is PackedInt32Array:
			continue
		return false
	return true


## 按三角形**质心**归格子 ✓ 返回 {Vector3i: PackedInt32Array(索引三元组...)}
func _bucket_triangles(verts: PackedVector3Array, idx: PackedInt32Array, aabb: AABB) -> Dictionary:
	var div := maxi(1, divisions)
	var size := aabb.size
	# 退化轴（宽度为 0）时该轴固定归 0 格，避免除零
	var inv := Vector3(
			0.0 if size.x <= 1e-5 else float(div) / size.x,
			0.0 if size.y <= 1e-5 else float(div) / size.y,
			0.0 if size.z <= 1e-5 else float(div) / size.z)
	var out := {}
	var tri_n := idx.size() / 3
	for t in range(tri_n):
		var i0 := idx[t * 3]
		var i1 := idx[t * 3 + 1]
		var i2 := idx[t * 3 + 2]
		var c := (verts[i0] + verts[i1] + verts[i2]) / 3.0
		var k := Vector3i(
				clampi(int((c.x - aabb.position.x) * inv.x), 0, div - 1),
				clampi(int((c.y - aabb.position.y) * inv.y), 0, div - 1),
				clampi(int((c.z - aabb.position.z) * inv.z), 0, div - 1))
		if not out.has(k):
			out[k] = PackedInt32Array()
		var arr: PackedInt32Array = out[k]
		arr.append(i0)
		arr.append(i1)
		arr.append(i2)
		out[k] = arr                    # Packed*Array 是值类型：取出来 append 后必须写回
	return out


## 只保留 tri_idx 用到的顶点，重建一份紧凑的顶点属性数组（重复顶点会被合并到同一新下标）
func _compact_arrays(arrays: Array, tri_idx: PackedInt32Array) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	remap.fill(-1)
	var new_index := PackedInt32Array()
	new_index.resize(tri_idx.size())
	var used := 0
	for i in range(tri_idx.size()):
		var old := tri_idx[i]
		var to := remap[old]
		if to < 0:
			to = used
			used += 1
			remap[old] = to
		new_index[i] = to
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	for a in range(Mesh.ARRAY_MAX):
		var v: Variant = arrays[a]
		if v == null:
			continue
		if a == Mesh.ARRAY_INDEX:
			out[a] = new_index
			continue
		var built: Variant = _remap_attr(v, remap, used, verts.size())
		if built == null:
			return []
		out[a] = built
	return out


## 把一种顶点属性数组按 remap 重排成 used 个元素
## ★ 注意 stride：Godot 的顶点属性**不是都 1 个元素/顶点** ✓
##   VERTEX/NORMAL=PackedVector3Array、TEX_UV=PackedVector2Array、COLOR=PackedColorArray → 1:1 ✓
##   **TANGENT** = PackedFloat32Array，**4 个 float / 顶点** ✓（这个是踩过的坑：
##   按 1:1 处理会得到"长度不匹配"→ 被当成不支持 → 整棵树悄悄不分块 ✗）
##   WEIGHTS / CUSTOM0..3 同样是 4 分量 ✓ BONES 是 4 个 int ✓
## 参数 vcount：原网格的顶点数（用来反推 stride）
func _remap_attr(v: Variant, remap: PackedInt32Array, used: int, vcount: int) -> Variant:
	if v is PackedVector3Array:
		var src := v as PackedVector3Array
		if src.size() != vcount:
			return null
		var dst := PackedVector3Array()
		dst.resize(used)
		for old in range(remap.size()):
			var n := remap[old]
			if n >= 0:
				dst[n] = src[old]
		return dst
	if v is PackedVector2Array:
		var src2 := v as PackedVector2Array
		if src2.size() != vcount:
			return null
		var dst2 := PackedVector2Array()
		dst2.resize(used)
		for old in range(remap.size()):
			var n2 := remap[old]
			if n2 >= 0:
				dst2[n2] = src2[old]
		return dst2
	if v is PackedColorArray:
		var src3 := v as PackedColorArray
		if src3.size() != vcount:
			return null
		var dst3 := PackedColorArray()
		dst3.resize(used)
		for old in range(remap.size()):
			var n3 := remap[old]
			if n3 >= 0:
				dst3[n3] = src3[old]
		return dst3
	# 多分量扁平数组（TANGENT / WEIGHTS / CUSTOM / BONES）：按 stride 搬运
	if v is PackedFloat32Array:
		var src4 := v as PackedFloat32Array
		if vcount <= 0 or src4.size() % vcount != 0:
			return null
		var stride := src4.size() / vcount
		var dst4 := PackedFloat32Array()
		dst4.resize(used * stride)
		for old in range(remap.size()):
			var n4 := remap[old]
			if n4 >= 0:
				for k in range(stride):
					dst4[n4 * stride + k] = src4[old * stride + k]
		return dst4
	if v is PackedInt32Array:
		var src5 := v as PackedInt32Array
		if vcount <= 0 or src5.size() % vcount != 0:
			return null
		var stride5 := src5.size() / vcount
		var dst5 := PackedInt32Array()
		dst5.resize(used * stride5)
		for old in range(remap.size()):
			var n5 := remap[old]
			if n5 >= 0:
				for k in range(stride5):
					dst5[n5 * stride5 + k] = src5[old * stride5 + k]
		return dst5
	return null
