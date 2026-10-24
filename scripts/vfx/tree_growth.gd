extends Node
## 树「从零生长」预览驱动（fast-tree 的 uGrowth 顶点动画移植）
##
## ── 效果来源 ────────────────────────────────────────────────
##   源实现：D:\sgames\fast-tree\src\core\materials.js  vertexBody()
##     growK   = smoothstep(clamp((uGrowth - aGrow.x) / (aGrow.y - aGrow.x)))
##     treePos = mix(aOrigin, treePos, mix(1.0, growK, uGrowthEnabled))
##   Godot 侧的顶点位移写在 assets/shaders/fast_tree_wind.gdshaderinc：
##     tree_growth_offset()  —— 没有 aGrow 属性，改用「顶点高度」推导生长窗口
##
## ── 用法 ────────────────────────────────────────────────
##   把本脚本挂到一个 Node 上，`tree_path` 指向树实例（留空 = 用父节点）
##   → play()  从 0 长到 1（duration 秒）
##   → reset() 直接回到长成状态（growth_enabled = false，零开销）
##
## ── 关键约束（别改）──────────────────────────────────────
##   ① **运行时复制材质**（.tres 是共享资源 ✗ 直接写会污染所有树实例 + 编辑器预览）
##   ② 同一份源材质只复制**一次**（按资源身份缓存）✓
##      树冠分块节点共用同一个材质实例（canopy_chunk_cull.gd 的正确性前提）
##      → 必须给它们铺**同一个**复制品，否则各块风摆参考高度不同会出现撕裂 ✓
##   ③ 不在 @tool 下运行 ✓ 只在游戏运行时生效 ✓

## 树实例路径（留空 = 父节点）
@export var tree_path: NodePath
## 从零长到满的时长（秒）
@export_range(0.1, 60.0, 0.1) var duration := 8.0
## 生长前沿的过渡带（0..1，占全高比例）：越大越"软"，越小越"一刀切"
@export_range(0.01, 1.0, 0.01) var growth_span := 0.3
## 进入场景就自动播放
@export var autoplay := false
## 长满后循环重播
@export var loop := false

signal finished

## 运行期复制出来的材质（每个源材质一份）
var _mats: Array[ShaderMaterial] = []
## 源材质 -> 复制品（保证同一源只复制一次、分块节点共用同一份）
var _mats_by_src: Dictionary = {}
var _growth := 1.0
var _playing := false
var _setup_done := false


func _ready() -> void:
	_setup()
	if autoplay:
		play()


func _process(delta: float) -> void:
	if not _playing:
		return
	_growth = minf(1.0, _growth + delta / maxf(0.01, duration))
	_push_growth()
	if _growth >= 1.0:
		if loop:
			_growth = 0.0
		else:
			_playing = false
			_push_disabled()
			finished.emit()


## 从头开始播放生长（growth 0 → 1）
func play() -> void:
	if not _setup_done:
		_setup()
	_growth = 0.0
	_playing = true
	_push_growth()


## 直接回到「长成」状态（不播动画、不留顶点位移开销）
func reset() -> void:
	if not _setup_done:
		_setup()
	_playing = false
	_growth = 1.0
	_push_disabled()


func is_playing() -> bool:
	return _playing


## 收集树的材质 → 逐个复制 → 写入生长参数（只做一次）
func _setup() -> void:
	_setup_done = true
	_mats.clear()
	_mats_by_src.clear()
	var root := _tree_root()
	if root == null:
		push_warning("[树生长] 找不到树木节点：%s" % tree_path)
		return
	_scan(root)
	if _mats.is_empty():
		push_warning("[树生长] 树里没有带 growth 参数的着色器材质（是不是还没烘焙树木网格？）")
		return
	var h := _measure_height()
	for m in _mats:
		m.set_shader_parameter("growth_height", h)
		m.set_shader_parameter("growth_span", growth_span)
		m.set_shader_parameter("growth", 1.0)
		m.set_shader_parameter("growth_enabled", false)


func _tree_root() -> Node:
	if tree_path != NodePath():
		var n := get_node_or_null(tree_path)
		if n != null:
			return n
	return get_parent()


## 深度优先扫描：给每个「材质里有 growth」的网格换成运行时复制品
func _scan(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var src := _source_material(mi)
		var sm := src as ShaderMaterial
		if sm != null and _has_growth(sm):
			var dup: ShaderMaterial = _mats_by_src.get(sm)
			if dup == null:
				dup = (sm.duplicate() as ShaderMaterial)
				_mats_by_src[sm] = dup
				_mats.append(dup)
			# ★ 分块节点共用同一个复制品（见文件头 ②）
			mi.material_override = dup
	for c in n.get_children():
		_scan(c)


func _source_material(mi: MeshInstance3D) -> Material:
	if mi.material_override != null:
		return mi.material_override
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		return mi.mesh.surface_get_material(0)
	return null


func _has_growth(sm: ShaderMaterial) -> bool:
	if sm.shader == null:
		return false
	for u in sm.shader.get_shader_uniform_list():
		if String(u.name) == "growth_enabled":
			return true
	return false


## 生长高度（模型空间米）：优先用材质里的 height_ref（= 全树高度），
## 读不到就退回网格 AABB 的最高点（相对树根）
func _measure_height() -> float:
	var h := 0.0
	for m in _mats:
		var v: Variant = m.get_shader_parameter("height_ref")
		if (v is float or v is int) and float(v) > h:
			h = float(v)
	if h > 0.0:
		return h
	var root := _tree_root()
	if root == null:
		return 8.0
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		h = maxf(h, mi.mesh.get_aabb().end.y)
	return maxf(h, 0.1)


func _push_growth() -> void:
	for m in _mats:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("growth", _growth)
		m.set_shader_parameter("growth_enabled", true)


func _push_disabled() -> void:
	for m in _mats:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("growth", 1.0)
		m.set_shader_parameter("growth_enabled", false)
