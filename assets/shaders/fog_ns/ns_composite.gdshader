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
/** ★ 底图**地板**强度（0..1，默认 1 = **逐字等于旧行为**）：
 *  1 = 底图是硬地板：`浓度 = max(模拟, 底图×增益)` —— 笔迹还没被模拟长出来时不会突然消失；
 *  0 = 底图只通过"向底图松弛"（ns_advect_density 的 base_relax）当**吸引子**，不再当地板。
 *  【为什么需要这个旋钮】底图一旦被刷满（浓度 1），`max` 就把**可见浓度锁死在 1**：
 *  角色/法术的挖雾、涡流、风都只能让模拟值变化，而渲染读到的永远是 1 ⇒
 *  "雾气扰动没效果"（实测：底图 1.0 + carve −1.4 时角色脚下浓度仍是 1.000）。
 *  地板去掉后，扰动才落得到可见浓度上（底图形状仍由 base_relax 拽住，不会散掉）。 */
uniform float base_floor = 1.0;
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
		float painted = texture(base_tex, SCREEN_UV).r * base_gain * clamp(base_floor, 0.0, 1.0);

		COLOR = vec4(clamp(max(smoothed, painted), 0.0, 1.0), 0.0, 0.0, 1.0);
	}
}
