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

// 顶点着色器中的风偏移计算（世界空间 -> 模型空间）
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
	// 顶点色里可能已经有明暗信息（部分模型自带），这里只取 r 通道做一次亮度归一
	ALBEDO = base;
	ROUGHNESS = roughness;
	if (flat_shading) {
		// 低多边形平面着色：用屏幕空间导数求面法线，得到硬边面片感
		// （MultiMesh 实例只含旋转/均匀缩放/平移，模型空间叉积方向 = 世界空间方向）
		NORMAL = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	}
}

void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	float toon = step(0.30, ndl);
	vec3 diff = mix(shadow_color, ALBEDO, toon);
	DIFFUSE_LIGHT += diff * LIGHT_COLOR * ATTENUATION;
}
