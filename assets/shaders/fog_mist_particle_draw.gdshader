// ============================================================================
// fog_mist_particle_draw.gdshader —— 雾气粒子的绘制（柔和圆形雾团）
// ============================================================================
// 粒子画的是一个 QuadMesh，用径向衰减把方片"捏"成软团：
//   · alpha 走 (1-smoothstep)² 而不是线性 —— 线性会留下明显的圆形边界
//   · 用粒子的 COLOR.a（process 着色器里按生命期写的淡入淡出）乘进来
//   · depth_draw_never + blend_mix：粒子之间不互相遮挡，叠起来才像雾而不是塑料片
//
// ★ 若发现粒子是实心方块，先查 GPUParticles3D.transform_align 是否设成了
//   面向相机的模式（TRANSFORM_ALIGN_Z_BILLBOARD），以及 process 着色器有没有写 COLOR.a。
// ============================================================================

shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform vec3 mist_color : source_color = vec3(0.90, 0.93, 0.97);
/** 软边范围（0..1）。越大越"糊" —— 雾团之间才不会有明显的圆盘边界 */
uniform float softness : hint_range(0.0, 1.0) = 0.35;
uniform float strength : hint_range(0.0, 1.0) = 0.22;
/** 最小屏幕尺寸（像素）：太远/太小的粒子会被**撑到至少这么大**，
 *  避免"远处雾团只剩零散几个像素、一闪一闪"（需求：支持最小 1 像素）。0 = 关闭（旧行为）。 */
uniform float min_pixel_size : hint_range(0.0, 8.0) = 1.0;
/** 视口像素尺寸：由 FogField 每帧写入（顶点阶段算"1 像素在世界里有多长"要用）。
 *  ★ 不直接用内建 VIEWPORT_SIZE：它在不同 Godot 版本的可用阶段不一致，传 uniform 最稳。 */
uniform vec2 viewport_size_px = vec2(1920.0, 1080.0);

/** ★ 顶点阶段把四边形撑开：算"顶点相对四边形中心"的投影跨度（像素），
 *  不足 min_pixel_size 就按比例放大局部 XY。
 *  为什么放在顶点阶段：绘制阶段只能改颜色，改不了几何尺寸。
 *  注意：撑大后单位面积不透明度不变，所以极小的粒子会略微变亮 —— 这是"至少看得见"
 *  与"能量守恒"之间的取舍，取前者（需求明确要求最小 1 像素）。 */
void vertex() {
	if (min_pixel_size <= 0.0) {
		return;
	}
	vec4 clip_center = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 clip_vert = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	if (clip_center.w > 0.0 && clip_vert.w > 0.0) {
		vec2 ndc_center = clip_center.xy / clip_center.w;
		vec2 ndc_vert = clip_vert.xy / clip_vert.w;
		vec2 pixels = abs(ndc_vert - ndc_center) * viewport_size_px * 0.5;
		float max_pixels = max(pixels.x, pixels.y);
		if (max_pixels > 0.0001 && max_pixels < min_pixel_size) {
			VERTEX.xy *= min_pixel_size / max_pixels;
		}
	}
}

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float radius = length(centered);
	float falloff = 1.0 - smoothstep(softness, 1.0, radius);
	falloff *= falloff;

	ALBEDO = mist_color;
	ALPHA = clamp(falloff * strength * COLOR.a, 0.0, 1.0);
}
