shader_type spatial;
render_mode diffuse_toon, cull_disabled, depth_draw_always, vertex_lighting;

// ============================================================
// 植被风摇（草 / 花 / 灌木 / 树通用）
// 风向由天气系统写入全局 uniform，所有植被按同一风向摆动。
// 顶点高度越高摆动越大；树冠（高处）同时做轻微扭曲，形成"树梢摆动"。
// 实例颜色（use_colors）会自动乘进 COLOR，这里不额外处理。
// ============================================================

// ---- 风（由 Weather 系统每帧写入）----
// ---- 风（由 Weather 系统每帧写入共享材质）----
//
// 这里绝对不能用 global uniform。实测 Godot 4.7 运行时（非编辑器）全局着色器
// 参数完全不工作：RenderingServer.global_shader_parameter_get_list() 永远返回空数组，
// global_shader_parameter_add()/set() 被静默忽略，连 set_override() 也只影响片元阶段 ——
// 顶点阶段永远读到 project.godot 里的静态默认值。表现就是风摇代码齐全但画面纹丝不动。
// 改成普通 uniform 后由 Weather 直接写这份共享材质，实测位移生效（dx1=197px）。
uniform vec2 wind_direction = vec2(1.0, 0.0);  // 水平风向（已归一化）
uniform float wind_strength = 0.25;            // 风力 0..1.5
uniform float wind_gust = 0.0;                 // 阵风 0..1，越高越猛
uniform float wind_speed = 1.4;                // 摆动频率
uniform float wind_turbulence = 0.35;          // 湍流（乱摆程度）

// ---- 材质 ----
uniform vec3 albedo_color : source_color = vec3(0.42, 0.72, 0.35);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec3 shadow_color : source_color = vec3(0.32, 0.55, 0.28);
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float sway_scale = 0.06;      // 每米高度的摆幅系数
uniform float bend_bias : hint_range(0.0, 1.0) = 0.35; // 顺风持续倾斜比例
uniform bool flat_shading = true;   // 低多边形平面着色

// ---- 燃烧（本项目新增）----
// ★ 为什么把 burn 做进**这个着色器**，而不是在外面叠一层：
//   这个着色器是 **不透明** 渲染（没有写 ALPHA，形状来自几何体），
//   在外面叠一层黑只会盖成"没有光照、没有层次的纯黑块"，
//   而且还要自己去解决轮廓/透明问题（反复踩坑）。做进着色器就天然正确：
//   未烧的部分保持原样，烧过的部分直接改 ALBEDO、并且不再受光。
//   默认 burn = 0 -> 输出与改动前完全一致（不影响没被烧的植被）。
uniform float burn : hint_range(0.0, 1.0) = 0.0;     // 0..1 烧蚀进度（斑点扩大）
uniform float ash : hint_range(0.0, 1.0) = 0.0;      // 灰化/消失进度
uniform vec3 char_color : source_color = vec3(0.07, 0.06, 0.05);
uniform vec3 ember_color : source_color = vec3(1.0, 0.32, 0.05);
uniform float burn_noise_scale : hint_range(0.1, 6.0) = 1.6;
uniform float burn_ember : hint_range(0.0, 2.0) = 0.45;
uniform float burn_phase = 0.0;                       // 每株随机，避免斑点位置雷同

varying float v_burned;
varying float v_ember;

// 顶点着色器中的风偏移计算（世界空间 -> 模型空间）
// ★ 这段绝对不能删：全项目植被的风吹摆动都靠它（本项目新增 burn 时我误删过一次）
vec3 wind_offset(vec3 world_pos, float h) {
	// 阵风：低频脉动，让风"一阵一阵"
	float gust = 1.0 + wind_gust * 2.2
			* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + world_pos.x * 0.013 + world_pos.z * 0.011));
	float amp = wind_strength * gust;

	// 顺风持续倾斜 + 垂直风向的横向摆动
	float along = sin(TIME * wind_speed + world_pos.x * 0.35 + world_pos.z * 0.28);
	float across = cos(TIME * wind_speed * 0.83 + world_pos.x * 0.23 - world_pos.z * 0.31)
			* wind_turbulence;
	float phase = sin(TIME * wind_speed * 1.6 + world_pos.x * 0.7 + world_pos.z * 0.6);

	vec2 dir = normalize(wind_direction + vec2(0.0001));
	vec2 perp = vec2(-dir.y, dir.x);
	vec2 horiz = dir * (bend_bias + (1.0 - bend_bias) * along) + perp * across * 0.5;
	// 高处再加一点相位差，避免整棵树像一块板
	horiz += perp * phase * 0.15 * h;
	return vec3(horiz.x, 0.0, horiz.y) * (h * sway_scale * amp);
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 高度权重：模型局部高度，越高摆得越狠（树冠 > 草丛）
	float h = max(VERTEX.y, 0.0);
	float hw = sqrt(clamp(h, 0.0, 12.0) * 0.5);   // 开方：低处也有轻微摆动
	vec3 offset = wind_offset(world_pos, hw);
	// 偏移是世界空间，转回模型空间再叠加
	VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
}

void fragment() {
	// KayKit 模型没有贴图：每个 surface 的 albedo 在 _load_glb_mesh() 里被烘进了顶点色。
	// COLOR 是实例色(use_colors) * 顶点色，所以这里一次拿到模型基色 + 每株的随机色偏。
	vec3 base = albedo_color * COLOR.rgb;
	vec4 tex = texture(albedo_texture, UV);
	if (tex.a > 0.001) {
		base *= tex.rgb;
	}
	// ★ 燃烧：世界坐标噪声决定"斑点"，阈值随 burn 下降 -> 斑点逐个出现并连成片
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float n = fract(sin(dot(wp.xz + vec2(wp.y), vec2(12.9898, 78.233)) + burn_phase) * 43758.5453);
	float thr = clamp(1.0 - burn, 0.0, 1.0);
	float burned = 1.0 - smoothstep(thr - 0.02, thr + 0.02, n);
	float ember = exp(-pow((n - thr) / 0.05, 2.0)) * burn_ember * (1.0 - ash);
	// ★ 灰化：按噪声把已烧部分一块块抠掉（不需要自己处理透明度/轮廓，几何体说了算）
	if (ash > 0.001) {
		if (n < ash) {
			discard;
		}
	}
	v_burned = burned;
	v_ember = ember;
	// 烧过的部分变焦黑；未烧部分不变（乘 (1-burned) 保证不污染原外观）
	base = mix(base, char_color, burned);
	ALBEDO = base + ember_color * ember * 0.35;
	ROUGHNESS = roughness;
	if (flat_shading) {
		// 低多边形平面着色：用屏幕空间导数求面法线，得到硬边面片感
		// （MultiMesh 实例只含旋转/均匀缩放/平移，模型空间叉积方向 = 世界空间方向）
		NORMAL = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	}
}

void light() {
	// 烧焦处不再受光（炭是黑的），未烧处照常
	float lit = 1.0 - v_burned;
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	float toon = step(0.30, ndl);
	vec3 diff = mix(shadow_color, ALBEDO, toon);
	DIFFUSE_LIGHT += diff * LIGHT_COLOR * ATTENUATION * lit;
	DIFFUSE_LIGHT += ember_color * v_ember * 2.0 * ATTENUATION;   // 余烬自发光
}
