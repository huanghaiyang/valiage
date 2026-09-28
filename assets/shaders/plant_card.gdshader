shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_toon, vertex_lighting;

// ============================================================
// 植物卡片（refs/planets 抠出来的 138 株，见 .runtime/make_plants.py）
//
// 与 vegetation_wind.gdshader 的三点区别：
//   1. **真的用 alpha**。植被那版只拿 tex.a 当开关（`if (tex.a > 0.001)`），
//      因为 KayKit 模型没贴图、颜色全靠顶点色。植物是上一轮辛苦抠出来的
//      高斯软边贴图，alpha 必须原样送到片元，否则边缘又变成硬锯齿。
//   2. **不吃顶点色**。同样因为植物用的是真实贴图，颜色直接来自图，
//      不需要「albedo_color * COLOR」那套回填。
//   3. 法线在建模阶段就按「偏上」烘进了模型（见 make_plants.py 的 NORMAL_UP_MIX）：
//      卡片的几何法线是水平的，直接拿它着色的话顶光下整片叶子会发黑。
//
// 风参数由 Weather 每帧写进材质 uniform（不能用 global uniform，
// 原因见 vegetation_wind.gdshader 顶部的实测说明）。
// ============================================================

uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_strength = 0.25;
uniform float wind_gust = 0.0;
uniform float wind_speed = 1.4;
uniform float wind_turbulence = 0.35;

uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.02;
uniform float sway_scale = 0.08;
uniform float bend_bias : hint_range(0.0, 1.0) = 0.35;
uniform float roughness : hint_range(0.0, 1.0) = 0.92;
uniform float base_ao : hint_range(0.0, 1.0) = 0.22;

vec3 wind_offset(vec3 world_pos, float h) {
	float gust = 1.0 + wind_gust * 2.2
			* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + world_pos.x * 0.013 + world_pos.z * 0.011));
	float amp = wind_strength * gust;

	float along = sin(TIME * wind_speed + world_pos.x * 0.35 + world_pos.z * 0.28);
	float across = cos(TIME * wind_speed * 0.83 + world_pos.x * 0.23 - world_pos.z * 0.31)
			* wind_turbulence;
	float phase = sin(TIME * wind_speed * 1.6 + world_pos.x * 0.7 + world_pos.z * 0.6);

	vec2 dir = normalize(wind_direction + vec2(0.0001));
	vec2 perp = vec2(-dir.y, dir.x);
	vec2 horiz = dir * (bend_bias + (1.0 - bend_bias) * along) + perp * across * 0.5;
	horiz += perp * phase * 0.15 * h;
	return vec3(horiz.x, 0.0, horiz.y) * (h * sway_scale * amp);
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = max(VERTEX.y, 0.0);
	// 开方：低处也有一点点摆动，不至于只有顶尖在动
	float hw = sqrt(clamp(h, 0.0, 12.0) * 0.5);
	vec3 offset = wind_offset(world_pos, hw);
	VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	if (tex.a <= alpha_cut) {
		discard;
	}
	// 根部稍微压暗一点：卡片贴地时不容易"飘"
	float ao = mix(1.0 - base_ao, 1.0, clamp(UV.y * 2.2, 0.0, 1.0));
	ALBEDO = tex.rgb * tint * ao;
	ALPHA = tex.a;
	ROUGHNESS = roughness;
	SPECULAR = 0.05;
}
