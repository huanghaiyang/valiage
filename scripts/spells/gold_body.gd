extends Node3D
## 金色守护 —— 金色碎片从角色四周（上下左右）汇聚到身上，形成一层金色薄膜；
## 停止施法（**包含法力不足**）后，薄膜逐渐碎裂并向四周发散消失。
##
## 三个阶段：
##   ① 汇聚 gather_time   碎片在角色的**球面**上生成，各自速度不同、按曲线收拢到身上
##   ② 守护                薄膜贴上角色（菲涅尔金边）+ 一层金色罩壳；持续耗蓝
##   ③ 碎裂 shatter_time   薄膜按噪声**一块块被抠掉**，同时碎片向外飞散消失
##
## 装配：薄膜用 material_overlay 逐个贴到角色的网格上（不动物体材质）；
##       碎片用 GPUParticles3D + particles 着色器（位置自己算，见 gold_shard.gdshader）。
##
## 对外接口与其它术法一致：
##   setup / start_cast / stop_cast / is_casting / aim_dir / origin_global / ran_out_of_mana

const FILM_SHADER := "res://assets/shaders/gold_film.gdshader"
const SHARD_SHADER := "res://assets/shaders/gold_shard.gdshader"
const NOISE_TEX := "res://assets/textures/法术特效/Noise1_tiled.png"
const SHARD_TEX := "res://assets/textures/法术特效/kenney/particle-pack/star_04.png"

@export var mana_per_sec := 30.0      ## 每秒耗蓝
@export var gather_time := 0.75       ## 碎片汇聚时长
@export var shatter_time := 0.9       ## 碎裂发散时长
@export var shard_amount := 48        ## 碎片数量
@export var gather_radius := 2.6      ## 碎片生成半径（米）
@export var aura_gain := 1.12         ## 罩壳相对角色高度的比例
@export var aura_body := 0.05         ## 罩壳的实心感（接近 0 = 只留边缘发光的一层壳）

# 0 = 关 / 1 = 汇聚 / 2 = 守护中 / 3 = 碎裂
const ST_OFF := 0
const ST_GATHER := 1
const ST_FILM := 2
const ST_SHATTER := 3

var casting := false

var _player: Node3D = null
var _shards: GPUParticles3D = null
var _shard_mat: ShaderMaterial = null
var _film: ShaderMaterial = null
var _aura: MeshInstance3D = null
var _aura_mat: ShaderMaterial = null
var _mesh_prev: Array[Dictionary] = []      ## {mi, prev}
var _ran_out := false
var _state := ST_OFF
var _state_t := 0.0


func _ready() -> void:
	set_process(true)
	_build_shards()


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	if _state == ST_OFF or _state == ST_SHATTER:
		_build_film()                      # 贴薄膜（reveal=0，先不可见）
		_set_shard_mode(0)
		if _shards != null:
			_shards.restart()
			_shards.emitting = true
		_state = ST_GATHER
		_state_t = 0.0


func stop_cast() -> void:
	casting = false


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 本术法不瞄准，方向固定用角色正前方（保持接口一致）
func aim_dir() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.FORWARD
	return -(_player as Node3D).global_transform.basis.z


func origin_global() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return global_position
	return (_player as Node3D).global_position


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _player != null and is_instance_valid(_player):
		global_position = _player.global_position       # 跟着角色走
	_state_t += delta
	match _state:
		ST_OFF:
			return
		ST_GATHER:
			var k := clampf(_state_t / maxf(gather_time, 0.01), 0.0, 1.0)
			_set_reveal(smoothstep(0.55, 1.0, k))       # 碎片快到齐时薄膜才显形
			if k >= 1.0:
				_state = ST_FILM
				_state_t = 0.0
				_set_reveal(1.0)
		ST_FILM:
			_set_reveal(1.0)
			if Mana.spend_rate(delta, mana_per_sec):
				_ran_out = false
			else:
				_ran_out = true
				_begin_shatter()
			if not casting:
				_begin_shatter()
		ST_SHATTER:
			var k2 := clampf(_state_t / maxf(shatter_time, 0.01), 0.0, 1.0)
			_set_dissolve(k2)                            # 薄膜一块块被抠掉
			if k2 >= 1.0:
				_cleanup()


# ---------------------------------------------------------------- 内部
func _begin_shatter() -> void:
	if _state == ST_SHATTER or _state == ST_OFF:
		return
	_state = ST_SHATTER
	_state_t = 0.0
	# 碎片向外飞散（同一个粒子系统换成 mode 1 重新发射）
	_set_shard_mode(1)
	if _shards != null:
		_shards.restart()
		_shards.emitting = true


func _cleanup() -> void:
	_state = ST_OFF
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = d["prev"]
	_mesh_prev.clear()
	if _aura != null and is_instance_valid(_aura):
		_aura.queue_free()
		_aura = null
	if _shards != null:
		_shards.emitting = false
	_set_reveal(0.0)
	_set_dissolve(0.0)


# ---------------------------------------------------------------- 装配
func _build_shards() -> void:
	_shard_mat = ShaderMaterial.new()
	var psh := load(SHARD_SHADER) as Shader
	if psh == null:
		push_warning("[GoldBody] 缺少 gold_shard.gdshader")
		return
	_shard_mat.shader = psh
	_shard_mat.set_shader_parameter("mode", 0)
	_shard_mat.set_shader_parameter("radius", gather_radius)

	var draw := StandardMaterial3D.new()
	draw.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	draw.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	draw.vertex_color_use_as_albedo = true
	draw.disable_receive_shadows = true
	var tex := load(SHARD_TEX) as Texture2D
	if tex != null:
		draw.albedo_texture = tex

	var quad := QuadMesh.new()
	quad.size = Vector2(0.20, 0.20)

	var p := GPUParticles3D.new()
	p.name = "GoldShards"
	p.amount = shard_amount
	p.lifetime = gather_time + 0.15
	p.one_shot = true
	p.explosiveness = 0.25            # 错开一点出现，不要齐刷刷
	p.local_coords = true             # 跟着角色走
	p.process_material = _shard_mat
	p.draw_pass_1 = quad
	p.material_override = draw
	p.emitting = false
	# ★ 碎片在半径 2.6 米处生成，默认可见包围盒太小会被整体剔除
	p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	add_child(p)
	_shards = p


func _set_shard_mode(m: int) -> void:
	if _shard_mat != null:
		_shard_mat.set_shader_parameter("mode", m)


## 把金色薄膜逐个贴到角色的网格上（material_overlay，不动物体自己的材质），
## 同时量出角色高度，用来自动定金色罩壳的大小。
func _build_film() -> void:
	if _film == null:
		_film = ShaderMaterial.new()
		var fsh := load(FILM_SHADER) as Shader
		if fsh == null:
			push_warning("[GoldBody] 缺少 gold_film.gdshader")
			return
		_film.shader = fsh
		var nt := load(NOISE_TEX) as Texture2D
		if nt != null:
			_film.set_shader_parameter("noise_tex", nt)
		_film.set_shader_parameter("reveal", 0.0)
		_film.set_shader_parameter("dissolve", 0.0)

	if _player == null or not is_instance_valid(_player):
		return
	var meshes: Array[MeshInstance3D] = []
	_gather_meshes(_player, meshes)
	var lo := 1e9
	var hi := -1e9
	for mi in meshes:
		_mesh_prev.append({"mi": mi, "prev": mi.material_overlay})
		mi.material_overlay = _film
		if mi.mesh != null:
			var aabb := mi.mesh.get_aabb()
			var xf := mi.global_transform
			for i in range(8):
				var c := aabb.position + Vector3(
						aabb.size.x if (i & 1) != 0 else 0.0,
						aabb.size.y if (i & 2) != 0 else 0.0,
						aabb.size.z if (i & 4) != 0 else 0.0)
				lo = minf(lo, (xf * c).y)
				hi = maxf(hi, (xf * c).y)
	if lo > hi:
		return
	# 金色罩壳：包住角色的一层光壳（与薄膜共用材质 -> 一起碎裂）
	var h := hi - lo
	var r := maxf(h * 0.5 * aura_gain, 0.35)
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	var aura := MeshInstance3D.new()
	aura.name = "GoldAura"
	aura.mesh = sm
	# ★ 罩壳用**自己的一份材质**：只保留边缘发光（body_strength 接近 0）。
	#   和身体薄膜共用一份材质时，罩壳会变成一个**实心金球**把角色整个盖住，
	#   反而看不到需求要的"一身金色薄膜"。
	_aura_mat = ShaderMaterial.new()
	_aura_mat.shader = _film.shader
	_aura_mat.set_shader_parameter("noise_tex", _film.get_shader_parameter("noise_tex"))
	_aura_mat.set_shader_parameter("reveal", 0.0)
	_aura_mat.set_shader_parameter("dissolve", 0.0)
	_aura_mat.set_shader_parameter("body_strength", aura_body)
	_aura_mat.set_shader_parameter("rim_strength", 1.7)
	_aura_mat.set_shader_parameter("rim_power", 3.2)
	_aura_mat.set_shader_parameter("crack_glow", 1.4)
	aura.material_override = _aura_mat
	aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(aura)
	aura.position = Vector3(0.0, (lo + hi) * 0.5 - global_position.y, 0.0)
	_aura = aura


func _set_reveal(v: float) -> void:
	var r := clampf(v, 0.0, 1.0)
	if _film != null:
		_film.set_shader_parameter("reveal", r)
	if _aura_mat != null:
		_aura_mat.set_shader_parameter("reveal", r)


func _set_dissolve(v: float) -> void:
	var d := clampf(v, 0.0, 1.0)
	if _film != null:
		_film.set_shader_parameter("dissolve", d)
	if _aura_mat != null:
		_aura_mat.set_shader_parameter("dissolve", d)


func _gather_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		else:
			_gather_meshes(c, out)
