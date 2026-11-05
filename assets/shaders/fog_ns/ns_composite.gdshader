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
/** ★ filter_linear：底图（默认 256 格）与模拟网格（96~160）分辨率不一致，
 *  用 nearest 会把底图边缘量化成台阶；线性采样让拼接边缘连续、无折痕。 */
uniform sampler2D base_tex : filter_linear, repeat_disable;
/** 平滑权重（0..0.6）。越大越糊但越没有格子感。 */
uniform float smooth_weight;
/** 底图在合成里的兜底增益 */
uniform float base_gain;
/** 清零请求（1 = 本帧输出 0，供 FogNsSolver.clear_density() 用） */
uniform float clear_request;

/** 平滑并集（soft max）：k 为过渡带宽（浓度单位）。
 *  max(a,b) 在 a≈b 处只有 C0 连续、梯度会突变 —— 底图与流体浓度相接的轮廓线
 *  因此切出一条"折痕"（低分辨率底图上尤其明显，看起来像拼接缝）。
 *  这里在 |a-b|<k 的窄带内把结果抬高最多 k/4，使梯度连续，k 很小（0.08），
 *  对整体浓度的影响可以忽略。 */
float ns_soft_max(float a, float b, float k) {
	float h = max(k - abs(a - b), 0.0) / k;
	return max(a, b) + h * h * k * 0.25;
}

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

		// ★ 用平滑并集而不是 max()：底图边缘与流体浓度相接处不再切出折痕。
		COLOR = vec4(clamp(ns_soft_max(smoothed, painted, 0.08), 0.0, 1.0), 0.0, 0.0, 1.0);
	}
}
