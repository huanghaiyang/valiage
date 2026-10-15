// ============================================================================
// fog_mist_particle_process.gdshader —— 雾气粒子：**被流场推着走的**雾团
// ============================================================================
// 【与体积雾的关系】体积雾负责"整体空气感"，粒子负责"看得见的一团团雾"。
//   两者吃同一份速度场（flow_tex），所以粒子的运动与体积雾的漂移方向一致 ——
//   这是"雾气粒子"看起来真实而不是随机飘的关键。
//
// 【为什么不用 ParticleProcessMaterial】需要在 process() 里采样流场纹理并按
//   域尺寸换算速度，内置材质做不到；用自定义 process 着色器 + GPUParticles3D 最直接。
//
// 【生命周期用法】Godot 的粒子着色器不提供"年龄"内建量，所以用 CUSTOM.x 自己累计：
//   start() 里置 0，process() 里 += DELTA。CUSTOM 是逐粒子且跨帧保留的。
//
// 【域坐标】粒子挂在"域中心"节点下，因此局部坐标 xz ∈ [-size/2, +size/2]
//   直接对应 uv = pos.xz / domain_size + 0.5。
// ============================================================================

shader_type particles;

/** 求解器的最终速度场（域单位/秒，RG = u, v）。线性过滤：粒子在格子之间落点也要连续。 */
uniform sampler2D flow_tex : filter_linear, repeat_disable;
uniform vec2 domain_size = vec2(80.0, 80.0);
/** 雾带厚度（米）：粒子出生高度范围 = [0, box_height]（节点已按 base_height 抬高） */
uniform float box_height = 14.0;
/** 雾带离地/离节点的高度（米）。节点本身已被抬高，这里只用于垂直回收判定 */
uniform float base_height = 0.0;
/** 跟随流场的速率（1/秒）：越大越"贴着风走"，越小越自由飘 */
uniform float flow_gain : hint_range(0.0, 4.0) = 1.4;
/** 流场速度缩放（把域速度换算得更慢/更快） */
uniform float flow_scale : hint_range(0.0, 4.0) = 1.0;
/** 粒子跟随速度的**上限（米/秒）**：0 = 不限。
 *  ★ 为什么需要它：域速度 × domain_size 是**单位换算**（域被归一化成 1×1，
 *    1 域单位 = domain_size 米），本身没错；但速度场里除了风还有
 *    `add_source` 注入、交互体径向排开、涡量约束（反耗散）——它们能让一个很小的场值
 *    （0.05 域单位/秒）经 ×80 变成 4 米/秒。加了这个上限，雾才不会以几米每秒横穿地图。 */
uniform float flow_speed_cap_mps : hint_range(0.0, 40.0) = 1.5;
/** 0 = **没有流场**（编辑器预览）：此时改用 synthetic_wind，而不是去采样空纹理。
 *  ★ 不设这个开关会踩大坑：未赋值的 sampler2D 在 Godot 里会绑成**白图**，
 *    采样得到 (1,1)×域尺寸 = 几十米/秒，粒子会瞬间飞出画面。 */
uniform int flow_enabled = 1;
/** 合成风（米/秒，世界 XZ）：只在 flow_enabled == 0 时使用。
 *  作用：编辑器预览里没有求解器，但**风参数必须能看出区别** —— 于是把
 *  `wind_speed_mps × wind_scale` 直接当风速推粒子。 */
uniform vec2 synthetic_wind = vec2(0.0);
/** 上升速度（米/秒）—— 雾气微微上浮 */
uniform float rise_speed : hint_range(-2.0, 2.0) = 0.12;
/** 自身抖动幅度（米/秒） */
uniform float wander : hint_range(0.0, 2.0) = 0.15;
uniform float life_min : hint_range(0.1, 60.0) = 4.0;
uniform float life_max : hint_range(0.1, 60.0) = 9.0;
/** 粒子寿命（秒）。必须与 GPUParticles3D.lifetime 一致 —— 用 uniform 而不是
 *  在着色器里写 LIFETIME：Godot 4.7 的粒子着色器里 LIFETIME 是**只读常量**，
 *  赋值会报 "Constants cannot be modified." 并让整个 process 着色器编译失败
 *  （失败后粒子系统照样派发 compute，于是刷屏报 "No compute pipeline was set"）。 */
uniform float lifetime_seconds : hint_range(0.1, 60.0) = 9.0;

// ==================== 只在"有雾的地方"生成/存活 ====================
// 需求：粒子要在**雾气的表面及内部**移动，禁止在雾外面生成。
// ★ 用**画笔底图**（雾画在哪儿）当判据，而不是求解器的模拟浓度：
//   底图是静态的、场景一开就有值、编辑器预览里也存在；模拟浓度开局是 0，
//   用它会出现"开局几秒一颗粒子都生不出来"。
uniform sampler2D fog_mask_tex : filter_linear, repeat_disable;
/** 0 = 不做任何限制（旧行为：整个雾带里随机播撒）；1 = 启用雾内限制。
 *  ★ 没绑底图（编辑器里没刷过雾）时必须为 0：未赋值的 sampler2D 会绑成白图，
 *    否则"限制"会退化成"哪里都算有雾"。 */
uniform int mask_enabled = 0;
/** 判定"这里算有雾"的底图阈值：调大 = 只在更浓的地方生成（往内部缩）；
 *  调小 = 连雾的边缘（表面）也算 ⇒ 粒子会贴着雾气表面游走。 */
uniform float mask_min : hint_range(0.0, 1.0) = 0.08;
/** 1 = 只在雾内生成，并且寿命内漂到雾外时**拉回雾内**（而不是留在外面） */
uniform int spawn_inside_only = 1;
/** 每次重掷生成位置的最大尝试次数（雾只占地图一角时需要多试几次） */
uniform int respawn_attempts = 12;

// ==================== 受光（局部光源/光束照亮烟团） ====================
// ★ 参考画面的核心：暗场景里让烟显形的是**烟内部的发光体**（激光/火焰/余烬）。
//   这里在粒子阶段算出"这颗粒子被哪些光找到、有多亮"，结果写进 COLOR.rgb，
//   绘制阶段直接乘上去 —— 于是同一批粒子在暗处是深灰、在红光旁边是亮红。
//   把光照放在粒子阶段而不是绘制阶段：每颗粒子每帧只算一次，而绘制阶段每像素都要算。
uniform vec4 fog_lights[8];
uniform vec3 fog_light_colors[8];
uniform int fog_light_count;
uniform vec4 beam_start[4];
uniform vec4 beam_end[4];
uniform vec3 beam_colors[4];
uniform int beam_count;
/** 受光强度：越大烟被光源"点亮"得越明显 */
uniform float light_response : hint_range(0.0, 8.0) = 2.4;
/** **点光源衰减指数**：1 = 1/(1+d²/r²)，20 米外仍有 23% ⇒ 整团烟均匀泛红；
 *  2~3 = 红光收拢成"从浓烟内部透出一片红"的局部红斑（参考图效果）。
 *  ★ 这是"局部光晕"与"整体染色"的分界参数。 */
uniform float light_falloff_power : hint_range(0.5, 4.0) = 2.0;

/** 逐粒子的确定性伪随机（0..1）。
 *  ★ 不用内建的 rand_from_seed()：Godot 4.7 的粒子着色器里它没有匹配的重载
 *    （编译期直接报 "No matching function found for: 'rand_from_seed'"），
 *    而这个 sin-hash 在任何版本、任何阶段都稳定可用，且每粒子每通道独立。 */
float fog_hash(float seed) {
	return fract(sin(seed * 12.9898 + 78.233) * 43758.5453);
}

/** 该点处的"雾有多少"（0..1）。没绑底图时返回 1（= 处处有雾，等价旧行为）。 */
float fog_mask_at(vec3 pos) {
	if (mask_enabled == 0) {
		return 1.0;
	}
	vec2 uv = clamp(pos.xz / domain_size + vec2(0.5), vec2(0.0), vec2(1.0));
	return texture(fog_mask_tex, uv).r;
}

bool inside_fog(vec3 pos) {
	return fog_mask_at(pos) >= mask_min;
}

/** 在雾带里掷一个候选位置（第 i 次尝试用不同的哈希种子，高度以 ry 为基准微调）。 */
vec3 roll_spot(float base, float i, float ry) {
	float seed = base + i * 7.13;
	float sx = fog_hash(seed + 0.11);
	float sz = fog_hash(seed + 0.37);
	float sy = fog_hash(seed + 0.73);
	return vec3((sx - 0.5) * domain_size.x,
			mix(ry, sy, 0.65) * box_height,
			(sz - 0.5) * domain_size.y);
}

void start() {
	float base = float(INDEX) * 0.6180339887;
	float ry = fog_hash(base + 0.73);
	float rl = fog_hash(base + 1.19);

	// ★ 只在雾内生成：最多试 respawn_attempts 次；全失败就标记"局外"（CUSTOM.z = 1），
	//   process() 会继续找位置 —— 于是绝不会在没雾的地方冒出一团烟。
	vec3 spawn = roll_spot(base, 0.0, ry);
	if (mask_enabled != 0 && spawn_inside_only != 0) {
		bool found = false;
		for (int i = 0; i < 16; i++) {
			if (i >= respawn_attempts) {
				break;
			}
			spawn = roll_spot(base, float(i), ry);
			if (inside_fog(spawn)) {
				found = true;
				break;
			}
		}
		CUSTOM.z = found ? 0.0 : 1.0;
	} else {
		CUSTOM.z = 0.0;
	}

	TRANSFORM[3].xyz = spawn;
	VELOCITY = vec3(0.0);
	CUSTOM.x = 0.0;                      // 自累计年龄
	// 逐粒子寿命差异：用 life_scale 影响淡出速度（而不是改 LIFETIME，见上）
	CUSTOM.y = mix(life_min, life_max, rl) / max(lifetime_seconds, 0.001);
	COLOR = vec4(1.0, 1.0, 1.0, 0.0);    // alpha 在 process 里按生命期写入
}

void process() {
	CUSTOM.x += DELTA;
	// 年龄按"逐粒子寿命比例"归一（CUSTOM.y 在 start() 里写好）：
	// CUSTOM.y < 1 表示这颗粒子的寿命比节点标称寿命短，淡出得更早。
	float lifetime_scale = max(CUSTOM.y, 0.001);
	float age = CUSTOM.x / max(LIFETIME * lifetime_scale, 0.001);

	vec3 pos = TRANSFORM[3].xyz;
	// ★ 垂直回收：粒子飘出雾带顶部就回到带底 —— 这样 box_height 才是"雾的整体高度"，
	//   否则粒子会一路上升飘走，看起来"厚度"根本不受控（踩过：上升速度把烟全带离地面）。
	if (pos.y > box_height) {
		pos.y = 0.0;
		TRANSFORM[3].xyz = pos;
		CUSTOM.x = 0.0;                   // 年龄重置：回收后的粒子重新走一遍生命曲线
	}
	vec2 uv = clamp(pos.xz / domain_size + vec2(0.5), vec2(0.0), vec2(1.0));

	// ★ 漂出雾气范围 ⇒ 找一个雾内的新位置把它拉回来（而不是让它留在没雾的地方）。
	//   CUSTOM.z: 1 = 当前处在雾外（这一帧就被拉回；找不到位置时保持标记，下一帧继续找）。
	if (mask_enabled != 0 && spawn_inside_only != 0 && !inside_fog(pos)) {
		float base = float(INDEX) * 0.6180339887 + CUSTOM.x;   // 用年龄当种子，逐帧尝试不同位置
		bool found = false;
		vec3 spot = pos;
		for (int i = 0; i < 16; i++) {
			if (i >= respawn_attempts) {
				break;
			}
			spot = roll_spot(base, float(i), 0.5);
			if (inside_fog(spot)) {
				found = true;
				break;
			}
		}
		if (found) {
			TRANSFORM[3].xyz = spot;
			VELOCITY = vec3(0.0);           // 重新从静止开始被流场推着走
			CUSTOM.x = 0.0;                 // 年龄重置：当成刚在雾里出生
			pos = spot;
			CUSTOM.z = 0.0;
		} else {
			CUSTOM.z = 1.0;
		}
	} else {
		CUSTOM.z = 0.0;
	}

	// 采样流场：**域单位/秒 × domain_size = 米/秒**（单位换算，见 flow_speed_cap_mps 说明）
	vec2 flow = synthetic_wind;
	if (flow_enabled != 0) {
		flow = texture(flow_tex, uv).xy * domain_size * flow_scale;
	}
	// ★ 物理速度限幅：雾不该以几米/秒横穿地图（场里的 splat/交互体/涡量都会推高它）
	float flow_speed = length(flow);
	if (flow_speed_cap_mps > 0.0 && flow_speed > flow_speed_cap_mps) {
		flow *= flow_speed_cap_mps / flow_speed;
	}
	VELOCITY.xz += (flow - VELOCITY.xz) * clamp(flow_gain * DELTA, 0.0, 1.0);
	VELOCITY.y = rise_speed;

	// 个体抖动：低频正弦 + 每粒子相位，避免所有粒子像一支部队同向平移
	float phase = float(INDEX) * 0.137;
	VELOCITY.x += sin(TIME * 0.9 + phase) * wander;
	VELOCITY.z += cos(TIME * 1.13 + phase * 1.7) * wander;

	// 生命期淡入淡出：出生/消亡都不该"啪"地出现或消失
	float fade = smoothstep(0.0, 0.18, age) * (1.0 - smoothstep(0.65, 1.0, age));

	// ---- 受光：局部光源（球状衰减）+ 光束（到线段距离）----
	vec3 lit = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= fog_light_count) {
			break;
		}
		vec4 light = fog_lights[i];
		float radius = max(light.w, 0.1);
		float dist = distance(pos, light.xyz);
		// ★ 距离衰减比 1/(1+d²/r²) 更快（见 light_falloff_power 的说明）：
		//   否则远处粒子仍被点亮，整团烟变成均匀的红，而不是局部光晕。
		float falloff = 1.0 / (1.0 + (dist * dist) / (radius * radius));
		lit += fog_light_colors[i] * pow(falloff, light_falloff_power);
	}
	for (int b = 0; b < 4; b++) {
		if (b >= beam_count) {
			break;
		}
		vec3 a = beam_start[b].xyz;
		vec3 ab = beam_end[b].xyz - a;
		float radius = max(beam_start[b].w, 0.02);
		float t_line = clamp(dot(pos - a, ab) / max(dot(ab, ab), 1.0e-4), 0.0, 1.0);
		float dist = distance(pos, a + ab * t_line);
		lit += beam_colors[b] * (beam_end[b].w / (1.0 + (dist * dist) / (radius * radius)));
	}
	// ★ 只写**受光能量**，不掺环境底色 —— 这是颜色模型拆分的关键一步。
	//   逐通道钳到 1：保住色相（红光进来就是偏红），但幅度有界，不会因为叠加或多盏灯而饱和成白/橙。
	//   环境底色改由绘制阶段用常量给出 ⇒ "没被照到的烟"永远是深灰，
	//   之后无论怎么调光强/半径/受光系数，都不会再出现"整片变色/爆白"。
	vec3 lit_color = clamp(lit * light_response, vec3(0.0), vec3(1.0));
	COLOR = vec4(lit_color, fade);
}
