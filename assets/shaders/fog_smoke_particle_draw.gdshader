// ============================================================================
// fog_smoke_particle_draw.gdshader —— **粒子烟雾的绘制**（每个粒子一团真实的烟）
// ============================================================================
// 【为什么不用径向渐变】上一版是 `(1-smoothstep(r))²` 的圆盘 —— 无论怎么叠都是一串
//   能数出来的圆球（用户原话"像贴图"）。真实的烟团必须有**内部纹理**：所以这里用一张
//   噪声图按"世界坐标 + 粒子自身偏移"采样，同一颗粒子在不同时刻、不同位置的形状都不同，
//   叠加起来才是有层次的烟。
//
// 【关键做法】
//   · UV 采样坐标 = 四边形 UV × noise_scale + **粒子的世界 XZ 位置** × world_scale
//     ⇒ 相邻粒子采到相近的噪声（大烟团连续），位置不同的粒子形状不同（细节丰富），
//       而且粒子一移动，纹理就跟着流动 —— 不需要 CUSTOM 传旋转角，也不用手写旋转。
//   · 两层噪声（不同频率/不同滚动速度）相乘：低层给大块团，高层给边缘的絮状撕裂。
//   · ALBEDO 乘 `COLOR.rgb`：那是**粒子着色器算出来的受光颜色**（靠近红光就发红），
//     所以同一批粒子在暗处是深灰、在激光旁边是亮红。
//   · ALPHA 由 软边 × 噪声 × VOLUME 组成，并在粒子出生/消亡时淡入淡出（避免"亮相"）。
//
// 【已知的坑】
//   1. 粒子材质必须是 `billboard`（Godot 4 里由 GPUParticles3D.transform_align 决定朝向），
//      着色器里不要再写 render_mode billboard，否则会与节点设置打架。
//   2. `depth_draw_opaque` 很重要：粒子之间要正确遮挡（否则浓烟内部会互相透亮）。
//   3. 噪声图必须是 `repeat_enable`，否则超过 UV 1.0 的部分会被钳成一条边（出现硬边）。
// ============================================================================

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, shadows_disabled, fog_disabled, unshaded;

/** 烟雾的形状噪声（2D，由 FogField 生成） */
uniform sampler2D noise_tex : filter_linear, repeat_enable;
/** 求解器的速度场（域单位/秒，RG）。用于 **flowmapping**：噪声被速度场拖拽、拉伸 ——
 *  这是 FluidNinja 的 "velocity-based flowmapping" 在无状态粒子里的等价物，
 *  也是"烟看起来像被风折叠"与"整块平移"的分界线。 */
uniform sampler2D flow_tex : filter_linear, repeat_disable;
uniform vec2 domain_size = vec2(80.0, 80.0);
/** flowmapping 强度：0 = 关闭（退回只有自身滚动的噪声）。单位就是 UV 偏移量。
 *  ★ 默认取小值：它吃的是**瞬时**速度场，偏大时网格尺度的速度噪声会被逐帧放大成
 *    可见抖动/闪烁（用户反馈"受风影响剧烈、闪烁"）。0.02~0.08 是安全区间；
 *    FogField 会把它设成 particle_flow_warp × wind_scale。 */
uniform float flow_warp : hint_range(0.0, 1.0) = 0.05;

// ==================== BlackBody 自发光 ====================
// ★ FluidNinja 的体渲染特性之一："Emissive from volume density, using the BlackBody-temperature
//   function" —— 火/余烬/激光把烟烤热的部分按**色温**上色（低=暗红，中=橙，高=黄白），
//   而不是简单地把红光照到烟上。这是参考图里"热核"质感的来源。
/** 自发光强度的**旧**参数：颜色模型拆分后由 `light_add` 取代，保留声明只为不破坏
 *  已保存材质里的 uniform 绑定；新代码请用 light_add。 */
uniform float emissive_strength : hint_range(0.0, 4.0) = 0.16;
/** 自发光的高温上限（钳制，避免整片爆白） */
uniform vec3 emissive_clamp = vec3(1.0, 0.92, 0.78);
/** 烟的**环境底色亮度**：没被光照到时烟的样子（0.25~0.5 = 参考图那种中灰；
 *  0 = 纯黑，会让未受光的粒子在暗场景里完全消失）。 */
uniform float ambient_grey : hint_range(0.0, 1.0) = 0.34;
/** 受光叠加量：只有"被照亮"的部分才加，且上限受此控制（0.3~0.7）。
 *  它与 blackbody(heat) 相乘，所以亮部是热色、暗部保持底色。 */
uniform float light_add : hint_range(0.0, 2.0) = 0.55;
/** 受光能量 -> 色温的换算增益 */
uniform float emissive_gain : hint_range(0.0, 8.0) = 1.0;

/** 黑体/白炽近似色带。分段线性足够骗过眼睛，又比 pow 便宜。 */
vec3 blackbody(float t) {
	t = clamp(t, 0.0, 2.0);
	vec3 c0 = vec3(0.06, 0.010, 0.008);
	vec3 c1 = vec3(1.00, 0.090, 0.020);
	vec3 c2 = vec3(1.00, 0.400, 0.070);
	vec3 c3 = vec3(1.00, 0.800, 0.420);
	vec3 c4 = vec3(1.00, 0.960, 0.860);
	if (t < 0.35) {
		return mix(c0, c1, t / 0.35);
	}
	if (t < 0.80) {
		return mix(c1, c2, (t - 0.35) / 0.45);
	}
	if (t < 1.30) {
		return mix(c2, c3, (t - 0.80) / 0.50);
	}
	return mix(c3, c4, clamp((t - 1.30) / 0.70, 0.0, 1.0));
}
/** 噪声在四边形上的缩放：越大，单颗粒子里的烟丝越细 */
uniform float noise_scale : hint_range(0.2, 8.0) = 1.6;
/** 噪声按世界坐标的缩放：越大，相邻粒子的纹理差异越明显 */
uniform float noise_world_scale : hint_range(0.0, 0.6) = 0.06;
/** 噪声自身的滚动速度（让静止的烟也在缓慢翻涌） */
uniform float noise_drift : hint_range(0.0, 1.0) = 0.02;
/** **顺风向拉伸倍率**：<1 = 顺风压扁 ⇒ 丝状结构。这是"流动感"最直接的来源，
 *  1.0 = 各向同性（看起来就是一团团各向同性的球）。0.25~0.45 效果明显。 */
uniform float stretch_along : hint_range(0.05, 1.0) = 0.35;
/** **边缘侵蚀强度**：用共享的世界噪声咬掉粒子边界。
 *  0 = 一堆软圆盘（用户反馈的"团块感"），0.6~0.9 = 相邻粒子融成连续流动的烟。 */
uniform float erosion : hint_range(0.0, 1.0) = 0.8;
/** 边缘软度：0.9 以上边缘很"糊"，更接近流体烟 */
uniform float softness : hint_range(0.0, 1.0) = 0.75;
/** 整体不透明度 */
uniform float strength : hint_range(0.0, 2.0) = 0.55;
/** 烟雾底色（会被粒子的受光颜色 COLOR.rgb 调制） */
uniform vec3 smoke_color : source_color = vec3(0.55, 0.56, 0.60);
/** 生命两端的不透明度淡出比例（防止粒子突然出现/消失） */
uniform float fade_in : hint_range(0.0, 0.5) = 0.28;
uniform float fade_out : hint_range(0.0, 0.5) = 0.42;

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float radius = length(centered);
	if (radius > 1.0) {
		discard;                       // 圆形裁切：四边形的角不该有烟
	}

	// ★ 形状噪声**只按世界坐标采样** —— 这是"连续流动"与"一坨一坨团块"的分界：
	//   粒子若在**自己的四边形 UV** 上采样（原 `UV * noise_scale`），每颗都是独立图案，
	//   叠起来永远是一堆球；改成世界坐标后，相邻粒子采到**同一片**噪声，
	//   浓淡分布彼此一致 ⇒ 边界互相抵消，融成一片连续的烟。
	vec3 world = MODEL_MATRIX[3].xyz;
	// flowmapping：用速度场（域单位/秒）做域扭曲。★ 单位陷阱：不要再乘 domain_size，
	// 乘了就变成几十个 UV 单位，噪声被推成常量、整片糊成一个颜色（踩过）。
	vec2 flow_uv = clamp(world.xz / domain_size + vec2(0.5), vec2(0.0), vec2(1.0));
	vec2 flow = texture(flow_tex, flow_uv).xy;
	vec2 warp = clamp(flow * flow_warp, vec2(-0.06), vec2(0.06));

	vec2 world_uv = world.xz * noise_world_scale + warp
		+ vec2(TIME * noise_drift, TIME * noise_drift * 0.7);
	// ★ 沿流向**各向异性拉伸**：顺风向压扁、垂直方向保持 ⇒ 出现被吹出来的丝状结构，
	//   而不是各向同性的圆团。这一步是"流动感"最直接的来源。
	vec2 wind_dir = normalize(flow + vec2(1.0e-4, 1.0e-4));
	float along = dot(world_uv, wind_dir) * stretch_along;
	float across = dot(world_uv, vec2(-wind_dir.y, wind_dir.x));
	vec2 stretched = wind_dir * along + vec2(-wind_dir.y, wind_dir.x) * across;

	float coarse = texture(noise_tex, stretched).r;
	float fine = texture(noise_tex, stretched * 2.9 + vec2(0.37, 0.53)
		- TIME * noise_drift * 0.6 + warp * 0.5).r;
	// 两层相乘：低层决定"这团有多大"，高层在边缘撕出絮状
	float shape = coarse * mix(0.55, 1.0, fine);

	// 四边形 UV 只做**边缘羽化**，不再参与形状生成
	float edge = 1.0 - smoothstep(mix(0.15, 0.95, softness), 1.0, radius);
	// ★ 用**共享的世界噪声侵蚀边缘**：相邻粒子"该薄的地方一起薄"，边界因此消失、
	//   烟连成一片（erosion 越大越连贯；0 = 退回一堆软圆盘）。
	float eroded = mix(edge, edge * shape * 1.6, clamp(erosion, 0.0, 1.0));
	// 同时用同一份噪声调制整体密度，让浓淡在空间上连续过渡
	float density_mod = mix(1.0, 0.35 + 1.3 * shape, clamp(erosion, 0.0, 1.0));

	float alpha = eroded * density_mod * strength * COLOR.a;
	// ★ 生命期淡入淡出在**粒子着色器**里已经算好并写进了 COLOR.a（绘制阶段拿不到 CUSTOM，
	//   那里也没有年龄信息）——所以这里不要再算一次。

	// ★ 颜色模型（已拆分）：COLOR.rgb 里**只有受光能量**（逐通道 ≤1），环境底色是这里的常量。
	//   ★★ 还区分"暖光 / 冷光"：只有暖光（火、激光、余烬）才该走 BlackBody 色温带；
	//      冷光（天光、月光、补光）应当**按光色直接提亮**，否则低能量冷光会被色温带染成暗红，
	//      高光就变成"泥红色"而不是参考图那种灰白亮部。
	float lum = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	float warm = clamp((max(COLOR.r, COLOR.g) - COLOR.b) / max(lum, 1.0e-3), 0.0, 1.0);
	vec3 base_color = smoke_color * ambient_grey;
	// 冷光 / 白光：直接按光色提亮（这就是"灰白高光"的来源）
	vec3 cold_color = COLOR.rgb * ((1.0 - warm) * light_add);
	// 暖光：走色温带（暗红→橙→黄白的热核）
	float heat = clamp(lum * emissive_gain, 0.0, 2.0);
	vec3 hot_color = min(blackbody(heat), emissive_clamp)
		* (warm * light_add * clamp(heat, 0.0, 1.0));
	ALBEDO = clamp(base_color + cold_color + hot_color, vec3(0.0), vec3(1.0));
	ALPHA = clamp(alpha, 0.0, 1.0);
}
