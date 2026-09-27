@tool
class_name RoadPath
extends Node3D
## 道路：沿本节点的子 Marker3D（或 point_0..N 导出数组）铺一条砂石路。
## 在场景里添加/移动子 Marker3D 即可改路线，高度自动贴合地形。

## 路宽（米）
@export var width := 3.5

## 额外控制点（世界坐标）；与子 Marker3D 按顺序合并
@export var extra_points: PackedVector3Array = PackedVector3Array()

## 是否使用子 Marker3D 作为控制点
@export var use_child_markers := true

## 起点额外控制点
@export var start_point := Vector3(0.0, 0.0, 0.0)

## 是否包含 start_point（关掉则仅用子 Marker3D）
@export var include_start := true

## 编辑器内实时预览铺路（需要 RoadNetwork 支持清理旧路面）
@export var preview_in_editor := false

## 按顺序收集控制点
func collect_points() -> Array:
	var pts: Array = []
	if include_start:
		pts.append(start_point)
	if use_child_markers:
		for c in get_children():
			if c is Node3D:
				pts.append((c as Node3D).global_position)
	for p in extra_points:
		pts.append(p)
	return pts
