shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled, fog_disabled;

// ============================================================
// 河流水面（低多边形风格）
// 低多边形水：平色 + 轻微波纹 + 菲涅尔提亮 + 顺流向的浅色条纹。
// 颜色偏青绿，与谷地草绿形成对比但不过饱和（中世纪做旧色调）。
// ============================================================

uniform vec3 water_color : source_color = vec3(0.239, 0.475, 0.541);
uniform vec3 deep_color : source_color = vec3(0.098, 0.278, 0.333);
uniform vec3 crest_color : source_color = vec3(0.639, 0.784, 0.804);
uniform float flow_speed = 0.35;      // 沿 UV.y（流向）滚动速度
uniform float wave_scale = 3.0;       // 波纹密度
uniform float alpha : hint_range(0.0, 1.0) = 0.68;   // 半透明：能看见水下河床

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// UV.y 是沿河累积长度，滚动它就有"水在流"的感觉
	vec2 uv = UV * wave_scale;
	uv.y -= TIME * flow_speed * 2.0;
	float w = vnoise(uv) * 0.6 + vnoise(uv * 2.3 + 11.0) * 0.4;
	// 稀疏的亮色水脊
	float crest = smoothstep(0.72, 0.86, w);
	vec3 col = mix(deep_color, water_color, smoothstep(0.25, 0.75, w));
	col = mix(col, crest_color, crest * 0.35);
	ALBEDO = col;
	// 菲涅尔：视线越掠射越亮，模拟水面反光
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	ALBEDO = mix(ALBEDO, crest_color, fres * 0.45);
	ROUGHNESS = 0.22;
	ALPHA = alpha + crest * 0.1;
}
