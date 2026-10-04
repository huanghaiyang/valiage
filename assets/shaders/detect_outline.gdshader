shader_type spatial;
// 被探测物体的**动漫描边** —— 物体保持原样，只在外缘加一圈线；
// 而且这圈线是**被波纹扫到哪儿、就显示到哪儿**（逐步出现，而不是一命中整个物体全亮）。
//
// 【外扩方式：视图空间】
//   在视图空间沿"远离视线轴"的方向推顶点：等价于在屏幕上把剪影向外胀一圈，
//   与表面朝向无关，俯视/侧视都成立，而且不需要知道视口尺寸。
//   （曾改成沿法线外扩想解决"边线只在一侧"，结果糊成实心团，已回退，详见下方 vertex() 注释。）
//
// 【内部怎么去掉：查深度纹理，不用填充色】
//   只画背面（cull_front）时若不管内部，这层壳会把整个剪影填满 = 一大块实心色。
//   这里采样深度纹理拿到**该像素上场景已有的深度**，如果它在我的片元前面，
//   说明这里是物体自身的内部（物体已写过深度）-> discard。
//   （早先用"近黑不透明填充"挡内部，结果整个物体变成大黑疙瘩，用户说"太丑"。）
//
// 【逐步出现：wave_center / wave_radius】
//   命中判定是球形查询 —— 大件物体的碰撞体在半径内，它整个可视子树（连几十米外）
//   会一起被描边。所以把波面中心与半径传进来，按每个片元到波心的水平距离判定，
//   只有 dist <= wave_radius 的部分才画，边缘用 reveal_soft 柔化。
render_mode blend_mix, unshaded, cull_front, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture;
uniform vec3 line_color : source_color = vec3(0.30, 0.95, 1.0);
/// 线宽：沿法线外扩多少米（细一点更像线稿）
uniform float line_grow : hint_range(0.002, 0.8) = 0.028;
/// 深度比较容差（米）：太小会在共面处闪烁，太大会把边线一起吃掉
uniform float depth_bias : hint_range(0.0, 0.5) = 0.005;

/// 波纹中心的**世界坐标**
uniform vec3 wave_center = vec3(0.0);
/// 波面当前的**世界半径**（米）
uniform float wave_radius = 0.0;
/// 揭示边缘的柔化宽度（米）：0 = 硬边
uniform float reveal_soft : hint_range(0.0, 3.0) = 0.35;

void vertex() {
	// ★ 用**视图空间外扩**：沿"远离视线轴"方向推顶点，等价于在屏幕上把剪影胀一圈。
	//   这一段是有截图验证过的版本（物体保持原样、外缘一圈细线）。
	//
	// ★★ 不要改成 `VERTEX += NORMAL * line_grow`：试过，**会糊成一团实心青色**。
	//    这批导入模型（Tripo）的法线长度与节点缩放都不可控 —— 外扩量会被放大到几米
	//    （即使加了 normalize(NORMAL)，模型空间的偏移还要再乘节点缩放）；
	//    而且那个配置下"深度去内部"没能挡住壳体内部，于是整个剪影被填满。
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec2 dir = view.xy;
	float len2 = dot(dir, dir);
	// 正好落在视线轴上的点没有"外侧"，给个固定方向（它们本来也会被 discard 掉）
	dir = len2 < 0.0001 ? vec2(0.0, 1.0) : dir * inversesqrt(len2);
	view.xy += dir * line_grow;
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	// ---- 波面揭示：只画已经被波纹扫过的部分 ----
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = distance(wp.xz, wave_center.xz);
	float reveal = 1.0 - smoothstep(wave_radius - reveal_soft,
			wave_radius + reveal_soft, dist);
	if (reveal <= 0.002) {
		discard;
	}

	// ---- 去内部：前面已经有东西（物体自身）说明这里是剪影内部 ----
	float sd = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 up = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, sd, 1.0);
	float scene_z = -(up.xyz / up.w).z;
	float my_z = -VERTEX.z;
	if (scene_z < my_z - depth_bias) {
		discard;
	}

	ALBEDO = line_color;
	ALPHA = reveal;
}
