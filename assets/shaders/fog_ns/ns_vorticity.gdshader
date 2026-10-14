// ============================================================================
// ns_vorticity.gdshader —— 通道 C：涡量约束力 F = ε·(N × ω)
// ============================================================================
// 【为什么需要它】半拉格朗日输运 + 有限次压力迭代会把小尺度涡抹平，风一停雾就
//   变成"一坨匀速平移的云"。涡量约束把这个损失补回来：沿 |ω| 的梯度方向施加力，
//   让涡旋重新卷起来。ε=0 时本通道等价于"原样复制速度"。
//
// 【实现】N = ∇|ω| / (|∇|ω|| + 1e-5)，2D 下 N × ω 退化为 (N.y·ω, -N.x·ω)。
//   与 CPU 参考实现 _apply_vorticity() 完全同式。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

uniform sampler2D velocity_tex : filter_nearest, repeat_disable;
uniform sampler2D curl_tex : filter_nearest, repeat_disable;
/** 涡量强度 ε（每帧乘 dt 后施加）。0 = 关闭。 */
uniform float vorticity_strength;
uniform float dt;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	vec2 velocity = texture(velocity_tex, SCREEN_UV).xy;

	if (vorticity_strength > 0.0) {
		float curl_center = abs(texture(curl_tex, SCREEN_UV).r);
		float curl_left = abs(texture(curl_tex, ns_uv(ns_wrap_cell(cell - vec2(1.0, 0.0)))).r);
		float curl_right = abs(texture(curl_tex, ns_uv(ns_wrap_cell(cell + vec2(1.0, 0.0)))).r);
		float curl_down = abs(texture(curl_tex, ns_uv(ns_wrap_cell(cell - vec2(0.0, 1.0)))).r);
		float curl_up = abs(texture(curl_tex, ns_uv(ns_wrap_cell(cell + vec2(0.0, 1.0)))).r);

		vec2 grad = 0.5 * vec2(curl_right - curl_left, curl_up - curl_down) * grid_size.x;
		vec2 n = grad / (length(grad) + 1.0e-5);
		float omega = texture(curl_tex, SCREEN_UV).r;

		velocity += vec2(n.y * omega, -n.x * omega) * vorticity_strength * dt;
	}
	COLOR = vec4(velocity, 0.0, 1.0);
}
