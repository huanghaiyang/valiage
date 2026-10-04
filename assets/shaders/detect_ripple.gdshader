shader_type spatial;
// 物体探测的地面波纹 —— 细线环 + 波前亮带 + 噪声扭曲，向外一层层荡开。
//
// 【为什么不用实体圆环（TorusMesh）】
//   torus 管子粗（内径/外径差 7%）看着像厚带子；贴地的平面圆环在起伏地形上会被埋进土里，
//   露出来那截就不像圆；而且一道环没有层叠感。改成按径向距离画，半径天生正圆、
//   线宽可控、一次就能画出一整串向外传播的环。
//
// 【三层叠加 —— 分层是 Niagara 那类效果的核心手感】
//   ① 波前亮带：跟随推进位置的一道较宽亮带（"正在前进"的可读性）
//   ② 尾随细环：一串很细的线，按 decay 逐圈衰减（水波震荡感）
//   ③ 噪声扭曲：波面沿角度/半径方向被噪声推得起伏，不再是数学上的标准圆
//      （对应 Niagara 里用噪声场扭曲位置的做法，观感从生硬变自然）
render_mode blend_add, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform vec3 wave_color : source_color = vec3(0.35, 0.90, 1.0);
/// 波前推进 0..1（相对 max_radius）
uniform float progress = 0.0;
uniform float max_radius = 16.0;
/// 相邻细环的间距（米）
uniform float wavelength = 2.8;
/// 越大线越细
uniform float sharpness = 46.0;
/// 后面的环衰减得多快
uniform float decay = 2.8;
/// 整体亮度（>1 会更接近 HDR，有 bloom 时会发光）
uniform float intensity = 1.25;
/// 噪声扭曲幅度（米）
uniform float warp = 0.55;
/// 波前亮带宽度（米）
uniform float lead_width = 0.9;
/// 波前亮带强度
uniform float lead_gain = 1.5;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec2 rel = (UV - 0.5) * 2.0;
	float rn = length(rel);

	// ★★ 噪声取**世界坐标**，不要用极坐标的 atan 角度。
	//    之前是 vnoise(vec2(ang * k, ...))，而 ang = atan(...) 在 ±π 处会**跳变**，
	//    于是整个波面出现一条明显的径向"接缝"（用户反馈"接缝处没有对齐"）。
	//    世界坐标的噪声天然处处连续 —— 没有接缝；而且频率以**米**为单位，
	//    波纹的起伏尺度不随探测半径变化（极坐标写法下半径越大波纹越密）。
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float n1 = vnoise(wp.xz * 0.16 + vec2(11.3, 7.1));
	float n2 = vnoise(wp.xz * 0.41 - vec2(3.7, 5.9));
	float wobble = (n1 - 0.5) + (n2 - 0.5) * 0.45;
	float r = rn * max_radius + wobble * warp * 2.0;

	float front = progress * max_radius;
	// 波前之外不画
	float inside = smoothstep(front + 0.05, front - 0.05, r);

	// ① 波前亮带
	float lead = exp(-pow((r - front) / max(lead_width, 0.05), 2.0));

	// ② 尾随细环
	float s = sin((r - front) * 6.28318530718 / max(wavelength, 0.05));
	float rings = pow(max(s, 0.0), max(sharpness, 1.0));

	// ③ 越靠后的环越淡
	float age = clamp((front - r) / max(max_radius, 0.001), 0.0, 1.0);
	float fade = exp(-age * max(decay, 0.0));

	float energy = lead * lead_gain + rings * fade;
	ALBEDO = wave_color * intensity;
	ALPHA = clamp(energy * inside, 0.0, 1.0);
}
