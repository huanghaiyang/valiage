@tool
class_name TerrainPlatform
extends Node3D
## 地形平台：把本节点周围 radius 米整平到目标高度（聚落/基地/哨站的操场）
## 场景里移动本节点或改半径，编辑器内即会重新整平对应区域。

## 整平半径（米）
@export var radius := 16.0

## 目标高度；勾选 sample_from_terrain 时忽略本项
@export var height := 0.4

## 从地形采样中心高度（取整到 0.25m）作为平台高度——原逻辑行为
@export var sample_from_terrain := true

## 采样取整步长（米）
@export var round_step := 0.25

## 在编辑器中实时预览整平效果
@export var preview_in_editor := false

## 编辑器脚本运行中（避免场景加载时重复执行）
var _editor_running := false

## 解析目标高度：采样模式取地形中心高度并取整
func resolve_height(terrain: Node) -> float:
	if not sample_from_terrain:
		return height
	if terrain == null or not terrain.has_method("get_height_at"):
		return height
	var h: float = terrain.get_height_at(global_position.x, global_position.z)
	if round_step > 0.0:
		h = floorf(h / round_step) * round_step
	return h

## 应用整平
func apply(terrain: Node) -> bool:
	if terrain == null or not terrain.has_method("flatten_region"):
		return false
	terrain.flatten_region(global_position, radius, resolve_height(terrain))
	return true

func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	_editor_running = true
	# 编辑器内：等一帧让地形节点就绪后再预览
	call_deferred("_editor_preview")

func _editor_preview() -> void:
	if not preview_in_editor or not _editor_running:
		return
	var terrain := _find_terrain()
	if terrain != null:
		apply(terrain)

func _find_terrain() -> Node:
	var n: Node = get_parent()
	while n != null:
		var t := n.get_node_or_null("Terrain")
		if t != null:
			return t
		n = n.get_parent()
	return null
