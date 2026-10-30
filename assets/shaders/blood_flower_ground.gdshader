// ============================================================================
// blood_flower_ground.gdshader —— 嗜血狂花：圈内贴地血泊
// ============================================================================
// 画在圈内的一块扁平四边形上（由 blood_flower.gd 按圈半径建 QuadMesh）：
//   · 边缘径向衰减，避免出现生硬圆盘边界；
//   · 两层正弦慢速流动叠出"血在缓慢涌动"的斑驳感；
//   · fade 由法术脚本驱动（生长时淡入、结束前淡出）。
// 渲染：unshaded + blend_mix + depth_draw_never —— 不参与光照、不写深度，
//   贴地叠在其它地表效果之上，不会和雾粒子互相遮挡。
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 pool_color : source_color = vec3(0.30, 0.012, 0.02);
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float pulse_speed : hint_range(0.0, 3.0) = 0.7;

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float r = length(c);
	// 中心实、边缘虚；平方一下让外沿更柔和
	float edge = 1.0 - smoothstep(0.55, 1.0, r);
	edge *= edge;
	// 两股慢速正弦错相 -> 斑驳的血色涌动（不引入噪声贴图，保持零额外资源）
	float swirl = sin(c.x * 6.0 + TIME * pulse_speed) * sin(c.y * 5.0 - TIME * pulse_speed * 0.8);
	float mottle = 0.7 + 0.3 * swirl;
	ALBEDO = pool_color * (0.8 + 0.4 * mottle);
	ALPHA = clamp(edge * (0.42 + 0.22 * mottle) * fade, 0.0, 1.0);
}
