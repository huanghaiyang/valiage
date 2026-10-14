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

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float radius = length(centered);
	float falloff = 1.0 - smoothstep(softness, 1.0, radius);
	falloff *= falloff;

	ALBEDO = mist_color;
	ALPHA = clamp(falloff * strength * COLOR.a, 0.0, 1.0);
}
