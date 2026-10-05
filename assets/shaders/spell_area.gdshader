shader_type spatial;
// 通用施法区域圆圈 —— 贴在地面/物体表面上的白色圆盘。
//
// 【地形适配】圆盘的顶点由脚本逐个**从上方朝下打射线**落在真实表面上
//   （地形、台阶、地形上的物体都能贴住），所以这里只负责"怎么画"，不负责"贴哪"。
//   顶点已抬高一点点，配合正常深度测试 -> 不会被地面 z-fighting 吃掉，也不会穿到物体后面。
//
// 【形状】UV 由脚本按圆盘映射（中心 0.5,0.5，边缘半径 0.5），所以
//   length(UV-0.5)*2 就是归一化半径，可用来做边缘亮带。
//   纹理用 circle_02.png 提供柔和度，整体白色。
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D area_tex : hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.85);
/// 边缘亮带强度（圆圈边界要看得清）
uniform float rim_strength : hint_range(0.0, 4.0) = 2.4;
/// 内部填充强度（0 = 只有一圈边框）
uniform float fill_strength : hint_range(0.0, 2.0) = 0.75;
/// 呼吸/脉动（0 关）
uniform float pulse : hint_range(0.0, 1.0) = 0.25;

void fragment() {
	vec4 t = texture(area_tex, UV);
	float r = clamp(length(UV - vec2(0.5)) * 2.0, 0.0, 1.0);
	float rim = smoothstep(0.72, 1.0, r) * (1.0 - smoothstep(0.98, 1.0, r));
	float breathe = 1.0 + pulse * sin(TIME * 3.0) * 0.35;
	// 半径刻度：每 1/8 画一条暗环，方便目测圈的大小
	float ticks = smoothstep(0.06, 0.0, abs(fract(r * 8.0) - 0.5) - 0.44) * 0.25;

	float a = t.a * tint.a * (fill_strength + rim_strength * rim) * breathe;
	a += t.a * ticks * tint.a;
	ALBEDO = tint.rgb * (0.65 + 0.9 * rim);
	ALPHA = clamp(a, 0.0, 2.0);
}
