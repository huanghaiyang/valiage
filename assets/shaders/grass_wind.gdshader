shader_type spatial;
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
}