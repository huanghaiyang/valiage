// ============================================================================
// fog_vortex_swirl.gdshader —— 角色**周身涡流**（独立可视化层，不做浓度扰动）
// ============================================================================
// 【为什么单独一层】雾浓度在浓雾场景里早已饱和（不透明度≈1 的白幕），**白幕上没有细节可看**：
//   无论怎么搅浓度场，屏幕上看不出来。所以涡流不再依赖浓度场，而是**直接画出来**：
//   在角色周围套一层"螺旋条纹"的圆筒，用**明暗差**（暗带压暗、亮带提亮）把涡卷显示出来。
//
// 【它画什么】极坐标下的螺旋带：
//     phase = θ + 旋向 × 圈数 × r + 高度项 − 时间 × 转速
//   亮带/暗带交替（ALBEDO 在 dark_color ↔ light_color 间插值），
//   径向与上下两端淡出 ⇒ 看起来是"绕着人卷起来的一股风"。
//   · 在浓白雾上：暗带把白雾压出灰蓝条纹 ⇒ 看得到
//   · 在深色草地/地面上：亮带提亮 ⇒ 也看得到
//   这就是"明暗变化"的来源（单靠加亮在白幕上是看不见的）。
//
// 【谁驱动】FogField 每帧把强度（角色速度）、旋向、半径、位置喂进来；
//   角色不动时 strength = 0 ⇒ 整层完全透明（等于没开）。
//
// 【参数】
//   radius/height    尺寸（米）：**两把独立的尺子**，只影响世界尺寸，**与图案无关**。
//                    （壳体上不做径向淡出，所以任何半径都成立；详见 fragment 里的教训注释）
//   y_fade           从哪个高度开始往上淡出（0.85 = 只在最上面淡出）
//   turns            螺旋圈数（越大条纹越密）
//   spin_speed       旋转速度（圈/秒）
//   spin_sign        +1 / −1：旋向（跟 character_swirl_mps 的符号一致）
//   strength         强度（0 = 不显示），由角色速度驱动
//   alpha_max        最大不透明度（这条涡流最浓能压多暗）
//   dark_color/light_color  暗带/亮带颜色
//   streak_sharpness 条纹锐度（越大越像细丝）
//   y_fade           从哪个高度开始往上淡出（0.2 = 很矮，1.0 = 到顶才淡）
//   wobble           条纹的抖动强度（用 sin-hash 打散规则感，避免"塑料螺旋"）
// ============================================================================

shader_type spatial;
// ★ depth_test_disabled 是必须的：这一层是"围绕角色的风/雾"，必须画在草叶**之上**。
//   开着深度测试时，它会被上千片草的裁剪逐像素剪碎 ⇒ 条纹变成一片麻点（实测就是这样）。
//   角色本体的遮挡不靠深度测试（这一层必须画在草之上），靠"壳体本来就在角色外面一圈"。
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never,
		cull_disabled, shadows_disabled, fog_disabled;

/** 涡流层半径（米）：只围着角色一点点（1~2 米足够）。与 height 完全独立 */
uniform float radius : hint_range(0.05, 40.0) = 1.5;
/** 涡流层高度（米）：**任意值**，与 radius 无关（0.5 = 贴地一圈，2.6 = 裹住身体） */
uniform float height : hint_range(0.05, 40.0) = 2.6;
/** 螺旋圈数：**沿高度**绕几圈（1~2 = 一股往上卷的风；>4 会碎成斑点） */
uniform float turns : hint_range(0.0, 8.0) = 1.6;
/** 旋转速度（圈/秒） */
uniform float spin_speed : hint_range(0.0, 6.0) = 1.5;
/** 旋向：+1 / −1（由 FogField 按 character_swirl_mps 的符号写入） */
uniform float spin_sign = 1.0;
/** 强度：0 = 完全透明（角色静止时），1 = 满强度（由角色速度驱动） */
uniform float strength : hint_range(0.0, 2.0) = 1.0;
/** 最大不透明度：这条涡流最浓时能压多暗 */
uniform float alpha_max : hint_range(0.0, 1.0) = 0.62;
/** 暗带颜色（把底下的雾/场景压暗，浓白雾上就靠它显形） */
uniform vec3 dark_color : source_color = vec3(0.30, 0.36, 0.47);
/** 亮带颜色（在深色地面/草上提亮，形成"被光扫过"的银边） */
uniform vec3 light_color : source_color = vec3(0.98, 0.99, 1.0);
/** 条纹锐度 */
uniform float streak_sharpness : hint_range(0.5, 8.0) = 1.7;
/** 从哪个高度开始往上淡出（0.85 = 只在最上面一点淡出；调小 = 贴地一条） */
uniform float y_fade : hint_range(0.1, 1.0) = 0.85;
/** 条纹抖动：打散"规则螺旋"的塑料感 */
uniform float wobble : hint_range(0.0, 1.0) = 0.28;
/** 被不透明物体遮挡时的过渡宽度（米）：★ 软遮挡的关键 —— 用屏幕深度做**渐变**淡出，
 *  而不是硬深度测试。硬测试会被上千片草叶逐像素剪碎（那就是最早的"麻点"），
 *  渐变只让它在草/角色/墓碑后面柔和地隐没。 */
uniform float occlusion_soft_m : hint_range(0.01, 3.0) = 0.35;
/** 屏幕深度（Godot 提供）：用来判断本片元是不是被不透明物体挡在后面 */
uniform sampler2D depth_tex : hint_depth_texture;

varying vec3 v_local;
/** 本片元沿视线方向的深度（米）：fragment 里与场景深度比较，做软遮挡 */
varying float v_view_depth;

void vertex() {
	v_local = VERTEX;      // 圆筒网格以自身原点为中心，Y 为轴向
	v_view_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

/** sin-hash：稳定、无纹理、够用（和粒子那边同一个套路） */
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

/** 平滑 value noise（2D），用来给条纹加不规则感 */
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	// ★★★ 这一层是**壳**（圆筒表面），不是体 —— 所以壳面上**不能**做径向淡出！
	//   网格是"半径 1、高 1"的单位圆筒，靠节点 scale 缩放 ⇒ 壳上每个片元的
	//   length(v_local.xz) **恒等于 1**。之前在这里做径向收口，直接导致：
	//     · r 写成 length(v_local.xz)/radius：半径 1.0 → r=1 → 外圈淡出 = 0 ⇒ **完全不显示**
	//       （用户实测"设置成 1 就没效果"），半径 0.2 → r=5 夹到 1 → 同样为 0；
	//       半径 2.0 → r=0.5 恰好落在可见区 ⇒ 只有这一小段半径"看着能用"。
	//     · 改成 length(v_local.xz) 更糟：恒为 1 ⇒ 永远不显示。
	//   现在壳面**不做任何径向淡出**：图案只由 角度 θ + 归一化高度 y 决定（一条螺旋带），
	//   "围一圈"的边界感由几何本身提供（圆筒就在那儿）。半径/高度只影响世界尺寸，与图案无关。
	float y = clamp(v_local.y + 0.5, 0.0, 1.0);
	float theta = atan(v_local.z, v_local.x);

	// 螺旋相位：θ 绕圈 + y 往上拧 ⇒ 一股沿着角色往上卷的风；再减去时间×转速让它转起来。
	// turns 现在是"沿高度绕几圈"（壳面没有半径方向，所以不能按 r 绕）。
	float phase = theta + spin_sign * turns * TAU * y
			- TIME * spin_speed * TAU * spin_sign;
	// 抖动：让条纹沿角度/高度方向轻微游走（不然就是一个完美的螺旋弹簧）
	phase += (vnoise(vec2(theta * 2.0, y * 5.0 - TIME * spin_speed * 2.0)) - 0.5)
			* wobble * TAU;
	float wave = 0.5 + 0.5 * sin(phase);
	// ★ 用 smoothstep 把正弦削成"实心丝 + 干净缝"：
	//   pow(wave, 2) 那种写法平均只有 ~0.35，再乘 alpha_max 0.55 ⇒ 实际不透明度不到 0.2，
	//   在浓白雾上就是"几乎看不见"（实测）。smoothstep 让丝芯吃满 alpha_max、缝隙归零。
	float sharp = clamp(0.30 / max(streak_sharpness, 0.2), 0.05, 0.45);
	float band = smoothstep(0.5 - sharp, 0.5 + sharp * 0.4, wave);

	// 只保留竖向淡出：底部与顶部渐隐，避免硬边
	float vertical = smoothstep(0.0, 0.12, y) * (1.0 - smoothstep(y_fade, 1.0, y));
	// ★ 软遮挡：这一层用了 depth_test_disabled（否则会被草叶剪成麻点），代价是它**永远画在所有
	//   东西之上 —— 包括角色本人**。半径小于角色本体（约 0.5 米）时，壳整个缩在身体里 ⇒
	//   条纹糊满全身，把角色"挡住"（用户实测反馈）。这里用屏幕深度做**渐变**遮挡：
	//   本片元比场景里最近的不透明表面还远 ⇒ 被挡住 ⇒ 淡出（0.35 米过渡，柔和，不产生硬边）。
	//   ⇒ 半径 0.2 米时壳整体被身体挡住（看不见，而不是糊在脸上）；草、墓碑、地面同理。
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec4 depth_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
	depth_view.xyz /= depth_view.w;
	float scene_view_depth = -depth_view.z;
	float keep = smoothstep(0.0, max(occlusion_soft_m, 0.01), scene_view_depth - v_view_depth);
	// 亮暗带 + 强度：静止时 strength = 0 ⇒ ALPHA = 0（整层看不见）
	float amount = band * vertical * strength;

	ALBEDO = mix(dark_color, light_color, band);
	ALPHA = clamp(amount * alpha_max * keep, 0.0, 1.0);
}
