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

角色扰动来自另一个 include（`assets/shaders/tree_player_disturb.gdshaderinc`，详见 §6）：

```glsl
// model_matrix 必须由调用方传 MODEL_MATRIX（同上：自定义函数取不到内置变量）
// 返回模型空间位移；无扰动时返回 vec3(0.0)
vec3 tree_player_displace(mat4 model_matrix, vec3 pos_model, vec4 c0, vec4 c1,
        bool is_bark, float amount);
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
| 树枝 ↔ 树叶/花朵同步（2026-10-22 用户反馈追加） | ✅ | 叶/花顶点烘焙时追加 `CUSTOM2=(宿主枝 phase, 宿主枝 aWind, 宿主 nodeId, 1)`：用叶生点 `aOrigin` 在 0.35m 内找最近树皮顶点；shader 里**刚性摆动**用宿主值、**局部抖动**用自身相位；叶/花材质刚性摆幅改为 0.8（与树皮一致）。`tests/wind_leaf_branch_sync.gd` 12/12 PASS：叶/花 95.1%/94.4% 顶点宿主相位=附近枝条相位，同相位配对刚性位移最大差 0.0216 m |
| 独立验证 | ✅ | `docs/wind-port-verification.md`：38/38 PASS（与 JS 源逐值一致 14 项、轨迹 7 项、烘焙 11 项、视觉 6 项） |
| 抖动去同步化（2026-10-22 用户反馈追加） | ✅ | 源实现所有元素同一个抖动频率 → 观感机械。新增 `wind_variation / wind_sway_variation` + 材质级 `wind_flutter_rate`：每片叶/每朵花按烘焙相位得到独立频率与幅度（叶 1.10 / 花 0.72 基础频率）。`tests/wind_freq_diversity.gd`：10/10 PASS（variation=0 时回到源实现；叶片频率跨度 0.605–1.594，花/叶均值比 0.658，元素内频率一致 0/不一致） |
| 角色扰动（2026-10-23 追加） | ✅ | `assets/shaders/tree_player_disturb.gdshaderinc` + 两个树着色器各一行调用；`wind.gd` 每帧写 `player_head_y`。改动后 `tests/wind_leaf_branch_sync.gd` 12/12 PASS、`tools/scan_all_scripts.gd` 0/413 失败、真实渲染 12 帧 0 SHADER ERROR。详见 §6 |
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
  当前 `main.tscn` 的 `BigSakuraTree` 只有平移 + **0.3 均匀缩放、无旋转**（均匀缩放不改变方向，
  所以摆向正确）；如果以后给树节点加**绕 Y 的旋转**，摆向会跟着模型一起转 —— 那时需要在
  `vertex()` 里把风向用 `MODEL_MATRIX` 转进模型空间（注意 `MODEL_MATRIX` 在自定义函数作用域不可见，
  要么在 `vertex()` 里算好当参数传，要么直接写在 `vertex()` 里）。

---

## 6. 树木"角色扰动"（2026-10-23）

> 需求：角色站在 / 走过 / 跳到**低于头顶**的 L5 枝条、树叶、花朵下面时，把它们顶开。
> 参考草的踩踏扰动，但树不是"倒下去"，而是**向上抬 + 左右分开**（低垂枝被头/肩顶起）。
> 实现文件：`assets/shaders/tree_player_disturb.gdshaderinc`（唯一实现，两个树着色器共用）。

### 6.1 判定顺序（shader 内）

| 步骤 | 条件 | 结果 |
| --- | --- | --- |
| 1 | `player_move <= 0.001` | 返回 0（未找到玩家，或 `stand_bend = 0` 且完全静止） |
| 2 | `player_head_y < -90000` | 返回 0（`wind.gd` 找不到玩家时的哨兵值 `-100000`） |
| 3 | 顶点世界高度 > 头顶 | `cap = 0`；头顶以上 `player_head_soft` 米内 `smoothstep` 淡出 |
| 4 | 水平距离 ≥ `player_radius` | 权重 0；范围内用 `1-t` 再 `smoothstep` 平滑到边缘不硬切 |
| 5 | 软度 `tree_player_flex()` | 烘焙网格取 `CUSTOM0.w`（aWind）；未烘焙树皮按高度渐入、叶片固定 0.70 |
| 6 | 位移 | `(左右分开 + 向前推 + 向上抬) × infl × amount` |

> 站立时 `player_move` 实际写的是 `max(stand_bend, _move_amt)`（见 `wind.gd` 的 `_write_mats`），
> 所以站着**也会**保持一个基础撑开量，不会完全回弹；走动时平滑逼近 1。

### 6.2 涉及文件

| 文件 | 作用 |
| --- | --- |
| `assets/shaders/tree_player_disturb.gdshaderinc` | uniform + `tree_player_flex()` + `tree_player_displace()` |
| `assets/shaders/tree_leaves_burn_ds.gdshader` | 树叶 / 花朵：`VERTEX += tree_player_displace(MODEL_MATRIX, VERTEX, CUSTOM0, CUSTOM1, false, 1.0) * alive` |
| `assets/shaders/tree_burn_keep_ds.gdshader` | 树干 / 枝条：同上，`is_bark=true`、`amount=0.45`（比叶子硬） |
| `scripts/wind.gd` | 每帧写 `player_*`；`is_tree` 时额外写 `player_head_y` |
| `scenes/树/大樱花树/*.tres` | **删除**了已不存在的旧 uniform `player_height_max`（写错的 uniform 是静默无效的） |

### 6.3 uniform 接口（每帧由 `wind.gd` 写）

| uniform | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `player_pos` | vec3 | `(0, -100000, 0)` | 玩家**脚底**世界坐标 |
| `player_forward` | vec3 | `(0, 0, -1)` | 玩家水平朝向（只用 xz） |
| `player_radius` | float | 0.55 | 影响半径（米）；运行时写入的是 `player_radius × lerp(stand_radius_scale, 1, move)` |
| `player_bend` | float | 0.55 | 向上抬的幅度（米级） |
| `player_spread` | float | 0.30 | 左右分开的幅度（米级） |
| `player_move` | float | 0.0 | 扰动强度 0..1（站立取 `stand_bend`，走动逼近 1） |
| `player_head_y` | float | `-100000` | 头顶**世界高度** = 脚底 y + 角色身高 |
| `player_head_soft` | float | 0.35 | 头顶以上淡出宽度（米）；0 = 硬线 |

材质级 `amount` 不通过 uniform：树皮 `0.45`、叶花 `1.0`，在调用点写死（与风摆比例一致）。

> `.tres` 里也会序列化一份 `player_*`（例如 `player_bend = 0.75`），那只是**初始值**；
> 运行时每帧都会被 `wind.gd` 覆盖，调手感请改 `WindSystem` 节点上的 `@export`，不要改材质。

### 6.4 写入链路（`scripts/wind.gd`）

```gdscript
# _write_mats(..., is_tree=true)
var head_y := ppos.y + _player_head_height()   # 脚底 + 身高
m.set_shader_parameter("player_head_y", head_y)
```

- `ppos` = 玩家 `global_position`（脚底）。**跳跃时脚底抬高 → 头顶自动变高**，
  所以不需要额外传"是否在跳跃"的标志。
- `_player_head_height()`：优先读玩家节点的 `target_height`（`player.gd` 有，按角色档案缩放），
  读不到再用节点上的 `@export player_head_height = 1.75` 兜底。
- 只有 `_mats_tree` 会写 `player_head_y`；草走自己的高度闸门（`sgt_height_gate`），互不影响。

### 6.5 数学要点

1. **必须用世界坐标判定**：`VERTEX` 是模型空间，`player_pos` 是世界坐标。
   旧实现直接 `VERTEX.xz - player_pos.xz` → 大樱花树在 `(-13.72, -14.54)`、缩放 0.3，
   两者天然差十几米 → 权重恒 0 → 永远没效果。
   现在：`wp = (MODEL_MATRIX * vec4(VERTEX, 1)).xyz` 先转世界，算完再反解回模型空间。
2. **权重**：先 `x = 1 - d/r`（`d` = 水平距离），再 `x²(3-2x)` 平滑（边缘不硬切）；
   `infl = x × player_move × cap × flex`，低于 `0.002` 直接早退。
3. **方向**：以玩家朝向 `fw` 和右向 `rt` 建立水平基；
   - 左右分开：`rt × sign(side) × player_spread`
   - 向前推：`-fw × 0.10 × front`（角色前方/身上的枝被顶得更明显）
   - 向上抬：`player_bend × (0.35 + 0.65 × front)` —— **向上的分量**，与草的倒伏方向相反
4. **世界 → 模型反解**：模型 basis 只有旋转 + 缩放（列向量两两正交）时，
   逆矩阵 = 转置 / 列长平方，所以逐轴做投影再除以 `dot(b, b)`。
   大樱花树缩放 0.3：若直接把世界位移加到 `VERTEX` 上会放大 `1/0.3 ≈ 3.33` 倍。
   （带斜切的非正交 basis 下是近似解，画面上通常看不出来。）

### 6.6 关键约束：`MODEL_MATRIX` 必须由调用方传入

```glsl
// ✗ 编译报错：表达式中的标识符未知："MODEL_MATRIX"
vec3 tree_player_displace(...) { vec3 wp = (MODEL_MATRIX * vec4(pos, 1)).xyz; ... }

// ✓ 内置变量只在 vertex()/fragment() 里可见 → 当参数传
vec3 tree_player_displace(mat4 model_matrix, ...) { ... }
VERTEX += tree_player_displace(MODEL_MATRIX, VERTEX, CUSTOM0, CUSTOM1, false, 1.0) * alive;
```

这是 2026-10-23 实际踩到的编译错误。`VERTEX` / `TIME` / `MODEL_MATRIX` 等内置变量
都遵循同一规则：自定义函数里取不到，必须从 `vertex()` 传参。

### 6.7 软度与位移实测（大樱花树，缩放 0.3）

| 网格 | aWind（CUSTOM0.w，缩放前模型空间） |
| --- | --- |
| `Bark_Trunk` 低处 | 0.012（几乎不动） |
| `Bark_L1` 低处 | ≈ 0 |
| `Bark_L3` | 0.462 |
| `Bark_L4` | 0.631 |
| `Bark_L5` | 0.746（动得最明显） |
| `Leaves` | 0.900 |
| `Flowers` | 0.808 |

角色站在最低枝叶正下方时的位移量（临时探针实测）：

| 网格 | 最大位移 |
| --- | --- |
| `Bark_L5` | ≈ 0.218 m |
| `Leaves` | ≈ 0.559 m |
| `Flowers` | ≈ 0.484 m |
| `Bark_Trunk` | ≈ 0.003 m（可忽略） |

即"只扰动 L5 与叶花、树干基本不动"由 aWind 天然保证，不需要额外按节点名分支。

### 6.8 验收 / 回归

- `tests/wind_leaf_branch_sync.gd`：12/12 PASS（原有枝叶同步未受影响）。
- `tools/scan_all_scripts.gd`：413 个脚本，0 失败。
- 真实渲染（真实 Vulkan，12 帧）：0 `SHADER ERROR`。
  > 注意：headless 下如果相机没有 `current = true`、场景未被绘制，着色器**不会被编译**，
  > 这种"探针通过"是假通过；验证着色器必须用真实渲染器并让相机出图。

### 6.9 调参与已知限制

- 手感优先改 `wind.gd` 上的 `player_bend / player_spread / player_radius / player_head_height`；
  想单独调树的抬升量，改两个调用点的 `amount`（树皮 `0.45` / 叶花 `1.0`）。
- 未烘焙的树（没有 CUSTOM0/1）：树皮按 `smoothstep(1.2, 3.0, y) × 0.45` 渐入，叶片固定 0.70；
  观感可用，但没有"L5 比 L1 软"的精确差异。
- 该 include 与 `fast_tree_wind.gdshaderinc` 的位移是**相加**的：风摆 + 角色扰动同时生效，
  互不覆盖（两者都在模型空间叠加）。
- 位移只在 `vertex()` 里改顶点，不写材质参数，因此**不会**污染场景文件（与蝴蝶参数保存问题不同）。




