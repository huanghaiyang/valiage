// ============================================================================
// blood_bleed.gdshader —— 嗜血狂花：敌人体表流血
// ============================================================================
// 通过 material_overlay 贴在敌人网格上（不修改敌人自己的材质），画一层：
//   · 淡血膜：保证任何部位一眼能看出"身上在流血"；
//   · 错落血痕：按模型水平坐标分列，每列有自己的相位/速度，沿 Y 向下缓慢淌。
// 不依赖 UV —— 项目里不同敌人模型的 UV 差异很大，用模型空间坐标分列更稳。
// 渲染：unshaded + blend_mix + depth_draw_never —— 与金色守护/水膜一样走叠加层，
//   可以由 body_overlay_chain.gd 与其它长时法术共存。
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 blood_color : source_color = vec3(0.36, 0.02, 0.03);
uniform float intensity : hint_range(0.0, 1.0) = 1.0;
uniform float drip_density : hint_range(4.0, 80.0) = 22.0;
uniform float drip_speed : hint_range(0.0, 2.0) = 0.28;

varying vec3 v_local;

float hash11(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	// 按模型空间 xz 分列：同一列的血痕同相位，不同列错落
	float col = floor((v_local.x * 0.85 + v_local.z * 0.55) * drip_density);
	float seed = hash11(col + 7.0);
	float lane_on = step(0.42, seed);
	float speed = drip_speed * (0.6 + seed * 1.8);
	// +TIME（而不是 -TIME）：斑纹沿 Y 向下移动 = 血往下淌
	float band = fract(v_local.y * 1.6 + TIME * speed + seed * 9.0);
	float tail = smoothstep(0.0, 0.30, band) * (1.0 - smoothstep(0.50, 0.95, band));
	float drip = lane_on * tail;
	// 底噪淡血膜：每列亮度略有差异，避免整身一片死红
	float film = 0.13 + 0.05 * hash11(col * 3.1);
	float a = clamp((film + drip * 0.85) * intensity, 0.0, 1.0);
	ALBEDO = blood_color * (0.75 + drip * 0.9);
	ALPHA = a;
}
