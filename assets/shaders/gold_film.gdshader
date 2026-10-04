shader_type spatial;
// 金身薄膜 —— 贴在角色身上的一层金色光膜，可整体碎裂。
//
// 【观感来源】菲涅尔：**边缘亮、正对镜头的部分弱**。这正是"一层膜裹住身体"的视觉特征
//   （纯加一个恒定金色会像"整体染黄"，没有膜的感觉）。
//
// 【怎么碎裂】用**世界坐标**采样噪声，噪声低于 dissolve 的像素直接丢弃 —— 于是薄膜
//   会一块块被"抠掉"，边缘再补一圈更亮的金边，就是"金色薄膜逐渐碎裂"。
//   ★ 不用 UV：这批 Tripo 模型**没有 UV**（只有 POSITION/NORMAL），
//     按 UV 采样会恒为常量、碎裂会变成整片一起消失。
//
// 【渲染】加色 + 不受光 + 不写深度：它是光膜，不该遮挡角色本体，也不参与光照。
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D noise_tex : hint_default_black;

/// 金色
uniform vec3 gold_color : source_color = vec3(1.0, 0.76, 0.22);
/// 边缘（菲涅尔）强度
uniform float rim_strength : hint_range(0.0, 6.0) = 2.2;
/// 菲涅尔指数：越大只有更掠射的边缘才亮
uniform float rim_power : hint_range(0.5, 8.0) = 2.6;
/// 正对部分的基础亮度（薄膜感：不要太高，否则像染色）
uniform float body_strength : hint_range(0.0, 1.0) = 0.16;
/// 0 = 完全没成型，1 = 完整金身
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
/// 0 = 完好，1 = 完全碎掉
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
/// 碎块边缘的亮边强度
uniform float crack_glow : hint_range(0.0, 4.0) = 1.6;
/// 噪声的世界尺度（越大碎块越小）
uniform float noise_scale : hint_range(0.05, 3.0) = 0.55;

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float n = texture(noise_tex, wp.xz * noise_scale + vec2(wp.y * noise_scale * 0.7)).r;

	// 碎裂：噪声低于阈值的像素被抠掉
	if (n < dissolve) {
		discard;
	}
	// 裂口附近补一圈亮边
	float edge = 1.0 - smoothstep(dissolve, dissolve + 0.10, n);

	float f = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0),
			rim_power);
	float a = (body_strength + rim_strength * f) * reveal;
	a *= (1.0 + crack_glow * edge);

	ALBEDO = gold_color;
	ALPHA = clamp(a, 0.0, 4.0);
}
