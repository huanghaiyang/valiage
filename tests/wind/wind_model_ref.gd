extends RefCounted
class_name WindModelRef
## ============================================================================
## fast-tree 风摆 · 参照模型（验证用，**只读产品代码，不改**）
## ============================================================================
## 本文件是两段**源实现**的逐行 GDScript 转录，两者必须分别对照、不要混为一谈：
##
##  A) `D:\sgames\fast-tree\src\core\windModel.js`
##     · leafTrajectory(wind, kind='current')  L46-108
##     · motionMetrics(wind, kind='current')   L117-170
##     · swayEnvelope(wind)                    L178-208
##     · rotateAroundAxis                      L21-35
##     → 函数：leaf_trajectory() / motion_metrics() / sway_envelope()
##       这是"分析模型"，JS 里就是给自检用的；本次逐行移植以便**离线**跑同样的断言。
##       只有 `current` 分支被移植（`legacy` 是历史对照版本，产品不用；传入会明确报错）。
##
##  B) `D:\sgames\fast-tree\src\core\materials.js` L29-135（顶点着色器 VERTEX_HEADER + vertexBody）
##     → 函数：compile_wind() + sample_leaf_at() / sample_leaf()
##       这是**真正要验证的对象**：用移植后的 GLSL 公式 + 真实烘焙的
##       CUSTOM0/CUSTOM1，算出一片叶子顶点在 t 时刻的模型空间位置。
##
## 数值约定（照抄源实现，别调参）：
##   · wind.strength（JS）/ wind_force（Godot uniform）= **米**，树梢顺风偏移量级
##   · direction 单位是**度**，wd = (cos, sin) 对应模型空间 (x, z)
##   · CUSTOM0 = (aOrigin.xyz, aWind)；CUSTOM1 = (aPhase, isLeaf, nodeId, baked)
##
## 与源实现的有意差异（都在测试里可接受，且明确列出）：
##   1) 不移植 `aGrow`/`uGrowth` 生长动画（本移植不用，见 docs/wind-port-spec.md）
##   2) 不移植 `uSelectMode` 节点选中判定（与风无关）
##   3) `modelMatrix` 默认取单位阵（测试场景里树在原点、无旋转）；需要时可传
##      wind["model_transform"] = Transform3D 走真实的模型→世界变换。
##   4) JS 的 `+x.toFixed(n)` 用 _round(x, n) 模拟（四舍五入到 n 位小数）。
## ============================================================================

## windModel.js L37-40 DEFAULTS（键名保持 JS 原样，便于逐行对照）
const DEFAULTS := {
	"strength": 0.15,
	"speed": 0.8,
	"frequency": 1.0,
	"gust": 0.5,
	"gustSpeed": 0.16,
	"turbulence": 0.12,
	"bias": 0.3,
	"leafFlutter": 0.6,
	"leafTwist": 0.5,
	"direction": 45.0,
}

## materials.js createSharedUniforms() 里的风场默认值（GLSL 参照实现用）
## uWindStrength=0.12 / uGust=0.35 / uGustSpeed=0.16 / uTurbulence=0.12
## uSpatialScale=0.22 / uWindBias=0.3 / uFlexFalloff=1.5 / uWindSpeed=0.8
## perMaterialUniforms(): uSway=1.0(叶) / leafFlutter / leafTwist 来自 params.wind
const GLSL_DEFAULTS := {
	"direction": 45.0,
	"speed": 0.8,
	"frequency": 1.0,
	"gust": 0.35,
	"gust_speed": 0.16,
	"turbulence": 0.12,
	"bias": 0.3,
	"force": 0.12,
	"spatial_scale": 0.22,
	"flex_falloff": 1.5,
	"seed": 0.0,
	"sway": 1.0,
	"enabled": true,
	"leaf_flutter": 0.6,
	"leaf_twist": 0.5,
}

## JS 的 `+x.toFixed(digits)`（四舍五入到 digits 位小数）
static func _round(x: float, digits: int) -> float:
	var m := pow(10.0, float(digits))
	return round(x * m) / m


## windModel.js L21-35 · 罗德里格旋转：v*c + cross(axis,v)*s + axis*dot(axis,v)*(1-c)
static func rotate_around_axis(v: Vector3, axis: Vector3, angle: float) -> Vector3:
	var c := cos(angle)
	var s := sin(angle)
	var d := axis.dot(v)
	var cross := axis.cross(v)
	return v * c + cross * s + axis * d * (1.0 - c)


## windModel.js L46-108 · leafTrajectory(kind='current')
## 返回 { pts: Array[Vector3], windDir: Vector2, windPerp: Vector2 }
## opts 键名与 JS 一致：aWind / stemDist / phase / dt / steps
static func leaf_trajectory(wind: Dictionary, kind: String = "current", opts: Dictionary = {}) -> Dictionary:
	var w := DEFAULTS.duplicate()
	for k in wind.keys():
		w[k] = wind[k]
	var freq := maxf(0.05, float(w.frequency))
	var rad := float(w.direction) * PI / 180.0
	var wd := Vector2(cos(rad), sin(rad))
	var wp := Vector2(-wd.y, wd.x)
	var a_wind := float(opts.get("aWind", 1.0))
	var stem_dist := float(opts.get("stemDist", 0.35))
	var phase := float(opts.get("phase", 1.234))
	var dt := float(opts.get("dt", 1.0 / 60.0))
	var steps := int(opts.get("steps", 1200))

	if kind != "current":
		push_error("[WindModelRef] leaf_trajectory: 只移植了 'current' 分支，收到 kind=%s" % kind)
		return {}

	var pts: Array[Vector3] = []
	pts.resize(steps)
	for i in steps:
		var tw := float(i) * dt * float(w.speed)
		# --- 现行: 顺风单向位移 (动态摆动占绝大部分) ---
		var wave := sin(tw + phase) * 0.72 + sin(tw * 2.17 * freq + phase * 1.7) * 0.28
		var osc := wave * 0.5 + 0.5
		var gust_factor := 1.0 - float(w.gust) * 0.6 * (1.0 - (sin(tw * float(w.gustSpeed) + phase * 0.21) * 0.5 + 0.5))
		var along := osc * gust_factor + float(w.bias) * 0.35
		var turb := sin(tw * 3.1 * freq + phase * 4.3)
		var x := (wd.x * along + wp.x * turb * float(w.turbulence)) * float(w.strength)
		var z := (wd.y * along + wp.y * turb * float(w.turbulence)) * float(w.strength)
		# --- 叶片: 固定方向弯曲 (水平分量主导) + 固定轴铰链俯仰 (叶柄不动) ---
		var flap := sin(tw * 4.1 * freq + phase * 6.3)
		var surge := sin(tw * 1.35 + phase * 2.1)
		var leaf_amp := float(w.leafFlutter) * float(w.strength) * 1.8 * (0.35 + a_wind)
		var bend_len := Vector3(wd.x, -0.3, wd.y).length()
		var bend_amt := stem_dist * leaf_amp * (0.5 + 0.35 * flap + 0.15 * surge)
		var bd := Vector3(wd.x / bend_len, -0.3 / bend_len, wd.y / bend_len)
		var rel := Vector3(
			wp.x * stem_dist + bd.x * bend_amt,
			bd.y * bend_amt,
			wp.y * stem_dist + bd.z * bend_amt)
		var pitch := flap * float(w.leafTwist) * 0.5 * (0.35 + float(w.strength) * 2.0)
		rel = rotate_around_axis(rel, Vector3(wp.x, 0.0, wp.y), pitch)
		pts[i] = Vector3(x + rel.x, rel.y, z + rel.z)
	return {"pts": pts, "windDir": wd, "windPerp": wp}


## windModel.js L117-170 的逐行转录，但输入是**任意点集**（供 sample_leaf 轨迹复用）。
static func metrics_from_points(pts: Array, wd: Vector2, wp: Vector2) -> Dictionary:
	var n := pts.size()
	if n <= 0:
		return {}
	var cx := 0.0
	var cy := 0.0
	var cz := 0.0
	for p in pts:
		var v: Vector3 = p
		cx += v.x
		cy += v.y
		cz += v.z
	cx /= float(n)
	cy /= float(n)
	cz /= float(n)
	var sa := 0.0
	var sp := 0.0
	var sv := 0.0
	var sxx := 0.0
	var szz := 0.0
	var sxz := 0.0
	var min_a := INF
	var max_a := -INF
	var min_p := INF
	var max_p := -INF
	for p in pts:
		var v: Vector3 = p
		var dx: float = v.x - cx
		var dy: float = v.y - cy
		var dz: float = v.z - cz
		var a: float = dx * wd.x + dz * wd.y
		var q: float = dx * wp.x + dz * wp.y
		sa += a * a
		sp += q * q
		sv += dy * dy
		sxx += dx * dx
		szz += dz * dz
		sxz += dx * dz
		if a < min_a:
			min_a = a
		if a > max_a:
			max_a = a
		if q < min_p:
			min_p = q
		if q > max_p:
			max_p = q
	var rms_along := sqrt(sa / float(n))
	var rms_perp := sqrt(sp / float(n))
	var rms_vert := sqrt(sv / float(n))
	var horiz := sa + sp
	var theta := 0.5 * atan2(2.0 * (sxz / float(n)), sxx / float(n) - szz / float(n))
	return {
		"samples": n,
		"rmsAlong": _round(rms_along, 4),
		"rmsPerp": _round(rms_perp, 4),
		"rmsVert": _round(rms_vert, 4),
		"thinness": _round(rms_perp / maxf(1e-9, rms_along), 3),
		"horizontalShare": _round(horiz / maxf(1e-12, horiz + sv), 3),
		# JS: ((theta*180/PI + 360) % 180) —— 负数角会落到 180+theta，即 [0,180) 模
		"azimuthDeg": _round(fmod((theta * 180.0 / PI + 360.0), 180.0), 1),
		"spanAlong": _round(max_a - min_a, 4),
		"spanPerp": _round(max_p - min_p, 4),
	}


## windModel.js L117-170 · motionMetrics
static func motion_metrics(wind: Dictionary, kind: String = "current", opts: Dictionary = {}) -> Dictionary:
	var traj := leaf_trajectory(wind, kind, opts)
	if traj.is_empty():
		return {}
	return metrics_from_points(traj["pts"], traj["windDir"], traj["windPerp"])


## windModel.js L178-208 · swayEnvelope（只看枝条位移，不含叶片局部弯曲）
static func sway_envelope(wind: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var w := DEFAULTS.duplicate()
	for k in wind.keys():
		w[k] = wind[k]
	var freq := maxf(0.05, float(w.frequency))
	var dt := float(opts.get("dt", 1.0 / 60.0))
	var steps := int(opts.get("steps", 2400))
	var phase := float(opts.get("phase", 0.7))
	var flex := float(opts.get("flex", 1.0))
	var min_a := INF
	var max_a := -INF
	var min_p := INF
	var max_p := -INF
	var sum := 0.0
	for i in steps:
		var tw := float(i) * dt * float(w.speed)
		var wave := sin(tw + phase) * 0.72 + sin(tw * 2.17 * freq + phase * 1.7) * 0.28
		var osc := wave * 0.5 + 0.5
		var gust_factor := 1.0 - float(w.gust) * 0.6 * (1.0 - (sin(tw * float(w.gustSpeed) + phase * 0.21) * 0.5 + 0.5))
		var along := (osc * gust_factor + float(w.bias) * 0.35) * float(w.strength) * flex
		var turb := sin(tw * 3.1 * freq + phase * 4.3) * float(w.turbulence) * float(w.strength) * flex
		if along < min_a:
			min_a = along
		if along > max_a:
			max_a = along
		if turb < min_p:
			min_p = turb
		if turb > max_p:
			max_p = turb
		sum += along
	return {
		"p2p": _round(max_a - min_a, 4),
		"meanAlong": _round(sum / float(steps), 4),
		"perpP2P": _round(max_p - min_p, 4),
	}


# ============================================================================
# 参照 GLSL 实现（materials.js L29-135）
# ============================================================================

## 把 wind 字典解析/编译成一次性的数值参数（避免 2400 步循环里反复查字典）。
## 兼容两套键名：
##   · Godot 侧 uniform 命名：direction / speed / frequency / gust / gust_speed /
##     turbulence / bias / force / spatial_scale / flex_falloff / seed / sway /
##     enabled / leaf_flutter / leaf_twist / model_transform
##   · fast-tree JS 命名（windModel.js）：strength ↔ force
static func compile_wind(wind: Dictionary) -> Dictionary:
	var w := GLSL_DEFAULTS.duplicate()
	for k in wind.keys():
		w[k] = wind[k]
	# JS 名 -> Godot 名（只在这一个地方做映射）
	if wind.has("strength") and not wind.has("force"):
		w["force"] = wind["strength"]
	if wind.has("gustSpeed") and not wind.has("gust_speed"):
		w["gust_speed"] = wind["gustSpeed"]
	if wind.has("spatialScale") and not wind.has("spatial_scale"):
		w["spatial_scale"] = wind["spatialScale"]
	if wind.has("flexFalloff") and not wind.has("flex_falloff"):
		w["flex_falloff"] = wind["flexFalloff"]
	if wind.has("leafFlutter") and not wind.has("leaf_flutter"):
		w["leaf_flutter"] = wind["leafFlutter"]
	if wind.has("leafTwist") and not wind.has("leaf_twist"):
		w["leaf_twist"] = wind["leafTwist"]

	var rad := float(w.direction) * PI / 180.0
	# GLSL: normalize(uWindDir + vec2(1e-5, 1e-6))
	var wd := (Vector2(cos(rad), sin(rad)) + Vector2(1e-5, 1e-6)).normalized()
	return {
		"windDir": wd,
		"windPerp": Vector2(-wd.y, wd.x),
		"speed": float(w.speed),
		"frequency": maxf(0.05, float(w.frequency)),
		"gust": float(w.gust),
		"gust_speed": float(w.gust_speed),
		"turbulence": float(w.turbulence),
		"bias": float(w.bias),
		"force": float(w.force),
		"spatial_scale": float(w.spatial_scale),
		"flex_falloff": float(w.flex_falloff),
		"seed": float(w.seed),
		"sway": float(w.sway),
		"enabled": 1.0 if bool(w.enabled) else 0.0,
		"leaf_flutter": float(w.leaf_flutter),
		"leaf_twist": float(w.leaf_twist),
		"model_transform": w.get("model_transform", Transform3D.IDENTITY),
	}


## 参照 GLSL 的顶点采样（单次，未编译版；等价于 compile_wind + sample_leaf_at）
static func sample_leaf(wind: Dictionary, custom0: Vector4, custom1: Vector4, t: float,
		model_pos: Vector3 = Vector3.ZERO) -> Dictionary:
	return sample_leaf_at(compile_wind(wind), custom0, custom1, t, model_pos)


## 参照 GLSL 的顶点采样（已编译参数版）。
## custom0 = (aOrigin.xyz, aWind)；custom1 = (aPhase, isLeaf, nodeId, baked)
## 返回 { pos: Vector3, flex: float, is_leaf: bool, baked: bool, rel: Vector3 }
static func sample_leaf_at(cw: Dictionary, custom0: Vector4, custom1: Vector4, t: float,
		model_pos: Vector3 = Vector3.ZERO) -> Dictionary:
	var wd: Vector2 = cw["windDir"]
	var wp: Vector2 = cw["windPerp"]
	var a_wind := custom0.w
	var a_phase := custom1.x
	var a_origin := Vector3(custom0.x, custom0.y, custom0.z)
	var is_leaf := custom1.y > 0.5

	# vec4 treeWorld = modelMatrix * vec4(treePos, 1.0);
	var tree_world: Vector3 = (cw["model_transform"] as Transform3D) * model_pos
	# float flex = pow(clamp(aWind, 0.0, 1.0), uFlexFalloff);
	var flex := pow(clampf(a_wind, 0.0, 1.0), float(cw["flex_falloff"]))
	# float phase = aPhase + dot(treeWorld.xz, windDir) * uSpatialScale + uSeed * 0.017;
	var phase := a_phase + (tree_world.x * wd.x + tree_world.z * wd.y) * float(cw["spatial_scale"]) \
			+ float(cw["seed"]) * 0.017
	# float tw = uTime * uWindSpeed;
	var tw := t * float(cw["speed"])
	var freq: float = cw["frequency"]
	# float wave = sin(tw + phase) * 0.72 + sin(tw * 2.17 * freq + phase * 1.7) * 0.28;
	var wave := sin(tw + phase) * 0.72 + sin(tw * 2.17 * freq + phase * 1.7) * 0.28
	var osc := wave * 0.5 + 0.5
	var gust := 1.0 - float(cw["gust"]) * 0.6 \
			* (1.0 - (sin(tw * float(cw["gust_speed"]) + phase * 0.21) * 0.5 + 0.5))
	var along := osc * gust + float(cw["bias"]) * 0.35
	var turb := sin(tw * 3.1 * freq + phase * 4.3)
	var sway := wd * along + wp * turb * float(cw["turbulence"])
	var amount := float(cw["force"]) * float(cw["sway"]) * flex * float(cw["enabled"])
	var tree_pos := model_pos
	tree_pos.x += sway.x * amount
	tree_pos.z += sway.y * amount

	var rel_out := tree_pos - a_origin
	if is_leaf:
		# vec3 rel = treePos - aOrigin;  float stemDist = length(rel);
		var rel := tree_pos - a_origin
		var stem_dist := rel.length()
		var flap := sin(tw * 4.1 * freq + phase * 6.3)
		var surge := sin(tw * 1.35 + phase * 2.1)
		var leaf_amp := float(cw["leaf_flutter"]) * float(cw["force"]) * 1.8 * float(cw["enabled"]) \
				* (0.35 + a_wind)
		var bend_dir := Vector3(wd.x, -0.3, wd.y).normalized()
		rel += bend_dir * stem_dist * leaf_amp * (0.5 + 0.35 * flap + 0.15 * surge)
		var pitch := flap * float(cw["leaf_twist"]) * 0.5 * float(cw["enabled"]) \
				* (0.35 + float(cw["force"]) * 2.0)
		rel = rotate_around_axis(rel, Vector3(wp.x, 0.0, wp.y), pitch)
		tree_pos = a_origin + rel
		rel_out = rel
	return {
		"pos": tree_pos,
		"flex": flex,
		"is_leaf": is_leaf,
		"baked": custom1.w > 0.5,
		"rel": rel_out,
	}


## 采样一整条叶尖轨迹（steps 步，t = i*dt；与 leafTrajectory 的时间轴一致）
static func sample_track(cw: Dictionary, custom0: Vector4, custom1: Vector4, model_pos: Vector3,
		steps: int, dt: float) -> Array[Vector3]:
	var pts: Array[Vector3] = []
	pts.resize(steps)
	for i in steps:
		var r := sample_leaf_at(cw, custom0, custom1, float(i) * dt, model_pos)
		pts[i] = r["pos"]
	return pts
