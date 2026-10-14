// ============================================================================
// fog_beam_glow.gdshader —— **实体亮线**：沿光束拉伸、绕光轴面向相机的加法混合条带
// ============================================================================
// 【为什么需要它】体积散射（FogField 里按"采样点到线段距离"累积）给的是**光晕**：
//   雾浓处亮、雾薄处暗，是"光把烟点亮"。但激光本身那条**线**必须由实体几何来画，
//   否则雾一薄、光束就散了。两者叠加才等于参考画面里的"红线穿过烟"。
//
// 【为什么不用 CylinderMesh / BoxMesh】
//   圆柱只有"从侧面看"才是一根线；相机转到与光束接近平行时会退化成一个圆点/一条边。
//   这条条带在**顶点阶段**绕光轴朝向相机，因此任意视角下线宽都一致。
//
// 【怎么做到"忽略节点变换"】
//   四边形的位置/朝向全在这里由 uniform（世界空间 start/end/radius）算出来，
//   所以 MeshInstance3D 必须保持**单位变换**（FogBeam 里设 top_level + 单位变换）。
//   同时必须给它 custom_aabb：引擎看不到着色器造出来的几何，不设就会被视锥剔除
//   （表现：转个视角整条亮线突然消失）。
//
// 【已知的坑】
//   1. 视线与光束几乎平行时 cross(axis, to_cam) 退化 ⇒ 必须换参考轴，
//      否则得到 NaN，表现为整条光束闪烁/消失。
//   2. noise_tex 不赋值时 Godot 会绑成白图（grain=1），所以 noise_strength 默认 0，
//      需要颗粒感时再把噪声纹理绑上并把强度调起来。
//   3. 与体积散射共用 radius_m，但视觉宽度由 width_scale 单独控制：
//      散射半径要略大于视觉线宽，才有"线的外面裹着一层光晕"的层次。
// ============================================================================

shader_type spatial;
// 加法混合（发光体）＋ 不写深度（不遮挡后面）＋ 不受光/不受雾影响
render_mode blend_add, cull_disabled, unshaded, depth_draw_never, shadows_disabled, fog_disabled;

/** 光束起点（世界坐标） */
uniform vec3 beam_start;
/** 光束终点（世界坐标） */
uniform vec3 beam_end;
/** 散射半径（米）——同时也是条带的基础半宽 */
uniform float beam_radius = 0.8;
uniform vec3 beam_color : source_color = vec3(1.0, 0.10, 0.05);
/** 亮线强度 */
uniform float beam_intensity = 2.5;
/** 视觉半宽相对 beam_radius 的倍率：<1 更细更像激光，>1 更像泛光 */
uniform float width_scale : hint_range(0.05, 8.0) = 0.4;
/** 亮核相对半宽的占比（越小核心越细） */
uniform float core_ratio : hint_range(0.02, 1.0) = 0.25;
/** 光晕衰减指数：越大越"收拢" */
uniform float glow_power : hint_range(0.5, 8.0) = 2.2;
/** 沿途颗粒感强度（需要 noise_tex 已赋值；不赋值时请保持 0） */
uniform float noise_strength : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform float noise_scale : hint_range(0.1, 40.0) = 8.0;
uniform float noise_scroll : hint_range(-4.0, 4.0) = 0.6;

// ==================== 被雾吸收（"埋进雾里"） ====================
// ★ 加法混合只能"加光"，浓雾处要变暗就必须**乘透过率**（Beer–Lambert）：
//   线经过浓烟的部分被压暗，于是看起来是"埋进雾里"而不是浮在画面前面。
uniform sampler2D fog_density_tex : filter_linear, repeat_disable;
uniform vec2 fog_domain_size = vec2(80.0, 80.0);
uniform vec2 fog_domain_center = vec2(0.0, 0.0);
/** 吸收系数：越大，浓雾处的线被压得越暗 */
uniform float fog_absorption : hint_range(0.0, 12.0) = 3.0;
/** 0 = 不做吸收（编辑器里没有密度纹理时用） */
uniform float fog_enabled : hint_range(0.0, 1.0) = 0.0;
/** 顶点阶段算出的世界坐标，供片元做雾采样 */
varying vec3 beam_world_pos;

void vertex() {
	vec3 axis_vector = beam_end - beam_start;
	float beam_length = max(length(axis_vector), 1.0e-3);
	vec3 axis = axis_vector / beam_length;
	vec3 middle = mix(beam_start, beam_end, 0.5);

	// ★ 绕光轴朝向相机：right = axis × (相机 - 光束中点)
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - middle);
	vec3 right = cross(axis, to_camera);
	// 视线与光束接近平行 ⇒ cross 退化，必须换参考轴，否则 NaN（整条闪烁/消失）
	if (length(right) < 1.0e-3) {
		right = cross(axis, vec3(0.0, 1.0, 0.0));
		if (length(right) < 1.0e-3) {
			right = cross(axis, vec3(1.0, 0.0, 0.0));
		}
	}
	right = normalize(right);

	float half_width = max(beam_radius * width_scale, 0.01);
	// 单位四边形：VERTEX.x ∈ [-0.5, 0.5] -> 宽度；VERTEX.y -> 沿光束方向
	vec3 world = middle
		+ right * (VERTEX.x * 2.0 * half_width)
		+ axis * (VERTEX.y * beam_length);
	// 直接写裁剪空间坐标（节点保持单位变换，故 world 即最终位置）
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	beam_world_pos = world;     // 传给片元做雾吸收采样（VERTEX 是原始单位四边形，不能用）
}

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float profile = clamp(1.0 - across, 0.0, 1.0);
	// 细亮核 + 柔光晕：核心用高次幂收得很细，光晕用低次幂铺开
	float core = pow(profile, 1.0 / max(core_ratio, 0.02));
	float halo = pow(profile, glow_power);
	// 两端淡出，避免"硬切"的端面
	float ends = smoothstep(0.0, 0.06, UV.y) * (1.0 - smoothstep(0.94, 1.0, UV.y));
	// 沿途颗粒：沿光束方向滚动，让光斑有流动感而不是一根塑料棒
	float grain = texture(noise_tex, vec2(UV.y * noise_scale + TIME * noise_scroll, 0.5)).r;
	float density = mix(1.0, grain * 1.5, noise_strength);

	float energy = (core * 1.2 + halo * 0.8) * ends * density;
	// ★ 被雾吸收：按当前片元所处的雾密度做 Beer–Lambert 透过率。
	//   加法混合下"乘 <1 的透过率"就等于把这条线压暗 ⇒ 浓雾处的线自然埋进去。
	if (fog_enabled > 0.5) {
		vec2 fog_uv = (beam_world_pos.xz - fog_domain_center)
			/ max(fog_domain_size, vec2(1.0)) + vec2(0.5);
		if (fog_uv.x > 0.0 && fog_uv.x < 1.0 && fog_uv.y > 0.0 && fog_uv.y < 1.0) {
			float fog_density = texture(fog_density_tex, fog_uv).r;
			energy *= exp(-fog_density * fog_absorption);
		}
	}
	ALBEDO = beam_color * beam_intensity * energy;
	ALPHA = clamp(energy, 0.0, 1.0);
}
