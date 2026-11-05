// ============================================================================
// star_dome.gdshader —— 夜间星空穹顶（day_night_cycle.gd 的 StarDome 节点）
// ============================================================================
// · 一个跟随相机的半球（半径 1000m < 相机 far=1200），被相机"从内部"观看，
//   因此必须 cull_disabled；片元里用视线方向做立方体投影 + 哈希网格撒星点。
// · 只在夜里可见：stars_alpha 由 day_night_cycle.gd 每帧按太阳仰角与云量写入。
// · 用 blend_add（加法混合）叠在天空上；fog_disabled 让它不被体积雾染色。
// · 星星位置是纯哈希、不含随机种子 —— 同一片夜空每次启动都一样，不会"星星乱跑"。
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

// 整体可见度（0=无星，1=满天星）。由脚本按夜晚程度 × 云量衰减写入。
uniform float stars_alpha : hint_range(0.0, 1.0) = 0.0;
uniform vec3 star_color : source_color = vec3(0.86, 0.92, 1.0);
// 网格密度：约等于"一条棱上切多少格"。70 在 60° FOV 下每颗星约 2~3 像素。
uniform float density : hint_range(20.0, 200.0) = 70.0;
// 每格出现星星的概率（0..1）。0.045 ≈ 上千颗，符合"稀疏但有层次"的夜空。
uniform float star_probability : hint_range(0.0, 0.2) = 0.045;

varying vec3 v_dir;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	// 相机在球心内部，归一化的局部顶点坐标就是视线方向。
	v_dir = normalize(VERTEX);
}

void fragment() {
	vec3 d = normalize(v_dir);
	// 地平线以下不画星（半球本来也很少覆盖到，这里再保险一点）。
	if (d.y < -0.08) {
		discard;
	}

	// 立方体投影：把方向映射到 [-1,1]^2，避免球面 UV 在极点处的挤压。
	vec3 ad = abs(d);
	vec2 uv;
	if (ad.y >= max(ad.x, ad.z)) {
		uv = d.xz / ad.y;
	} else if (ad.x >= ad.z) {
		uv = d.yz / ad.x;
	} else {
		uv = d.xy / ad.z;
	}

	vec2 cell = uv * density;
	vec2 id = floor(cell);
	vec2 local = fract(cell) - 0.5;

	float r = hash21(id);
	if (r < 1.0 - star_probability) {
		discard;
	}
	// 在格子内随机偏移星点位置，避免所有星星都落在格子中心形成规则网格。
	vec2 offset = vec2(hash21(id + 3.1), hash21(id + 7.9)) - 0.5;
	offset *= 0.55;
	float dist = length(local - offset);
	float star = 1.0 - smoothstep(0.0, 0.22, dist);

	// 每颗星有自己的亮度与闪烁相位（TWI 由 TIME 驱动力度很轻，避免"迪斯科星空"）。
	float r2 = hash21(id + 19.7);
	float twinkle = 0.72 + 0.28 * sin(TIME * 1.4 + r2 * 47.0);
	// 接近地平线时淡出：低空的星光被大气/雾吃掉。
	float horizon = smoothstep(-0.05, 0.25, d.y);

	float bright = star * twinkle * horizon * stars_alpha;
	ALBEDO = star_color * (0.65 + 0.7 * r2) * bright;
	ALPHA = bright;
}
