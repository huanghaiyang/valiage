shader_type spatial;
// ★★★ 局部风场（进阶需求）：由 scripts/spells/blue_tornado.gd 每帧广播
global uniform vec3 tornado_pos;
global uniform float tornado_radius;
global uniform float tornado_strength;
global uniform float tornado_swirl;
// 【树干 / 枝 专用】燃烧但**烧完不消失** ✓ —— 保留焦黑效果 ✓
//
// 与 assets/shaders/burn_foliage.gdshader 的关系：
//   它是给花草树木做的"燃烧 -> 变黑 -> **消失**"（ash 会缩放 + 淡出 ✓）✗
//   本文件是它的**去消失版** ✓：斑点/焦黑/余烬/烧焦后摆动减弱**全部保留** ✓，
//   但 `ash`（灰化消失）**不驱动任何消失** ✗ → 烧完就是一棵**焦黑的树** ✓。
//
// 另外两处适配"实心树干"的差异：
//   ① render_mode 里去掉 `cull_disabled` ✓（树干是实体 ✓ 只画正面 ✓）
//      也去掉 `ambient_light_disabled` / `fog_disabled` / `shadows_disabled` ✓
//      → 未燃烧时应与原来的 StandardMaterial3D **观感一致** ✓（正常受光 ✓）
//   ② 默认值按"替换型材质"设好 ✓：use_albedo = true / overlay_mode = false ✓
//
// 【怎么被驱动】scripts/vfx/foliage_burn.gd 会挑"材质里带 burn 参数的物体" ✓
//   （它检查 uniform 名 == "burn" ✓）→ 这个 shader 有 `burn` ✓ → 会被自动接管 ✓
// ★★★ 测试性改动（验收后按结果定稿 ✓）：**暂时去掉双面** ✗
//   树干是**闭合实体** ✓ → 双面时会画背面 → 与正面**深度冲突（镂空）** + 背面受光异常（发白）✓
//   若这次正常 → 说明"双面"就是根因 ✓ → 我会把它定成：**实体默认单面** ✓（更快 ✓ 也无冲突 ✓）
render_mode depth_draw_opaque;


uniform sampler2D noise_tex : hint_default_black;
/// 原贴图（树干用 diff 图 ✓）
// ★★★ 关键修复：**必须加 `source_color`** ✓✓（不加 → sRGB 未转线性 → 采样偏亮 → **发白** ✓）
uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform sampler2D mask_tex : hint_default_white;
uniform bool use_mask = false;
uniform int mask_channel = 3;
uniform float scissor : hint_range(0.0, 1.0) = 0.35;
uniform bool scissor_enabled = true;
uniform bool force_opaque = false;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

/// 燃烧进度 0..1（斑点扩大 ✓）—— 由控制器每帧写 ✓
uniform float burn : hint_range(0.0, 1.0) = 0.0;
/// ★ 本 shader **忽略 ash 的消失作用** ✓（仅留作兼容 ✓：控制器仍会写它 ✓）
uniform float ash : hint_range(0.0, 1.0) = 0.0;
uniform vec3 char_color : source_color = vec3(0.06, 0.05, 0.045);
uniform vec3 ember_color : source_color = vec3(1.0, 0.34, 0.05);
uniform float ember_width : hint_range(0.005, 0.5) = 0.035;
uniform float ember_gain : hint_range(0.0, 4.0) = 0.5;
uniform bool overlay_mode = false;
uniform float noise_scale : hint_range(0.1, 6.0) = 1.4;
/// 摆动幅度（米）——树干建议 0 ✓（想要"燃烧中颤动"就调到 0.02~0.05 ✓）
uniform float sway_amt : hint_range(0.0, 0.5) = 0.0;
uniform float sway_freq : hint_range(0.0, 6.0) = 1.8;
uniform float phase = 0.0;
// ★★★ 与树叶**同步摆动**（用户要求 ✓）：用**同一套风参数** ✓
//   由 `scripts/wind.gd` 每帧写入 ✓（风向 ✓ 风强 ✓ 阵风 ✓ 湍流 ✓ 角色倒伏 ✓）
//   → 树枝与树叶**相位/方向完全一致** ✓（树枝幅度更小 ✓ 见 vertex 里的 0.45 系数）
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_strength = 0.18;
uniform float wind_gust = 0.15;
uniform float wind_speed = 1.4;
uniform float wind_turbulence = 0.30;
uniform bool wind_enabled = false;
uniform float wind_height_ref : hint_range(0.01, 30.0) = 8.0;
uniform float wind_height_power : hint_range(0.5, 4.0) = 1.8;
uniform float wind_sway_scale : hint_range(0.0, 2.0) = 0.22;
uniform vec3 player_pos = vec3(0.0, -100000.0, 0.0);
uniform vec3 player_forward = vec3(0.0, 0.0, -1.0);
uniform float player_radius : hint_range(0.05, 3.0) = 0.55;
uniform float player_bend : hint_range(0.0, 2.0) = 0.75;
uniform float player_spread : hint_range(0.0, 1.5) = 0.30;
uniform float player_move : hint_range(0.0, 1.0) = 0.0;
uniform float height_ref : hint_range(0.05, 20.0) = 6.0;
uniform bool use_albedo = true;
uniform bool use_uv = true;
// ★★ 可选的法线/粗糙度 ✓ —— **有就带、没有就不带** ✓（与 tree_leaves_burn 一致 ✓）
//   默认 false ✓ → 不采样 ✓ 零额外开销 ✓；由插件转换时按源材质自动写入 ✓
uniform sampler2D normal_tex : hint_normal;
uniform bool has_normal = false;
uniform sampler2D rough_tex : hint_default_white;
uniform bool has_rough = false;

varying vec2 v_uv;
varying float v_hgt;      // ★ 距模型根部的高度（**模型空间** ✓ 稳定 ✓ 不随相机抖动 ✓）

void vertex() {
	v_uv = UV;
	v_hgt = VERTEX.y;         // ★ 模型空间高度 ✓（插值到像素 ✓ 比逐像素重建世界坐标稳定得多 ✓）
	float h = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.5);
	float alive = 1.0 - clamp(burn, 0.0, 1.0) * 0.75;
	// ★★★ 与树叶**同步**（用户要求 ✓）：用**同一套风**（阵风/沿线/湍流/高度加权 ✓）
	//   相位、方向、风速与叶子**完全一致** ✓ → 两者一起摆 ✓（不再各摆各的 ✗）
	//   树枝幅度 ×0.45 ✓（比叶子更硬 ✓ 叶子摆得最凶 ✓）；× alive（烧得越深越不摆 ✓）
	if (wind_enabled) {
		float base_y = MODEL_MATRIX[3].y;
		float hw = clamp((VERTEX.y - base_y) / max(0.001, wind_height_ref), 0.0, 1.0);
		float lev = pow(hw, wind_height_power);
		float gust = 1.0 + wind_gust * 2.2
				* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + VERTEX.x * 0.013 + VERTEX.z * 0.011));
		float amp = wind_strength * gust;
		vec2 dir = normalize(wind_direction + vec2(0.0001));
		float along = sin(TIME * wind_speed + VERTEX.x * 0.35 + VERTEX.z * 0.28) * 0.35 + 0.65;
		float across = cos(TIME * wind_speed * 0.83 + VERTEX.x * 0.23 - VERTEX.z * 0.31) * wind_turbulence;
		vec2 sway = dir * along + vec2(-dir.y, dir.x) * (across * 0.25);
		float dist = (VERTEX.y - base_y) * wind_sway_scale * amp;
		VERTEX.xz += sway * (dist * lev) * 0.45 * alive;
		// ★★★ 局部风场（龙卷风）：绕中心的切向环流，越靠中心越强
		if (tornado_strength > 0.001) {
			float t_base = MODEL_MATRIX[3].y;
			float t_h = clamp((VERTEX.y - t_base) / max(0.001, wind_height_ref), 0.0, 1.0);
			vec2 t_rel = VERTEX.xz - tornado_pos.xz;
			float t_d = length(t_rel);
			if (t_d < tornado_radius) {
				float t_k = 1.0 - t_d / max(tornado_radius, 0.001);
				t_k = t_k * t_k;
				vec2 t_out = normalize(t_rel + vec2(0.0001));
				vec2 t_tan = vec2(-t_out.y, t_out.x) * tornado_swirl;
				float t_scale = wind_height_ref * 1.40;  // ★ x2（用户要求 ✓）  // ★ 按真实高度（≈4.5m → 3.1m）✓ 去掉旧上限 ✓
		// ★★★ 物理化（用户要求：实际物理特性 + 查算法）
		//   依据：A Simulation on Grass Swaying with Dynamic Wind Force (ACM)
		//         + 对马岛之魂草地做法（Godot 实现：2Retr0/GodotGrass）
		//   ① 悬臂梁静力偏转 δ ∝ h²（均布载荷）→ 单向 ✓ 不回摆 ✗
		//      风压 = tornado_strength → 衰减时偏转同步减小；
		//      strength = 0（龙卷风停止）→ 自动回位 ✓ 即"除非龙卷风停止"
		//   ② 高频颤动：单峰权重 w(h)=(h/h0)*e^(1-h/h0)，h0=0.3
		//      → h=0.3 峰值（用户要的 30% 最抖）/ h=0 为 0（根部渐弱 ✓）
		float t_w30 = (t_h / 0.3) * exp(1.0 - t_h / 0.3);
		float t_flut = sin(TIME * 24.0 + VERTEX.x * 7.0 + VERTEX.z * 5.0);
		vec2 t_loc = t_tan * 0.9 - t_out * 0.15;
		VERTEX.xz += t_loc * (tornado_strength * t_k * t_scale * t_h * t_h);
		VERTEX.xz += t_tan * (tornado_strength * t_k * t_scale * 0.15 * t_flut * t_w30);
			}
		}
	}
	// ★ 这里**没有** `VERTEX *= 1.0 - ash * 0.35` ✓ —— 烧完不收缩 ✓（与 burn_foliage 的关键区别 ✓）
}

void fragment() {
	// ★ 有法线/粗糙度就采样 ✓（没有就用默认值 ✓ 不白花两次采样 ✓）
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, v_uv).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
	// ★ 没有粗糙度贴图时用 **1.0（全哑光）** ✓ —— 与原来的 StandardMaterial3D 默认一致 ✓
	//   （原来我写 0.75 ✗ → 更反光 → 树干观感偏亮/发白 ✓ 用户反馈 ✓）
	ROUGHNESS = 1.0;
	if (has_rough) {
		ROUGHNESS = texture(rough_tex, v_uv).r;
	}
	METALLIC = 0.0;
	// ★★★ 关键修复：**双面渲染时背面必须翻转法线** ✓✓
	//   本 shader 是 `cull_disabled`（双面 ✓ 因为源材质 cull_mode=2 ✓）→ 背面也被绘制 ✓
	//   若不翻法线 ✗：背面法线朝外 → 被光照打亮成**白色** ✓ + 与正面深度冲突 → **镂空** ✓✓
	//   （原生 StandardMaterial3D 在双面时会自动处理 ✓ 所以它一直正常 ✓；自定义 shader 必须自己做 ✗）
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// ★ 世界坐标哈希噪声 ✓ —— **不依赖噪声贴图** ✗
	//   （材质没设 noise_tex 时它默认全黑 ✗ → thr=1 且 n=0 → burn=0 也全判为"已烧" ✗ → 一进场就焦黑 ✓）
	// ★★★ 噪声改用 **UV** ✓（修复"燃烧时闪烁"✗）：
	//   原来用世界坐标哈希 `fract(sin(dot(wp…))*43758)` ✗ —— 它对坐标的**极小变化**极其敏感 ✓
	//   相机稍微一动 / 浮点误差 → 整片图案**每帧重新随机** → **闪烁** ✓✓（用户实测 ✓）
	//   UV 是模型自带数据 ✓ 不随相机变化 ✓ → 同一位置永远同一个值 ✓ 稳定不闪 ✓✓
	float n = fract(sin(dot(v_uv * noise_scale, vec2(12.9898, 78.233))) * 43758.5453);

	// ★★ 关键修复（实测推理 ✓）：**不再看 `use_albedo`** ✓，无条件采样 ✓
	//   证据链：① `base_color=红` → 树干变红 ✓（shader 在跑 ✓）
	//          ② 探针直接 `texture(albedo_tex, v_uv)` → 树干正常树皮 + UV 渐变 ✓（贴图能采 ✓）
	//          ③ 但 `ALBEDO=col` 时**纯白** ✗ ⇒ 说明 `if (use_albedo)` 没进 ✗
	//   ⇒ 运行时 `use_albedo` 实际为 false ✗（材质里写着 true ✗ = 参数被某处覆盖 ✓）
	//   → 无条件采样 ✓ 彻底绕开 ✓（燃烧只影响颜色混合 ✓ 不需要这个开关 ✓）
	vec4 base = base_color * texture(albedo_tex, v_uv);

	// ① ★★★ 从下往上"蔓延"（用户要求 ✓ 慢速 ✓）
	//   前沿高度 = `burn × height_ref` 米 ✓ 从**模型根部**（MODEL_MATRIX 原点 ✓）往上爬 ✓
	//   旧写法是"噪声阈值扫描"✗ → 阈值一越过噪声分布就**整片同时变黑** ✗（用户反馈 ✓）
	//   边缘用 UV 噪声做 ±0.45 米的不规则 ✓（稳定 ✓ 不闪 ✓）
	//   ★ 前沿 ×1.15：保证 `burn = 1` 时前沿**越过树顶** ✓
	//     （否则会停在 height_ref 高度 ✗ → 树冠卡在"半烧"状态 → 余烬最亮 → **整片橙红** ✗✓ 用户实测 ✓）
	float front_h = clamp(burn, 0.0, 1.0) * height_ref * 1.15 + (n - 0.5) * 0.9;
	float hgt = v_hgt;                        // ★ 用模型空间高度 ✓（原来的 wp.y 会随相机抖动 → 闪烁 ✗✓）
	float burned = 0.0;
	if (burn > 0.001) {
		burned = 1.0 - smoothstep(front_h - 0.45, front_h + 0.15, hgt);
		// 已烧区域内部保留一点斑点质感 ✓（用同一低频噪声 ✓ 不抖 ✓）
		burned = clamp(burned * (0.85 + 0.15 * n), 0.0, 1.0);
	}

	// ② 焦黑 + 前沿余烬（一致 ✓）
	vec3 col = mix(base.rgb, char_color, burned);
	// ★★★ 余烬改为**平滑前沿带** ✓（修复"燃烧时闪烁"✗）
	//   旧写法 `exp(-(n-thr)²/w²)` ✗：在**逐像素高频噪声**上开一条**极窄**的亮缝 ✓
	//     → burn 每推进一点就扫过一批像素 → 逐帧乱跳 = **闪烁** ✓✓（实测 ember_gain=0 即不闪 ✓）
	//   新写法 `4·burned·(1-burned)` ✓：纯 `burned` 的平滑函数 ✓ 前沿在哪亮在哪 ✓ 永不抖 ✓✓
	// ★★★ 烧到最后**必须熄灭** ✓（修复"烧完由黑变红"✗）
	//   旧写法余烬峰值在 burned=0.5 的过渡带 ✓ → burn 停在 1 时仍有部位处于过渡带 → **整片橙红** ✓✓
	//   现在乘 `(1 - burn)` ✓：前沿越接近树顶余烬越弱 ✓ `burn = 1` 时**完全熄灭** ✓ → **纯焦黑** ✓✓
	float ember = 4.0 * burned * (1.0 - burned);
	ember *= ember_gain * (1.0 - ash) * 1.5 * (1.0 - clamp(burn, 0.0, 1.0));
	col += ember_color * ember;

	// ③ ★ 烧到底也只是"更黑的焦炭" ✓ —— **不淡出、不消失** ✗（与 burn_foliage 的关键区别 ✓）
	col = mix(col, vec3(0.03, 0.03, 0.03), clamp(ash, 0.0, 1.0) * 0.6);
	float a = base.a;                                  // ★ 不再乘 (1 - ash) ✓

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
		if (scissor_enabled && shape < scissor) {
			discard;
		}
	}

	if (overlay_mode) {
		ALBEDO = mix(char_color, ember_color, clamp(ember, 0.0, 1.0));
		ALPHA = clamp(burned * 0.92 + ember * 0.55, 0.0, 1.0) * shape;   // ★ 不随 ash 淡出 ✓
	} else {
		ALBEDO = col;
		ALPHA = 1.0;
	}
}
