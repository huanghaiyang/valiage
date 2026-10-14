// ============================================================================
// fog_screen_volume.gdshader —— 屏幕空间雾气（**投影式**，参考本项目的扇形选点效果）
// ============================================================================
// 【为什么改成这个做法】原来是把雾做成一个"光线步进的盒子"，并在循环里逐步长做深度测试。
//   两个致命问题（都实测过）：
//     ① 逐步长的深度测试只能整步丢弃/保留 ⇒ 雾与物体交界处出现一层层台阶（分层感）；
//     ② 我试图用"屏幕空间深度反投影"去补，但那套推演假设了**透视相机与逐像素射线起点**，
//        在等轴/正交相机下会把终点算成极远 ⇒ 整个盒子累积 ⇒ 整屏白雾。
//
// 【本文件照抄的已验证配方】scripts/spells/spell_targeting.gd + spell_sector_screen.gdshader
//   · 一块挂在相机前方 1 米的 QuadMesh（size 4×4），材质 render_priority = 127；
//   · render_mode 里 depth_test_disabled：**完全不跟几何做深度测试**；
//   · 深度还原世界坐标：ndc = vec3(SCREEN_UV*2-1, raw_depth) 直接喂 INV_PROJECTION_MATRIX
//     （Forward+ 的 DEPTH_TEXTURE 是 **reversed-Z 原始深度**，不需要自己翻转）；
//   · 画不画由**世界空间规则**决定（原效果用 ground_y/floor_margin 做高度过滤）。
//   这套在用户项目里是"渲染正确"的既有实现，所以雾也照它来做。
//
// 【用户要求的行为】物体"淹在雾里"的那一段要呈现雾的效果：
//   ⇒ 判定只看**该像素表面点自身的世界高度**，与相机/视线/深度约定无关：
//      表面点高于雾带顶 ⇒ 露在雾外，不画（物体探出雾面）
//      表面点在带内或带下 ⇒ 被雾淹没，按该处浓度画雾（物体下段被雾覆盖）
//
// 【为什么没有分层】整条渲染路径**没有步进循环**：浓度直接从浓度场按 XZ 采样，
//   高度剖面按表面高度算 ⇒ 不存在"离散步长"，也就不可能有台阶。
//
// 【已知的坑】
//   1. 必须 `render_priority = 127`（在 GDScript 里设）：否则草、粒子等后画的透明物
//      会盖在雾上面，出现"雾里有没被雾盖住的草"。
//   2. 必须 `extra_cull_margin` 很大（16384）：全屏面挂在相机下，被视锥剔除就整块不画。
//   3. 深度纹理在**没有不透明物体**的像素上（天空）会给出远处深度 ⇒ wp 很远 ⇒
//      高度远高于雾带顶 ⇒ 自动不画雾，正是我们要的（不需要额外分支）。
//   4. 域外（uv 超出 0..1）直接不画：雾只存在于 domain_size 覆盖的范围内。
// ============================================================================

shader_type spatial;
// 不参与光照/阴影/引擎雾；不写深度、不测深度；两面可见（相机旋转时不会突然消失）
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never,
		cull_disabled, shadows_disabled, ambient_light_disabled, fog_disabled;

/** 深度纹理（Forward+：reversed-Z 原始深度） */
uniform sampler2D depth_tex : hint_depth_texture;
/** 浓度场：画笔底图 / 求解器输出的密度 */
uniform sampler2D density_tex : filter_linear, repeat_disable;
/** 三维细节噪声（可选）：给雾内部加絮状层次 */
uniform sampler3D detail_tex : filter_linear, repeat_enable;
uniform float detail_scale : hint_range(0.0, 0.5) = 0.055;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.65;
uniform float detail_speed : hint_range(0.0, 2.0) = 0.35;

/** 雾域：中心（世界）与水平尺寸（米） */
uniform vec3 domain_center = vec3(0.0);
uniform vec2 domain_size = vec2(80.0, 80.0);
/** 雾带底面 / 顶面的世界高度（米）——**本着色器的核心判定量** */
uniform float box_bottom = 0.0;
uniform float box_top = 1.5;
/** 顶部软过渡宽度（米）：物体探出雾面时不会有一条硬边 */
uniform float top_soft = 0.6;
/** 高度剖面指数：越大，雾越贴地（越高越薄） */
uniform float height_power : hint_range(0.2, 6.0) = 1.6;
/** 域边缘淡出宽度（UV） */
uniform float edge_fade : hint_range(0.001, 0.5) = 0.12;
/** 整体不透明度 */
uniform float fog_opacity : hint_range(0.0, 4.0) = 1.1;
/** 被照亮处 / 背光处的雾色 */
uniform vec3 mist_color_lit : source_color = vec3(0.86, 0.89, 0.94);
uniform vec3 mist_color_shadow : source_color = vec3(0.62, 0.68, 0.78);
/** 环境项占比：0 = 全靠高度剖面（贴地最浓），1 = 上下均匀 */
uniform float ambient_amount : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	// ---- ① 深度 -> 世界坐标（与 spell_sector_screen.gdshader 完全一致的配方）----
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_pos.xyz /= max(view_pos.w, 1.0e-6);
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;

	// ---- ② 世界空间高度规则：淹在雾里的表面画雾，探出雾面的不画 ----
	// 顶上 top_soft 米内做软过渡，避免出现一条硬边。
	float below_top = smoothstep(box_top + top_soft, box_top - top_soft, world_pos.y);
	// 带内归一化高度：0 = 雾带底，1 = 雾带顶（夹住，带下的表面也算 0 = 最浓）
	float band = max(box_top - box_bottom, 0.001);
	float h = clamp((world_pos.y - box_bottom) / band, 0.0, 1.0);
	float profile = mix(1.0, pow(1.0 - h, height_power), 1.0 - ambient_amount);

	// ---- ③ 浓度：直接按 XZ 采样浓度场（投影式，无步进 ⇒ 无分层）----
	vec2 uv = (world_pos.xz - domain_center.xz) / max(domain_size, vec2(0.001)) + vec2(0.5);
	vec2 uv_clamped = clamp(uv, vec2(0.0), vec2(1.0));
	float density = texture(density_tex, uv_clamped).r;

	// 域边缘淡出（否则域边界会是一条竖直硬边）
	vec2 edge_vector = smoothstep(vec2(0.0), vec2(max(edge_fade, 0.001)), uv)
		* smoothstep(vec2(0.0), vec2(max(edge_fade, 0.001)), vec2(1.0) - uv);
	float edge = edge_vector.x * edge_vector.y;
	// 域外直接不画
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);

	// ---- ④ 三维细节（可选）：让雾内部有絮状层次而不是一层均匀色 ----
	float detail_mix = 0.5;
	if (detail_strength > 0.0) {
		vec3 detail_uv = world_pos * detail_scale + vec3(0.0, TIME * detail_speed, 0.0);
		float detail = texture(detail_tex, detail_uv).r;
		float detail2 = texture(detail_tex, detail_uv * 2.37 + vec3(0.37, 0.11, 0.53)).r;
		detail_mix = mix(0.5, detail * 0.68 + detail2 * 0.32, clamp(detail_strength, 0.0, 1.0));
	}
	float detail_gain = mix(1.0, 0.35 + 1.3 * detail_mix, clamp(detail_strength, 0.0, 1.0));

	// ---- ⑤ 颜色与透明度：亮部/暗部按高度插值（越低越暗 ⇒ 有体积感）----
	vec3 color = mix(mist_color_shadow, mist_color_lit, clamp(1.0 - h, 0.0, 1.0));
	ALBEDO = color;
	ALPHA = clamp(density * edge * inside * profile * detail_gain * below_top * fog_opacity,
			0.0, 1.0);
}
