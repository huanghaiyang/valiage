class_name RoadNetwork
extends Node3D
## 砂石路网：浅灰条带沿路径铺设（参考复古战棋大地图的浅灰细线道路）
## 分段贴合地形起伏铺路（每 ~10m 一段，采样两端地形高度），条带垂直抬升 ROAD_LIFT 米
## 避免与草地 Z-fighting（render_priority=1）；不改地形，与聚落平台零冲突

const ROAD_WIDTH := 3.5    # 道路宽度（米）
const ROAD_THICK := 0.10   # 条带厚度（米）
const ROAD_LIFT := 0.18    # 条带高于地形的高度（分层偏移，避免 Z-fighting）
const SEG_LEN := 10.0      # 分段长度（米），贴合地形起伏

var _terrain: TerrainSystem
var _mat: StandardMaterial3D

func setup(terrain: TerrainSystem) -> void:
	_terrain = terrain

## 沿多段路径铺路（points: Array，至少 2 个 Vector3 世界坐标点）
## 每段按 SEG_LEN 细分，采样两端地形高度铺贴地条带；端点/转折点用圆盘盖住接缝
func build_path(points: Array, width: float = ROAD_WIDTH) -> void:
	if _terrain == null or points.size() < 2:
		return
	_ensure_material()
	for i in points.size() - 1:
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.5:
			continue
		var dir := (b - a) / seg
		var n := maxi(1, int(round(seg / SEG_LEN)))
		for k in n:
			var t0 := float(k) / float(n)
			var t1 := float(k + 1) / float(n)
			var p0 := a.lerp(b, t0)
			var p1 := a.lerp(b, t1)
			var mid := (p0 + p1) * 0.5
			var h0 := _terrain.get_height_at(p0.x, p0.z) + ROAD_LIFT
			var h1 := _terrain.get_height_at(p1.x, p1.z) + ROAD_LIFT
			var hmid := (h0 + h1) * 0.5
			var seg_len := p0.distance_to(p1)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(seg_len, ROAD_THICK, width)
			mi.mesh = box
			mi.material_override = _mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position = Vector3(mid.x, hmid, mid.z)
			mi.rotation.y = atan2(-dir.z, dir.x)
			add_child(mi)
		var ja := _terrain.get_height_at(a.x, a.z) + ROAD_LIFT
		var jb := _terrain.get_height_at(b.x, b.z) + ROAD_LIFT
		_add_joint(a, ja, width)
		_add_joint(b, jb, width)

## 端点/转折点圆盘：盖住条带接缝（视觉上道路连续）
func _add_joint(p: Vector3, y: float, width: float) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = width * 0.5
	cyl.bottom_radius = width * 0.5
	cyl.height = ROAD_THICK
	mi.mesh = cyl
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(p.x, y, p.z)
	add_child(mi)

func _ensure_material() -> void:
	if _mat != null:
		return
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.72, 0.69, 0.60)   # 浅灰砂石
	_mat.roughness = 1.0
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.render_priority = 1
