extends Node3D
## ============================================================================
## combat_test.gd —— 攻击数值测试场景（scenes/combat_test.tscn）的装配脚本
## ----------------------------------------------------------------------------
## CameraRig 不会自己去找节点：它依赖的 camera / player / terrain 都是 @export，
## 由 main.gd::_wire_camera_rig() 在运行时注入。本场景没有 main.gd，所以在这里
## 做同样的事（CameraRig 的 _physics_process 每帧都会用 player / terrain，漏一个
## 就会刷 "Nonexistent function ... in base 'Nil'"）。
##
## 场景内容：40×40 平地 + 角色 + 正前方 6m 的"人物靶子"（scenes/damage_dummy.gd）。
## 靶子在组 "enemies" 里，火焰灼烧 / 火焰推进 / 蓝色龙卷风会把伤害打到它身上，
## 头顶 Label3D 实时显示累计伤害 / 命中次数 / 平均 DPS；按 R 清零。
## ============================================================================

@onready var camera_rig: CameraRig = $CameraRig
@onready var player: Player = $Player
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _terrain: TerrainSystem = $Terrain


func _ready() -> void:
	camera_rig.camera = _camera
	camera_rig.player = player
	camera_rig.terrain = _terrain
	camera_rig.aim_from_player()
	print("[攻击测试] 场景就绪：靶子在角色正前方 6m（Q 选法术，R 清零统计）")
