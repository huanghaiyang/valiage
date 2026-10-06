shader_type spatial;
// 【扇形选点器 · 屏幕空间覆盖】
//
// 用户的要求只有一句："扇形扫到的地方变白，不管它是什么物体、不管多大，
// 可以是整个物体也可以是物体的一部分。"
//
// 这句话本身就决定了做法：**逐像素判定**，而不是"给物体挂材质"。
//   · 投影贴花 Decal：只能贴一个盒体里的表面，且形状受贴图分辨率限制；
//   · material_overlay：要先"发现物体"再挂，天生是 opt-in（发现不了就不白）；
//   · 射线贴合网格：只能表达高度场（台阶/竖面/大物体都无解）。
// 这里是：相机前一个全屏面 -> 用**深度纹理**重建该像素的世界坐标 ->
// 落在扇形内就上白。于是地形、草、墓碑、17m 的碎块底座、只被切到一半的物体，
// 全部天然正确，边界就是扇形的两条边 + 外弧。
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never,
		cull_disabled, shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture;
// ★ 用 Godot 内置矩阵：INV_PROJECTION_MATRIX（屏幕->视图）与 INV_VIEW_MATRIX（视图->世界）。
//   之前是自己传 inv_proj/inv_view，只要取相机矩阵那一步失败，整套 uniform 写不进去、
//   全屏面一次都不会出图（实测"依旧没有白色"）。

/// 0 = 扇形（推进，有两条边 + 外弧）；1 = 圆盘（火焰灼烧，只有外弧）
uniform int shape_mode = 0;
uniform vec3 sector_center = vec3(0.0);
uniform float axis = 0.0;
uniform float half_angle = 0.785;
uniform float radius = 10.0;
uniform float inner_m = 0.5;
/// ★ 允许画到"脚下以下"多少米（防止穿到地下）。
///   角色站在高处（石台/岩石/台阶）时，镜头里那片**低处地面**可能比脚下低好几米
///   —— 原来硬编码 1.5m ✗，于是低处地面被切掉、只有高物体变白（用户实测 bug ✓）。
///   现在做成 uniform 并放宽到 12m ✓：足以覆盖常见落差，又仍能排除地下深处。
uniform float floor_margin = 12.0;
/// ★ 角色脚下高度：高度过滤的**唯一正确基准**。
///   之前用"圆心.y"当基准，而圆心会被鼠标抬到围栏/石头顶上（实测 3.02m），
///   于是允许范围整体上移、地面掉出范围 -> "地面不白、只有高物体白"。
///   锚在脚下就不会切到地面（地面≈脚下），只排除地下/地基。
uniform float ground_y = 0.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float fill_strength : hint_range(0.0, 2.0) = 0.55;
uniform float edge_strength : hint_range(0.0, 4.0) = 2.2;
uniform float rim_strength : hint_range(0.0, 4.0) = 1.6;

void fragment() {
	// 深度 -> 世界坐标（Forward+ 的 DEPTH_TEXTURE 是 reversed-Z 的原始深度）
	float d = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vpos.xyz /= max(vpos.w, 1e-6);
	vec3 wp = (INV_VIEW_MATRIX * vec4(vpos.xyz, 1.0)).xyz;

	vec2 dd = wp.xz - sector_center.xz;
	float r = length(dd) / max(radius, 0.001);
	float ang = atan(dd.y, dd.x) - axis;
	ang = atan(sin(ang), cos(ang));
	float ad = abs(ang);

	float inside = 1.0;
	float edge = 0.0;
	if (shape_mode == 0) {
		inside = 1.0 - smoothstep(half_angle - 0.008, half_angle + 0.008, ad);
		edge = exp(-pow((ad - half_angle) / 0.020, 2.0));
	}
	float inner_r = clamp(inner_m / max(radius, 0.001), 0.0, 0.85);
	float inner_ok = smoothstep(inner_r - 0.006, inner_r + 0.006, r);
	float outer_ok = 1.0 - smoothstep(0.985, 1.0, r);
	// 高度过滤：只排除"脚下 floor_margin 米以下"（地下/地基/地道）✓
	// ★ 基准是 ground_y（脚下与圆心的较低者 ✓），下限由 uniform 控制 ✓
	//   —— 站高处时低处地面在 12m 以内 → 照常被覆盖 ✓（bug 修复）
	float above = smoothstep(ground_y - floor_margin, ground_y - floor_margin + 1.0, wp.y);

	float rim = smoothstep(0.86, 1.0, r) * outer_ok;
	float a = inside * inner_ok * outer_ok * (fill_strength + rim_strength * rim);
	a += edge * edge_strength * inner_ok * outer_ok;
	ALBEDO = mix(vec3(0.93, 0.96, 1.0), vec3(1.0), clamp(edge + rim * 0.6, 0.0, 1.0));
	ALPHA = clamp(a * tint.a * above, 0.0, 2.0);

}
