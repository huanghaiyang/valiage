shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

// ============================================================
// 天空穹顶云层（低多边形）
// ============================================================
// 几何：包住相机的半球。为什么不用一张平面：
//   相机俯角约 -0.16 rad（地平线落在画面偏下），天地平线只到约 35 度仰角。
//   一张 y=340m 的平面要出现在画面里需要水平距离 >= 340/tan(35) ~= 485m，
//   永远落在山脊之后 —— 地面相机根本看不到。穹顶则铺在抬头能看到的天空上。
//   半径必须 < 相机远裁剪面（main.tscn 的 Camera3D.far = 1200），否则整个穹顶被裁掉。
//
// 云图：直接对半球方向做 **3D 噪声**。
//   两种 2D 投影都试过，都不行：
//     - d.xz / d.y（海拔投影）：天顶退化，天空被拉成放射状条纹
//     - d.xz（平面投影）：地平线附近纵向无限拉伸，出现竖条带状伪影
//   3D 噪声没有极点也没有接缝，云块在球面上各向同性。
//
// alpha：用视线仰角控制 —— 抬头方向满不透明，接近地平线淡出，不会出现云墙。
// ============================================================

uniform float coverage : hint_range(0.0, 1.05) = 0.35; // 云量：0 晴空，>1 阴云密布
uniform float density : hint_range(0.0, 1.0) = 0.90;   // 不透明度上限
uniform vec2 wind_dir = vec2(1.0, 0.0);                // 水平风向
uniform float wind_speed = 1.0;                        // 漂移速度
uniform float cloud_scale = 2.4;                       // 云块尺度
uniform float horizon_start = 0.03;                    // 仰角淡出起点
uniform float horizon_end = 0.42;                      // 仰角淡出终点
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.985, 0.95);
uniform vec3 cloud_shadow : source_color = vec3(0.60, 0.645, 0.72);

varying vec3 v_dir;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += vnoise3(p) * amp;
		p *= 2.07;
		amp *= 0.5;
	}
	return v;
}

void vertex() {
	v_dir = VERTEX;
}

void fragment() {
	vec3 d = normalize(v_dir);
	vec3 p = d * cloud_scale;
	p.xz += wind_dir * TIME * wind_speed * 0.02;
	float n = fbm3(p);
	float t = smoothstep(1.05 - coverage, 1.35 - coverage, n * 1.35);
	float thick = smoothstep(0.30, 0.90, n);
	vec3 col = mix(cloud_shadow, cloud_lit, thick);
	float band = smoothstep(horizon_start, horizon_end, d.y);
	ALBEDO = col;
	ALPHA = t * density * band;
}
