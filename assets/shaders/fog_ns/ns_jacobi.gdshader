// ============================================================================
// ns_jacobi.gdshader —— 通道 E：压力雅可比（Gauss-Seidel 式就地）迭代的那一趟
// ============================================================================
// 解 ∇²p = div 的一次迭代：
//     p_new = (div + p[left] + p[right] + p[down] + p[up]) / 4
// 这是求解器里唯一重复 N 次的通道（链条里连续放 N 个，每个读上一趟的输出）。
//
// 【为什么能跨帧热启动】链条是环形的：本帧的第 1 趟读的是**上一帧最后一趟**的压力，
//   于是压力天然被继承下来。对雾气这种时间连续场，这等于白拿了几十次迭代的效果。
//
// 【边界】压力用诺伊曼（贴边复制），与固壁边界一致：压力不在墙上产生通量。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

/** 散度（右端项，全帧不变） */
uniform sampler2D divergence_tex : filter_nearest, repeat_disable;
/** 上一趟迭代的压力 */
uniform sampler2D pressure_tex : filter_nearest, repeat_disable;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	vec2 left = ns_wrap_cell(cell - vec2(1.0, 0.0));
	vec2 right = ns_wrap_cell(cell + vec2(1.0, 0.0));
	vec2 down = ns_wrap_cell(cell - vec2(0.0, 1.0));
	vec2 up = ns_wrap_cell(cell + vec2(0.0, 1.0));

	float divergence = texture(divergence_tex, SCREEN_UV).r;
	float p_left = texture(pressure_tex, ns_uv(left)).r;
	float p_right = texture(pressure_tex, ns_uv(right)).r;
	float p_down = texture(pressure_tex, ns_uv(down)).r;
	float p_up = texture(pressure_tex, ns_uv(up)).r;

	float pressure = (divergence + p_left + p_right + p_down + p_up) * 0.25;
	COLOR = vec4(pressure, 0.0, 0.0, 1.0);
}
