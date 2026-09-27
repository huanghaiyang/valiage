class_name WorldBuilder
extends RefCounted
## 世界组装器：把场景中声明的布局（出生点 / 地形平台 / 聚落 / 道路 / 植被）
## 按正确顺序应用到运行时系统上。
##
## 场景是结构的唯一事实来源：
##   Main/SpawnPoint                出生点（位置/朝向）
##   Main/Terrain/Platform*         整平平台（半径/高度）
##   Main/Roads/RoadPath*           道路（子 Marker3D 为控制点）
##   Main/Buildings/Layout/*        建筑布局件（meta: kind=wall/house/tower）
##   Main/Settlements/ClearZone*    聚落清场区（半径）
##   Main/Vegetation/Spawned/<cat>/* 植被撒点
##
## 运行时生成的顺序约束：
##   1) 地形生成 → 2) 平台整平（必须在生成之后、取样高度之前）
##   → 3) 聚落建筑 → 4) 道路 → 5) 植被铺底 + 清场 → 6) 网格/碰撞重建

const TAG := "WorldBuilder"


static func build(main: Node3D, terrain: TerrainSystem, vegetation: VegetationSystem,
		buildings: BuildingManager, roads: RoadNetwork, player: Player,
		camera_rig: CameraRig) -> Dictionary:
	var report := {
		"spawn": false, "platforms": 0, "buildings": 0,
		"roads": 0, "clear_zones": 0, "vegetation": -1, "generated_ms": 0,
	}

	# ---- 1. 地形高度场 ----
	var t0 := Time.get_ticks_msec()
	terrain.generate()
	report["generated_ms"] = Time.get_ticks_msec() - t0

	print("WorldBuilder | 1/6 地形生成 %dms" % report["generated_ms"])
	# ---- 2. 地形平台（聚落操场等），必须在取样高度之前整平 ----
	report["platforms"] = _apply_platforms(main, terrain)

	print("WorldBuilder | 2/6 平台整平 %d 处" % report["platforms"])
	# ---- 3. 聚落建筑（场景布局件 → 构建实例） ----
	buildings.build_from_scene()
	buildings.flush_all()
	report["buildings"] = buildings.get_undo_count()
	print("WorldBuilder | 3/6 聚落建筑 %d 件" % report["buildings"])
	# ---- 4. 道路（贴合当前地形） ----
	roads.setup(terrain)
	report["roads"] = _build_roads(main, roads)
	print("WorldBuilder | 4/6 道路 %d 条" % report["roads"])
	# ---- 5. 植被：先铺场景布局，再按清场区回收 ----
	vegetation._terrain = terrain
	vegetation._terrain_half = terrain.HALF
	vegetation.build_from_scene()
	report["clear_zones"] = _clear_zones(main, vegetation)

	print("WorldBuilder | 5/6 清场 %d 处，植被 %s" % [report["clear_zones"], str(vegetation._category_total)])
	# 地形起伏重做后，把烘焙进场景的植被重新贴回新地表（否则山坡长高会埋住植被）
	var resynced := vegetation.sync_heights()
	print("WorldBuilder | 5b/6 植被贴地修正 %d 株" % resynced)
	# ---- 6. 地形网格/碰撞重建，保证与高度数据一致 ----
	terrain.rebuild()

	print("WorldBuilder | 6/6 地形网格/碰撞重建完成")
	# ---- 7. 相机与角色 ----
	camera_rig.terrain = terrain
	report["spawn"] = place_spawn(main, terrain, player, camera_rig)
	return report


## 出生点：读 Main/SpawnPoint（缺失则退回原点上方）
## SpawnPoint 给出的是角色朝向；相机 yaw 由 aim_from_player() 反推，保持镜头在角色身后。
static func place_spawn(main: Node3D, terrain: TerrainSystem, player: Player,
		camera_rig: CameraRig) -> bool:
	var sp := main.get_node_or_null("SpawnPoint") as SpawnPoint
	var pos := Vector3(6.0, terrain.get_height_at(6.0, 11.0) + 2.0, 11.0)
	var yaw := 0.0
	var pitch := -0.16
	if sp != null:
		pos = sp.resolve_position(terrain)
		yaw = sp.resolve_yaw()
		pitch = sp.resolve_pitch()
	player.global_position = pos
	player.rotation = Vector3.ZERO
	camera_rig._current_yaw = yaw
	camera_rig._current_pitch = pitch
	camera_rig.aim_from_player()
	return sp != null


static func _apply_platforms(main: Node3D, terrain: TerrainSystem) -> int:
	var holder := main.get_node_or_null("Terrain")
	if holder == null:
		return 0
	var n := 0
	for c in holder.get_children():
		if c is TerrainPlatform and (c as TerrainPlatform).apply(terrain):
			n += 1
	return n


static func _build_roads(main: Node3D, roads: RoadNetwork) -> int:
	var holder := main.get_node_or_null("Roads")
	if holder == null:
		return 0
	var n := 0
	for c in holder.get_children():
		if not (c is RoadPath):
			continue
		var path := c as RoadPath
		var pts := path.collect_points()
		if pts.size() < 2:
			continue
		roads.build_path(pts, path.width)
		n += 1
	return n


static func _clear_zones(main: Node3D, vegetation: VegetationSystem) -> int:
	var holder := main.get_node_or_null("Settlements")
	if holder == null:
		return 0
	var n := 0
	for c in holder.get_children():
		if not (c is Node3D) or not c.has_meta("clear_radius"):
			continue
		var radius := float(c.get_meta("clear_radius"))
		if radius <= 0.0:
			continue
		vegetation.clear_around((c as Node3D).global_position, radius)
		n += 1
	return n
