class_name Player
extends CharacterBody3D
## 玩家角色：第三方模型（KayKit Adventurers - Mage，CC0）
## CharacterBody3D + 胶囊碰撞体，由 CameraRig 用 move_and_slide 驱动（走物理碰撞）

var body: Node3D
var anim_player: AnimationPlayer
var _moving := false

const CHARACTER_SCENE := "res://assets/models/characters/Mage.glb"
# Mage 模型身体（头顶）原始约 2.94m，缩到 0.368 → 角色约 1.08m（门 1.7m 的约 64%）
const CHARACTER_SCALE := 0.368

# 碰撞体尺寸（胶囊，底部对齐脚底；高度匹配身体 1.08m，随缩放等比缩小）
const COLLIDER_RADIUS := 0.28
const COLLIDER_HEIGHT := 1.08
const COLLIDER_OFFSET_Y := 0.54

func _ready() -> void:
	body = _instantiate_character()
	if body == null:
		body = Node3D.new()
		body.name = "Visual"
		add_child(body)
	body.scale = Vector3.ONE * CHARACTER_SCALE

	# 角色碰撞体（胶囊，底部对齐脚底 origin）
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = COLLIDER_RADIUS
	cap.height = COLLIDER_HEIGHT
	col.shape = cap
	col.position = Vector3(0, COLLIDER_OFFSET_Y, 0)
	add_child(col)

	# 碰撞：层1=玩家；mask 与地形(2)/建筑(4)/植被(8)碰撞
	collision_layer = 1
	collision_mask = 2 | 4 | 8
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)

func _instantiate_character() -> Node3D:
	var scene: PackedScene = load(CHARACTER_SCENE)
	if scene == null:
		return null
	var inst := scene.instantiate()
	inst.name = "Visual"
	add_child(inst)
	anim_player = _find_animation_player(inst)
	if anim_player != null:
		_play_anim("Idle")
	return inst

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var r := _find_animation_player(c)
		if r != null:
			return r
	return null

func _play_anim(name: String) -> void:
	if anim_player != null and anim_player.has_animation(name):
		anim_player.play(name)

## 第一人称隐藏角色模型（避免相机卡进头部内部），第三人称显示
func set_body_visible(v: bool) -> void:
	if body != null:
		body.visible = v

## 角色面向水平移动方向（Mage 模型 +Z 为面部前方）
func face_direction(face: Vector3) -> void:
	if body != null:
		body.rotation.y = atan2(face.x, face.z)

func set_moving(m: bool) -> void:
	if m == _moving:
		return
	_moving = m
	if _moving:
		_play_anim("Walk")
	else:
		_play_anim("Idle")