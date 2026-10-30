extends Node3D
## ============================================================================
## blood_flower_test.gd —— 【嗜血狂花】测试场景（scenes/测试/嗜血狂花测试.tscn）的装配脚本
## ----------------------------------------------------------------------------
## 与 combat_test.gd 同一套装配方式：本场景没有 main.gd，CameraRig 依赖的
## camera / player / terrain 三个 @export 由这里在运行时注入（漏一个就会每帧刷
## "Nonexistent function ... in base 'Nil'"）。
##
## 场景内容：40×40 平地 + 角色 + 4 个"人物靶子"（scripts/damage_dummy.gd，组 "enemies"）：
##   · 近靶（圈心附近）：验证 10s 持续掉血与体表流血
##   · 侧靶 / 远靶：验证"只在圈内的敌人才掉血、才流血"
## 进入场景时**预选**「嗜血狂花」，省掉每次开轮盘的步骤；按 Q 仍可正常重开轮盘。
## 靶子头顶 Label3D 实时显示累计伤害 / 命中次数 / 平均 DPS，按 R 清零。
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
	# 预选术法（仍可随时按 Q 重开轮盘改选别的）：SpellCaster 是 autoload，
	# 用 get_node_or_null + call 而不是直接写标识符 —— 与 player.gd 的跨上下文编译约定一致。
	var caster := get_node_or_null("/root/SpellCaster")
	if caster != null and caster.has_method("select_spell"):
		caster.call("select_spell", "blood_flower")
		print("[嗜血狂花测试] 已预选「嗜血狂花」：点地面圈选范围即可施放（Q 可重新打开轮盘）")
	else:
		print("[嗜血狂花测试] ✗ 找不到 SpellCaster 自动加载，请按 Q 手动选择术法")
	print("[嗜血狂花测试] 场景就绪：4 个靶子（组 enemies），按 R 清零统计")
