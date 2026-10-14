// ============================================================================
// ns_composite.gdshader —— 通道 H：合成（去网格噪点 + 底图兜底 + 输出渲染用浓度）
// ============================================================================
// 模拟网格通常只有 96~160 格，直接拿去画 80 米见方的雾会看到明显的格子感。
// 这一趟做一次轻量 5 点平滑（权重可调），把格子感压掉，同时：
//   · 与画笔底图取 max：底图上"模拟还没来得及长出来"的部分也不会突然消失
//   · 输出 alpha=1，链尾被通道 A / G（下一帧）读回去
// 平滑强度用 smooth_weight 控制：0 = 完全不平滑（保留细节，适合高分辨率档位）。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

uniform sampler2D density_tex : filter_nearest, repeat_disable;
uniform sampler2D base_tex : filter_nearest, repeat_disable;
/** 平滑权重（0..0.6）。越大越糊但越没有格子感。 */
uniform float smooth_weight;
/** 底图在合成里的兜底增益 */
uniform float base_gain;
/** 清零请求（1 = 本帧输出 0，供 FogNsSolver.clear_density() 用） */
uniform float clear_request;

void fragment() {
	if (clear_request > 0.5) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec2 cell = ns_cell(SCREEN_UV);
		float center = texture(density_tex, SCREEN_UV).r;

		float neighbors = 0.0;
		neighbors += texture(density_tex, ns_uv(ns_wrap_cell(cell + vec2(1.0, 0.0)))).r;
		neighbors += texture(density_tex, ns_uv(ns_wrap_cell(cell - vec2(1.0, 0.0)))).r;
		neighbors += texture(density_tex, ns_uv(ns_wrap_cell(cell + vec2(0.0, 1.0)))).r;
		neighbors += texture(density_tex, ns_uv(ns_wrap_cell(cell - vec2(0.0, 1.0)))).r;
		neighbors *= 0.25;

		float smoothed = mix(center, neighbors, clamp(smooth_weight, 0.0, 1.0));
		float painted = texture(base_tex, SCREEN_UV).r * base_gain;

		COLOR = vec4(clamp(max(smoothed, painted), 0.0, 1.0), 0.0, 0.0, 1.0);
	}
}
