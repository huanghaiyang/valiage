extends Node
## 长辈系统（自动加载单例 Elders）
##
## 长老是聚落里的 NPC：走近按 E 交谈。设计参考常见 RPG 的"长老/导师"：
##   * **声望**（`favor`）随交互增长；达到门槛时长老**赠杖**；
##   * 长老有自己的**元素属性**，可以把你的杖**祝福**成他的元素
##     （改的是动态效果与配色，不改模型 —— 见 StaffSystem.bless）；
##   * 每根法杖有"长老石"，用于祝福/升级，随赠杖与交谈累积。
##
## 三个聚落各一位：
##   村庄(260,60) 火长老 · 前哨A(-160,220) 自然长老 · 前哨B(60,-240) 神圣长老

signal elder_spoke(id: String, line: String)
signal favor_changed(id: String, value: int)
signal staff_granted(id: String, staff_id: String)

## 交谈距离（米）
const TALK_RANGE := 3.6
## 每次交谈获得的声望
const FAVOR_PER_TALK := 1
## 赠杖门槛：第 n 次到达门槛就送第 n 根
const GIFT_THRESHOLDS := [2, 6, 12, 20]

## 长老定义
const DEFS := {
	"village": {
		"name": "火长老",
		"title": "守护村庄的老者",
		"pos": Vector3(252.0, 0.0, 64.0),
		"yaw": deg_to_rad(-35.0),
		"element": 1,                       # StaffSystem.Element.FIRE
		"model": "res://assets/models/crafted/elder_village.glb",
		"gifts": ["lamp", "flame", "crescent"],
		"lines": [
			"村子靠这炉火过冬。手冷了，就回来烤烤。",
			"你手里那根杖……还没认主。让我给它添把火。",
			"火不挑柴，只挑时机。急不得。",
		],
	},
	"outpost_a": {
		"name": "自然长老",
		"title": "听着林子的老者",
		"pos": Vector3(-154.0, 0.0, 216.0),
		"yaw": deg_to_rad(150.0),
		"element": 4,                       # NATURE
		"model": "res://assets/models/crafted/elder_outpost_a.glb",
		"gifts": ["thorn", "mushroom", "tentacle"],
		"lines": [
			"这林子比村子老。它记得每一个来过的人。",
			"树根扎得深，风才吹不倒。你把根扎在哪？",
			"低头看看草——它们从不急着长。",
		],
	},
	"outpost_b": {
		"name": "神圣长老",
		"title": "守着灯火的老者",
		"pos": Vector3(64.0, 0.0, -236.0),
		"yaw": deg_to_rad(30.0),
		"element": 5,                       # HOLY
		"model": "res://assets/models/crafted/elder_outpost_b.glb",
		"gifts": ["angel", "swordstaff", "cage"],
		"lines": [
			"这盏灯不能灭。灭了，路就断了。",
			"光不驱散黑暗，它只是让你看清脚下。",
			"愿意被照亮的人，也能照亮别人。",
		],
	},
}

## 每位长老的声望
var favor: Dictionary = {}
## 已经赠出的杖数（用于选 gifts 里第几根）
var gifted: Dictionary = {}
## 对话轮换计数
var _talk_count: Dictionary = {}
## 节点引用：id -> Node3D
var _nodes: Dictionary = {}

var _world: Node3D = null


func _ready() -> void:
	for id in DEFS.keys():
		favor[id] = 0
		gifted[id] = 0
		_talk_count[id] = 0


## 由 main 注入世界根节点，然后生成长老
func build(world: Node3D) -> void:
	if world == null:
		return
	_world = world
	var holder := world.get_node_or_null("Elders")
	if holder == null:
		holder = Node3D.new()
		holder.name = "Elders"
		world.add_child(holder)
	for id in DEFS.keys():
		_spawn(String(id), holder)


func _spawn(id: String, holder: Node3D) -> void:
	var d: Dictionary = DEFS[id]
	var path := str(d["model"])
	if not ResourceLoader.exists(path):
		push_warning("Elders: 模型不存在 %s" % path)
		return
	var scene: PackedScene = load(path)
	var npc := scene.instantiate() as Node3D
	npc.name = "Elder_" + id
	npc.position = d["pos"] as Vector3
	npc.rotation = Vector3(0.0, float(d["yaw"]), 0.0)
	# 贴地：用地形高度
	var terrain := holder.get_parent().get_node_or_null("Terrain") as TerrainSystem
	if terrain != null:
		npc.position.y = terrain.get_height_at(npc.position.x, npc.position.z)
	# 给长老加一个碰撞体，避免玩家穿过去
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = 4
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.6
	cs.shape = cap
	cs.position = Vector3(0.0, 0.8, 0.0)
	body.add_child(cs)
	npc.add_child(body)
	# 头顶一个小灯，远处也能看见（"这里有 NPC"的可读性）
	var light := OmniLight3D.new()
	light.name = "Glow"
	light.position = Vector3(0.0, 1.45, 0.0)
	light.omni_range = 4.5
	light.light_energy = 0.0
	light.shadow_enabled = false
	npc.add_child(light)
	# 头顶宝珠的微光：按长老元素上色
	var sys := _staff_system()
	if sys != null:
		var col: Color = sys.call("element_color", int(d["element"]))
		light.light_color = col
		npc.set_meta("glow_color", col)
	holder.add_child(npc)
	# 头顶缓慢浮动的小标记（可交互提示）
	var marker := MeshInstance3D.new()
	marker.name = "Marker"
	var sm := SphereMesh.new()
	sm.radius = 0.07
	sm.height = 0.14
	sm.radial_segments = 8
	sm.rings = 5
	marker.mesh = sm
	var mat := StandardMaterial3D.new()
	var mc: Color = npc.get_meta("glow_color", Color.WHITE)
	mat.albedo_color = mc
	mat.emission_enabled = true
	mat.emission = mc
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat
	marker.position = Vector3(0.0, 2.05, 0.0)
	npc.add_child(marker)
	_nodes[id] = npc


func _process(delta: float) -> void:
	# 头顶标记上下浮动 + 灯光呼吸，让 NPC "活着"
	var t := Time.get_ticks_msec() / 1000.0
	for id in _nodes.keys():
		var npc: Node3D = _nodes[id]
		if not is_instance_valid(npc):
			continue
		var marker := npc.get_node_or_null("Marker") as Node3D
		if marker != null:
			marker.position.y = 2.05 + sin(t * 1.8 + float(id.hash() % 7)) * 0.06
			marker.rotate_y(delta * 1.2)
		var light := npc.get_node_or_null("Glow") as OmniLight3D
		if light != null:
			light.light_energy = 0.5 + 0.22 * sin(t * 2.0 + float(id.hash() % 5))


func _staff_system() -> Node:
	return get_node_or_null("/root/StaffSystem")


## 找玩家附近最近的长老；没有返回 ""
func nearest(player_pos: Vector3, max_dist: float = TALK_RANGE) -> String:
	var best := ""
	var best_d := max_dist * max_dist
	for id in _nodes.keys():
		var npc: Node3D = _nodes[id]
		if not is_instance_valid(npc):
			continue
		var d := npc.global_position.distance_squared_to(player_pos)
		if d < best_d:
			best_d = d
			best = String(id)
	return best


func npc_node(id: String) -> Node3D:
	return _nodes.get(id, null)


func elder_name(id: String) -> String:
	var d: Dictionary = DEFS.get(id, {})
	return str(d.get("name", id))


func element_of(id: String) -> int:
	var d: Dictionary = DEFS.get(id, {})
	return int(d.get("element", 0))


## 当前应该说的话：还没赠完就提示，否则轮换日常台词
func next_line(id: String) -> String:
	var d: Dictionary = DEFS.get(id, {})
	var f := int(favor.get(id, 0))
	var g := int(gifted.get(id, 0))
	var gifts: Array = d.get("gifts", [])
	if g < gifts.size() and f >= _threshold_for(g):
		return "等等 —— 这根该归你了。拿好，别丢。"
	var lines: Array = d.get("lines", [])
	if lines.is_empty():
		return "……"
	var n := int(_talk_count.get(id, 0)) % lines.size()
	return str(lines[n])


func _threshold_for(index: int) -> int:
	if index < GIFT_THRESHOLDS.size():
		return int(GIFT_THRESHOLDS[index])
	return int(GIFT_THRESHOLDS[GIFT_THRESHOLDS.size() - 1]) + index * 10


## 与长老交谈一次：涨声望 → 可能赠杖 → 否则祝福手上的杖
## 返回一句给 UI 显示的话
func talk(id: String) -> String:
	if not DEFS.has(id):
		return "……"
	var d: Dictionary = DEFS[id]
	_talk_count[id] = int(_talk_count.get(id, 0)) + 1
	var line := next_line(id)
	favor[id] = int(favor.get(id, 0)) + FAVOR_PER_TALK
	emit_signal("favor_changed", id, int(favor[id]))

	var sys := _staff_system()
	var g := int(gifted.get(id, 0))
	var gifts: Array = d.get("gifts", [])
	var f := int(favor[id])

	# 1) 到门槛了就赠杖
	if g < gifts.size() and f >= _threshold_for(g):
		var sid := str(gifts[g])
		gifted[id] = g + 1
		if sys != null and bool(sys.call("has", sid)):
			sys.call("unlock", sid)
			# 同时给他一颗长老石，用于之后的祝福/升级
			sys.call("add_stone", sid, 1)
			emit_signal("staff_granted", id, sid)
			line = "%s：这根%s归你了 —— 拿着。" % [elder_name(id),
					str(sys.call("display_name", sid))]
		emit_signal("elder_spoke", id, line)
		return line

	# 2) 否则：祝福当前装备的杖（改元素 → 改动态效果与配色）
	if sys != null:
		var cur := str(sys.get("equipped"))
		if cur != "":
			var before: int = int(sys.call("element_of", cur))
			var elem := element_of(id)
			if before != elem:
				sys.call("bless", cur, elem)
				line = "%s：让%s之力流进你的%s。" % [elder_name(id),
						str(sys.call("element_name", elem)),
						str(sys.call("display_name", cur))]
	emit_signal("elder_spoke", id, line)
	return line


func favor_of(id: String) -> int:
	return int(favor.get(id, 0))


func gifted_count(id: String) -> int:
	return int(gifted.get(id, 0))


func next_gift(id: String) -> String:
	var d: Dictionary = DEFS.get(id, {})
	var gifts: Array = d.get("gifts", [])
	var g := int(gifted.get(id, 0))
	return str(gifts[g]) if g < gifts.size() else ""


func next_threshold(id: String) -> int:
	return _threshold_for(int(gifted.get(id, 0)))
