class_name ProceduralMesh
extends RefCounted
## 程序化网格生成工具库
## 负责构建墙体、塔楼、屋顶等搭建件的基础几何体

const UP := Vector3.UP

# ------------------------------------------------------------
# 内部辅助：向几何数组追加四边形 / 三角形
# 传入的 verts/normals/uvs/indices 会被就地修改，vi 为当前顶点偏移
# ------------------------------------------------------------
static func _add_quad(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vi: int,
		pa: Vector3, pb: Vector3, pc: Vector3, pd: Vector3, n: Vector3,
		u0: Vector2, u1: Vector2, u2: Vector2, u3: Vector2) -> int:
	verts.append(pa); verts.append(pb); verts.append(pc); verts.append(pd)
	for i in 4:
		normals.append(n)
	uvs.append(u0); uvs.append(u1); uvs.append(u2); uvs.append(u3)
	indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
	indices.append(vi); indices.append(vi + 2); indices.append(vi + 3)
	return vi + 4

static func _add_quad_simple(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vi: int,
		pa: Vector3, pb: Vector3, pc: Vector3, pd: Vector3, n: Vector3) -> int:
	verts.append(pa); verts.append(pb); verts.append(pc); verts.append(pd)
	for i in 4:
		normals.append(n)
	uvs.append(Vector2.ZERO); uvs.append(Vector2.ONE); uvs.append(Vector2(1, 0)); uvs.append(Vector2(0, 1))
	indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
	indices.append(vi); indices.append(vi + 2); indices.append(vi + 3)
	return vi + 4

static func _add_tri(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vi: int,
		pa: Vector3, pb: Vector3, pc: Vector3, n: Vector3) -> int:
	verts.append(pa); verts.append(pb); verts.append(pc)
	for i in 3:
		normals.append(n)
	uvs.append(Vector2(0, 0)); uvs.append(Vector2(1, 0)); uvs.append(Vector2(0.5, 1))
	indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
	return vi + 3

## 构建一段长方体墙
## a/b：地面上的两个端点；height：墙高；thickness：墙厚；base_y：底部高度
static func build_wall(a: Vector3, b: Vector3, height: float, thickness: float, base_y: float = 0.0) -> Array:
	var dir := (b - a)
	dir.y = 0.0
	var length := dir.length()
	if length < 0.01:
		return []
	dir = dir.normalized()
	var right := dir.cross(UP).normalized()
	var half_t := thickness * 0.5

	var p0 := a + right * half_t
	var p1 := a - right * half_t
	var p2 := b - right * half_t
	var p3 := b + right * half_t
	p0.y = base_y; p1.y = base_y; p2.y = base_y; p3.y = base_y
	var q0 := p0 + UP * height
	var q1 := p1 + UP * height
	var q2 := p2 + UP * height
	var q3 := p3 + UP * height

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0

	var wall_len := maxf(length, 0.001)
	# 前后面（长边）
	vi = _add_quad(verts, normals, uvs, indices, vi, p0, p3, q3, q0, dir, Vector2(0, 0), Vector2(wall_len, 0), Vector2(wall_len, height), Vector2(0, height))
	vi = _add_quad(verts, normals, uvs, indices, vi, p2, p1, q1, q2, -dir, Vector2(0, 0), Vector2(wall_len, 0), Vector2(wall_len, height), Vector2(0, height))
	# 左右端面
	vi = _add_quad(verts, normals, uvs, indices, vi, p1, p0, q0, q1, -right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, height), Vector2(0, height))
	vi = _add_quad(verts, normals, uvs, indices, vi, p3, p2, q2, q3, right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, height), Vector2(0, height))
	# 顶面
	vi = _add_quad(verts, normals, uvs, indices, vi, q0, q3, q2, q1, UP, Vector2(0, 0), Vector2(wall_len, 0), Vector2(wall_len, thickness), Vector2(0, thickness))

	return [verts, normals, uvs, indices]

## 构建带城垛的墙体（Tiny Glade 风格城堡墙）
static func build_crenellated_wall(a: Vector3, b: Vector3, height: float, thickness: float, base_y: float = 0.0) -> Array:
	var dir := (b - a)
	dir.y = 0.0
	var length := dir.length()
	if length < 0.01:
		return []
	dir = dir.normalized()
	var right := dir.cross(UP).normalized()
	var half_t := thickness * 0.5

	var base := build_wall(a, b, height * 0.8, thickness, base_y)

	# 城垛沿墙顶排列
	var merlon_count := maxi(1, int(length / 1.2))
	var merlon_w := length / float(merlon_count) * 0.55
	var merlon_h := height * 0.35
	var gap := length / float(merlon_count)
	var start := a

	var verts: PackedVector3Array = base[0]
	var normals: PackedVector3Array = base[1]
	var uvs: PackedVector2Array = base[2]
	var indices: PackedInt32Array = base[3]
	var vi := verts.size()

	var y0 := base_y + height * 0.8
	for i in merlon_count:
		var t0 := start + dir * (float(i) * gap)
		var t1 := t0 + dir * merlon_w
		var p0 := t0 + right * half_t; p0.y = y0
		var p1 := t0 - right * half_t; p1.y = y0
		var p2 := t1 - right * half_t; p2.y = y0
		var p3 := t1 + right * half_t; p3.y = y0
		var q0 := p0 + UP * merlon_h
		var q1 := p1 + UP * merlon_h
		var q2 := p2 + UP * merlon_h
		var q3 := p3 + UP * merlon_h
		# 前后面
		vi = _add_quad(verts, normals, uvs, indices, vi, p0, p3, q3, q0, dir, Vector2(0, 0), Vector2(merlon_w, 0), Vector2(merlon_w, merlon_h), Vector2(0, merlon_h))
		vi = _add_quad(verts, normals, uvs, indices, vi, p2, p1, q1, q2, -dir, Vector2(0, 0), Vector2(merlon_w, 0), Vector2(merlon_w, merlon_h), Vector2(0, merlon_h))
		# 端面
		vi = _add_quad(verts, normals, uvs, indices, vi, p1, p0, q0, q1, -right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, merlon_h), Vector2(0, merlon_h))
		vi = _add_quad(verts, normals, uvs, indices, vi, p3, p2, q2, q3, right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, merlon_h), Vector2(0, merlon_h))
		# 顶面
		vi = _add_quad(verts, normals, uvs, indices, vi, q0, q3, q2, q1, UP, Vector2(0, 0), Vector2(merlon_w, 0), Vector2(merlon_w, thickness), Vector2(0, thickness))

	return [verts, normals, uvs, indices]

## 构建圆柱塔楼
## center：中心点；radius：半径；height：高度；segments：圆周分段
static func build_tower(center: Vector3, radius: float, height: float, base_y: float = 0.0, segments: int = 16) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0

	# 侧面
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		var q0 := p0 + UP * height
		var q1 := p1 + UP * height
		var n := Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5)).normalized()
		vi = _add_quad_simple(verts, normals, uvs, indices, vi, p0, p1, q1, q0, n)

	# 顶盖（扇形）
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, base_y + height, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, base_y + height, sin(a1) * radius)
		var top_center := center + UP * (base_y + height)
		verts.append(top_center); verts.append(p1); verts.append(p0)
		for j in 3:
			normals.append(UP)
		uvs.append(Vector2(0.5, 0.5)); uvs.append(Vector2(0.5 + cos(a1) * 0.5, 0.5 + sin(a1) * 0.5)); uvs.append(Vector2(0.5 + cos(a0) * 0.5, 0.5 + sin(a0) * 0.5))
		indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
		vi += 3

	return [verts, normals, uvs, indices]

## 构建锥形屋顶（圆塔顶）
static func build_conical_roof(center: Vector3, radius: float, height: float, base_y: float = 0.0, segments: int = 16) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0
	var apex := center + UP * (base_y + height)
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		var n := (Vector3(cos((a0 + a1) * 0.5), 0.4, sin((a0 + a1) * 0.5))).normalized()
		verts.append(apex); verts.append(p1); verts.append(p0)
		for j in 3:
			normals.append(n)
		uvs.append(Vector2(0.5, 1)); uvs.append(Vector2(0.5 + cos(a1) * 0.5, 0.5 + sin(a1) * 0.5)); uvs.append(Vector2(0.5 + cos(a0) * 0.5, 0.5 + sin(a0) * 0.5))
		indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
		vi += 3
	return [verts, normals, uvs, indices]

## 构建双坡屋顶（山墙屋顶）
## a/b：沿屋脊方向的两个端点；width：屋顶覆盖宽度；ridge_height：屋脊高度；eave_height：檐口高度；base_y
static func build_gable_roof(a: Vector3, b: Vector3, width: float, ridge_height: float, eave_height: float, base_y: float = 0.0) -> Array:
	var dir := (b - a)
	dir.y = 0.0
	var length := dir.length()
	if length < 0.01:
		return []
	dir = dir.normalized()
	var right := dir.cross(UP).normalized()
	var half_w := width * 0.5

	var y0 := base_y + eave_height
	var yr := base_y + ridge_height

	var p0 := a + right * half_w; p0.y = y0
	var p1 := a - right * half_w; p1.y = y0
	var p2 := b - right * half_w; p2.y = y0
	var p3 := b + right * half_w; p3.y = y0
	var ra := a + dir * (length * 0.5); ra.y = yr
	var rb := b - dir * (length * 0.5); rb.y = yr

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0

	# 两个坡面
	var slope_n := (right + UP * 0.6).normalized()
	vi = _add_quad_simple(verts, normals, uvs, indices, vi, p0, p3, rb, ra, slope_n)
	vi = _add_quad_simple(verts, normals, uvs, indices, vi, p2, p1, ra, rb, (-right + UP * 0.6).normalized())
	# 两端三角山墙
	vi = _add_tri(verts, normals, uvs, indices, vi, p0, ra, p1, -dir)
	vi = _add_tri(verts, normals, uvs, indices, vi, p3, p2, rb, dir)

	return [verts, normals, uvs, indices]

## 把几何数组转为 ArrayMesh surface arrays
static func arrays_to_surface(geom: Array) -> Array:
	if geom.is_empty() or (geom[0] as PackedVector3Array).is_empty():
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = geom[0]
	arrays[Mesh.ARRAY_NORMAL] = geom[1]
	arrays[Mesh.ARRAY_TEX_UV] = geom[2]
	arrays[Mesh.ARRAY_INDEX] = geom[3]
	return arrays
