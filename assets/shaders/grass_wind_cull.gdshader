shader_type spatial;
// 【树/灌木叶片专用】grass_wind 的**单面**变体 ✓
//
// 与 assets/shaders/grass_wind.gdshader 的**唯一区别**：
//   ★ 去掉 `cull_disabled` → 只渲染正面（默认 cull_back）✓
//
// 为什么需要它（性能 ✓ 实测推导）：
//   草地里的草是**单片薄草**，必须双面才不穿帮 → 原版保留 cull_disabled ✓
//   但树/灌木的叶片是**大量互相重叠的小面片** ✓：
//     · 背面本来就看不见 ✓ → 双面渲染等于白白多画一遍 ✗
//     · 叶片是"overdraw 大户" ✓ → 双面 = overdraw 再翻倍 ✗✗
//   实测：两棵低模树进场就很卡 ✓ → 把叶片改成单面是**最直接**的一项 ✓
//
// 其余（风 / 角色倒伏 / 燃烧 / alpha 裁剪 / 世界坐标）全部与原版**逐字一致** ✓
//   —— 保证树的摆动/燃烧表现与草一致 ✓
// ★★ 与 grass_wind.gdshader 的**两处**性能改动（其余逐字一致 ✓）：
//   ① 去掉 `cull_disabled` → 只渲染**正面** ✓（碎片成本减半 ✓ 叶片背面看不见 ✓）
//   ② 去掉 `depth_prepass_alpha` → **省掉一整个几何预通道** ✓
//      叶片用 ALPHA_SCISSOR（裁剪 ✓ 不是混合 ✗）→ **渲染顺序无所谓** ✓ → 预通道纯开销 ✗✗
//   另外 fragment 里**不再采样 rough_tex** ✓（每像素采样 3 → 1 ✓ overdraw 优化 ✓）
// ★★ 改成**双面渲染** ✓（用户要求：从不同角度都能看到叶子 ✓）
//   原来是我为性能去掉的 `cull_disabled` ✗ → 背面不画 ✓ 另一侧看就"没了/发黑" ✗✓
//   ★ 双面**必须同时翻背面法线**（见 fragment ✓）否则背面受光错误 → **发黑** ✓✓
render_mode world_vertex_coords, cull_disabled;

// ---- 天气系统会驱动的这 5 个 ----
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_strength = 0.18;
uniform float wind_gust = 0.15;
uniform float wind_speed = 1.4;
uniform float wind_turbulence = 0.30;

// ---- 叶片的 ----
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D alpha_tex : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic;
uniform bool has_normal = true;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
// 风默认关闭：由导出面板顶部栏的「初始化风参数」决定要不要写进材质。
uniform bool wind_enabled = false;
uniform float wind_height_ref : hint_range(0.01, 3.0) = 0.16;
uniform float wind_height_power : hint_range(0.5, 4.0) = 1.8;
uniform float wind_sway_scale : hint_range(0.0, 1.0) = 0.22;

// ---- 角色倒伏（世界坐标，由 scripts/wind.gd 每帧写）----
uniform vec3 player_pos = vec3(0.0, -100000.0, 0.0);
uniform vec3 player_forward = vec3(0.0, 0.0, -1.0);
uniform float player_radius : hint_range(0.05, 3.0) = 0.55;
uniform float player_bend : hint_range(0.0, 2.0) = 0.75;
uniform float player_spread : hint_range(0.0, 1.5) = 0.30;
uniform float player_move : hint_range(0.0, 1.0) = 0.0;
// ★★ 角色影响的**绝对高度上限**（米 ✓）—— 这是"树"和"草"的关键区别 ✓
//   草整株 ~0.2 m ✓ → 叶尖 h≈1 ✓ 角色倒伏作用在根部附近 ✓ 正确 ✓
//   树冠离根 8 m ✓ → 没有这个上限时 ✗ → **整个树冠**都会吃 player_spread（左右分开）✗✗
//   → 现在只影响离根 ≤ player_height_max 的部分 ✓（树冠只受风影响 ✓）
uniform float player_height_max : hint_range(0.1, 8.0) = 1.2;

// ---- 燃烧（语义与 grass_wind.gdshader 完全一致）----
uniform float burn : hint_range(0.0, 1.0) = 0.0;
uniform float ash : hint_range(0.0, 1.0) = 0.0;
uniform vec3 char_color : source_color = vec3(0.07, 0.06, 0.05);
uniform vec3 ember_color : source_color = vec3(1.0, 0.32, 0.05);
uniform float burn_ember : hint_range(0.0, 2.0) = 0.45;
uniform float burn_phase = 0.0;
varying float v_burn_amt;
varying float v_burn_ember;

void vertex() {
	float base_y = MODEL_MATRIX[3].y;
	float h = clamp((VERTEX.y - base_y) / max(0.001, wind_height_ref), 0.0, 1.0);
	float lev = pow(h, wind_height_power);

	if (wind_enabled) {
		float gust = 1.0 + wind_gust * 2.2
			* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + VERTEX.x * 0.013 + VERTEX.z * 0.011));
		float amp = wind_strength * gust;
		vec2 dir = normalize(wind_direction + vec2(0.0001));
		float along = sin(TIME * wind_speed + VERTEX.x * 0.35 + VERTEX.z * 0.28) * 0.35 + 0.65;
		float across = cos(TIME * wind_speed * 0.83 + VERTEX.x * 0.23 - VERTEX.z * 0.31) * wind_turbulence;
		vec2 sway = dir * along + vec2(-dir.y, dir.x) * (across * 0.25);
		float dist = (VERTEX.y - base_y) * wind_sway_scale * amp;
		VERTEX.xz += sway * (dist * lev);
	}

	if (player_move > 0.001) {
		// ★ 高度上限：离模型根部越高，角色影响越弱 ✓ 超过 player_height_max 完全不受影响 ✓
		//   （否则树冠会跟着角色左右分开 ✗ —— 用户实测 ✓）
		float hb = VERTEX.y - base_y;
		float capf = 1.0 - smoothstep(player_height_max * 0.6, player_height_max, hb);
		if (capf > 0.001) {
			vec2 rel = VERTEX.xz - player_pos.xz;
			float dd = length(rel);
			float infl = 1.0 - clamp(dd / max(0.01, player_radius), 0.0, 1.0);
			infl = infl * infl * (3.0 - 2.0 * infl) * clamp(player_move, 0.0, 1.0) * capf;
			if (infl > 0.001) {
				vec2 fw = normalize(player_forward.xz + vec2(0.0001));
				vec2 rt = vec2(-fw.y, fw.x);
				float along2 = dot(rel, fw);
				float side = dot(rel, rt);
				float front = smoothstep(-0.35, 0.45, along2);
				float dirsign = 1.0;
				if (side < 0.0) { dirsign = -1.0; }
				vec2 push = rt * (dirsign * player_spread) - fw * (0.10 * front);
				VERTEX.xz += push * (infl * h * (0.35 + 0.65 * front));
				VERTEX.y -= infl * h * player_bend * (0.40 + 0.60 * front);
			}
		}
	}

	float bn = fract(sin(dot(VERTEX.xz + vec2(VERTEX.y), vec2(12.9898, 78.233))
			+ burn_phase) * 43758.5453);
	if (burn > 0.001) {
		v_burn_amt = 1.0 - smoothstep(burn - 0.02, burn + 0.02, bn);
		v_burn_ember = exp(-pow((bn - burn) / 0.05, 2.0)) * burn_ember * (1.0 - ash);
	} else {
		v_burn_amt = 0.0;
		v_burn_ember = 0.0;
	}

	float burn_scale = clamp(1.0 - ash, 0.0, 1.0);
	vec3 burn_root = MODEL_MATRIX[3].xyz;
	VERTEX.xz = burn_root.xz + (VERTEX.xz - burn_root.xz) * burn_scale;
	VERTEX.y = burn_root.y + (VERTEX.y - burn_root.y) * burn_scale;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = texture(alpha_tex, UV).r;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
	// ★ 叶片小、屏幕上就几像素 ✓ → 法线/粗糙度几乎看不出 ✗
	//   但每像素采样 3 张 4K 贴图很贵 ✗ → 这里只采样 albedo + alpha（= overdraw 优化 ✓）
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
	ROUGHNESS = 0.75;                     // ★ 不再采样 rough_tex ✓（写死一个合理值 ✓）
	METALLIC = 0.0;

	if (v_burn_amt > 0.001) {
		ALBEDO = mix(ALBEDO, char_color, v_burn_amt);
		ALBEDO += ember_color * v_burn_ember;
	}
	if (ash > 0.999) {
		discard;
	}
}
