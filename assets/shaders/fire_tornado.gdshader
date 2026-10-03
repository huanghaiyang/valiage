shader_type particles;
// 火焰编织 —— 粒子沿柱轴"螺旋前进"：绕轴旋转 + 半径沿轴张开（漏斗），同时被拉长成火舌。
//
// 位置与朝向全部由解析式给出，所以：
//   · render_mode disable_velocity —— 否则引擎会再叠加一遍速度积分
//   · 节点 transform_align 必须保持 DISABLED(0) —— 朝向下面自己算，不能被引擎覆盖
//   · 节点 local_coords = true —— 下面写的是**节点本地坐标**
//
// 柱轴 = 节点本地 +Y。脚本把 +Y 对准瞄准方向，于是龙卷是**横向**喷出去的（同火焰喷射）。
//
// ★★ 运动参数化（速度是一等参数，不是从长度和寿命倒推出来的）：
//     位置由**粒子自己的年龄（秒）**推进，不是由归一化寿命推进：
//         age            = t * LIFETIME          （秒）
//         沿轴位置        = age * speed            -> 柱长 = speed * lifetime
//         绕轴角度        = age * angular_speed    -> 螺距 = speed / angular_speed（米/圈）
//     所以：
//       · 想更快 -> 直接加 speed / angular_speed
//       · 加 speed 会让柱子变长（柱长 = speed × lifetime）；要"同样长但更快"，
//         就把 lifetime 按同样比例调短 —— 这不是绕路，是几何本身的关系
//       · 改 lifetime 不再顺带改变转速（角速度现在是独立的），调参不会互相牵连
//
// ★ 为什么自己算 billboard 而不是用 transform_align：
//   引擎的 Z_BILLBOARD 会把四边形朝向整个覆盖掉，就没法再让它"沿运动方向拉长"了
//   （那才是火舌的关键）。这里用 cam_local_pos 手工构造正交基：
//   长边 = 螺旋切线在屏幕平面上的投影，短边 = 与之垂直，法线 = 指向相机。

// ---------------------------------------------------------------- 运动（初速度）
uniform float speed = 4.23;            // ★ 沿轴初速度（米/秒）
uniform float angular_speed = 2.39;    // ★ 绕轴角速度（圈/秒）
uniform float spin = 1.00;             // 旋向：+1 / -1

// ---------------------------------------------------------------- 柱形
uniform float base_radius = 0.15;      // 起点半径（米）
uniform float top_radius = 0.40;       // 末端半径（米）；比起点大 -> 漏斗
uniform float radius_jitter = 0.08;    // 半径随机抖动（0 = 全贴在半径面上）
uniform float phase_jitter = 0.26;     // 初相位抖动；★ 螺旋可见度的主开关，1.0 会变成均匀圆筒
uniform float phase_offset = 0.00;     // ★ 整层的起始角偏移（单位：圈）。多层必须错开，
                                       //   否则各层相位对齐、叠成同一条飘带而不是一个涡柱。

// ---------------------------------------------------------------- 外观
uniform float size_min = 0.22;
uniform float size_max = 0.36;
uniform float stretch = 2.40;          // ★ 沿运动方向拉长的倍数（火舌长度）
uniform float alpha = 0.55;
uniform float fade_in = 0.10;
uniform float fade_out = 0.28;
uniform float heat = 1.00;             // 1 = 起点白热、末端暗红；0 = 整柱同色

// ---------------------------------------------------------------- 相机
// 相机在**节点本地空间**的位置，由 fire_tornado_particles.gd 每帧写入
uniform vec3 cam_local_pos = vec3(0.0, 0.0, 8.0);

void start() {
	// 用粒子序号做黄金比例散布：不需要随机数也均匀，且必定能编译
	CUSTOM.x = fract(float(NUMBER) * 0.6180339887) * phase_jitter + phase_offset; // 初相位（含整层偏移）
	CUSTOM.y = 0.0;                                                        // 年龄进度 0→1
	CUSTOM.z = 1.0 - radius_jitter * fract(float(NUMBER) * 0.3819660113); // 半径系数
	CUSTOM.w = mix(size_min, size_max, fract(float(NUMBER) * 0.7548776662));
}

void process() {
	// CUSTOM 跨帧保留，所以年龄自己累加（这是内置 ParticleProcessMaterial 的同款约定）
	CUSTOM.y += DELTA / LIFETIME;
	float t = clamp(CUSTOM.y, 0.0, 1.0);        // 0 = 起点, 1 = 末端
	float age = t * LIFETIME;                   // ★ 真实年龄（秒）—— 运动按它推进

	// ★ 螺旋前进：沿轴以 speed 推进 + 以 angular_speed 绕轴旋转 + 半径随年龄张开
	float r = mix(base_radius, top_radius, t) * CUSTOM.z;
	float a = CUSTOM.x * TAU + spin * age * angular_speed * TAU;
	vec3 pos = vec3(cos(a) * r, age * speed, sin(a) * r);

	// 运动方向 = 位置对**时间**的导数（把火舌拉长在"真正在走"的方向上）
	float dr = (top_radius - base_radius) * CUSTOM.z / LIFETIME;   // dr/dt
	float da = spin * angular_speed * TAU;                          // da/dt
	vec3 tangent = vec3(-sin(a) * r * da + cos(a) * dr,
			speed,
			cos(a) * r * da + sin(a) * dr);
	tangent = length(tangent) > 0.0001 ? normalize(tangent) : vec3(0.0, 1.0, 0.0);

	// 自己算 billboard：长边取切线在屏幕平面上的投影
	vec3 view = normalize(cam_local_pos - pos);
	vec3 long_axis = tangent - view * dot(tangent, view);
	if (length(long_axis) < 0.0001) {
		long_axis = vec3(0.0, 1.0, 0.0) - view * view.y;
	}
	long_axis = normalize(long_axis);
	vec3 short_axis = normalize(cross(long_axis, view));
	vec3 normal = cross(short_axis, long_axis);   // 指向相机那一侧

	float s = CUSTOM.w;
	TRANSFORM[0].xyz = short_axis * s;             // 宽
	TRANSFORM[1].xyz = long_axis * s * stretch;    // 长（沿运动方向拉长 -> 火舌）
	TRANSFORM[2].xyz = normal;                     // 面向相机
	TRANSFORM[3].xyz = pos;

	// 两端淡出，避免出现生硬的截面
	float fade = smoothstep(0.0, max(fade_in, 0.001), t)
			* (1.0 - smoothstep(1.0 - fade_out, 1.0, t));
	// 越靠起点越白热，越往前越暗红（乘到材质的顶点色上）
	COLOR = vec4(mix(vec3(1.0), vec3(1.0, 0.42, 0.12), t * heat), alpha * fade);
}
