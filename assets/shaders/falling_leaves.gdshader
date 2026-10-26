shader_type spatial;
// ============================================================================
//  落叶效果（移植自 fast-tree: D:\sgames\fast-tree\src\core\fallingLeaves.js）
// ============================================================================
//  源实现要点（与这里的写法一一对应）：
//    ① 每片叶子只是一张卡片（4 顶点 / 2 三角），整层**一个 draw call**
//    ② 顶点属性里 POSITION 存的是**出生点**，卡片形状由 UV 在顶点着色器里展开
//    ③ 生命循环 t = fract(TIME × 速度 × 每叶速度差 + 每叶相位) —— 叶子们不同时落地
//    ④ 局部空间里做自旋 spin + 翻滚 tumble + 侧倾，落地前 15% 生命淡出
//    ⑤ 风场用**与树完全相同的一套 uniform**（scripts/wind.gd 每帧写）
//       → 风向一变，落叶立刻同向飘；风越大飘得越远
//    ⑥ 全程只读 TIME，CPU 零开销（脚本侧只在构建时写入一次顶点数据）
//
//  Godot 适配差异：
//    · 每片叶多带一个 fall_dist（CUSTOM1.x）= 出生点到地面的距离（源实现用整树高度，
//      低处的叶子会在地下走完大半生命 → 看不见；这里逐叶取真实距离）
//    · wind_force 是"米"量级（本项目风系统约定），乘 3 换算成源实现的 0..1 相对风强
//    · 无贴图时用椭圆裁形兜底（同源实现的 uHasMap < 0.5 分支）
// ============================================================================
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// ---- 风场（由 scripts/wind.gd 每帧写入；名字与 fast_tree_wind.gdshaderinc 保持一致）----
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_gust = 0.15;
uniform float wind_speed = 1.4;
uniform bool wind_enabled = true;
uniform float wind_force = 0.06;       // 米：树梢顺风偏移量级
uniform float wind_gust_speed = 0.16;
uniform float wind_bias = 0.30;

// ---- 落叶参数（对应 fast-tree 的 params.fall）----
uniform sampler2D leaf_tex : source_color, hint_default_white;
uniform bool has_map = true;
/// 卡片半宽/半高（由贴图宽高比决定：half.x = 0.5 × 宽高比，half.y = 0.5）
uniform vec2 card_half = vec2(0.35, 0.5);
uniform float fall_speed = 1.0;
/// 卡片尺寸倍率（米；整层共用，单片再乘 CUSTOM0.z 的随机大小）
uniform float size_scale = 0.35;
uniform float swirl = 1.0;
uniform float spin_speed = 1.2;
uniform float stagger = 0.6;
uniform float wind_follow = 1.0;
uniform float opacity = 1.0;
uniform float alpha_test = 0.35;
uniform vec4 tint : source_color = vec4(1.0);

varying vec2 v_uv;
varying float v_shade;
varying float v_fade;

// 旋转矩阵：Godot 着色语言不认 mat3 的 9 标量构造，必须按列用 vec3 拼
mat3 rot_x(float a) {
	float c = cos(a), s = sin(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}
mat3 rot_y(float a) {
	float c = cos(a), s = sin(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}
mat3 rot_z(float a) {
	float c = cos(a), s = sin(a);
	return mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
}

void vertex() {
	// ---- 每片叶子的随机参数（script 侧一次写入，运行时不再回写）----
	float phase = CUSTOM0.x;         // 生命循环偏移 0..1
	float speed_scale = CUSTOM0.y;   // 下落快慢差 0.65..1.35
	float leaf_size = CUSTOM0.z;     // 大小差 0.7..1.3
	float spin_dir = CUSTOM0.w;      // 自旋方向 ±1
	float fall_dist = max(2.0, CUSTOM1.x);

	// ① 生命进度 0..1（每片叶错开）
	float t = fract(TIME * fall_speed * speed_scale * 0.35 + phase);

	// ② 卡片局部形状（UV 铺满贴图）→ 自旋 + 翻滚 + 侧倾
	vec3 local = vec3((UV - 0.5) * 2.0 * card_half, 0.0) * size_scale * leaf_size;
	float spin = TIME * spin_speed * spin_dir * (0.6 + 0.8 * speed_scale) + phase * 6.28318;
	float tumble = t * 6.28318 * (0.8 + phase);
	mat3 R = rot_y(spin) * rot_x(tumble) * rot_z(phase * 6.28318 + spin * 0.4);
	local = R * local;

	// ③ 下落：从出生点落到地面（t = 1 时正好落地）
	vec3 p = VERTEX;
	p.y -= t * fall_dist;
	// 落地前 15% 生命淡出（与源实现一致）
	float fade = 1.0 - smoothstep(0.85, 1.0, t);

	// ④ 风场 + 打旋（与树同源；只推不拉 + bias 抬低谷）
	vec2 wd = normalize(wind_direction + vec2(1e-5, 1e-5));
	float gust = 1.0 - wind_gust * 0.6 * (1.0 - (sin(TIME * wind_gust_speed + phase * 6.28318) * 0.5 + 0.5));
	float along = wind_enabled ? (wind_force * 3.0 * wind_follow * (0.55 * gust + wind_bias * 0.45)) : 0.0;
	// 越到生命后期被吹得越远（源实现 3.0 + 14.0 × t）
	p.x += wd.x * along * (3.0 + 14.0 * t);
	p.z += wd.y * along * (3.0 + 14.0 * t);
	float ang = (t * 6.28318 + phase * 12.0) * (0.5 + swirl);
	p.x += sin(ang) * swirl * (0.25 + 0.75 * t) * stagger;
	p.z += cos(ang * 0.85) * swirl * (0.25 + 0.75 * t) * stagger;
	p.y += sin(TIME * (1.0 + wind_speed) + phase * 7.0) * along * 0.8;

	// ⑤ 卡片中心跟着出生点走，局部旋转只改朝向
	VERTEX = p + local;

	v_uv = UV;
	// 正面朝上时亮一点、背面暗一点（翻飞时的明暗变化），再乘落地淡出
	v_shade = (0.55 + 0.45 * max(0.0, R[1][1])) * fade;
	v_fade = fade;
}

void fragment() {
	vec4 tex = has_map ? texture(leaf_tex, v_uv) : vec4(1.0);
	if (has_map) {
		if (tex.a < alpha_test) {
			discard;
		}
	} else {
		// 无贴图兜底：用椭圆隐式方程裁出叶形（同源实现），否则会是一堆方块
		vec2 d = v_uv - vec2(0.5);
		if (length(vec2(d.x * 1.6, d.y)) > 0.5) {
			discard;
		}
	}
	vec3 base = has_map ? tex.rgb : tint.rgb;
	vec3 col = base * (has_map ? tint.rgb : vec3(1.0)) * v_shade;
	float alpha = opacity * v_fade;
	if (alpha < 0.01) {
		discard;
	}
	ALBEDO = col;
	ALPHA = alpha;
}
