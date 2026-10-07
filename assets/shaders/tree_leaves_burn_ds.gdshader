shader_type spatial;
// ★★★ 局部风场（进阶需求 ✓）：由 `scripts/spells/blue_tornado.gd` 每帧广播 ✓
//   机制与 camera_rig 的 occ_player_uv 相同：RenderingServer.global_shader_parameter_set ✓
//   strength = 0 时完全无影响 ✓（龙卷风结束/不存在时它是 0 ✓）
global uniform vec3 tornado_pos;         // 龙卷风中心（世界坐标 ✓）
global uniform float tornado_radius;     // 影响半径（米 ✓）
global uniform float tornado_strength;   // 局部风速强度（0 = 无 ✓）
global uniform float tornado_swirl;      // 环流方向：+1 逆时针 / -1 顺时针 ✓
// 【树叶专用】从下往上烧 ✓ → 烧到就消失 ✓
//
// ★ 与花草用的 burn_foliage.gdshader **完全独立** ✓（花草逻辑一行未改 ✓）
//
// 与花草版的三处差别（都是树需要的 ✓）：
//   ① 燃烧前沿 = **高度**（从下往上 ✓），不是"整片同时冒斑点" ✗
//      —— 因为树是"火从根部烧上去" ✓，而原来的噪声阈值会让树冠先冒斑 ✗
//   ② 烧完**消失** ✓（ash 缩放 + 淡出 + 裁剪 ✓）—— 叶子要烧没 ✓
//   ③ 带叶片的 **颜色图 + 独立 alpha 遮罩**（草的逻辑保留 ✓）
//
// 控制方式与花草一致 ✓：scripts/vfx/foliage_burn.gd 只会写
//   burn（0..1 斑点/前沿进度）与 ash（0..1 消失进度）✓ —— 本 shader 两个都支持 ✓
render_mode blend_mix, cull_disabled, depth_draw_opaque,
		ambient_light_disabled, fog_disabled;

uniform sampler2D albedo_tex : source_color, hint_default_white;
/// 叶片的独立 alpha 遮罩（取红通道 ✓ 与草一致：形状在 r 通道 ✓）
uniform sampler2D alpha_tex : hint_default_white;
// ★★ 可选的法线/粗糙度 ✓ —— **有就带、没有就不带** ✓（用户要求 ✓）
//   默认 has_* = false ✓ → 不采样 ✓ 零额外开销 ✓（叶片 overdraw 大 ✓ 这点很重要 ✓）
uniform sampler2D normal_tex : hint_normal;
uniform bool has_normal = false;
uniform sampler2D rough_tex : hint_default_white;
uniform bool has_rough = false;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

/// 燃烧进度 0..1（= 燃烧前沿高度比例 ✓ 从下往上 ✓）
uniform float burn : hint_range(0.0, 1.0) = 0.0;
/// 消失进度 0..1（前沿到顶后开始 ✓ 叶子缩小淡出 ✓）
uniform float ash : hint_range(0.0, 1.0) = 0.0;
uniform vec3 char_color : source_color = vec3(0.06, 0.05, 0.045);
uniform vec3 ember_color : source_color = vec3(1.0, 0.34, 0.05);
uniform float ember_width : hint_range(0.005, 0.5) = 0.045;
uniform float ember_gain : hint_range(0.0, 4.0) = 0.7;
/// 这株树的**总高度**（米 ✓）：前沿 = burn * height_ref ✓
/// ★ 必须设成实际树高 ✓，否则前沿会被压缩（默认先给 8 ✓）
uniform float height_ref : hint_range(0.05, 30.0) = 8.0;
/// 边缘不规则程度（米 ✓）：用世界噪声轻微扰动前沿 ✓ 避免"一条直边" ✗
uniform float edge_jitter : hint_range(0.0, 1.0) = 0.25;
/// 叶片的风摆（沿用 grass 的简单两频摆动 ✓ 燃烧越深摆得越小 ✓）
uniform float sway_amt : hint_range(0.0, 0.5) = 0.06;
uniform float sway_freq : hint_range(0.0, 6.0) = 1.4;
uniform float phase = 0.0;
uniform bool wind_enabled = false;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_strength = 0.18;
uniform float wind_speed = 1.4;
// ★★★ 参照"风对草的影响"补齐 ✓（用户要求 ✓）：与 grass_wind 同一套风场 ✓
//   由 `scripts/wind.gd` 每帧写入 ✓（阵风 gust ✓ 湍流 turbulence ✓ 角色倒伏 player_* ✓）
uniform float wind_gust = 0.15;
uniform float wind_turbulence = 0.30;
uniform float wind_height_ref : hint_range(0.01, 30.0) = 8.0;
uniform float wind_height_power : hint_range(0.5, 4.0) = 1.8;
uniform float wind_sway_scale : hint_range(0.0, 2.0) = 0.22;
uniform vec3 player_pos = vec3(0.0, -100000.0, 0.0);
uniform vec3 player_forward = vec3(0.0, 0.0, -1.0);
uniform float player_radius : hint_range(0.05, 3.0) = 0.55;
uniform float player_bend : hint_range(0.0, 2.0) = 0.75;
uniform float player_spread : hint_range(0.0, 1.5) = 0.30;
uniform float player_move : hint_range(0.0, 1.0) = 0.0;
// ★★★ 角色身高上限（从 grass_wind_cull **移动过来** ✓ 用户要求：应该放在**叶片** ✓）
//   离模型根部越高，角色影响越弱 ✓ 超过它就完全不受影响 ✓（保护树冠只被风吹 ✓）
uniform float player_height_max : hint_range(0.1, 8.0) = 1.2;

uniform sampler2D noise_tex : hint_default_black;

varying vec2 v_uv;
varying float v_y;          // 局部高度 ✓（树的根 = 0）
varying float v_hnorm;      // 归一化高度 0..1 ✓

void vertex() {
	v_uv = UV;
	v_y = VERTEX.y;
	v_hnorm = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.0);
	float alive = 1.0 - clamp(burn, 0.0, 1.0) * 0.8;      // 烧得越深越不摆 ✓
	float hw = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.0);
	// ★★★ 参照"风对草的影响"（与 grass_wind 同一套算法 ✓ 用户要求 ✓）
	//   阵风 gust ✓ 沿线 along ✓ 侧向湍流 across ✓ 高度加权（wind_height_ref/power ✓）
	//   × alive（烧得越深摆得越小 ✓）
	if (wind_enabled) {
		float base_y = MODEL_MATRIX[3].y;
		float h = clamp((VERTEX.y - base_y) / max(0.001, wind_height_ref), 0.0, 1.0);
		float lev = pow(h, wind_height_power);
		float gust = 1.0 + wind_gust * 2.2
				* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + VERTEX.x * 0.013 + VERTEX.z * 0.011));
		float amp = wind_strength * gust;
		vec2 dir = normalize(wind_direction + vec2(0.0001));
		float along = sin(TIME * wind_speed + VERTEX.x * 0.35 + VERTEX.z * 0.28) * 0.35 + 0.65;
		float across = cos(TIME * wind_speed * 0.83 + VERTEX.x * 0.23 - VERTEX.z * 0.31) * wind_turbulence;
		vec2 sway = dir * along + vec2(-dir.y, dir.x) * (across * 0.25);
		float dist = (VERTEX.y - base_y) * wind_sway_scale * amp;
		VERTEX.xz += sway * (dist * lev) * alive;
		// ★★★ 局部风场（龙卷风 ✓ 进阶需求）：把风改成**绕中心的切向环流** ✓
		//   越靠中心越强（k² 衰减 ✓）、带一点向内吸（0.25 ✓）、方向由 tornado_swirl 决定 ✓
		if (tornado_strength > 0.001) {
			vec2 rel = VERTEX.xz - tornado_pos.xz;
			float d = length(rel);
			if (d < tornado_radius) {
				float k = 1.0 - d / max(tornado_radius, 0.001);
				k = k * k;                                   // 中心更强 ✓
				vec2 outw = normalize(rel + vec2(0.0001));
				vec2 tang = vec2(-outw.y, outw.x) * tornado_swirl;
				float t_scale2 = wind_height_ref * 1.40; // ★ x2（用户要求 ✓） // ★ 按真实高度 ✓ 去掉旧上限 ✓
			float t_swing2 = sin(TIME * 3.0);
			// ★★★ 物理化（用户要求）：悬臂梁单向偏转 δ∝h² + 30% 高度峰值颤动
			float t_w30 = (hw / 0.3) * exp(1.0 - hw / 0.3);
			float t_flut = sin(TIME * 24.0 + VERTEX.x * 7.0 + VERTEX.z * 5.0);
			vec2 local = tang * 0.9 - outw * 0.15;
			VERTEX.xz += local * (tornado_strength * k * t_scale2 * hw * hw) * alive;
			VERTEX.xz += tang * (tornado_strength * k * t_scale2 * 0.15 * t_flut * t_w30) * alive;
			}
		}
	}
	// 角色走过时的倒伏 / 左右分开（同样照草 ✓）
	if (player_move > 0.001) {
		float base_y2 = MODEL_MATRIX[3].y;
		float h2 = clamp((VERTEX.y - base_y2) / max(0.001, wind_height_ref), 0.0, 1.0);
		// ★ 身高上限：离根越高角色影响越弱 ✓ 超过 player_height_max 完全不受影响 ✓
		float capf = 1.0 - smoothstep(player_height_max * 0.6, player_height_max, VERTEX.y - base_y2);
		vec2 rel = VERTEX.xz - player_pos.xz;
		float dd = length(rel);
		float infl = 1.0 - clamp(dd / max(0.01, player_radius), 0.0, 1.0);
		infl = infl * infl * (3.0 - 2.0 * infl) * clamp(player_move, 0.0, 1.0) * capf;   // ★ × 身高上限 ✓
		if (infl > 0.001) {
			vec2 fw = normalize(player_forward.xz + vec2(0.0001));
			vec2 rt = vec2(-fw.y, fw.x);
			float along2 = dot(rel, fw);
			float side = dot(rel, rt);
			float front = smoothstep(-0.35, 0.45, along2);
			float dirsign = 1.0;
			if (side < 0.0) {
				dirsign = -1.0;
			}
			vec2 push = rt * (dirsign * player_spread) - fw * (0.10 * front);
			VERTEX.xz += push * (infl * h2 * (0.35 + 0.65 * front)) * alive;
			VERTEX.y -= infl * h2 * player_bend * (0.40 + 0.60 * front) * alive;
		}
	}
	// ★ 消失**只用材质透明**（用户要求 ✓）：不再缩放几何 ✗
	//   —— 原来看起来会"整株缩没" ✗；现在叶子保持原尺寸、只靠 alpha 淡出 ✓✓
}

void fragment() {
	vec4 base = base_color * texture(albedo_tex, v_uv);
	// ★ 叶片的独立遮罩（取 r 通道 ✓ 与 grass_wind 的做法一致 ✓）
	float shape = texture(alpha_tex, v_uv).r;
	if (shape < alpha_scissor) {
		discard;
	}

	// ★ 世界坐标哈希当噪声 ✓ —— **不依赖噪声贴图** ✓
	//   （之前用 noise_tex：材质没设贴图时默认全黑 ✗ → n=0 被算成"已烧" ✗
	//     → 叶子烧都没烧就全黑 ✓ 用户实测 ✓）
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float nz = fract(sin(dot(wp.xz + vec2(wp.y), vec2(12.9898, 78.233))) * 43758.5453);

	// ★★ 从下往上烧 ✓：前沿高度比例 = burn ✓（+ 噪声扰动 → 边缘不规则 ✓）
	float front = clamp(burn, 0.0, 1.0);
	// ★★ burn=0（未烧）时**强制不焦黑** ✓ —— 无论噪声/高度如何 ✓（杜绝"未烧先黑"✗）
	float burned = 0.0;
	if (burn > 0.001) {
		float jitter = (nz - 0.5) * edge_jitter * 0.35;
		float f2 = front + jitter;
		burned = 1.0 - smoothstep(f2 - 0.06, f2 + 0.06, v_hnorm);
	}

	vec3 col = mix(base.rgb, char_color, burned);
	float d = abs(v_hnorm - front);
	float ember = exp(-(d * d) / max(ember_width * ember_width, 1e-6));
	ember *= ember_gain * (1.0 - clamp(ash, 0.0, 1.0)) * (1.0 - burned * 0.5);
	col += ember_color * ember;

	// ★★ 消失 = **材质透明** ✓，并且**末端缓慢** ✓（用户要求 ✓）
	float fade = 1.0 - smoothstep(0.2, 1.0, clamp(ash, 0.0, 1.0));
	// ★★ 关键修复：ALPHA **只用于"烧尽淡出"** ✓ —— 不再乘 mask / 贴图 alpha ✗
	//   之前 `ALPHA = base.a * shape * fade` ✗ → 半透明混合 → 整棵树**发白** ✓ 叶子变稀 ✓（用户实测 ✓）
	//   叶子的真实轮廓已由上面的 `if (shape < alpha_scissor) discard;` **硬裁** ✓ → 叶子是实心 ✓
	float a = fade;
	col = mix(col, vec3(0.03, 0.03, 0.03), clamp(ash, 0.0, 1.0) * 0.4);
	if (a < 0.02) {
		discard;
	}
	// ★ 有法线/粗糙度就采样 ✓（没有就用默认 ✓ 不白花两次采样 ✓）
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, v_uv).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
	ROUGHNESS = 0.75;
	if (has_rough) {
		ROUGHNESS = texture(rough_tex, v_uv).r;
	}
	METALLIC = 0.0;
	ALBEDO = col;
	ALPHA = a;
}
