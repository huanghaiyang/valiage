// 遮挡挖洞（保留原材质外观）
//
// 之前只把 albedo 贴图和颜色搬过来，丢了原材质的三样东西，所以"被挖洞的物体贴图变了"：
//   * uv1_scale / uv1_offset  -> 贴图平铺比例不一样
//   * 法线贴图                 -> 表面细节消失（红枫树刚补的法线图就丢了）
//   * 顶点色                   -> KayKit/Kenney 那批建筑的明暗主要靠顶点色
// 现在这三样都从原材质取过来（着色器里都有对应 uniform）。
//
// 另外：**绝不写 ALPHA**。Godot 判断材质是否透明就是看着色器有没有写 ALPHA，
// 写了就进透明队列、不参与阴影绘制（已经踩过两次）。形状全部靠 discard 出。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back,
	diffuse_burley, specular_schlick_ggx;

global uniform vec2 occ_player_uv;      // 角色屏幕 UV
global uniform float occ_radius;        // 洞半径（UV）
global uniform float occ_softness;      // 边缘过渡
global uniform float occ_hole_alpha;    // 洞内"看起来"的不透明度

uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform sampler2D normal_tex : hint_normal;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform vec4 uv_scale_offset = vec4(1.0, 1.0, 0.0, 0.0);   // xy=scale zw=offset
uniform bool use_vertex_color = false;
uniform bool use_normal_map = false;

// 4x4 Bayer：把"半透明"量化成网格状稀疏像素（discard 出形，才能投影）
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
	vec2 uv = UV * uv_scale_offset.xy + uv_scale_offset.zw;
	vec4 c = texture(albedo_tex, uv) * tint;
	if (use_vertex_color) {
		c.rgb *= COLOR.rgb;
	}
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	if (use_normal_map) {
		NORMAL_MAP = texture(normal_tex, uv).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}

	// 洞内 -> occ_hole_alpha，洞外 -> 1.0
	float d = distance(SCREEN_UV, occ_player_uv);
	float k = smoothstep(occ_radius - occ_softness, occ_radius + occ_softness, d);
	float a = mix(occ_hole_alpha, 1.0, k);
	if (a < 1.0) {
		if (bayer4(FRAGCOORD.xy) > a) {
			discard;
		}
	}
}
