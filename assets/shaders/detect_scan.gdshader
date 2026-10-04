shader_type spatial;
// 扫描波在**物体表面游走** —— 支持**多圈**：当前所有活跃脉冲逐个叠加，
// 于是物体表面会被**每一圈**依次扫过（每一圈都是真实脉冲，有自己的检测）。
//
// 【和描边的关系】描边画在 material_overlay 上；本材质挂在那个描边材质的 **next_pass**，
//   也就是"同一次绘制的后续 pass"。
//
// 【单圈的相位】
//   d      = 到该圈圆心的水平距离
//   r_here = 该圈半径 - 高度*climb          // 越高处到达半径越小 -> 波面沿表面往上爬
//   x      = r_here - d
//     x ≈ 0 正在被扫过 -> 前沿亮带（高斯）
//     x > 0 已扫过     -> 身后余辉，exp(-x/trail_len)
//     x < 0 还没扫到   -> 不画
//   多圈就是把每个脉冲的贡献**相加**（每圈的余辉各自衰减）。
render_mode blend_add, unshaded, cull_back, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform vec3 scan_color : source_color = vec3(0.35, 0.95, 1.0);
uniform float scan_alpha : hint_range(0.0, 2.0) = 0.85;

/// 多圈：每个元素 = (圆心.x, 圆心.z, 半径, 0)。最多 8 圈同时存在。
uniform vec4 scan_waves[8];
uniform int wave_count = 0;
/// 兼容单波模式（wave_count = 0 时用）
uniform vec3 wave_center = vec3(0.0);
uniform float wave_radius = 0.0;

/// 前沿亮带宽度（米）
uniform float band_width : hint_range(0.05, 4.0) = 0.7;
/// 前沿亮带强度
uniform float band_gain : hint_range(0.0, 4.0) = 1.6;
/// 身后余辉长度（米）
uniform float trail_len : hint_range(0.1, 8.0) = 2.2;
/// 身后余辉强度（多圈时会叠加，别调太高）
uniform float trail_gain : hint_range(0.0, 2.0) = 0.35;
/// 每米高度让到达半径减少多少（>0 = 波面沿表面往上爬）
uniform float climb : hint_range(-2.0, 2.0) = 0.8;
/// 掠射角增强
uniform float edge_boost : hint_range(0.0, 2.0) = 0.6;
/// 横向条纹频率（0 = 关）
uniform float pattern_freq : hint_range(0.0, 8.0) = 1.4;
/// 横向条纹强度
uniform float pattern_gain : hint_range(0.0, 1.0) = 0.25;

/// 单个圈在给定世界位置处的能量
float wave_energy(vec3 wp, vec2 center_xz, float radius) {
	float d = distance(wp.xz, center_xz);
	float r_here = radius - wp.y * climb;
	float x = r_here - d;
	float lead = exp(-pow(x / max(band_width, 0.05), 2.0));
	float trail = x > 0.0 ? exp(-x / max(trail_len, 0.05)) : 0.0;
	float pat = 1.0 - pattern_gain
			+ pattern_gain * (0.5 + 0.5 * sin(d * pattern_freq * 6.28318));
	return (lead * band_gain + trail * trail_gain) * pat;
}

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float energy = 0.0;
	if (wave_count > 0) {
		for (int i = 0; i < 8; i++) {
			if (i >= wave_count) {
				break;
			}
			vec4 w = scan_waves[i];
			energy += wave_energy(wp, w.xy, w.z);
		}
	} else {
		energy = wave_energy(wp, wave_center.xz, wave_radius);
	}
	// 掠射角增强（侧面看更亮）
	float fres = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 3.0);
	energy *= 1.0 + edge_boost * fres;

	ALBEDO = scan_color;
	ALPHA = clamp(energy * scan_alpha, 0.0, 1.0);
}
