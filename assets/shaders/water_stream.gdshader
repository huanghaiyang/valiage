shader_type spatial;
// 实体螺旋水带 —— 有厚度的管状水流（不是光效），沿管流动、从脚底爬到头顶。
//
// 【为什么是实体】顶点由脚本按**角色高度剖面**生成（绕行半径 = 该高度上角色各网格的
//   最大水平半径），所以管身必然包在身体外侧 —— 既有实体网格、又不穿模。
//
// 【UV 约定】u = 绕管截面一圈(0..1)，v = 沿管长度(0=脚底, 1=头顶)。
//   爬升 = 用 v 与 climb 比较遮罩；流动 = 噪声沿 v 滚动。
//
// 【渲染】blend_mix（有实体感，能遮挡背景）+ 不受光 + 双面。
//   用加色会又变回"光"，所以这里走不透明混合；体积感靠菲涅尔边缘提亮。
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D noise_tex : hint_default_black;

uniform vec3 col_low : source_color = vec3(0.20, 0.50, 0.84);    // 下端：深蓝
uniform vec3 col_high : source_color = vec3(0.72, 0.96, 1.0);    // 上端：亮青
uniform vec3 col_core : source_color = vec3(0.88, 0.99, 1.0);    // 水心高光

/// 沿管爬升进度 0..1（1 = 已到头顶）
uniform float climb : hint_range(0.0, 1.0) = 0.0;
/// 整体淡出（成膜阶段把水带收掉）
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float flow_speed : hint_range(0.0, 4.0) = 0.85;
/// 水体基础不透明度
uniform float opacity : hint_range(0.0, 1.0) = 0.78;

void fragment() {
	float v = UV.y;
	// 流动：噪声沿管滚动（横向再混一次，让水纹有斜向感）
	float n = texture(noise_tex, vec2(UV.x * 2.0, v * 2.6 - TIME * flow_speed)).r;
	float n2 = texture(noise_tex, vec2(UV.x * 3.0 + 0.37, v * 4.1 - TIME * flow_speed * 1.6)).r;

	// 爬升揭示：climb 以下才有水；前沿一小段更亮（像是水头在往上顶）
	float reveal = 1.0 - smoothstep(climb - 0.06, climb + 0.06, v);
	// ★ 水头高光在爬到顶时要收掉：否则 climb=1 那一帧高光正好卡在头顶最亮，
	//   叠加"切换成膜"就看着像闪了一下（实测症状=汇聚到头顶时闪一下）。
	float lead = (1.0 - smoothstep(0.0, 0.14, abs(v - climb)))
			* (1.0 - smoothstep(0.88, 1.0, climb));

	// 体积感：管壁边缘（菲涅尔）更亮
	float f = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 2.0);

	float a = (0.55 + 0.45 * n) * (0.45 + 1.0 * f) * reveal * fade;
	a += lead * 0.7 * fade;

	vec3 col = mix(col_low, col_high, clamp(v * 0.9 + n2 * 0.35, 0.0, 1.0));
	col = mix(col, col_core, clamp(lead * 0.8 + n2 * 0.25, 0.0, 1.0));

	ALBEDO = col;
	ALPHA = clamp(a * opacity * 1.6, 0.0, 1.0);
}
