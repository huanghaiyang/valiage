shader_type spatial;
render_mode cull_back, depth_draw_opaque;
// 框内高亮 / 框外变暗。
// 盒子用 原点 + 三个正交轴 + 半尺寸 描述（任意朝向都支持）。
// 每个片元取世界坐标，转到盒子局部空间，判断是否在盒内。

uniform vec4 base_color : source_color = vec4(0.78, 0.78, 0.78, 1.0);
uniform sampler2D base_tex : source_color, hint_default_white;
uniform bool use_tex = false;

uniform bool box_on = false;
uniform vec3 box_origin = vec3(0.0);
uniform vec3 box_bx = vec3(1.0, 0.0, 0.0);
uniform vec3 box_by = vec3(0.0, 1.0, 0.0);
uniform vec3 box_bz = vec3(0.0, 0.0, 1.0);
uniform vec3 box_half = vec3(1.0);

uniform float dim = 0.22;
uniform float inside_glow = 0.10;

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 rel = wp - box_origin;
	bool inside = box_on
		&& abs(dot(rel, box_bx)) <= box_half.x
		&& abs(dot(rel, box_by)) <= box_half.y
		&& abs(dot(rel, box_bz)) <= box_half.z;

	vec4 base = base_color;
	if (use_tex) {
		base *= texture(base_tex, UV);
	}

	float k = 1.0;
	if (box_on && !inside) {
		k = dim;
	}
	ALBEDO = base.rgb * k;
	if (box_on && inside) {
		EMISSION = base.rgb * inside_glow;
	} else {
		EMISSION = vec3(0.0);
	}
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
}
