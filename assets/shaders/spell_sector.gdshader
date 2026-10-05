shader_type spatial;
// 扇形施法区域（火焰推进专用）—— **独立于圆盘那一套**，不复用 spell_area.gdshader。
//
// 【为什么单独一份】选点器的圆盘材质是全局复用一份的，之前把扇形做进同一个着色器、
//   靠 sector_enabled 开关切换，结果状态会互相污染（切回圆盘法术时圆圈被扇形的
//   角度/内圈继续裁着 -> 圆圈直接看不见）。独立材质就没有这个问题。
//
// 【形状】UV 由脚本按圆盘映射（中心 0.5,0.5，边缘半径 0.5）：
//   · r = length(UV-0.5)*2        -> 归一化半径
//   · ang = atan(UV.y-0.5, UV.x-0.5) -> 与"中轴"同一套角度（脚本传的是 atan2(z,x)）
//   所以扇形 = (r > inner) 且 (|ang - axis| <= half)。
//
// 【观感】区域内部半透明白；两条边用白线（用户要求）；外弧保留圆盘的亮带，
//   内圈留白（角色前 sector_inner_m 米不画）。
// 地形适配由脚本负责（顶点逐个从上方打射线落在真实表面上）。
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.72);
/// 中轴方向（弧度，XZ 平面 atan2(z, x)）
uniform float axis = 0.0;
/// 半角（弧度）
uniform float half_angle = 0.785;
/// 内圈（归一化半径）：小于它的部分不画（角色前留白）
uniform float inner = 0.0;
/// 内部填充强度
uniform float fill_strength : hint_range(0.0, 2.0) = 0.55;
/// 两条边的白线强度
uniform float edge_strength : hint_range(0.0, 4.0) = 2.2;
/// 外弧亮带强度
uniform float rim_strength : hint_range(0.0, 4.0) = 1.6;

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = clamp(length(d) * 2.0, 0.0, 1.0);
	float ang = atan(d.y, d.x);
	float dd = ang - axis;
	dd = atan(sin(dd), cos(dd));                 // 包到 -PI..PI，避免跨 ±PI 断裂
	float ad = abs(dd);

	// 角域内（软化一点点避免锯齿）
	float inside = 1.0 - smoothstep(half_angle - 0.010, half_angle + 0.010, ad);
	// 内圈留白 + 外缘收边
	float inner_ok = smoothstep(inner - 0.010, inner + 0.010, r);
	float outer_ok = 1.0 - smoothstep(0.985, 1.0, r);
	// 外弧亮带（让扇形边界看得清）
	float rim = smoothstep(0.86, 1.0, r) * outer_ok;
	// 两条边的白线
	float edge = exp(-pow((ad - half_angle) / 0.028, 2.0));

	float a = inside * inner_ok * outer_ok * (fill_strength + rim_strength * rim);
	a += edge * edge_strength * inner_ok;        // 边线也要跟着内圈留白
	ALBEDO = mix(vec3(0.92, 0.95, 1.0), vec3(1.0), clamp(edge + rim * 0.6, 0.0, 1.0));
	ALPHA = clamp(a * tint.a, 0.0, 2.0);
}
