# fast-tree 风摆移植 · 规格与接口（唯一事实来源）

> 目标：把 `D:\sgames\fast-tree`（three.js 程序化树）里"树枝 / 树叶 / 花朵 / 果实随风摆动"的
> 顶点着色器算法，**逐行等价**地移植到 CozyVale（Godot 4.7 / GDScript / spatial shader）。
> 同时把 `scripts/wind.gd` 从 autoload 改成**场景内实例化节点**，让 `@export` 在 Inspector 可见。

---

## 0. 源实现（必须逐行对照，不要"凭感觉调参"）

| 内容 | 位置 |
| --- | --- |
| 顶点风场 + 叶片弯曲/铰链俯仰 | `D:\sgames\fast-tree\src\core\materials.js` L29-135（`VERTEX_HEADER` + `vertexBody`） |
| 风参数默认值 / 量级约定 | `D:\sgames\fast-tree\src\core\autowind.js`、`src\core\windModel.js`（L37-40 DEFAULTS） |
| uniform 写入 | `materials.js` L360-390（shared）、L790-803（`updateWindUniforms`）、L605/L697-698（per-material） |
| 图形自检（轨迹指标） | `windModel.js` L46-208（`leafTrajectory` / `motionMetrics` / `swayEnvelope`） |

### 0.1 源算法原文（GLSL，逐行对照用）

```glsl
// ---- 每个顶点（materials.js vertexBody）----
vec4 treeWorld = modelMatrix * vec4(treePos, 1.0);
float flex = pow(clamp(aWind, 0.0, 1.0), uFlexFalloff);
vec2 windDir = normalize(uWindDir + vec2(1e-5, 1e-6));
vec2 windPerp = vec2(-windDir.y, windDir.x);
float phase = aPhase + dot(treeWorld.xz, windDir) * uSpatialScale + uSeed * 0.017;
float tw = uTime * uWindSpeed;
float freq = max(0.05, uWindFrequency);
float wave = sin(tw + phase) * 0.72 + sin(tw * 2.17 * freq + phase * 1.7) * 0.28;
float osc = wave * 0.5 + 0.5;                 // 0..1
float gust = 1.0 - uGust * 0.6 *
  (1.0 - (sin(tw * uGustSpeed + phase * 0.21) * 0.5 + 0.5));
float along = osc * gust + uWindBias * 0.35;
float turb = sin(tw * 3.1 * freq + phase * 4.3);
vec2 sway = windDir * along + windPerp * turb * uTurbulence;
float amount = uWindStrength * uSway * flex * uWindEnabled;
treePos.xz += sway * amount;
if (uIsLeaf > 0.5) {
  vec3 rel = treePos - aOrigin;
  float stemDist = length(rel);
  float flap = sin(tw * 4.1 * freq + phase * 6.3);
  float surge = sin(tw * 1.35 + phase * 2.1);
  float leafAmp = uLeafFlutter * uWindStrength * 1.8 * uWindEnabled * (0.35 + aWind);
  vec3 bendDir = normalize(vec3(windDir.x, -0.3, windDir.y));
  rel += bendDir * stemDist * leafAmp * (0.5 + 0.35 * flap + 0.15 * surge);
  float pitch = flap * uLeafTwist * 0.5 * uWindEnabled * (0.35 + uWindStrength * 2.0);
  rel = treeRotate(rel, vec3(windPerp.x, 0.0, windPerp.y), pitch);
  treePos = aOrigin + rel;
}
```
`treeRotate(v, axis, angle)` = 罗德里格旋转：`v*c + cross(axis,v)*s + axis*dot(axis,v)*(1-c)`。

### 0.2 物理约定（照抄，别改结构）

1. 顺风位移**恒沿 windDir**，只有幅度随时间变化；`bias` 只抬高摆动低谷（风只推、不拉）。
2. 叶片**叶柄固定**：只做 (a) 沿固定方向（下风向为主 + 少量重力）的弯曲，幅度 ∝ 顶点到叶柄距离；
   (b) 绕固定水平轴（⊥风向）的铰链俯仰。**全程没有绕垂直轴的自转** —— 这是"不绕圈"的结构保证。
3. 垂直于风向的位移**只**来自 turbulence。
4. `flex` 是逐顶点的"跟随枝条程度"（0=树干根部不动，1=枝梢/叶）。

---

## 1. 源顶点属性已经烘焙在 GLB 里（关键事实，勿重复造轮子）

`assets/models/树/大樱花树.glb` 是 fast-tree 导出的，**每个 primitive 都带**：

| glTF 属性 | 类型 | 含义 |
| --- | --- | --- |
| `_AWIND` | float | aWind（0..1，枝条柔软度） |
| `_APHASE` | float | aPhase（每枝/每叶随机相位，rad） |
| `_AORIGIN` | vec3 | aOrigin（叶柄/枝条基点，模型空间） |
| `_AGROW` | vec2 | 生长动画区间（本移植不用） |
| `_ANODEID` | float | 节点 id（本移植不用） |

Godot 的 glTF 导入器**丢弃**了这些自定义属性（`_wind_probe*.gd` 实测：surface 只有
VERTEX/NORMAL/TANGENT/COLOR/UV/INDEX）。所以必须自己"补回去"：把它们写成
`Mesh.ARRAY_CUSTOM0` / `ARRAY_CUSTOM1`。

实测结论（已跑通）：
- 自定义通道格式必须显式给 flags：
  `flags = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)`
  （= 57344 | 458752 = 516096）；数据是 `PackedFloat32Array`，每顶点 4 个 float。
- `ArrayMesh.add_surface_from_arrays(prim, arrays, [], {}, flags)` 后 CUSTOM0/1 可读回，
  `ResourceSaver.save()` 成 `.res` 后重新加载**不丢**。
- Godot 导入后的**顶点顺序与 GLB 不同**（计数相同），所以补属性时必须**按位置匹配**
  （量化位置做 key，必要时用 normal 二次筛选），不能按下标对齐。

---

## 2. 移植后的着色器接口（约定，两个队友都按这个写）

新文件 `assets/shaders/fast_tree_wind.gdshaderinc`，被 `tree_leaves_burn_ds.gdshader` 与
`tree_burn_keep_ds.gdshader` `#include`。它提供：

### 2.1 顶点属性（烘焙后由 Mesh 提供，shader 里直接用内置的 `CUSTOM0` / `CUSTOM1`）

| 通道 | 分量 | 内容 |
| --- | --- | --- |
| `CUSTOM0` | `.xyz` = aOrigin, `.w` = aWind | 叶柄/枝条基点 + 柔软度 |
| `CUSTOM1` | `.x` = aPhase, `.y` = isLeaf(0/1), `.z` = 备用(nodeId), `.w` = **baked 标志（1=有烘焙数据）** | |

> `CUSTOM1.w == 0`（未烘焙的网格）→ 着色器走**旧的高度权重回退路径**，保证其它树/灌木观感不变。

### 2.2 每帧由 `wind.gd` 写入的 uniform（全局风场）

| uniform | 类型 | 含义 / 量级 |
| --- | --- | --- |
| `wind_direction` | vec2 | 水平风向（已归一化） |
| `wind_gust` | float | 阵风 0..1 |
| `wind_turbulence` | float | 湍流 0..1 |
| `wind_speed` | float | 相位推进速度（weather 的 wind_speed，0.8..3.6） |
| `wind_force` | float | **米**：树梢顺风偏移量级 = `tree_force_min + clamp(weather.wind,0,1) × tree_force_per_wind`（默认 0.03 + k×0.30，即 fast-tree autoWind 档位） |
| `wind_frequency` | float | **材质级**基础频率倍率（fast-tree `uWindFrequency`，默认 1.0；叶/花可在 .tres 里各自调） |
| `wind_freq_scale` | float | 全局频率倍率（wind.gd 的 `tree_frequency`，默认 1.0） |
| `wind_variation` | float | 每元素（每叶/每花）局部抖动**频率与幅度**的微差，默认 0.45；`0` = 逐位回到源实现 |
| `wind_sway_variation` | float | 每元素**刚性主波次级项**的频率微差，默认 0.15；`0` = 源实现 |
| `wind_gust_speed` | float | 阵风脉动速度（默认 0.16） |
| `wind_spatial_scale` | float | 世界 xz 相位错开（默认 0.22） |
| `wind_bias` | float | 顺风静态偏置（默认 0.3） |
| `wind_flex_falloff` | float | flex 指数（默认 1.5） |
| `wind_seed` | float | 每棵树随机种子（材质里写，默认 0） |
| `wind_strength` | float | **旧的相对强度**（0..1.5）；仅回退路径与草地用 |
| `wind_height_ref` / `wind_height_power` / `wind_sway_scale` | float | 旧回退路径参数（保留） |

### 2.3 材质级（在 `.tres` 里写，Inspector 可调）

`wind_enabled: bool`、`wind_sway: float`（摆幅倍率；树皮 ~0.8，叶/花 1.0）、
`wind_is_leaf: bool`、`wind_leaf_flutter: float`、`wind_leaf_twist: float`、
`wind_frequency`（基础频率）、`wind_flutter_rate`（该材质的抖动频率倍率：叶 1.10 / 花 0.72，避免同频）。

### 2.4 对外函数

```glsl
vec3 treeRotate(vec3 v, vec3 axis, float angle);
// pos=模型空间顶点, c0/c1=CUSTOM0/CUSTOM1, world_pos/base_y 由 vertex() 传入
// （MODEL_MATRIX 在自定义函数作用域里不可见，必须当参数传）
// 返回模型空间位移；out_flex 供片元透光使用
vec3 tree_wind_offset(vec3 pos, vec4 c0, vec4 c1, vec3 world_pos, float base_y,
        float legacy_scale, out float out_flex);
```

---

## 3. wind.gd 改造约定

- **不再是 autoload**：`project.godot` 删除 `Wind="*res://scripts/wind.gd"`。
- 在 `scenes/main.tscn` 里放一个**实例节点** `WindSystem`（脚本 = `scripts/wind.gd`），
  于是 `@export` 参数在 Inspector 可见、可调。
- `scripts/wind.gd` 加 `class_name WindSystem` + 静态取用口：
  ```gdscript
  static var _instance: WindSystem
  static func get_instance() -> WindSystem
  ```
  `_ready()` 里登记（`add_to_group("wind_system")`），`_exit_tree()` 里注销。
- 原来"脚本型 autoload 看不到 @export，所以参数走项目设置 `Wind/sgt_player/*`"那套机制
  （`_ensure_project_settings` / `_sgt_setting` / `_sgt_num` / `_sgt_bool` / `SGT_SET_*`）
  **整套删除**，全部改用 `@export` 的成员变量；`project.godot` 的 `[Wind]` 段一并删除。
- 读取方（`scripts/vfx/fire_burst.gd`、`tools/verify_flame_scorch.gd`、
  `tools/verify_foliage_burn.gd` 等）改成：
  `WindSystem.get_instance()` → 失败再 `get_tree().get_first_node_in_group("wind_system")`
  → 再兼容旧 `/root/Wind`（没有就静默跳过，不许报错）。

---

## 4. 验收标准

1. `godot --headless --path . --check-only` 式脚本检查：所有改动脚本零解析错误、零 shader 编译错误。
2. `tools/bake_tree_wind.gd` 可重复执行：输出 `.res` 的 CUSTOM0/1 与 GLB 原始 accessor 一致
   （抽样误差 < 1e-4），且 `CUSTOM1.w == 1`。
3. 轨迹自检（照抄 `windModel.js` 的指标）：CPU 端用移植公式 + 烘焙属性采样叶尖轨迹：
   - `azimuthDeg` 与 `wind_direction` 一致（误差 ≤ 3°）
   - `thinness`（横向/顺风 RMS 比）≤ 0.45（不能像绕圈）
   - 顺风峰峰值随 `wind_force` 线性增长
   - 叶片俯仰存在（同一点在顺风/垂直方向位移不共线）
4. 视觉：同一棵树两帧（间隔 0.5s）截图，树冠区域像素差异明显（说明确实在动），
   树干底部几乎不动。
5. `WindSystem` 节点在 Inspector 里能看到全部 @export 参数。

---

## 5. 落地状态（2026-10-22）

| 项 | 状态 | 证据 / 命令 |
| --- | --- | --- |
| 烘焙（8 个网格 CUSTOM0/1） | ✅ | `tools/bake_tree_wind.gd` 重跑：0 匹配失败，最大位置误差 7.6e-4 m（Godot 导入压缩所致，已用分格最近匹配）；`.res` 序列化往返不丢 |
| 烘焙网格挂回场景 | ✅ | `big_sakura_tree.tscn` 8 个 `MeshInstance3D` 的 `mesh` 覆盖；`_wind_probe5` 实测 8/8 有 CUSTOM |
| 分块剔除不丢自定义通道 | ✅ | `canopy_chunk_cull.gd` 补了 `ARRAY_CUSTOM_*_FLOAT` 的 flags；16 块 custom_ok=16 bad=0，三角形总数不变 |
| 两个树着色器接入 | ✅ | `tree_leaves_burn_ds`（叶/花，legacy_scale=1.0）、`tree_burn_keep_ds`（树干/枝/果，0.45）；headless 全场景 0 SHADER ERROR |
| 静态外观无回归 | ✅ | 新旧着色器同机位 `wind_enabled=false`：全图 mean=0.00000 / max=0.0000 |
| 运动可见 | ✅ | 同机位 t=0.5s vs 1.17s：树冠变化像素占比 17.9%（1280×720）；`calm(force .06)` vs `storm(force .36)` 同帧差异 37–43% |
| wind.gd 去 autoload | ✅ | `class_name WindSystem` + 静态 `get_instance()` + 分组 `wind_system`；`project.godot` 无 Wind autoload/`[Wind]` 段；`scenes/main.tscn` 的 `Main` 下有 `WindSystem` 节点（@export 38 项 Inspector 可见） |
| 树风参数可在 Inspector 调 | ✅ | 节点上 `tree_*` 一组 export；材质上 `wind_sway / wind_is_leaf / wind_leaf_flutter / wind_leaf_twist / wind_force 默认值` |
| 真实 main.tscn 写入链路 | ✅ | `tests/wind_integration_probe.gd`（headless 加载 main.tscn）：`WindSystem` 在 `/root/Main/WindSystem`，`tree_mats=3`，三个树材质 `wind_force=0.0840`（=0.03+0.18×0.30）、`wind_strength=0.18`、`wind_speed=1.30`、风向随时间变化 |
| 一条命令导入新树 | ✅ | `tools/import_fasttree.ps1`（包装 `tools/fasttree_import.gd`）：GLB → 烘焙 .res + 3 个树着色器材质 + 可拖入场景的 tscn（含 CanopyCull / 可选碰撞）。用法见 `docs/fasttree-glb-import.md`；编辑器入口：FileSystem 右键 `.glb` →「fast-tree 一键烘烤…」（`addons/fasttree_import/`，仅对 .glb 出现） | 
| 独立验证 | ✅ | `docs/wind-port-verification.md`：38/38 PASS（与 JS 源逐值一致 14 项、轨迹 7 项、烘焙 11 项、视觉 6 项） |
| 抖动去同步化（2026-10-22 用户反馈追加） | ✅ | 源实现所有元素同一个抖动频率 → 观感机械。新增 `wind_variation / wind_sway_variation` + 材质级 `wind_flutter_rate`：每片叶/每朵花按烘焙相位得到独立频率与幅度（叶 1.10 / 花 0.72 基础频率）。`tests/wind_freq_diversity.gd`：10/10 PASS（variation=0 时回到源实现；叶片频率跨度 0.605–1.594，花/叶均值比 0.658，元素内频率一致 0/不一致） |
| 其它树（非 fast-tree 导出） | ⚠ 保持旧观感 | 没有 `_AWIND/_APHASE/_AORIGIN` 数据 → 走旧的高度权重回退路径（分支/叶片不丢，只是没有"逐枝柔度 + 叶柄铰链"） |

**已知限制**
- 只有 fast-tree 导出的 GLB 带真实逐顶点风数据；其它 GLB 想吃到同等效果，需要先在 fast-tree 里导出（导出会带 `_AWIND/_APHASE/_AORIGIN`），再跑一次：
  `godot --headless --path . --script res://tools/bake_tree_wind.gd -- --glb=<glb> --scene=<tscn> --out=<dir>`
  （`LEAF_NODES` 常量目前写死 `Leaves/Flowers`，换命名时改一行）。
- `tree_force_per_wind` 调得很大时（>~1.0），树冠分块剔除的安全余量（2.6×force + 旧公式取大）可能不够，
  需要在 `canopy_chunk_cull.gd` 上把 `margin_scale` 或 `inflate` 调大，否则视野边缘可能出现"块突然消失/出现"。
- 树冠中央那片"白色网格状斑点"（`depth_prepass_alpha` + 花材质的 alpha 抖动）在改动前就存在，
  静态对比像素完全一致，不属于本次移植范围。
- 位移是在**模型空间**沿风向施加的（与 fast-tree 源实现一致，因为 fast-tree 的网格都在单位变换下）。
  当前 `main.tscn` 里那棵樱花树是单位变换，所以方向正确；如果以后给树节点加**绕 Y 的旋转**，
  摆向会跟着模型一起转 —— 那时需要在 include 里把风向用 `MODEL_MATRIX` 转进模型空间
  （注意 `MODEL_MATRIX` 在自定义函数作用域不可见，要么在 `vertex()` 里算好当参数传，要么写在 vertex 里）。




