// 遮挡挖洞（不丢阴影版）
//
// 上一版用 blend_mix（alpha 混合）做半透明 —— 而 **Godot 的阴影 pass 会跳过
// 混合材质**，于是整棵树都不投影了（用户："挖洞后，模型的阴影没了"）。
//
// 这一版改用 **discard + 抖动**：
//   * 材质走"不透明 + discard"这条路 -> 参与阴影 pass，投影回来了
//   * 用屏幕空间的 4x4 Bayer 抖动，把"半透明"表现成一格格的稀疏像素，
//     远看仍是一层薄纱（而不是实心）
//
// 角色屏幕位置/半径通过 global uniform 每帧写一次，一份着色器全场景共用。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back,
	diffuse_burley, specular_schlick_ggx;

global uniform vec2 occ_player_uv;      // 角色屏幕 UV
global uniform float occ_radius;        // 洞半径（UV）
global uniform float occ_softness;      // 边缘过渡
global uniform float occ_hole_alpha;    // 洞内"看起来"的不透明度（0~1）

uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

// 4x4 Bayer 矩阵：把连续的不透明度量化成"网格状稀疏像素"
float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int idx = y * 4 + x;
	float m[16] = float[16](
		0.0,  8.0,  2.0, 10.0,
		12.0, 4.0, 14.0,  6.0,
		3.0, 11.0,  1.0,  9.0,
		15.0, 7.0, 13.0,  5.0);
	return m[idx] / 16.0;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * tint;
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	// 洞内 -> occ_hole_alpha，洞外 -> 1.0
	float d = distance(SCREEN_UV, occ_player_uv);
	float k = smoothstep(occ_radius - occ_softness, occ_radius + occ_softness, d);
	float a = mix(occ_hole_alpha, 1.0, k);

	// Bayer 抖动：a 越小，被丢弃的格子越多 -> 看起来越透。
	// 用 discard 而不是 ALPHA，是为了让材质留在不透明路径上（才能投影）。
	if (a < 1.0) {
		if (bayer4(FRAGCOORD.xy) > a) {
			discard;
		}
	}
	ALPHA = 1.0;
}
