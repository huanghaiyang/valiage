// ============================================================================
// ns_advect_velocity.gdshader —— 通道 A：速度自输运 + 加力（风力 / 笔刷 / 热源）
// ============================================================================
// 【本通道做什么】一个 pass 里完成三件事，省掉两个来回（每省一趟 = 少一个 SubViewport）：
//   ① 半拉格朗日自输运（回trace + 手工双线性）
//   ② 速度耗散（1 - σ·dt）
//   ③ 加力：均匀风（朝目标速度松弛）+ 最多 MAX_SPLATS 个高斯冲量
//   最后套固壁边界条件。
//
// 【输入】velocity_tex = 上一帧**投影后**的速度（链条尾部的输出，见 fog_ns_solver.gd 的
//   链式结构说明）。注意是"上一帧"，因为本通道在链里排在它前面 —— 这正是把整条链做成
//   环形（尾接头）的原因：不需要额外的 ping-pong 缓冲，也就不会出现"读自己正在写的纹理"。
//
// 【★ 单位】速度是域单位/秒，所以回trace 的单元偏移 = velocity * dt * grid_size。
//   少乘 grid_size 会让雾几乎不动、且怎么调风都不明显（最容易犯的错）。
// ============================================================================

shader_type canvas_item;

#include "ns_common.gdshaderinc"

/** 上一帧投影后的速度场（RG = u, v） */
uniform sampler2D velocity_tex : filter_nearest, repeat_disable;
/** 本帧时长（秒）。为 0 表示暂停，此时通道退化成"原样复制 + 边界处理"。 */
uniform float dt;
/** 速度耗散（每秒比例）。数值耗散之外再主动衰减一点，避免风停后永远打转。 */
uniform float velocity_dissipation;
/** 风的目标速度（域单位/秒）。实际速度会朝它松弛过去。 */
uniform vec2 wind_target;
/** 风松弛速率（1/秒）。越大越快贴近目标风；0 = 不加风。 */
uniform float wind_strength;
/** 本帧的有效高斯源数量（<= MAX_SPLATS） */
uniform int splat_count;
/** 高斯源：xy = 域坐标(0..1)，z = 半径(域比例)，w = 强度 */
uniform vec4 splats[8];
/** 每个高斯源的**速度**作用：xy = 目标速度（域单位/秒），z = 松弛速率(1/秒)。
 *  ★ 语义是"把这片区域的速度拉向目标值"，不是"施加一个冲量"：冲量语义要求调用方
 *    自己乘 dt，强度会跟帧率耦合；目标速度语义直接对应"这个热源以 3 m/s 喷气"。
 *  ★ 曾经把力乘上 splat.w（浓度分量）—— 于是"只推速度、不投雾"的源完全失效
 *    （w=0 把力乘成 0，表现为"热源完全没反应"）。一个分量不要身兼两职。 */
uniform vec4 splat_force[8];
/** ★ 每个高斯源的**绕心切向速度**（域单位/秒）：>0 一个方向、<0 相反方向、0 = 关闭
 *  （**逐字等于旧行为**）。
 *  【为什么需要它】原来的两种注入都是"平移"：drag 把这片区域推向某个方向，radial 把它
 *   推向"离开源中心"。两者都**没有旋转**，所以物体穿过雾只会排开/拖拽，不会卷。
 *   本项给目标速度叠加一个**绕源中心 ±90° 的切向量** ⇒ 该区域整体绕心环流。
 *   浓度是被动标量，由半拉格朗日平流输运 ⇒ 环流会把它**自然卷成螺旋臂**，
 *   不需要额外写浓度通道，也不需要新增管线（用满已有的 8 个源配额）。
 *  【符号与轴向】cell 是纹理单元坐标（v 向下），所以正负号只表示"顺时针/逆时针"，
 *   具体哪边由调用方用带符号的参数决定（如 FogField.character_swirl_mps）。 */
uniform float splat_swirl[8];

const int MAX_SPLATS = 8;

void fragment() {
	vec2 cell = ns_cell(SCREEN_UV);
	vec2 velocity = texture(velocity_tex, SCREEN_UV).xy;

	// ---- ① 半拉格朗日自输运 ----
	vec2 back = ns_wrap_cell(cell - velocity * dt * grid_size);
	vec2 base = floor(back);
	vec2 frac = back - base;
	// 源纹理是 NEAREST，所以手工取四邻做双线性：既能精确控制边界，也不受各向异性过滤影响。
	vec2 v00 = texture(velocity_tex, ns_uv(ns_wrap_cell(base + vec2(0.0, 0.0)))).xy;
	vec2 v10 = texture(velocity_tex, ns_uv(ns_wrap_cell(base + vec2(1.0, 0.0)))).xy;
	vec2 v01 = texture(velocity_tex, ns_uv(ns_wrap_cell(base + vec2(0.0, 1.0)))).xy;
	vec2 v11 = texture(velocity_tex, ns_uv(ns_wrap_cell(base + vec2(1.0, 1.0)))).xy;
	vec2 advected = mix(mix(v00, v10, frac.x), mix(v01, v11, frac.x), frac.y);

	// ---- ② 耗散 ----
	advected *= (1.0 - clamp(velocity_dissipation * dt, 0.0, 1.0));

	// ---- ③ 加力 ----
	if (wind_strength > 0.0) {
		advected += (wind_target - advected) * clamp(wind_strength * dt, 0.0, 1.0);
	}
	for (int i = 0; i < MAX_SPLATS; i++) {
		if (i >= splat_count) {
			break;
		}
		vec4 splat = splats[i];
		vec2 center = splat.xy * grid_size - vec2(0.5);
		float radius = max(splat.z * grid_size.x, 0.75);
		float d2 = dot(cell - center, cell - center);
		float gaussian = exp(-d2 / (2.0 * radius * radius));
		vec4 source = splat_force[i];
		// ★ w > 0：把这区域的速度沿"离开源中心"的方向推 —— 也就是**物体排开介质**，
		//   等价于 FluidNinja 的 OutwardVelocityMult。比"朝物体移动方向推"更像实物：
		//   烟被挤到两侧与后方，而不是被整体拖着走。
		vec2 target_velocity = source.xy;
		if (source.w > 0.0) {
			vec2 outward = cell - center;
			target_velocity = (length(outward) > 0.001 ? normalize(outward) : vec2(0.0)) * source.w;
		}
		// ★ 涡流（"绕身环绕"的来源）：在目标速度上再叠加一个**切向**分量 ——
		//   把 radial 的"推开"和这里的"绕"叠在一起，就是"角色把雾挤开、同时卷着走"。
		//   splat_swirl[i] == 0 时整块被跳过 ⇒ 旧行为逐字不变。
		float swirl = splat_swirl[i];
		if (abs(swirl) > 0.0) {
			vec2 r = cell - center;
			float rl = length(r);
			vec2 tangent = rl > 0.001 ? vec2(-r.y, r.x) / rl : vec2(0.0);
			target_velocity += tangent * swirl;
		}
		advected += (target_velocity - advected) * gaussian * clamp(source.z * dt, 0.0, 1.0);
	}

	COLOR = vec4(advected, 0.0, 1.0);
}
