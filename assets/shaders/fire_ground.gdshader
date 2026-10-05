shader_type spatial;
// 贴地燃烧底光 —— 让火焰"粘"在地表上，而不是一丛悬空的火。
//
// 【为什么需要它】只有竖直的一丛火焰时，火焰与地面之间是"摆上去"的关系，
//   观感就是悬浮、没有粘滞感（用户反馈）。加一层贴着地表、随地形倾斜的燃烧光斑，
//   火焰才像"从地上烧起来"。
//
// 【UV】水平面盘的 UV 已按圆盘映射（中心 0.5，边缘半径 0.5），用径向距离做柔和衰减。
//   火焰纹理沿 V 方向滚动 -> 有"火舌从地面往外舔"的动感。
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D fire_tex : hint_default_black, filter_linear_mipmap;
/// 火色（偏红，与竖直火焰同一色系）
uniform vec4 tint : source_color = vec4(1.0, 0.32, 0.07, 1.0);
uniform float scroll_speed : hint_range(0.0, 3.0) = 0.85;
/// 点燃/熄灭系数（跟随整簇火的 grow）
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float strength : hint_range(0.0, 3.0) = 1.3;

void fragment() {
	float r = clamp(length(UV - vec2(0.5)) * 2.0, 0.0, 1.0);
	// 圆盘边缘柔和收掉 -> 不会有硬边方块
	float edge = smoothstep(1.0, 0.15, r);
	float n = texture(fire_tex, vec2(UV.x * 1.6 + 0.13, UV.y * 1.15 + TIME * scroll_speed)).r;
	float a = edge * (0.25 + 0.9 * n) * strength * fade;
	ALBEDO = tint.rgb * (0.85 + 1.1 * n);
	ALPHA = clamp(a, 0.0, 2.0);
}
