// ============================================================================
// ns_curl.gdshader —— 通道 B：涡量 ω = ∂v/∂x - ∂u/∂y
// ============================================================================
// 只算标量涡量，供涡量约束通道（ns_vorticity）使用。中心差分 × N（因为 /h = ×N）。
// 单独一趟的意义：涡量在诊断时也有用（tests 用 curl 的解析解验证过刚体旋转 = 2ω）。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

uniform sampler2D velocity_tex : filter_nearest, repeat_disable;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	vec2 left = ns_wrap_cell(cell - vec2(1.0, 0.0));
	vec2 right = ns_wrap_cell(cell + vec2(1.0, 0.0));
	vec2 down = ns_wrap_cell(cell - vec2(0.0, 1.0));
	vec2 up = ns_wrap_cell(cell + vec2(0.0, 1.0));

	float v_right = texture(velocity_tex, ns_uv(right)).y;
	float v_left = texture(velocity_tex, ns_uv(left)).y;
	float u_up = texture(velocity_tex, ns_uv(up)).x;
	float u_down = texture(velocity_tex, ns_uv(down)).x;

	float omega = 0.5 * ((v_right - v_left) - (u_up - u_down)) * grid_size.x;
	COLOR = vec4(omega, 0.0, 0.0, 1.0);
}
