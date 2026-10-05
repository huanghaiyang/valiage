shader_type spatial;
// 扇形选点器 · **物体表面叠加**（复用【物体探测】那套：material_overlay + 世界坐标算形状）。
//
// 【为什么要有这一份】地形那张贴合网格是"顶点高度场"：顶点只能上下动，
//   于是物体立面铺不上、物体边缘还会拉出"裙边"。这里改成把材质**叠在物体自己身上**
//   （material_overlay），形状在片元里按**世界坐标**算 —— 于是石头顶、墙面、树干
//   任何朝向的表面都能正确画出扇面（这就是探测波"贴着物体表面走"的做法）。
//
// 【形状】与 spell_sector.gdshader 完全一致，只是把 UV 换成世界 XZ：
//   r   = length(wp.xz - center.xz) / radius
//   ang = atan2(dz, dx)（和选点器的 axis 同一套约定）
//   扇形 = (r > inner) 且 (|ang - axis| <= half)
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform vec3 sector_center = vec3(0.0);
uniform float axis = 0.0;
uniform float half_angle = 0.785;
uniform float radius = 10.0;
uniform float inner_m = 0.5;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.72);
uniform float fill_strength : hint_range(0.0, 2.0) = 0.55;
uniform float edge_strength : hint_range(0.0, 4.0) = 2.2;
uniform float rim_strength : hint_range(0.0, 4.0) = 1.6;
/// ★ 沿表面往上爬：越高处"到达半径"越小 -> 扇形的边界会顺着立面往上收，
///   像【物体探测】探测波的 band 一样"爬上墙"，而不是像投影一样平铺上去。
///   取自 detect_scan.gdshader 的 climb（那里默认 0.8，是它观感好的关键）。
uniform float climb : hint_range(-2.0, 2.0) = 0.4;
/// ★ 掠射角增强：从侧面看立面时更亮（贴在石块/墙面上的轮廓才看得清）。
///   同样取自 detect_scan.gdshader 的 edge_boost。
uniform float edge_boost : hint_range(0.0, 2.0) = 0.6;

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 d = wp.xz - sector_center.xz;
	// climb：离脚下越高，扇形的"到达半径"越小 -> 边界沿立面往上收（探测波的爬表面做法）
	float r_here = max(radius - max(wp.y - sector_center.y, 0.0) * climb, 0.05);
	float r = clamp(length(d) / max(r_here, 0.001), 0.0, 1.0);
	float ang = atan(d.y, d.x);
	float dd = ang - axis;
	dd = atan(sin(dd), cos(dd));                 // 包到 -PI..PI，避免跨 ±PI 断裂
	float ad = abs(dd);

	float inside = 1.0 - smoothstep(half_angle - 0.010, half_angle + 0.010, ad);
	float inner_r = clamp(inner_m / max(r_here, 0.001), 0.0, 0.85);
	float inner_ok = smoothstep(inner_r - 0.010, inner_r + 0.010, r);
	float outer_ok = 1.0 - smoothstep(0.985, 1.0, r);
	float rim = smoothstep(0.86, 1.0, r) * outer_ok;
	float edge = exp(-pow((ad - half_angle) / 0.028, 2.0));

	float a = inside * inner_ok * outer_ok * fill_strength;
	// ★ 填充按**表面朝向**分配，但**立面不能归零**：
	//   顶面（平台/石台）填满 —— 和地面连成一片，凸起处不显得"没涂到"；
	//   立面（墓碑/墙/箱子侧面）保留 55% —— 用户实测："墓碑表面没有白色，就不对"；
	//   整块糊满又会像"白斑"（同一批反馈的另一半）→ 所以是"顶面 100%、立面 55%"。
	//   NORMAL 在片元里是**视图空间**，要转到世界空间取"朝上程度"。
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float upness = clamp(wn.y, 0.0, 1.0);
	a *= mix(0.55, 1.0, smoothstep(0.0, 0.9, upness));
	a += inside * inner_ok * outer_ok * rim_strength * rim;
	a += edge * edge_strength * inner_ok * outer_ok;   // 边线同样要受半径限制
	// 掠射角增强（侧面看更亮）—— 和探测波扫描带同一套算法
	float fres = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 3.0);
	a *= 1.0 + edge_boost * fres;
	ALBEDO = mix(vec3(0.92, 0.95, 1.0), vec3(1.0), clamp(edge + rim * 0.6, 0.0, 1.0));
	ALPHA = clamp(a * tint.a, 0.0, 2.0);
}
