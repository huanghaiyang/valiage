shader_type spatial;
// 带 alpha 遮罩 + 风动的草材质。
//
// ★★ 风参数用**逐材质 uniform**，绝对不能用 global uniform ★★
// 见 scripts/world/weather.gd L191-194 与 assets/shaders/vegetation_wind.gdshader L14：
// Godot 4.7 运行时下全局着色器参数是坏的（顶点阶段永远拿 project.godot 的默认值），
// 只有直接写材质 uniform 才真正生效。
//
// uniform 名字与 assets/shaders/vegetation_wind.gdshader **完全一致**，
// 于是天气系统 Weather 的同一段代码就能同时驱动植被和这里的草。
render_mode cull_disabled, depth_prepass_alpha;

// ---- 天气系统会写的这 5 个（名字/含义与 vegetation_wind.gdshader 一致）----
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
// 风默认**关闭**：由导出面板的「初始化风参数」决定要不要把风参数写进材质。
// GLSL 必须有声明，但默认值是关的 -> 不写就是没风。
uniform bool wind_enabled = false;
uniform float wind_height_ref : hint_range(0.01, 3.0) = 0.16;
uniform float wind_height_power : hint_range(0.5, 4.0) = 1.8;
uniform float wind_sway_scale : hint_range(0.0, 1.0) = 0.22;

// ---- 角色踩踏交互（由 Wind 每帧写玩家位置）----
// 默认把玩家点放到极远处 -> 等于没有交互
uniform vec3 player_pos = vec3(0.0, -100000.0, 0.0);
uniform float player_radius : hint_range(0.05, 3.0) = 0.55;
uniform float player_bend : hint_range(0.0, 2.0) = 0.75;

void vertex() {
	if (wind_enabled) {
		vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float h = clamp(VERTEX.y / max(0.001, wind_height_ref), 0.0, 1.0);
		float lev = pow(h, wind_height_power);
		float gust = 1.0 + wind_gust * 2.2
			* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + wpos.x * 0.013 + wpos.z * 0.011));
		float amp = wind_strength * gust;
		vec2 dir = normalize(wind_direction + vec2(0.0001));
		float along = sin(TIME * wind_speed + wpos.x * 0.35 + wpos.z * 0.28) * 0.35 + 0.65;
		float across = cos(TIME * wind_speed * 0.83 + wpos.x * 0.23 - wpos.z * 0.31) * wind_turbulence;
		vec2 sway = dir * along + vec2(-dir.y, dir.x) * across * 0.35;
		float dist = VERTEX.y * wind_sway_scale * amp;
		VERTEX.x += sway.x * dist * lev;
		VERTEX.z += sway.y * dist * lev;
	}

	// 角色踩踏：靠近玩家的草被压弯（根部不动，越靠上压得越狠）
	{
		vec3 ppos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float hb = clamp(VERTEX.y / max(0.001, wind_height_ref), 0.0, 1.0);
		float dd = distance(ppos.xz, player_pos.xz);
		float infl = 1.0 - clamp(dd / max(0.01, player_radius), 0.0, 1.0);
		infl = infl * infl * (3.0 - 2.0 * infl);
		if (infl > 0.001) {
			vec2 away = normalize(ppos.xz - player_pos.xz + vec2(0.0001));
			VERTEX.xz += away * (infl * player_bend * hb);
			VERTEX.y -= infl * player_bend * hb * 0.6;
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