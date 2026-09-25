shader_type spatial;
render_mode diffuse_toon, cull_disabled, depth_draw_always;

// ============================================================
// 草地 / 树叶 随风摆动材质
// 顶点动画 + 卡通渐变
// ============================================================

uniform vec3 albedo_color : source_color = vec3(0.42, 0.72, 0.35);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec3 shadow_color : source_color = vec3(0.32, 0.55, 0.28);
uniform float wind_strength : hint_range(0.0, 2.0) = 0.25;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;

void vertex() {
	// 基于世界位置的简单正弦摆动，低模植被更生动
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wind_speed;
	float sway = sin(world_pos.x * 0.6 + t) * cos(world_pos.z * 0.5 + t * 0.8);
	// 顶点越高摆动越大
	float height_factor = clamp(VERTEX.y * 0.08, 0.0, 1.0);
	VERTEX.x += sway * wind_strength * height_factor;
	VERTEX.z += cos(world_pos.x * 0.4 + t * 0.7) * wind_strength * 0.6 * height_factor;
}

void fragment() {
	vec3 base = albedo_color;
	if (texture(albedo_texture, UV).a > 0.001) {
		base *= texture(albedo_texture, UV).rgb;
	}
	ALBEDO = base;
	ROUGHNESS = roughness;
}

void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	float toon = step(0.30, ndl);
	vec3 diff = mix(shadow_color, albedo_color, toon);
	DIFFUSE_LIGHT += diff * LIGHT_COLOR * ATTENUATION;
}
