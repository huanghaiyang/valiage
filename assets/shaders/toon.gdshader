shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_disabled;

// ============================================================
// Cozy Vale 卡通风格材质
// 三阶渐变光照 + 柔和边缘光 + 可调明暗面颜色
// 支持顶点色（MultiMesh 随机色）+ 手绘噪点细节
// ============================================================

uniform vec3 albedo_color : source_color = vec3(0.85, 0.82, 0.75);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform float albedo_tex_scale : hint_range(0.1, 20.0) = 1.0;

// 卡通渐变光照
uniform vec3 shadow_color : source_color = vec3(0.55, 0.52, 0.55);
uniform vec3 mid_color : source_color = vec3(0.78, 0.74, 0.72);
uniform float toon_threshold_1 : hint_range(0.0, 1.0) = 0.35;
uniform float toon_threshold_2 : hint_range(0.0, 1.0) = 0.62;

// 边缘光
uniform vec3 rim_color : source_color = vec3(0.92, 0.96, 1.0);
uniform float rim_intensity : hint_range(0.0, 3.0) = 0.45;
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;

// 可选轮廓（假轮廓：边缘光反转，用于草地等）
uniform float outline_boost : hint_range(0.0, 1.0) = 0.0;

// 细节
uniform float roughness : hint_range(0.0, 1.0) = 0.92;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.08;

// 顶点色混合强度：0 = 忽略顶点色，1 = 完全使用顶点色（MultiMesh 随机色）
uniform float color_variation : hint_range(0.0, 1.0) = 0.0;
// 手绘噪点细节强度（世界空间颗粒感）
uniform float detail_strength : hint_range(0.0, 0.3) = 0.04;

void fragment() {
	vec3 base = albedo_color;
	if (texture(albedo_texture, UV * albedo_tex_scale).a > 0.001) {
		base *= texture(albedo_texture, UV * albedo_tex_scale).rgb;
	}
	// 顶点色（MultiMesh 实例色）混合
	base *= mix(vec3(1.0), COLOR.rgb, color_variation);
	// 世界空间手绘噪点：细颗粒感，让纯色表面不单调
	if (detail_strength > 0.001) {
		vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float n = fract(sin(dot(wp.xz * 0.6, vec2(12.9898, 78.233))) * 43758.5453);
		float n2 = fract(sin(dot(wp.xz * 1.7 + 3.7, vec2(39.346, 11.135))) * 64119.6321);
		base *= 1.0 + (n * 0.7 + n2 * 0.3 - 0.5) * detail_strength * 2.0;
	}
	ALBEDO = base;
	ROUGHNESS = roughness;
	SPECULAR = specular_strength;
}

void light() {
	// 自定义卡通光照：根据 NdotL 分为三段
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	float toon = 0.0;
	if (ndl < toon_threshold_1) {
		toon = 0.0;
	} else if (ndl < toon_threshold_2) {
		toon = 0.5;
	} else {
		toon = 1.0;
	}
	// 平滑过渡，避免生硬锯齿
	float blend = smoothstep(toon_threshold_1 - 0.04, toon_threshold_1 + 0.04, ndl);
	vec3 diff = mix(shadow_color, albedo_color, blend);

	// 第二段过渡
	float blend2 = smoothstep(toon_threshold_2 - 0.05, toon_threshold_2 + 0.05, ndl);
	vec3 diff2 = mix(diff, albedo_color, blend2);

	// 暖色衰减
	vec3 light_color = LIGHT_COLOR * ATTENUATION;
	DIFFUSE_LIGHT += diff2 * light_color;

	// 简单高光
	float ndh = max(dot(NORMAL, normalize(LIGHT + VIEW)), 0.0);
	float spec = pow(ndh, 24.0) * toon;
	SPECULAR_LIGHT += vec3(spec) * light_color * 0.3;

	// 边缘光（只对主方向光起效，避免点光源闪烁）
	if (LIGHT_IS_DIRECTIONAL) {
		float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), rim_power);
		DIFFUSE_LIGHT += rim_color * rim * rim_intensity * light_color;
	}
}
