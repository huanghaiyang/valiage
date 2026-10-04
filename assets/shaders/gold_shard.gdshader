shader_type particles;
// 金色碎片 —— 两种模式：
//   mode = 0（汇聚）：碎片在角色四周的**球面**上生成，各自以不同速度、按曲线**汇聚到角色身上**。
//   mode = 1（发散）：从角色身上往外飞散消失（施法结束/法力不足时的碎裂）。
//
// 【为什么用 particles 着色器自己算位置，而不是 ParticleProcessMaterial】
//   需求要"每个碎片速度不一 + 曲线移动 + 精确汇聚到角色身上"。用内置参数只能做到
//   "大致朝某个方向"，汇聚点与速度曲线都不可控；自己写就能一次说清：
//     · 方向：球面均匀随机（上下左右都会生成）—— 存进 CUSTOM.xyz
//     · 速度：由 INDEX 做哈希，每片不同 —— 不占额外存储、天然稳定
//     · 曲线：pow(age, k) —— 起步慢、末段贴上去（ease-in），mode 1 时反过来
//     · 半径：由 age 直接算，所以**必然收敛到 0**，不会飞过头
//
// 注意：颗粒的年龄没有内置变量，用 CUSTOM.w 自己累加 DELTA；restart 时归零。
uniform int mode = 0;
uniform float radius = 2.4;          // 生成半径（mode 0）/ 飞散半径（mode 1）
uniform float min_speed = 0.55;      // 最慢的碎片
uniform float max_speed = 1.65;      // 最快的碎片
uniform vec3 gold = vec3(1.0, 0.80, 0.32);

float hash1(float i) {
	return fract(sin(i * 127.1 + 311.7) * 43758.5453);
}

void start() {
	// 用自带哈希取随机方向。
	// ★ 不要用 rand_from_seed()：在 Godot 4.7 的 particles 着色器里它报
	//   "No matching function found for: 'rand_from_seed'"，会让整份着色器编译失败。
	//   哈希里掺了 TIME，所以每次重新发射（restart）方向都不一样。
	float t = TIME;
	float r1 = hash1(float(INDEX) * 12.9898 + t * 78.233);
	float r2 = hash1(float(INDEX) * 39.3467 + t * 11.135);
	// 球面均匀取点（上下左右都会生成）
	float z = r1 * 2.0 - 1.0;
	float th = r2 * 6.28318530718;
	float s = sqrt(max(1.0 - z * z, 0.0));
	CUSTOM.xyz = vec3(s * cos(th), z, s * sin(th));
	CUSTOM.w = 0.0;
}

void process() {
	CUSTOM.w += DELTA;
	float k = clamp(CUSTOM.w / max(LIFETIME, 0.001), 0.0, 1.0);

	// 每个碎片速度不同（由 INDEX 哈希，稳定且不需要额外存储）
	float sp = mix(min_speed, max_speed, hash1(float(INDEX)));
	// 曲线：ease-in -> 起步慢、越来越快，最后"贴"到角色身上
	float e = pow(k, 1.25 / max(sp, 0.05));

	float r;
	if (mode == 0) {
		r = radius * (1.0 - e);                       // 汇聚到 0
		COLOR = vec4(gold, 1.0 - 0.45 * k);
	} else {
		r = radius * 1.5 * e;                         // 向外飞散
		COLOR = vec4(gold, 1.0 - k);                  // 越飞越淡
	}
	TRANSFORM[3].xyz = CUSTOM.xyz * max(r, 0.04);
}
