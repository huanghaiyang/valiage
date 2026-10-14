// ============================================================================
// ns_advect_density.gdshader —— 通道 G：雾浓度输运（被动标量）
// ============================================================================
// 一步做四件事：
//   ① 半拉格朗日输运（用本帧**最终速度场**，链上就在前面）
//   ② 耗散：浓度按每秒比例衰减（雾会自然散开消失，画面才"活"）
//   ③ 向"画笔底图"松弛：d += (base·gain - d) · relax·dt
//      —— 这是画笔与流体统一的关键：插件刷出来的雾是**吸引子**，风把它吹变形、
//      耗散让它变淡，但它会被慢慢拉回刷出来的形状（而不是每帧硬盖一层静态雾）。
//   ④ 高斯源注入：热源/角色/法术产生的雾（每帧最多 8 个）
//
// 输出被"通道 H（合成）"读取；下一帧的本通道读的是通道 H 的上一帧结果，
// 所以链条里不存在"读自己正在写的纹理"。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

/** 上一帧的雾浓度（来自合成通道，已含画笔底图） */
uniform sampler2D density_tex : filter_nearest, repeat_disable;
/** 本帧最终速度场 */
uniform sampler2D velocity_tex : filter_nearest, repeat_disable;
/** 画笔底图（静态；没有笔刷时为全 0） */
uniform sampler2D base_tex : filter_nearest, repeat_disable;
uniform float dt;
/** 浓度耗散（每秒比例） */
uniform float density_dissipation;
/** 向底图松弛的速率（1/秒）。0 = 不吸附（刷出来的雾会被彻底吹散） */
uniform float base_relax;
/** 底图增益（>1 让刷出来的雾更浓） */
uniform float base_gain;
/** 有效高斯源数量 */
uniform int splat_count;
/** 高斯源：xy = 域坐标，z = 半径(域比例)，w = 浓度强度 */
uniform vec4 splats[8];

const int MAX_SPLATS = 8;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	vec2 velocity = texture(velocity_tex, SCREEN_UV).xy;

	// ① 输运
	vec2 back = ns_wrap_cell(cell - velocity * dt * grid_size);
	vec2 base_cell = floor(back);
	vec2 frac = back - base_cell;
	float d00 = texture(density_tex, ns_uv(ns_wrap_cell(base_cell + vec2(0.0, 0.0)))).r;
	float d10 = texture(density_tex, ns_uv(ns_wrap_cell(base_cell + vec2(1.0, 0.0)))).r;
	float d01 = texture(density_tex, ns_uv(ns_wrap_cell(base_cell + vec2(0.0, 1.0)))).r;
	float d11 = texture(density_tex, ns_uv(ns_wrap_cell(base_cell + vec2(1.0, 1.0)))).r;
	float density = mix(mix(d00, d10, frac.x), mix(d01, d11, frac.x), frac.y);

	// ② 耗散
	density *= (1.0 - clamp(density_dissipation * dt, 0.0, 1.0));

	// ③ 向画笔底图松弛
	float painted = texture(base_tex, SCREEN_UV).r * base_gain;
	if (base_relax > 0.0) {
		density += (painted - density) * clamp(base_relax * dt, 0.0, 1.0);
	}

	// ④ 源注入
	for (int i = 0; i < MAX_SPLATS; i++) {
		if (i >= splat_count) {
			break;
		}
		vec4 splat = splats[i];
		vec2 center = splat.xy * grid_size - vec2(0.5);
		float radius = max(splat.z * grid_size.x, 0.75);
		float d2 = dot(cell - center, cell - center);
		density += splat.w * exp(-d2 / (2.0 * radius * radius)) * dt;
	}

	// 浓度是物理量（0..1），必须钳位：否则一次猛灌会溢出成"白幕"且再也降不下来。
	density = clamp(density, 0.0, 1.0);
	COLOR = vec4(density, 0.0, 0.0, 1.0);
}
