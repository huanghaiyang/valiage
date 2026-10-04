shader_type spatial;
// 流水治疗 —— 贴在**角色自己的网格**上的一层流水（material_overlay）。
//
// 【为什么不做成球/圆柱/螺旋管】需求要求"包裹住角色周身、不穿模、不是球体"。
//   自造几何体（球体、圆柱、螺旋管）在角色这种非回转体上必然某些角度穿进/穿出身体；
//   而把水膜直接铺在**角色体表**上：形状 = 角色身形、**零穿模**。
//
// 【两股流水怎么"交错缠绕、从脚底爬到头顶"】
//   在体表按**世界坐标**算螺旋相位（不需要 UV —— 这批模型本来就没有 UV）：
//     h   = (世界高度 - 脚底) / 身高        // 0 = 脚底, 1 = 头顶
//     ang = atan2(水平偏移) / TAU          // 环绕角，整圈 = 1.0
//     u   = h * turns + ang                // 沿螺旋走的参数
//   两股取 u 与 u + 0.5（错开半圈）-> **交错缠绕**；
//   再用 h <= climb 遮罩 -> **从下往上爬**；前沿做一点柔化。
//   全程在体表计算，所以爬升也一样不穿模。
//
// 【成膜】climb 到顶后 veil 渐增：整身变成一层流动水膜（菲涅尔 + 噪声流纹 + 上下渐变色），
//   流水带同时淡出（stream_fade）。
//
// 【配色】整体淡蓝：脚底偏深蓝、头顶偏亮青，两股流水带用更亮的青白高光。
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D noise_tex : hint_default_black;

uniform vec3 col_low : source_color = vec3(0.18, 0.45, 0.78);    // 底部：深蓝
uniform vec3 col_high : source_color = vec3(0.66, 0.93, 1.0);    // 顶部：亮青
uniform vec3 col_band : source_color = vec3(0.80, 0.98, 1.0);    // 流水带：更亮的青白

/// 角色中心（只用 xz）
uniform vec3 center_xz = vec3(0.0, 0.0, 0.0);
/// 脚底世界高度
uniform float feet_y = 0.0;
/// 身高（米）
uniform float body_h = 1.8;

uniform float turns : hint_range(0.5, 8.0) = 2.2;        // 缠绕圈数
uniform float climb : hint_range(0.0, 1.0) = 0.0;        // 爬升进度（0=脚底 1=头顶）
uniform float veil : hint_range(0.0, 1.0) = 0.0;         // 成膜程度
uniform float stream_fade : hint_range(0.0, 1.0) = 1.0;  // 流水带亮度（成膜后淡出）
uniform float band_width : hint_range(0.02, 0.5) = 0.13; // 水带宽度（螺旋参数单位）
uniform float flow_speed : hint_range(0.0, 4.0) = 0.55;  // 流动速度
uniform float rim_strength : hint_range(0.0, 4.0) = 1.7; // 水膜边缘（菲涅尔）
uniform float body_strength : hint_range(0.0, 1.0) = 0.32; // 水膜正面基础强度

/// 一股螺旋水带的强度（u = 螺旋参数，hh = 归一化高度，t = 时间）
float band(float u, float hh, float t) {
	float f = fract(u);
	float d = min(f, 1.0 - f);                            // 到最近水带中心的距离
	float core = exp(-(d * d) / (band_width * band_width)); // 窄带（高斯）
	float n = texture(noise_tex, vec2(u * 2.5, hh * 1.8 - t * flow_speed)).r;
	return core * (0.35 + 0.95 * n);
}

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = clamp((wp.y - feet_y) / max(body_h, 0.05), 0.0, 1.0);
	float ang = atan(wp.x - center_xz.x, wp.z - center_xz.z) / 6.28318530718;

	// ---- 两股交错缠绕的流水，按 climb 从下往上爬 ----
	float u1 = h * turns + ang;
	float b1 = band(u1, h, TIME);
	float b2 = band(u1 + 0.5, h, TIME);                   // 错开半圈 -> 交错
	float front = smoothstep(climb + 0.07, climb - 0.07, h);  // 只画已爬到的部分
	float streams = (b1 + b2) * front * stream_fade;

	// ---- 成膜：整身水膜（噪声流纹 + 菲涅尔边缘 + 上下渐变）----
	float n2 = texture(noise_tex, vec2(wp.x * 0.55 + TIME * 0.04,
			wp.y * 0.45 - TIME * flow_speed * 0.45)).r;
	float fres = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 2.2);
	float film = veil * (body_strength + rim_strength * fres + 0.22 * n2);

	float a = streams + film;

	// 上浅下深的淡蓝渐变，流水带再提亮一档
	vec3 col = mix(col_low, col_high, clamp(h * 0.8 + n2 * 0.25, 0.0, 1.0));
	col = mix(col, col_band, clamp(streams * 0.9, 0.0, 1.0));

	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 2.5);
}
