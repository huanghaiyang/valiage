shader_type spatial;
// ★★★ 局部风场（进阶需求 ✓）：由 scripts/spells/blue_tornado.gd 每帧广播 ✓
global uniform vec3 tornado_pos;         // 龙卷风中心（世界坐标 ✓）
global uniform float tornado_radius;     // 影响半径（米 ✓）
global uniform float tornado_strength;   // 局部风速强度（0 = 无 ✓）
global uniform float tornado_swirl;      // 环流方向：+1 逆时针 / -1 顺时针 ✓
// 带 alpha 遮罩 + 风动 + 角色倒伏 的草材质。
//
// ★★ 两个关键决定，都是为了"实例被随机旋转后方向依然正确" ★★
//
// 1) render_mode 里有 **world_vertex_coords**：
//    这样 VERTEX 直接就是**世界坐标**，风/推力的方向向量（世界空间）可以直接相加。
//    否则 VERTEX 是模型局部坐标，把世界方向加进去会被实例自身的旋转**再转一次** ——
//    表现就是"每株草朝自己随机的方向前后乱摆"（World Brush 默认会随机 Y 旋转）。
//    SimpleGrassTextured 的着色器也是这么写的（world_vertex_coords），项目里已验证可用。
//
// 2) 风参数用**逐材质 uniform**，不能用 global uniform：
//    见 scripts/world/weather.gd L191-194 与 assets/shaders/vegetation_wind.gdshader L14 ——
//    Godot 4.7 运行时下全局着色器参数是坏的（顶点阶段永远拿 project.godot 的默认值）。
//
// 它住在 assets/shaders/（运行时资产，和 vegetation_wind.gdshader 一个地方），
// 不属于导出插件 —— 否则禁用/删除插件会让所有草的材质失效。
// uniform 名字与 vegetation_wind.gdshader 一致（wind_*），由 scripts/wind.gd 每帧写入。
render_mode cull_disabled, depth_prepass_alpha, world_vertex_coords;

// ---- 天气系统会驱动的这 5 个 ----
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_strength = 0.18;
uniform float wind_gust = 0.15;
uniform float wind_speed = 1.4;
uniform float wind_turbulence = 0.30;

// ---- 草自己的 ----
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D alpha_tex : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic;
uniform bool has_normal = true;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
// 风默认关闭：由导出面板顶部栏的「初始化风参数」决定要不要写进材质。
uniform bool wind_enabled = false;
uniform float wind_height_ref : hint_range(0.01, 3.0) = 0.16;   // 到这个高度摆幅最大
uniform float wind_height_power : hint_range(0.5, 4.0) = 1.8;
uniform float wind_sway_scale : hint_range(0.0, 1.0) = 0.22;    // 每米高度的摆幅系数

// ---- 角色倒伏（世界坐标，由 scripts/wind.gd 每帧写）----
uniform vec3 player_pos = vec3(0.0, -100000.0, 0.0);
uniform vec3 player_forward = vec3(0.0, 0.0, -1.0);
uniform float player_radius : hint_range(0.05, 3.0) = 0.55;
uniform float player_bend : hint_range(0.0, 2.0) = 0.75;
uniform float player_spread : hint_range(0.0, 1.5) = 0.30;      // 左右分开力度
uniform float player_move : hint_range(0.0, 1.0) = 0.0;         // 移动量：站着 = 0 -> 草回弹

// ---- 燃烧（本项目新增；语义与 vegetation_wind.gdshader 一致）----
// ★ 为什么做进**这个着色器**而不是在外面叠一层：消失要用 **scale**，
//   而叠加层只是多画一遍，动不了原几何体（用户要求 bermuda 草也用 scale 消失）。
//   默认 burn = 0 -> 输出与改动前完全一致。
uniform float burn : hint_range(0.0, 1.0) = 0.0;     // 0..1 烧蚀进度（斑点扩大）
uniform float ash : hint_range(0.0, 1.0) = 0.0;      // 0..1 消失进度（驱动 scale）
uniform vec3 char_color : source_color = vec3(0.07, 0.06, 0.05);
uniform vec3 ember_color : source_color = vec3(1.0, 0.32, 0.05);
uniform float burn_ember : hint_range(0.0, 2.0) = 0.45;
uniform float burn_phase = 0.0;                       // 每株随机，避免斑点位置雷同
varying float v_burn_amt;
varying float v_burn_ember;

void vertex() {
	// world_vertex_coords 下 VERTEX 是世界坐标；实例自己的世界原点在 MODEL_MATRIX[3]。
	// 用它算"离地高度" -> 根部不动、越高越摆（不受实例旋转影响）。
	float base_y = MODEL_MATRIX[3].y;
	float h = clamp((VERTEX.y - base_y) / max(0.001, wind_height_ref), 0.0, 1.0);
	float lev = pow(h, wind_height_power);

	if (wind_enabled) {
		// 世界坐标做相位 -> 空间连续（同一阵风扫过整片，而不是每株各摆各的）
		float gust = 1.0 + wind_gust * 2.2
			* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + VERTEX.x * 0.013 + VERTEX.z * 0.011));
		float amp = wind_strength * gust;
		vec2 dir = normalize(wind_direction + vec2(0.0001));
		float along = sin(TIME * wind_speed + VERTEX.x * 0.35 + VERTEX.z * 0.28) * 0.35 + 0.65;
		float across = cos(TIME * wind_speed * 0.83 + VERTEX.x * 0.23 - VERTEX.z * 0.31) * wind_turbulence;
		// 主方向 + 很小的侧向扰动（侧向系数压小，避免"乱晃"观感）
		vec2 sway = dir * along + vec2(-dir.y, dir.x) * (across * 0.25);
		float dist = (VERTEX.y - base_y) * wind_sway_scale * amp;
		VERTEX.xz += sway * (dist * lev);
		// ★★★ 局部风场（龙卷风 ✓ 进阶需求）：绕中心的切向环流 ✓ 越靠中心越强 ✓
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
		// ★★ 收敛幅度（用户反馈"太难看了"✗）：位移改用**植被自身尺度** ✓
		//   原来 ≈ 3~4 米 → 把整片草按平 ✗；现在 草≈0.1 米 / 树顶≈0.5 米 ✓
		float t_scale = min(wind_height_ref, 1.5) * 1.2;   // ★ 只做"强倾斜" ✓ 不按平 ✗
		float t_swing = sin(TIME * 3.0);              // ★ 正负交替 = 来回"卷" ✓
		vec2 t_loc = t_tan * t_swing - t_out * 0.15;
		VERTEX.xz += t_loc * (tornado_strength * t_k * t_scale * t_h);
			}
		}
	}

	// 角色倒伏：**全部在世界空间算** -> 实例怎么旋转都不会把方向带歪
	if (player_move > 0.001) {
		vec2 rel = VERTEX.xz - player_pos.xz;
		float dd = length(rel);
		float infl = 1.0 - clamp(dd / max(0.01, player_radius), 0.0, 1.0);
		infl = infl * infl * (3.0 - 2.0 * infl) * clamp(player_move, 0.0, 1.0);
		if (infl > 0.001) {
			vec2 fw = normalize(player_forward.xz + vec2(0.0001));
			vec2 rt = vec2(-fw.y, fw.x);              // 玩家的右手方向
			float along2 = dot(rel, fw);              // >0 = 在身前
			float side = dot(rel, rt);                // 正/负 = 在右/左侧
			float front = smoothstep(-0.35, 0.45, along2);
			float dirsign = 1.0;
			if (side < 0.0) { dirsign = -1.0; }
			vec2 push = rt * (dirsign * player_spread) - fw * (0.10 * front);
			VERTEX.xz += push * (infl * h * (0.35 + 0.65 * front));
			VERTEX.y -= infl * h * player_bend * (0.40 + 0.60 * front);
		}
	}

	// ★ 燃烧：世界坐标噪声决定斑点（同一株上位置固定、不同株不雷同），
	//   阈值就是 burn：bn < burn 的区域被烧掉 -> 焦黑面积随 burn **单调增加**。
	float bn = fract(sin(dot(VERTEX.xz + vec2(VERTEX.y), vec2(12.9898, 78.233))
			+ burn_phase) * 43758.5453);
	if (burn > 0.001) {
		v_burn_amt = 1.0 - smoothstep(burn - 0.02, burn + 0.02, bn);
		v_burn_ember = exp(-pow((bn - burn) / 0.05, 2.0)) * burn_ember * (1.0 - ash);
	} else {
		// 长回阶段（burn=0）：正常的绿草在长大，不能还带焦黑/火光
		v_burn_amt = 0.0;
		v_burn_ember = 0.0;
	}

	// ★ 消失/长回用**缩放**，枢轴 = 该网格的根。
	//   world_vertex_coords 下 VERTEX 已是世界坐标，网格原点就是 MODEL_MATRIX[3]
	//   （上面的 base_y 也是这么取的），所以绕它缩才是"从自己的根缩下去"。
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
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
	ROUGHNESS = texture(rough_tex, UV).r;
	METALLIC = 0.0;

	// ★ 燃烧：烧焦变黑 + 余烬；完全缩没后丢弃（避免留一个点）
	if (v_burn_amt > 0.001) {
		ALBEDO = mix(ALBEDO, char_color, v_burn_amt);
		ALBEDO += ember_color * v_burn_ember;
	}
	if (ash > 0.999) {
		discard;
	}
}
