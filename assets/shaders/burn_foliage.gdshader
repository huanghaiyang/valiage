shader_type spatial;
// 植被燃烧 —— 花草树木被点着后：**不规则斑点逐渐扩大 -> 变黑烧焦 -> 消失**，
// 燃烧过程中模型像被不规则的风吹动一样摆动。
//
// 【斑点是"长"出来的，不是整片一起变黑】
//   用噪声当"燃料分布"：阈值 thr = 1 - burn 随着燃烧进度下降，
//   噪声值高于阈值的部分被判定为"已烧" -> 斑点逐个出现、互相连接成片。
//   噪声值取**世界坐标**（wp.xz/wp.y），所以同一株上的斑点位置固定不会游走，
//   不同株之间也不会雷同。
//
// 【烧焦 + 余烬】
//   已烧部分 mix 到 char_color（近黑的焦色）；烧蚀前沿按距离做一个亮边
//   （ember）—— 这就是"火星在表面燃烧/蔓延"的观感来源。
//
// 【摆动】vertex() 里按高度加权做两频叠加的横向位移（每株 phase 不同），
//   燃烧越深摆得越小 —— 快烧完的枝叶不该还那么飘。
//
// 【怎么用】可以 material_override（会完全接管外观，适合本来就很简单的植被），
//   也可以 material_overlay（保留原外观，只叠加焦黑与余烬）—— 由控制器决定。
render_mode blend_mix, cull_disabled, depth_draw_opaque, shadows_disabled,
		ambient_light_disabled, fog_disabled;

uniform sampler2D noise_tex : hint_default_black;
/// 原贴图（用 override 时可留空；用 overlay 时传入原本的 albedo）
uniform sampler2D albedo_tex : hint_default_white;
/// ★ 遮罩贴图：用它的 **alpha** 裁出植被的真实轮廓。
///   没有它的话，叠加层会盖满整张卡片 -> 烧出来是**方块斑块**（用户实测反馈：
///   "烧的时候还是出现了斑块"）。草/树叶的形状都在贴图 alpha 里，必须用它遮罩。
uniform sampler2D mask_tex : hint_default_white;
uniform bool use_mask = false;
/// ★ 遮罩取**哪个通道**：0=r 1=g 2=b 3=a。必须和原着色器一致 ——
///   bermuda 草（grass_wind.gdshader）写的是 `ALPHA = texture(alpha_tex, UV).r`，
///   形状在**红通道**，而那张 PNG 的 a 恒为 1；取 .a 会让遮罩失效
///   -> 叠加层盖满卡片 -> **透明区域也变黑**（用户实测：卡片状黑块）。
uniform int mask_channel = 3;
/// ★ alpha 裁剪阈值：原贴图 alpha 低于它就直接丢弃。
///   只做 `ALPHA *= shape` 是不够的：半透明边缘仍会显示成"大黑斑"，
///   必须按植被真实轮廓**剪裁**（用户实测反馈："其他草还是大黑斑"）。
uniform float scissor : hint_range(0.0, 1.0) = 0.35;
/// 是否启用裁剪。**由原材质决定**：Alpha 混合的软边材质不能裁剪（会被硬切）。
uniform bool scissor_enabled = true;
/// 原材质的贴图是否"强制不透明"（force_opaque）：是的话它没有轮廓 alpha，别拿它遮罩
uniform bool force_opaque = false;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

/// 燃烧进度 0..1（斑点扩大）
uniform float burn : hint_range(0.0, 1.0) = 0.0;
/// 灰化/消失进度 0..1（烧完之后才推进）
uniform float ash : hint_range(0.0, 1.0) = 0.0;
/// 焦炭颜色
uniform vec3 char_color : source_color = vec3(0.06, 0.05, 0.045);
/// 余烬亮边颜色
uniform vec3 ember_color : source_color = vec3(1.0, 0.34, 0.05);
/// 余烬亮边宽度（噪声单位）：**要窄**，只留一条缝。
/// 太宽会变成"整片烧过的地方都发红光"，而不是焦黑（用户实测反馈）。
uniform float ember_width : hint_range(0.005, 0.5) = 0.035;
uniform float ember_gain : hint_range(0.0, 4.0) = 0.5;
/// ★ 叠加模式（material_overlay）：只在"烧过/余烬"的地方画，
///   未烧的地方 alpha=0 -> 完全不影响原外观。
///   这样就不必接管原生材质（接管会丢掉草的自定义着色器/透明裁剪，
///   草片会变成不透明方块 —— 观感就是"模型变大了"）。
uniform bool overlay_mode = true;
/// 噪声世界尺度（越大斑点越碎）
uniform float noise_scale : hint_range(0.1, 6.0) = 1.4;
/// 摆动幅度（米）与频率
uniform float sway_amt : hint_range(0.0, 0.5) = 0.07;
uniform float sway_freq : hint_range(0.0, 6.0) = 1.8;
/// 每株随机相位（错开，避免整片一起摆）
uniform float phase = 0.0;
/// 用来做高度加权的参考高度（米）：一般给这株的大致高度
uniform float height_ref : hint_range(0.05, 20.0) = 1.0;
/// 是否用原贴图着色（override 模式打开）
uniform bool use_albedo = false;
uniform bool use_uv = true;

varying vec2 v_uv;

void vertex() {
	v_uv = UV;
	// 不规则风动：高度加权 + 两频叠加（单频会显得像节拍器）
	float h = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.5);
	// 烧得越深越不飘（烧焦的枝叶是脆的）
	float alive = 1.0 - clamp(burn, 0.0, 1.0) * 0.75;   // ★ GLSL 没有 :=，写错会报 Expected a ',' or ';'
	float t = TIME * sway_freq + phase;
	float ax = sin(t) * 0.6 + sin(t * 1.73 + phase * 2.1) * 0.4;
	float az = cos(t * 1.21 + phase * 1.7) * 0.6 + cos(t * 2.3 + phase) * 0.4;
	VERTEX.x += ax * sway_amt * h * alive;
	VERTEX.z += az * sway_amt * h * alive;
	// 灰化阶段整体轻微收缩（配合控制器的隐藏，让"消失"更自然）
	VERTEX *= 1.0 - clamp(ash, 0.0, 1.0) * 0.35;
}

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float n = texture(noise_tex, wp.xz * noise_scale + vec2(wp.y * noise_scale * 0.35)).r;

	vec4 base = base_color;
	if (use_albedo) {
		base *= texture(albedo_tex, v_uv);
	} else {
		base.a *= 1.0;                  // overlay 模式：底色交给下面 mix
	}

	// ① 斑点扩大：阈值下降 -> 已烧区域逐步连成片
	float thr = clamp(1.0 - burn, 0.0, 1.0);
	float burned = 1.0 - smoothstep(thr - 0.015, thr + 0.015, n);

	// ② 烧焦：整块**变黑**（不是染红），只在前沿留一条窄的余烬缝
	vec3 col = mix(base.rgb, char_color, burned);
	float d = n - thr;
	float ember = exp(-(d * d) / max(ember_width * ember_width, 1e-6));
	ember *= ember_gain * (1.0 - ash) * (1.0 - burned * 0.5);
	col += ember_color * ember;

	// ③ 灰化：整体变暗并淡出
	float a = base.a * (1.0 - clamp(ash, 0.0, 1.0));
	col = mix(col, vec3(0.03, 0.03, 0.03), clamp(ash, 0.0, 1.0) * 0.6);

	// ★ 用原贴图的轮廓裁出真实形状：否则叠加层会盖满整张卡片（方块斑块）
	//   注意**通道**要和原着色器一致（mask_channel），否则透明区域也会变黑。
	float shape = 1.0;
	if (use_mask && !force_opaque) {
		vec4 m = texture(mask_tex, v_uv);
		if (mask_channel == 0) {
			shape = m.r;
		} else if (mask_channel == 1) {
			shape = m.g;
		} else if (mask_channel == 2) {
			shape = m.b;
		} else {
			shape = m.a;
		}
		// ★ 裁剪只在原材质本身是"裁剪型"时做：
		//   Alpha 混合的软边材质裁了会像被剪刀剪过（用户提醒："没考虑材质透明度"）
		if (scissor_enabled && shape < scissor) {
			discard;
		}
	}

	if (overlay_mode) {
		// 叠加：只在"烧过"与"余烬"处有像素，未烧区域完全透明 -> 原外观不受影响
		ALBEDO = mix(char_color, ember_color, clamp(ember, 0.0, 1.0));
		ALPHA = clamp(burned * 0.92 + ember * 0.55, 0.0, 1.0) * (1.0 - clamp(ash, 0.0, 1.0))
				* shape;
	} else {
		ALBEDO = col;
		ALPHA = a * shape;
	}
}
