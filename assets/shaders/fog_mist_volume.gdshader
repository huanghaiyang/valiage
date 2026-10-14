// ============================================================================
// fog_mist_volume.gdshader —— 体积雾：光线步进 + **三维细节** + **单次散射光照**
// ============================================================================
// 【相对上一版的根本差别】上一版把 2D 浓度场沿高度"挤出"成一层雾，靠高度剖面
//   假装体积 —— 低角度/侧看就是一张片（用户反馈"像贴图"）。这一版做了三件事：
//     ① 三维细节：步进时在世界坐标采样一张 3D 噪声（detail_tex），并按风向/时间滚动，
//        于是同一处水平浓度在不同高度有不同形状 —— 真的会翻涌、有层次；
//     ② **体积光照（丁达尔/光轴）**：每个步进点朝太阳方向再走 light_steps 步，
//        累积光学厚度得到透过率 T = exp(-absorption·τ)，乘进散射贡献。雾浓的地方
//        自己挡自己 ⇒ 出现光束、明暗分层（这是 HDRP 体积雾最"值钱"的那一项）；
//     ③ 相函数（Henyey–Greenstein）：朝太阳看时更亮（前向散射），背光看时更暗 —— 雾
//        因此有"银边"，而不是一团均匀的灰。
//
// 【性能】每个像素的成本 ≈ march_steps × (1 + light_steps) 次纹理采样。默认
//   march_steps=8、light_steps=3 ⇒ 32 次采样，1080p 下对现代 GPU 很轻。
//   质量档位由 FogField.apply_quality() 统一调（steps / light_steps 一起降）。
//
// 【为什么散射是"单次 + 自遮挡"而不是真阴影】真阴影要采样方向光的 shadow map，
//   在 Godot 的自定义体积材质里拿不到稳定的接口；而"沿光方向累积自身浓度"这一项
//   已经能给出光轴与分层明暗，且不依赖光类型（平行光/点光都能用）。这是实时体积雾
//   的常规近似（single scattering + self shadowing）。
//
// 【参数含义】
//   height_power     竖向衰减指数：越大雾越贴地（1.0 线性、2~3 是"地面晨雾"）
//   edge_fade        水平边缘淡出比例（0.1 = 四周各 10% 宽度渐隐，避免看到盒子边界）
//   wisp_amount      二维絮状扰动（大尺度"一团一团"层次）
//   detail_strength  三维细节强度（小尺度翻涌；0 = 退回上一版观感）
//   scatter_strength 散射强度（太阳在雾里的亮度）
//   absorption       自遮挡强度（越大光轴越锐利、暗处越暗）
//   hg_anisotropy    前向散射各向异性（0 = 各向同性，0.6~0.8 = 明显的逆光银边）
// ============================================================================

shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

/** 合成后的雾浓度场（R 通道），由 fog_ns_solver.gd 的链尾提供。
 *  这里要 filter_linear：96 格的场铺到 80 米见方，最近邻会看到明显格子。 */
uniform sampler2D density_tex : filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture;
/** 三维细节噪声（由 FogField 用 FastNoiseLite 生成的小 3D 纹理）。
 *  未设置时 Godot 会绑一张默认白图 ⇒ detail = 1，退化成"只有二维层次"。 */
uniform sampler3D detail_tex : filter_linear, repeat_enable;

uniform vec3 mist_color_lit : source_color = vec3(0.86, 0.89, 0.94);
uniform vec3 mist_color_shadow : source_color = vec3(0.62, 0.68, 0.78);
uniform float opacity : hint_range(0.0, 4.0) = 1.1;
uniform float density_gain : hint_range(0.0, 8.0) = 2.4;
uniform float height_power : hint_range(0.2, 6.0) = 1.6;
uniform float edge_fade : hint_range(0.0, 0.5) = 0.14;
uniform float depth_fade : hint_range(0.01, 20.0) = 2.0;
uniform float camera_fade : hint_range(0.0, 40.0) = 3.0;
uniform float wisp_amount : hint_range(0.0, 1.0) = 0.35;
uniform float wisp_scale : hint_range(0.0, 2.0) = 0.12;
uniform float wisp_speed : hint_range(0.0, 2.0) = 0.25;

/** 域中心（世界 XZ；y = 盒子底面高度） */
uniform vec3 domain_center = vec3(0.0);
uniform vec2 domain_size = vec2(80.0, 80.0);
uniform float box_height : hint_range(0.5, 200.0) = 14.0;
/** 步进次数：4~8 足够（再多画面几乎不变，只是更贵） */
uniform int march_steps : hint_range(1, 32) = 6;

// ==================== 三维细节 ====================
/** 细节纹理的世界采样频率（1/米）。0.05 ≈ 每 20 米一个噪声团 */
uniform float detail_scale : hint_range(0.0, 0.5) = 0.055;
/** 细节强度：0 = 关闭三维翻涌（退回平面观感），1 = 强烈 */
uniform float detail_strength : hint_range(0.0, 1.0) = 0.65;
/** 细节自身的滚动速度（让雾"活"起来；与风解耦，避免风停后完全静止） */
uniform float detail_speed : hint_range(0.0, 2.0) = 0.06;
/** 细节随风的漂移量：让噪声跟着风走，而不是原地抖动 */
uniform vec2 detail_flow = vec2(0.0);

/** ★ **垂直剪切**：采样浓度场时给 UV 加上"随高度线性偏移"的量。
 *  这是把"一层 2D 场"变成"看起来有体积"的最省成本的手段：不同高度看到的横向
 *  图案不同（像被风剪切的层积云），于是侧看不再是同一张图被拉高。
 *  取值 0 = 退回平面观感；0.2~0.5 比较自然；太大(<1)会出现明显的斜条纹。 */
uniform float vertical_shear : hint_range(0.0, 1.0) = 0.32;
/** 剪切方向（世界 XZ）。FogField 会把它设成风向；默认给个斜向 */
uniform vec2 shear_direction = vec2(1.0, 0.35);

// ==================== 体积光照 ====================
/** 太阳方向：**光线传播方向**（从太阳指向地面），由 FogField 从平行光取负 Z 轴 */
uniform vec3 sun_direction = vec3(0.3, -1.0, 0.2);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.88);
/** 散射强度（太阳在雾里的亮度） */
uniform float scatter_strength : hint_range(0.0, 8.0) = 2.2;
/** 自遮挡强度：越大光轴越锐利 */
uniform float absorption : hint_range(0.0, 8.0) = 2.6;
/** 前向散射各向异性：0 = 各向同性；0.6~0.8 = 明显的逆光银边 */
uniform float hg_anisotropy : hint_range(-0.9, 0.9) = 0.55;
/** 朝太阳方向的额外采样步数（0 = 关闭体积光照） */
uniform int light_steps : hint_range(0, 12) = 3;

// ==================== 局部光源（激光/火焰/余烬在烟里的散射） ====================
// ★ 参考画面（暗场景 + 红光渗进烟里）靠的就是这一组：真实体积雾里最亮的往往
//   不是太阳，而是**雾内部的发光体**。xyz = 世界位置，w = 影响半径（米）。
uniform vec4 fog_lights[8];
/** 每个局部光的颜色 × 强度 */
uniform vec3 fog_light_colors[8];
uniform int fog_light_count;
/** 局部散射整体强度 */
uniform float local_scatter_strength : hint_range(0.0, 16.0) = 3.0;

// ==================== 光束（激光穿过烟，把沿途的烟点亮） ====================
// 每束：起点 xyz + 半径 w；终点 xyz + 强度 w。
uniform vec4 beam_start[4];
uniform vec4 beam_end[4];
uniform vec3 beam_colors[4];
uniform int beam_count;

// ==================== 空洞 / 絮状边缘 ====================
/** 低于这个噪声值的体素**完全没有雾**（挖出洞），是"能透过烟看到黑背景"的来源 */
uniform float cavity_threshold : hint_range(0.0, 1.0) = 0.34;
/** 空洞边缘的软硬：越小边缘越硬（絮状越明显） */
uniform float cavity_softness : hint_range(0.02, 1.0) = 0.38;

varying vec3 v_world;

/** Henyey–Greenstein 相函数：描述"散射往哪个方向偏"。
 *  cos_theta = 1 表示正对太阳（前向散射）⇒ 值最大 ⇒ 逆光看雾更亮（银边）。 */
float hg_phase(float cos_theta, float g) {
	float g2 = g * g;
	float denom = 1.0 + g2 - 2.0 * g * cos_theta;
	return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(denom, 1.0e-4), 1.5));
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 box_min = vec3(
		domain_center.x - domain_size.x * 0.5,
		domain_center.y,
		domain_center.z - domain_size.y * 0.5
	);
	vec3 box_max = vec3(
		domain_center.x + domain_size.x * 0.5,
		domain_center.y + box_height,
		domain_center.z + domain_size.y * 0.5
	);

	vec3 ray_origin = CAMERA_POSITION_WORLD;
	vec3 ray_dir = normalize(v_world - ray_origin);

	// slab 法求射线与盒子的相交区间
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t_a = (box_min - ray_origin) * inv_dir;
	vec3 t_b = (box_max - ray_origin) * inv_dir;
	vec3 t_near = min(t_a, t_b);
	vec3 t_far = max(t_a, t_b);
	float enter = max(max(t_near.x, t_near.y), t_near.z);
	float exit_t = min(min(t_far.x, t_far.y), t_far.z);
	enter = max(enter, 0.0);

	if (exit_t <= enter) {
		ALBEDO = mist_color_lit;
		ALPHA = 0.0;
	} else {
		// 场景深度（视图空间 z），用于逐步遮挡测试
		float raw_depth = texture(depth_tex, SCREEN_UV).r;
		vec4 view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
		view_pos.xyz /= view_pos.w;
		float scene_view_depth = -view_pos.z;
		float entry_view_depth = -(VIEW_MATRIX * vec4(ray_origin + ray_dir * enter, 1.0)).z;

		// ★ 屏幕空间投影求"雾的可见终点"：把该像素的场景深度点投影到**本像素的视线**上，
		//   得到连续（非量化）的终点距离 t_surface。
		//   原来是在逐步循环里"采样点跑到几何后面就 break" —— 终点只能落在离散步长上，
		//   而档位中档的 march_steps 只有 4，于是雾与物体表面交界处出现一层层的硬切（分层感）。
		//   改成连续终点后，表面深度怎么移动，雾的终点就怎么连续移动，台阶消失。
		vec3 surface_world = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;
		float t_surface = dot(surface_world - ray_origin, ray_dir);
		float t_end = clamp(min(exit_t, t_surface), enter, exit_t);
		float span = max(t_end - enter, 0.0);

		// 相函数只需算一次：视线方向与"指向太阳"的夹角
		float cos_theta = dot(ray_dir, -normalize(sun_direction));
		float phase = hg_phase(cos_theta, hg_anisotropy);
		// 归一化到"各向同性时约等于 1"，这样改 hg 不会整体变亮变暗
		float phase_ref = hg_phase(0.0, hg_anisotropy);
		phase = phase / max(phase_ref, 1.0e-4);

		vec2 flow_offset = detail_flow * TIME * detail_speed * 100.0;
		vec3 sun_step = -normalize(sun_direction) * (box_height / float(max(light_steps, 1)) + 1.0);

		float steps = float(max(march_steps, 1));
		float accumulated = 0.0;
		float scattered = 0.0;
		vec3 local_scatter = vec3(0.0);
		// 上一步采样点的视图空间 z：用来把"被表面切掉的比例"算成连续值
		float prev_view_depth = entry_view_depth;
		for (int i = 0; i < 32; i++) {
			if (i >= march_steps) {
				break;
			}
			float t = mix(enter, exit_t, (float(i) + 0.5) / steps);
			vec3 sample_pos = ray_origin + ray_dir * t;
			float sample_view_depth = -(VIEW_MATRIX * vec4(sample_pos, 1.0)).z;

			// ★ 方案 A：只用**视图空间 z** 判断遮挡，**不再**用 INV_PROJECTION_MATRIX 反投影
			//   （反投影那版在等轴/正交相机下会把终点算成极远 ⇒ 整盒累积 ⇒ 整屏白雾，实测）。
			//   关键改进：不直接 break，而是先算出"本步被物体表面切掉的比例" partial ——
			//   表面在本步之内穿过时，本步只按走过的比例计入。贡献因此随表面位置**连续**变化，
			//   离散步长造成的台阶（分层感）消失；且每步权重恒 ≤ 1，任何画质档都不会变亮。
			float partial = 1.0;
			bool clipped = false;
			if (sample_view_depth > scene_view_depth) {
				float denom = max(sample_view_depth - prev_view_depth, 1.0e-5);
				partial = clamp((scene_view_depth - prev_view_depth) / denom, 0.0, 1.0);
				clipped = true;
			}

			vec2 uv = (sample_pos.xz - domain_center.xz) / domain_size + vec2(0.5);
			float height_factor = clamp((sample_pos.y - box_min.y) / max(box_height, 0.001), 0.0, 1.0);
			float profile = pow(1.0 - height_factor, height_power);
			// ★ 垂直剪切：越高的地方横向图案越偏 ⇒ 侧看有"层"，不再是一张片
			vec2 uv_sheared = uv + normalize(shear_direction + vec2(0.0001, 0.0001))
				* (vertical_shear * (height_factor - 0.5));

			vec2 edge_vector = smoothstep(vec2(0.0), vec2(max(edge_fade, 0.001)), uv)
				* smoothstep(vec2(0.0), vec2(max(edge_fade, 0.001)), vec2(1.0) - uv);
			float edge = edge_vector.x * edge_vector.y;

			// 程序化絮状扰动：两层正交正弦叠加，成本极低但足以打散"一块饼"的观感
			float wisp = 0.5 + 0.5 * sin(sample_pos.x * wisp_scale + TIME * wisp_speed)
				* cos(sample_pos.z * wisp_scale * 0.87 - TIME * wisp_speed * 0.73);
			float modulation = mix(1.0, wisp, clamp(wisp_amount, 0.0, 1.0));

			// ★ 三维细节：世界坐标 + 风向漂移 + 时间滚动 ⇒ 同一处水平浓度在不同高度
			//   形状不同，雾才会"翻涌"而不是一张片。两层不同频率叠加避免过于规则。
			vec3 detail_uv = sample_pos * detail_scale
				+ vec3(flow_offset.x, TIME * detail_speed, flow_offset.y);
			float detail = texture(detail_tex, detail_uv).r;
			float detail2 = texture(detail_tex, detail_uv * 2.37 + vec3(0.37, 0.11, 0.53)).r;
			float detail_mix = mix(0.5, detail * 0.68 + detail2 * 0.32, clamp(detail_strength, 0.0, 1.0));
			// 细节不能把浓度整体抬高/压低，所以用它做**乘性调制**（围绕 1 波动）
			float detail_gain = mix(1.0, 0.35 + 1.3 * detail_mix, clamp(detail_strength, 0.0, 1.0));

			float density = texture(density_tex, clamp(uv_sheared, vec2(0.0), vec2(1.0))).r;
			// ★ 空洞掩码：把三维噪声当"挖洞器"。参考画面里烟是有洞、有丝状边缘的
			//   —— 均匀密度无论怎么调都像一块塑料。阈值以下是真空（能看穿到黑背景）。
			float cavity = smoothstep(cavity_threshold, cavity_threshold + cavity_softness, detail_mix);
			float step_density = density * profile * edge * modulation * detail_gain * cavity * partial;

			// ★ 局部光源散射：红光从光源向四周渗进烟里（1/(1+(d/r)²) 衰减）
			vec3 local_rgb = vec3(0.0);
			for (int li = 0; li < 8; li++) {
				if (li >= fog_light_count) {
					break;
				}
				vec4 light = fog_lights[li];
				float dist = distance(sample_pos, light.xyz);
				float radius = max(light.w, 0.1);
				float atten = 1.0 / (1.0 + (dist * dist) / (radius * radius));
				local_rgb += fog_light_colors[li] * atten;
			}
			// ★ 光束：点到线段距离决定亮度 ⇒ 细亮核心 + 柔和光晕，正好是激光在烟里的样子
			for (int bi = 0; bi < 4; bi++) {
				if (bi >= beam_count) {
					break;
				}
				vec3 a = beam_start[bi].xyz;
				vec3 ab = beam_end[bi].xyz - a;
				float radius = max(beam_start[bi].w, 0.02);
				float t_line = clamp(dot(sample_pos - a, ab) / max(dot(ab, ab), 1.0e-4), 0.0, 1.0);
				float dist = distance(sample_pos, a + ab * t_line);
				float atten = 1.0 / (1.0 + (dist * dist) / (radius * radius));
				local_rgb += beam_colors[bi] * (atten * beam_end[bi].w);
			}

			// ★ 体积光照：朝太阳方向累积光学厚度 ⇒ 自遮挡 ⇒ 光轴
			float transmittance = 1.0;
			if (light_steps > 0) {
				float optical_depth = 0.0;
				for (int k = 0; k < 12; k++) {
					if (k >= light_steps) {
						break;
					}
					vec3 light_pos = sample_pos + sun_step * (float(k) + 0.5);
					vec2 light_uv = (light_pos.xz - domain_center.xz) / domain_size + vec2(0.5);
					float light_height = clamp((light_pos.y - box_min.y) / max(box_height, 0.001), 0.0, 1.0);
					bool inside = light_uv.x > 0.0 && light_uv.x < 1.0 && light_uv.y > 0.0 && light_uv.y < 1.0
						&& light_height > 0.0 && light_height < 1.0;
					if (inside) {
						float ld = texture(density_tex, clamp(light_uv, vec2(0.0), vec2(1.0))).r;
						optical_depth += ld * pow(1.0 - light_height, height_power);
					}
				}
				transmittance = exp(-absorption * optical_depth / float(max(light_steps, 1)));
			}

			accumulated += step_density;
			scattered += step_density * transmittance;
			local_scatter += step_density * local_rgb;
			// 本步跨过表面 ⇒ 本步已按比例计入（见 partial），可以收工了
			prev_view_depth = sample_view_depth;
			if (clipped) {
				break;
			}
		}
		accumulated /= steps;
		scattered /= steps;
		// ★ 平均透过率 = 散射累积 / 浓度累积（数学上 ≤ 1）：用它把太阳项**归一化**。
		//   不归一化的话"雾一浓就把颜色顶到 3 以上"，整屏直接白掉（踩过：
		//   scatter_strength × density_gain ≈ 9.5，ALBEDO 超过 1 就被裁成纯白）。
		float avg_transmittance = accumulated > 1.0e-5
			? clamp(scattered / accumulated, 0.0, 1.0)
			: 1.0;

		// 相机附近淡出：避免镜头钻进雾里变成一片白
		float camera_distance = distance(ray_origin, v_world);
		float camera_soft = camera_fade > 0.0
			? smoothstep(0.0, camera_fade, camera_distance)
			: 1.0;
		// 盒子入口已经在几何体后面就整体不画（避免"贴脸"的假雾）
		float depth_soft = smoothstep(0.0, depth_fade, scene_view_depth - entry_view_depth);

		float density_value = accumulated * density_gain;
		// Beer-Lambert 消光：浓度越大越接近不透明，但永远不会硬切到 1
		float alpha = (1.0 - exp(-density_value * opacity)) * camera_soft * depth_soft;

		// ★ 颜色 = 雾的底色 + 太阳散射（体积光照）。关键是**两个都要有界**：
		//   avg_transmittance ≤ 1、phase 由相函数给（前向散射时最大），
		//   再乘一个小的系数，最后 min(·,1) 兜底 —— 保证不会出现"整屏纯白"。
		float height_tint = clamp(accumulated * density_gain * 0.5, 0.0, 1.0);
		vec3 base_color = mix(mist_color_shadow, mist_color_lit, 1.0 - height_tint);
		float sun_visible = clamp(avg_transmittance * phase * scatter_strength * 0.12, 0.0, 1.0);
		vec3 lit_color = base_color * (0.85 + 0.30 * sun_visible) + sun_color * sun_visible * 0.28;
		// ★ 局部光源散射（参考画面的红光就来自这里）：按浓度累积后除以步数，
		//   再乘强度。有界性由 1/(1+(d/r)²) ≤ 1 保证，但仍 clamp 兜底。
		lit_color += clamp(local_scatter / steps, vec3(0.0), vec3(4.0)) * local_scatter_strength * 0.25;

		ALBEDO = min(lit_color, vec3(1.0));
		ALPHA = clamp(alpha, 0.0, 1.0);
	}
}
