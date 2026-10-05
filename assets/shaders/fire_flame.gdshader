shader_type spatial;
// 火焰 —— 用灰阶火纹理做遮罩，向上滚动 + 噪声扭曲，并按渐变**染成红色**。
//
// 【为什么纹理能直接用】T_FirePanningCyl45.png 是 1024² 的**黑底灰阶火焰舌**，
//   本来给"旋转圆柱"用的。这里把它当**遮罩**：
//     · 亮度 r 当作"火焰浓度"
//     · 低于 dissolve 的部分直接侵蚀掉 —— 于是边缘不规则，不会出现方块边
//     · 再用浓度做**上色渐变**：边缘暗红 → 主体正红 → 核心暖黄
//   所以火焰一定是红的：主色 col_body 是纯红，只有最亮的核心才带一点黄。
//
// 【怎么动起来】
//   ① UV 的 V 方向持续滚动      -> 火苗持续往上窜
//   ② 噪声扰动 UV.x             -> 火苗左右扭动（越靠上扭得越厉害）
//   ③ 顶点随高度左右摆          -> 整张焰卡轻微摇曳
//   （每个实例的 phase 不同，见 fire_burst.gd -> 互相错开，不会整齐划一）
//
// 【渲染方式】blend_mix（**不透明混合**）+ 不受光（unshaded）+ 不写深度。
//   ★ 不能用 blend_add：加色**永远不会遮挡背景**，草会透过火苗看得见，
//     观感就是"透明度过低/像一层半透明贴片"（用户原话）。mix 才会真正覆盖背景。
//     想要"发光"的观感靠颜色本身够亮（brightness>1 时核心直接饱和到 1），
//     再加一层加色的核心辉光（见 fire_burst.gd 的 CoreGlow）来补辉光。
//   不写深度是为了避免多层焰卡互相切出硬边。
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never,
		shadows_disabled, ambient_light_disabled, fog_disabled;

uniform sampler2D fire_tex : hint_default_black, filter_linear_mipmap;
uniform sampler2D noise_tex : hint_default_black, filter_linear_mipmap;

/// 核心色（最亮处）：偏红的暖色 —— 刻意压掉黄白，整体保持"红火"
uniform vec4 col_core : source_color = vec4(1.0, 0.40, 0.06, 1.0);
/// 主体色：**正红**
uniform vec4 col_body : source_color = vec4(1.0, 0.13, 0.015, 1.0);
/// 边缘色：暗红（快烧尽的部分）
uniform vec4 col_edge : source_color = vec4(0.36, 0.008, 0.0, 1.0);

/// 火苗向上窜的速度
uniform float scroll_speed : hint_range(0.0, 4.0) = 1.15;
/// ★ 每张卡的滚动**倍率**（由 fire_burst 逐卡随机 0.7~1.4）。
///   只给 phase 不同是不够的：相位只错开"起始位置"，**频率仍完全一致**，
///   整片火会按同一个节奏一起窜，看起来很机械（用户实测反馈）。
///   让频率也各不相同，火焰才有"各自燃烧"的杂沓感。
uniform float scroll_scale : hint_range(0.3, 2.0) = 1.0;
/// 噪声扭曲幅度（火苗左右扭动）
uniform float noise_amt : hint_range(0.0, 0.6) = 0.16;
/// 侵蚀阈值：越大火焰越"瘦"（0.12 = 保留更多火肉，密度更高）
uniform float dissolve : hint_range(0.0, 0.8) = 0.12;
/// 顶部烧尽的位置（UV.y，越小越早淡出）
uniform float top_fade : hint_range(0.2, 1.0) = 0.86;
/// 整体亮度（mix 模式下**要让核心过曝到白热**，否则会变成一片纯红剪纸：
/// 亮度太低时整个火焰都停在 col_body 的红上，层次全丢）
uniform float brightness : hint_range(0.0, 6.0) = 2.2;
/// 整体透明度缩放（控制"一片火"的浓淡；这张纹理火肉少，所以给得偏高）
uniform float alpha_scale : hint_range(0.0, 2.0) = 1.45;
/// 每张焰卡的相位（错开滚动与摇摆）
uniform float phase = 0.0;
/// 顶点摇摆幅度
uniform float sway : hint_range(0.0, 0.2) = 0.035;

// ---- UV 是**算出来的**，不是读模型的（声明必须在 vertex() 之前，否则编译报 Unknown identifier）----
// ★ 这个网格只有 POSITION + NORMAL，**没有任何 UV**（Tripo 生成时没贴图）。
//   直接读 UV 会恒为 0 -> 纹理采样到固定常量（黑）-> 火焰完全不可见（实际踩过）。
//   这张焰卡躺在 YZ 平面上（X 只有 0.02~0.035 米厚），所以把 (z, y) 归一化到 0..1
//   就正好得到"沿着火苗展开"的贴图坐标。scale 取 1/卡的尺寸近似值：
//   宽度约 0.4 米 -> 2.5；高度约 0.59 米 -> 1.7。
uniform float uv_scale_x = 2.5;
uniform float uv_scale_y = 1.7;
uniform vec2 uv_offset = vec2(0.5, 0.5);

// ---- 随机波纹 + 卷曲（进阶）----
/// ★ 每张卡的**运动倍率**（由 fire_burst 逐卡随机 0.7~1.5）。
///   波纹/卷曲如果是全场同一频率，整片火会像一块布在齐步抖 ——
///   和之前"贴图流速完全一致导致太有节奏"是同一类问题。
uniform float motion_scale : hint_range(0.3, 2.0) = 1.0;
/// 波纹幅度（米）：随高度**线性**增强，底部几乎不动（火根要稳）
uniform float ripple_amt : hint_range(0.0, 0.2) = 0.05;
/// 波纹频率（沿高度的波数）
uniform float ripple_freq : hint_range(0.0, 12.0) = 4.2;
/// 波纹上行速度（火舌像有波在往上走）
uniform float ripple_speed : hint_range(0.0, 6.0) = 2.1;
/// 卷曲幅度（米）：随高度**平方**增强 -> 越靠上越卷，火梢卷出去
uniform float curl_amt : hint_range(0.0, 0.4) = 0.10;
/// 贴图扭曲幅度：让火舌**纹理**也跟着卷，而不只是轮廓在动
uniform float uv_curl : hint_range(0.0, 0.3) = 0.07;

varying vec2 v_uv;
varying float v_curl;

void vertex() {
	// 用局部坐标生成 UV（模型没有 UV，见上）
	v_uv = vec2(VERTEX.z * uv_scale_x, VERTEX.y * uv_scale_y) + uv_offset;
	float h = v_uv.y;
	float ms = motion_scale;   // ★ 局部变量不能带 hint_range 限定符（会报 Expected a ',' or ';'）
	float t = TIME * ms;
	// ① 基础摇摆：越靠上摆得越厉害（火苗尖端飘）
	VERTEX.x += sin(t * 2.3 + phase) * sway * h;
	VERTEX.z += cos(t * 1.7 + phase * 1.3) * sway * 0.6 * h;
	// ② 波纹：两列不同频率/相位的行波叠加（沿高度往上走）-> 不规则的水波状边缘
	float ripple_a = sin(h * ripple_freq - t * ripple_speed + phase * 1.7) * ripple_amt * h * ms;
	float ripple_b = cos(h * ripple_freq * 0.63 - t * ripple_speed * 0.72 + phase * 2.3)
			* ripple_amt * 0.7 * h * ms;
	VERTEX.x += ripple_a;
	VERTEX.z += ripple_b;
	// ③ 卷曲：h² 增强（顶部卷得最厉害），方向由本卡的 phase 决定 -> 每张卡卷的方向不同
	float curl = curl_amt * h * h * ms;
	VERTEX.x += cos(phase * 1.9 + t * 0.6) * curl;
	VERTEX.z += sin(phase * 1.9 + t * 0.6) * curl;
	v_curl = curl;
}

void fragment() {
	// ① 向上滚动（采样器默认 repeat，不需要 fract，避免接缝）
	//   ★ 符号说明（这里踩过坑）：采样坐标要**减去**时间才叫"往上走"。
	//     uv.y = v_uv.y - TIME*s  ->  纹理特征出现在 v_uv.y = t + TIME*s，随时间变大。
	//     而 v_uv.y 正比于高度，所以特征是在**往上升**。
	//     原先写成 `uv.y += TIME*s`，特征随时间出现在更小的 v_uv.y -> **往下走**，
	//     观感就是"火焰向下燃烧"（用户实测反馈），而且和下面 ② 里本来是向上走的
	//     噪声方向相反、互相打架。
	vec2 uv = v_uv;
	uv.y -= TIME * scroll_speed * scroll_scale + phase;
	// ★ 贴图也跟着卷：只让轮廓动、纹理不动的话，火舌会像"纸片在晃"而不是"火焰在卷"
	uv.x += sin(v_uv.y * 3.4 + TIME * 1.3 + phase) * uv_curl * clamp(v_uv.y, 0.0, 1.0);
	uv.x += v_curl * 0.6;

	// ② 噪声扰动：越靠上扭得越厉害。噪声的流速也跟着本卡的 scroll_scale 走，
	//   否则噪声与火纹频率不一致，同一张卡会显得"两层皮"。
	float n = texture(noise_tex, vec2(uv.x * 1.7,
			uv.y * 0.7 - TIME * 0.35 * scroll_scale)).r;
	uv.x += (n - 0.5) * noise_amt * (1.3 - v_uv.y);

	float m = texture(fire_tex, uv).r;

	// ③ 侵蚀 + 顶部烧尽。过渡带 0.35：内部填满、边缘柔化，
	//    既有"不透明"的火肉，又不会像剪纸一样一刀切。
	float mask = smoothstep(dissolve, dissolve + 0.35, m);
	mask *= 1.0 - smoothstep(top_fade, 1.0, v_uv.y);

	// ④ 按浓度上色：暗红 -> 正红 -> 白热核心。
	//    mix 模式下亮度 2.2，所以核心那几个像素会过曝成近白 —— 这正是火焰该有的样子；
	//    阈值放宽（0.08~0.55 / 0.60~0.95）是为了让整段渐变都用上，避免整片停在同一个红。
	vec3 col = mix(col_edge.rgb, col_body.rgb, smoothstep(0.08, 0.45, m));
	col = mix(col, col_core.rgb, smoothstep(0.42, 0.85, m));

	ALBEDO = col * brightness;
	ALPHA = clamp(mask * alpha_scale, 0.0, 1.0);
}
