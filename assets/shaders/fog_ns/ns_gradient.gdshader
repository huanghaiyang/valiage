// ============================================================================
// ns_gradient.gdshader —— 通道 F：减去压力梯度（完成投影，得到无散度速度）
// ============================================================================
//     u -= 0.5 * (p[x+1] - p[x-1]) * N
//     v -= 0.5 * (p[y+1] - p[y-1]) * N
// 乘 N 就是除以 h=1/N（CPU 参考实现里的 /h）。本通道的输出就是**本帧最终速度场**，
// 也是链尾被"通道 A（下帧）"读回去的那一份。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

uniform sampler2D velocity_tex : filter_nearest, repeat_disable;
uniform sampler2D pressure_tex : filter_nearest, repeat_disable;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	vec2 velocity = texture(velocity_tex, SCREEN_UV).xy;

	vec2 left = ns_wrap_cell(cell - vec2(1.0, 0.0));
	vec2 right = ns_wrap_cell(cell + vec2(1.0, 0.0));
	vec2 down = ns_wrap_cell(cell - vec2(0.0, 1.0));
	vec2 up = ns_wrap_cell(cell + vec2(0.0, 1.0));

	float p_left = texture(pressure_tex, ns_uv(left)).r;
	float p_right = texture(pressure_tex, ns_uv(right)).r;
	float p_down = texture(pressure_tex, ns_uv(down)).r;
	float p_up = texture(pressure_tex, ns_uv(up)).r;

	velocity.x -= 0.5 * (p_right - p_left) * grid_size.x;
	velocity.y -= 0.5 * (p_up - p_down) * grid_size.y;
	COLOR = vec4(velocity, 0.0, 1.0);
}
