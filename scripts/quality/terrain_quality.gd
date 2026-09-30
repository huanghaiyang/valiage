@tool
class_name TerrainQuality
extends Node
## 地表贴图分级（范例）
##
## 作用：按当前画质档位，把 Terrain3D 贴图资产里的 albedo / normal
## 换成对应分辨率的版本，并同步地形的 LOD 参数。
##
## 用法：
##   1. 在场景里加一个空 Node3D（或任意 Node），挂上本脚本
##   2. terrain_path 指到 Terrain3D（留空则自动在场景里找）
##   3. 每档贴图按 "…_diff_4k.jpg / _diff_2k.jpg / _diff_1k.jpg" 命名放好
##      （只有一套 4K 也能跑：找不到就逐级回退，最后回退到原图，绝不会变白）
##
## 切档：QualityManager.instance.set_tier(QualityTiers.Tier.LOW)

@export var terrain_path: NodePath
@export var follow_quality := true
@export var tier: int = QualityTiers.Tier.HIGH
@export var apply_lod := true
## 编辑器里是否也自动应用。
## 默认 false —— 否则在编辑器里切档会把"当前档位的贴图路径"烤进场景文件 ✗。
## 想预览某档效果时再临时勾上 ✓。
@export var apply_in_editor := false


func _ready() -> void:
	# 编辑器里默认不动手：切档若改到场景里的贴图引用，保存后档位就被"烤"进场景了 ✗
	if Engine.is_editor_hint() and not apply_in_editor:
		return
	if follow_quality and QualityManager.instance != null:
		QualityManager.instance.tier_changed.connect(_on_tier_changed)
	apply_current()


func _on_tier_changed(t: int) -> void:
	apply_tier(t)


func get_terrain() -> Terrain3D:
	if terrain_path != NodePath():
		return get_node_or_null(terrain_path) as Terrain3D
	var root: Node = null
	if get_tree() != null:
		root = get_tree().current_scene
	if root == null:
		root = self
	return _find_terrain_in(root)


func _find_terrain_in(n: Node) -> Terrain3D:
	if n is Terrain3D:
		return n as Terrain3D
	for c in n.get_children():
		var r := _find_terrain_in(c)
		if r != null:
			return r
	return null


func current_tier() -> int:
	if follow_quality and QualityManager.instance != null:
		return QualityManager.instance.tier
	return tier


## 应用当前档位，返回统计结果（便于日志/测试）
func apply_current() -> Dictionary:
	return apply_tier(current_tier())


func apply_tier(t: int) -> Dictionary:
	var terrain := get_terrain()
	if terrain == null:
		return {"ok": false, "message": "没找到 Terrain3D 节点"}
	var preset := QualityTiers.get_preset(t)
	var res := apply_on_assets(terrain.assets, t)
	if apply_lod:
		terrain.mesh_size = int(preset.get("terrain_mesh_size", 48))
		var mesh_list = terrain.assets.mesh_list if terrain.assets != null else []
		for m in mesh_list:
			var ma := m as Terrain3DMeshAsset
			if ma != null:
				ma.lod0_range = float(preset.get("terrain_lod0_range", 128.0))
	res["tier_name"] = QualityTiers.tier_name(t)
	print("[画质] 地表贴图已按「%s」应用：%s" % [res["tier_name"], res])
	return res


## ★ 纯逻辑（可单测）：把 Terrain3DAssets 里每个贴图资产的 albedo/normal 换成本档分辨率。
## 统计：changed=替换了几个 ｜ fallback=回退到更低档几个 ｜ missing=完全没有几个 ｜ skipped=跳过几个
##
## 特意做的一条防护：**resource_path 为空的内嵌贴图直接跳过** ——
## 碰它只会把大块图像数据留在场景里（曾把 main.tscn 撑到 102 MB）。
static func apply_on_assets(assets: Terrain3DAssets, t: int) -> Dictionary:
	var out := {"ok": true, "tier": t, "changed": 0, "fallback": 0, "missing": 0, "skipped": 0, "inner": 0}
	if assets == null:
		out["ok"] = false
		out["message"] = "assets 为空"
		return out
	for a in assets.texture_list:
		var ta := a as Terrain3DTextureAsset
		if ta == null:
			continue
		for prop in ["albedo_texture", "normal_texture"]:
			var cur = ta.get(prop)
			if not (cur is Texture2D):
				continue
			var src := (cur as Texture2D).resource_path
			if src == "" or not src.begins_with("res://"):
				out["inner"] = int(out["inner"]) + 1     # 内嵌贴图：不碰 ✓
				continue
			var want := QualityTiers.texture_for_tier(src, t)
			var use := QualityTiers.resolve_existing(src, t)
			if not ResourceLoader.exists(want):
				if use == src:
					out["missing"] = int(out["missing"]) + 1
				else:
					out["fallback"] = int(out["fallback"]) + 1
			if use == src:
				continue
			var tex := load(use)
			if tex is Texture2D:
				ta.set(prop, tex)
				out["changed"] = int(out["changed"]) + 1
	return out