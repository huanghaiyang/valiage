shader_type spatial;
// 逐物体描边 —— UE "inverted hull"（反壳）的 Godot 版，**不需要任何遮罩通道**。
//
// 【核心：只画外扩壳的背面，内部交给普通的深度测试】
//   1) 顶点沿"远离视线轴"的方向外扩（视图空间），轮廓整体向外胀一圈；
//   2) 只画**背面**（cull_front），所以壳的内表面朝外的那层不参与；
//   3) 壳的背面在物体自己**后面** —— 深度测试（深度更大）自然失败 -> 内部不画；
//      而轮廓之外没有东西遮挡 -> 背面画得出来 -> 一圈线。
//   ★ 我之前的错误是**额外加了一个"手动查深度纹理后 discard"**。那一步把靠镜头那侧的
//     边线一起丢掉了（那里的壳层被地面/物体本身压住），于是只剩背向镜头的一侧有线。
//     深度测试本来就够用，不该再手工插一脚。
//
// 【为什么这条路对"草"是结构性免疫】
//   材质是**逐个物体**叠加的（material_overlay），只加在被探测到的物体上。
//   草不在探测集合里 -> 永远不会被描。不靠名字、不靠遮罩、不靠过滤。
//
// 【像素恒定线宽】外扩量正比于视深度：
//   grow = line_px * (2*tan(fov/2) / screen_height) * 视深度
//   于是不管物体远近，线的粗细都是一样的（单位是像素）。
render_mode blend_mix, unshaded, cull_front, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform vec3 line_color : source_color = vec3(0.30, 0.95, 1.0);
uniform float line_alpha : hint_range(0.0, 1.0) = 1.0;
/// 线宽（像素）
uniform float line_px : hint_range(0.5, 6.0) = 1.5;
/// 由脚本写入：2*tan(fov/2) / 视口高度
uniform float screen_k = 0.0017;
/// 波纹中心（世界坐标）与当前半径：让轮廓随波面**逐步**长出来
uniform vec3 wave_center = vec3(0.0);
uniform float wave_radius = 0.0;
uniform float reveal_soft : hint_range(0.0, 3.0) = 0.35;

void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec2 dir = view.xy;
	float len2 = dot(dir, dir);
	// 正好在视线轴上的点没有"外侧"，给个固定方向即可（它们本来也会被 discard）
	dir = len2 < 0.0001 ? vec2(0.0, 1.0) : dir * inversesqrt(len2);
	view.xy += dir * (line_px * screen_k * max(-view.z, 0.01));
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	// 波面揭示：只画已经被波纹扫过的部分（逐步出现）
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = distance(wp.xz, wave_center.xz);
	float reveal = 1.0 - smoothstep(wave_radius - reveal_soft,
			wave_radius + reveal_soft, dist);
	if (reveal <= 0.002) {
		discard;
	}
	ALBEDO = line_color;
	ALPHA = reveal * line_alpha;
}
