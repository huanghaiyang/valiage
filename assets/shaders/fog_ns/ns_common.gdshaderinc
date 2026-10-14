// ============================================================================
// ns_common.gdshaderinc —— 雾气纳维-斯托克斯求解器：所有片元通道共用的约定
// ============================================================================
// 【为什么要有这个文件】8 个模拟通道必须严格遵守同一套网格/采样约定，否则会出现
//   "看起来能跑但物理不对"（例如半格偏移、单位差一个 N 倍）。把约定集中一处，
//   比在每个着色器里各写一遍可靠得多。
//
// 【与 CPU 参考实现的对齐关系】scripts/fx/fog_ns_reference.gd 是同一套离散格式的
//   GDScript 版本（也是测试的真值来源）。两边必须一致：
//     · 域 = [0,1]²，速度 = **域单位/秒**（1.0 = 每秒横穿整个域一次）
//     · 单元中心坐标 cell = SCREEN_UV * grid_size - 0.5（与 uv_to_cell() 同式）
//     · 采样坐标 uv = (cell + 0.5) * texel_size（与 bilinear() 同一套）
//     · 半拉格朗日回trace 的单元偏移 = 速度 * dt * N
//     · 散度 = -0.5 * (1/N) * (∂u/∂x + ∂v/∂y)（Stam 的符号约定）
//     · 压力梯度更新 u -= 0.5 * (p[+x] - p[-x]) * N
//     · 涡量 ω = 0.5 * ((v[+x]-v[-x]) - (u[+y]-u[-y])) * N
//     · 边界：固壁 —— 法向速度分量取反、标量取诺伊曼（贴边复制）
//
// 【数据布局】速度 RG=(u,v)；浓度 R；散度 R；压力 R；涡量 R。
//   Alpha 一律写 1.0：canvas_item 默认是混合绘制，alpha<1 会和清屏色混在一起污染数据。
//
// 【★ 为什么用 SubViewport 片元通道而不是 RenderingDevice compute】
//   本机实测（tools/fog_gpu_verify.tscn）：本地 RenderingDevice 能跑 compute，但它的纹理
//   无法交给 Texture2DRD（引擎报 "texture_is_valid" 失败），而主 RenderingDevice 又被
//   引擎禁止 submit/sync（"Only local devices can submit and sync."）。也就是说 compute
//   结果要上屏必须每帧 CPU 回读+上传 —— 对每帧跑的雾气来说不可接受。
//   SubViewport 链路的结果本身就是渲染器纹理，可以直接被材质/粒子采样，零回读。
// ============================================================================

/** 网格分辨率（宽, 高）。建议正方形；各通道的邻居偏移按 1 格算。 */
uniform vec2 grid_size;
/** 1.0 / grid_size，采样换算用。 */
uniform vec2 texel_size;

/** 当前片元所在的**单元中心坐标**（与 CPU 参考的 cell 坐标一致）。
 *  ★ screen_uv 必须由调用方传进来，不能在这里直接写 SCREEN_UV：
 *    Godot 的 include 文件里的函数看不到带 stage 限定的内建量（SCREEN_UV/FRAGCOORD 等），
 *    直接引用会报 "Unknown identifier in expression: 'SCREEN_UV'"（踩过）。
 *    调用方一律写成 ns_cell(SCREEN_UV)。 */
vec2 ns_cell(vec2 screen_uv) {
	return screen_uv * grid_size - vec2(0.5);
}

/** 单元坐标 -> 采样 uv（落在纹素中心）。 */
vec2 ns_uv(vec2 cell) {
	return (cell + vec2(0.5)) * texel_size;
}

/** 把单元坐标绕回域内（**周期性边界**）。
 *  ★ 为什么是周期边界而不是固壁：这是"被风吹着走"的雾，风速 4 m/s 时雾必须真的从域
 *    的一侧移到另一侧。固壁 + 不可压约束意味着"闭盒里不允许净流动"，压力投影会把风
 *    给的速度几乎全部抵消（实测：目标 0.15 域单位/秒的风只剩 0.0015，雾基本不动）。
 *    周期边界同时消掉两个麻烦：
 *      · 压力泊松在周期域上自动满足相容性（∫div = 0），投影质量更好；
 *      · 无需任何边界处理，雾飘出右边会从左边回来（域足够大时肉眼不可见）。
 *    代价：局部浓雾飘出去会从对面回来 —— 由底图松弛（base_relax）把形状锚住。 */
vec2 ns_wrap_cell(vec2 cell) {
	return mod(cell, grid_size);
}
