// 遮挡挖洞：只把"盖住角色"的那一块像素抠掉，模型其余部分保持不透明。
//
// 原理：片元着色器拿自己的 SCREEN_UV 和「角色在屏幕上的位置」比距离，
// 落在洞里就 ALPHA=0（透明），洞外用 smoothstep 平滑过渡回不透明。
// 角色的屏幕位置/半径通过 **global uniform** 每帧写一次
// （RenderingServer.global_shader_parameter_set），所以一份着色器就够，
// 不用给每个材质单独接线。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back,
	diffuse_burley, specular_schlick_ggx;

// 每帧由 camera_rig.gd 写入
global uniform vec2 occ_player_uv;      // 角色在屏幕上的 UV（0~1，左上为原点）
global uniform float occ_radius;        // 洞的半径（UV 单位）
global uniform float occ_softness;      // 边缘过渡宽度
global uniform float occ_hole_alpha;    // 洞内保留的不透明度（0=全透，1=不淡）

uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 c = texture(albedo_tex, UV) * tint;
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	// 洞里半透明、洞外不透明，边缘用 smoothstep 过渡
	float d = distance(SCREEN_UV, occ_player_uv);
	float k = smoothstep(occ_radius - occ_softness, occ_radius + occ_softness, d);
	float a = mix(occ_hole_alpha, 1.0, k);
	ALPHA = a * c.a;
	// 只要不是完全不透明，就把深度推到最远 ——
	// 否则半透明的遮挡物仍会把角色挡在它后面（透明只影响颜色不影响深度）
	if (a < 0.999) {
		DEPTH = 1.0;
	}
}
