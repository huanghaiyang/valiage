// ============================================================================
// ns_divergence.gdshader —— 通道 D：散度 ∇·u（压力泊松方程的右端项）
// ============================================================================
// 与 CPU 参考实现同式（Stam 的符号约定）：
//     div = -0.5 * (1/N) * ( u[x+1]-u[x-1] + v[y+1]-v[y-1] )
// 这个负号不是笔误：这样压力方程写成 ∇²p = div，投影更新写成 u -= ∂p/∂x，
// 两者符号一致；改符号会让投影变成"放大散度"。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

uniform sampler2D velocity_tex : filter_nearest, repeat_disable;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	float u_right = texture(velocity_tex, ns_uv(ns_wrap_cell(cell + vec2(1.0, 0.0)))).x;
	float u_left = texture(velocity_tex, ns_uv(ns_wrap_cell(cell - vec2(1.0, 0.0)))).x;
	float v_up = texture(velocity_tex, ns_uv(ns_wrap_cell(cell + vec2(0.0, 1.0)))).y;
	float v_down = texture(velocity_tex, ns_uv(ns_wrap_cell(cell - vec2(0.0, 1.0)))).y;

	float divergence = -0.5 * texel_size.x * ((u_right - u_left) + (v_up - v_down));
	COLOR = vec4(divergence, 0.0, 0.0, 1.0);
}
