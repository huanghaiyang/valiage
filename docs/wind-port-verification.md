# fast-tree 风摆移植 · 独立验证报告

> 验证对象：CozyVale（Godot 4.7）把 `D:\sgames\fast-tree` 的顶点风场（`materials.js` L29-135）
> 与轨迹自检模型（`windModel.js` L46-208）逐行移植到 spatial shader + 烘焙 CUSTOM 属性。
> 判据来源：`docs/wind-port-spec.md` §4（验收标准 1–5）。
> 本报告只覆盖**验证**；测试代码全部在 `tests/wind/**`，未改任何产品代码。

---

## 0. 结论

**全部 4 层验证 PASS（38 项检查 / 0 FAIL）**，且移植实现与 JS 源实现在 60 组输入上**逐值一致**。

| 层 | 内容 | 结果 | 关键数字 |
| --- | --- | --- | --- |
| A | GDScript 移植 vs `windModel.js` 逐值等价 | **PASS** 14/14 | 60 组指标 + 12 组包络 0 差异；600 轨迹点 max\|Δ\|=4.47e-9（float32 级） |
| B | 叶尖轨迹指标（真实烘焙 CUSTOM0/1，120 叶尖 × 2400 步） | **PASS** 7/7 | azimuth 最大 1.10°；thinness 最大 0.373；spanAlong 0.0789→0.1941→0.3940 m；俯仰贡献 rmsVert +271% |
| C | `.res` CUSTOM0/1 ↔ GLB 原始 accessor | **PASS** 11/11 | 8 节点 × 200 抽样全命中；属性误差 **0**；全量 125,937/125,937 顶点可匹配 |
| D | 视觉动 / 不动（真渲染 1280×720，t=0/0.25/0.5s） | **PASS** 6/6 | 树冠变化像素 **11.10%**；树干根部 **0/1092 = 0.0000%** |

**与 spec §4 的对应：**

| spec §4 判据 | 本报告章节 | 结果 |
| --- | --- | --- |
| 1. 脚本零解析错误 / 零 shader 编译错误 | 本文各节执行日志；`tests/wind/*.gd` 均以 `--check-only` 等价方式跑通 | PASS（见各节 stdout：无 `SCRIPT ERROR` / `Parse Error`） |
| 2. 烘焙 `.res` 与 GLB accessor 一致（抽样 <1e-4，`CUSTOM1.w==1`） | §4 | PASS（属性误差 0；位置误差见 §4.3 说明） |
| 3. 轨迹自检：azimuth / thinness / spanAlong / 俯仰存在 | §2、§3 | PASS |
| 4. 视觉：树冠动、树干底部几乎不动 | §5 | PASS |
| 5. `WindSystem` 在 Inspector 可见 `@export` | 不在本任务范围（由集成方验收；本次只做数值/视觉验证） | 未覆盖（见 §7） |

---

## 1. 被测快照与环境

### 1.1 环境

| 项 | 值 |
| --- | --- |
| Godot | `Godot Engine v4.7.2.stable.official.ed1daf0bf`（`D:\godot\Godot_v4.7.2-stable_win64_console.exe`） |
| 渲染 | `Vulkan 1.4.351 - Forward+`，NVIDIA GeForce RTX 3060 Laptop GPU |
| Python | 3.11.9（仅标准库：`zlib` 手写 PNG 解码） |
| Node | v22.22.0（`tests/wind/crosscheck_windmodel.mjs` 直接 `import` 源实现，不复制公式） |
| 平台 | Windows；项目根 `D:\sgames\CozyVale` |
| 沙箱限制 | `user://` 不可写（Godot 日志写失败属环境噪音，与验证无关）；所有产物写 `res://.runtime/wind_port/` |

### 1.2 被测产物快照（本次运行时的实际文件）

| 项 | 值 |
| --- | --- |
| GLB | `assets/models/树/大樱花树.glb`，md5 `092ee50e9d740f7f3f8d8d2b3f0ce4c6`，12,115,964 B |
| 烘焙目录 | `assets/models/树/wind/`（8 个 `ArrayMesh.res`，md5 见 §4.4） |
| 着色器 | `assets/shaders/fast_tree_wind.gdshaderinc`（8,035 B），被 `tree_leaves_burn_ds.gdshader`、`tree_burn_keep_ds.gdshader` include |
| 场景 | `scenes/树/大樱花树/big_sakura_tree.tscn` 的 8 个 `MeshInstance3D` 已改为引用烘焙 `.res` |
| 烘焙工具 | `tools/bake_tree_wind.gd`（15,370 B；`CELL=0.002`、`MATCH_EPS=0.003`）——**只读，未修改** |

### 1.3 本次新增的验证代码（全部在 `tests/wind/`，未触碰产品代码）

| 文件 | 作用 |
| --- | --- |
| `wind_model_ref.gd` | A：`windModel.js` L46-208 逐行移植（`leaf_trajectory` / `motion_metrics` / `sway_envelope`）+ 参照 GLSL 的 `sample_leaf()` / `sample_leaf_at()` / `compile_wind()` |
| `crosscheck_windmodel.mjs` | A：直接 import 源 `windModel.js`，生成参照输出 |
| `crosscheck_windmodel.gd` | A：用移植实现生成同输入输出 |
| `compare_ref.py` | A：逐值比较 JS/GDScript（取整指标必须相等） |
| `test_wind_motion.gd` | B：叶尖轨迹指标（headless） |
| `glb_attrs.gd` | C：最小 GLB 读取（JSON+BIN，accessor 解码；与 bake 工具同读法） |
| `test_baked_attrs.gd` | C：`.res` ↔ GLB 属性校验（headless） |
| `wind_visual.tscn` / `wind_visual.gd` | D：树 + Camera3D + DirectionalLight3D，0.5 s 三帧截图 |
| `diff_visual.py` | D：像素差分统计（纯标准库 PNG 解码） |
| `run_headless.ps1` / `run_gui.ps1` | 复现用运行器（含超时杀进程、清理残留） |

---

## 2. A · 移植等价性（GDScript ↔ `windModel.js`）

### 2.1 方法

1. `crosscheck_windmodel.mjs` 用 `import()` 直接加载 `D:\sgames\fast-tree\src\core\windModel.js`（**源文件本体**，不抄公式），
   按固定表生成 60 组 `motionMetrics(current)` + 12 组 `swayEnvelope` + 第 1 组的 600 个**未取整**轨迹点。
2. `crosscheck_windmodel.gd` 用 `wind_model_ref.gd`（逐行移植）生成同输入的输出。
3. `compare_ref.py` 比较：源实现自己用 `toFixed` 取整，所以**取整后的指标必须完全相等**；
   未取整轨迹点允许 float32 级误差（Godot `Vector3` 是 32-bit，JS `number` 是 double）。

### 2.2 结果（`[PASS]` 全部 14 行）

| 指标 | 组数 | 不一致数 | max \|diff\| | 结果 |
| --- | --- | --- | --- | --- |
| `samples` | 60 | 0 | 0 | PASS |
| `rmsAlong` | 60 | 0 | 0 | PASS |
| `rmsPerp` | 60 | 0 | 0 | PASS |
| `rmsVert` | 60 | 0 | 0 | PASS |
| `thinness` | 60 | 0 | 0 | PASS |
| `horizontalShare` | 60 | 0 | 0 | PASS |
| `azimuthDeg` | 60 | 0 | 0 | PASS |
| `spanAlong` | 60 | 0 | 0 | PASS |
| `spanPerp` | 60 | 0 | 0 | PASS |
| `envelope.p2p` | 12 | 0 | 0 | PASS |
| `envelope.meanAlong` | 12 | 0 | 0 | PASS |
| `envelope.perpP2P` | 12 | 0 | 0 | PASS |
| 原始轨迹点（600 点 × 3 分量） | 1800 | 0 | **4.470e-09** | PASS（float32 级） |
| `windDir` / `windPerp` | 2 | 0 | 0 | PASS |

两点说明（都不是 bug）：

- **azimuth 是 `[0,180)` 模**：源公式 `(theta*180/π + 360) % 180` 会把负角映射到 `180+theta`，
  即 0° 与 180° 属于**同一条水平主轴**。比较器因此对 `azimuthDeg` 取 `min(d, 180-d)`；
  只有 1 个 case（`wind.direction=0`、`turbulence=0`、纯轴向运动）落在 180/0 的浮点回绕边界，
  两种实现的取整结果分别是 0 与 180 —— 物理上是同一根轴。
- 轨迹点 4.47e-9 的差异来自 Godot `Vector3` 为 float32，而 JS 为 double，属预期。

### 2.3 复现

```powershell
cd D:\sgames\CozyVale
node tests\wind\crosscheck_windmodel.mjs
pwsh -NoProfile -File tests\wind\run_headless.ps1 -Script res://tests/wind/crosscheck_windmodel.gd
python tests\wind\compare_ref.py
# 最后一行应为：RESULT: PASS  移植实现与 windModel.js 在上述 60 组输入上逐值一致
```

---

## 3. B · 叶尖轨迹指标（真实烘焙属性）

### 3.1 方法

- 数据源：`res://assets/models/树/wind/Leaves.res`（**MODE=baked**，实测抽到 120 个
  `CUSTOM1.w==1 && CUSTOM1.y==1` 的叶尖；`VERTEX`=叶尖位置，`CUSTOM0`=origin+aWind，`CUSTOM1`=phase/isLeaf/nodeId/baked）。
- 用 §1.3 的 `sample_leaf_at()`（**参照 GLSL 公式**，不是 `windModel.js` 的解析模型）在
  `t = i·dt`（`dt=1/60`，2400 步 = 40 s）采样轨迹，再用 `metrics_from_points()`（`windModel.js` L117-170 的逐行移植）算指标。
- 固定风场：`direction=45°`、`speed=0.8`、`frequency=1.0`、`gust=0.35`、`gust_speed=0.16`、
  `turbulence=0.12`、`bias=0.3`、`force=0.15 m`、`spatial_scale=0.22`、`flex_falloff=1.5`、
  `sway=1.0`、`leaf_flutter=0.6`、`leaf_twist=0.5`。

### 3.2 结果（7/7 PASS，`MODE=baked tips=120 steps=2400 dt=0.016667`）

| 断言 | 期望 | 实际 | 结果 |
| --- | --- | --- | --- |
| `azimuth_consistency` | max \|az − wind.dir\| ≤ 3°（180° 模） | max **1.10°**，mean 0.32°（n=120，dir=45°） | PASS |
| `azimuth_sweep` | 6 个风向各自 max ≤ 3° | max **1.40°**；0°:1.20 / 30°:1.10 / 90°:1.40 / 135°:1.40 / 200°:1.40 / 315°:1.30（每方向 40 叶尖） | PASS |
| `thinness` | max thinness ≤ 0.45 | max **0.373**，mean 0.259（n=120） | PASS |
| `horizontal_share` | mean ≥ 0.70（方向看得见） | mean **0.896**，min 0.426 | PASS |
| `force_monotonic` | spanAlong 随 `wind_force` 严格单调增 | `f=0.05: 0.0789 m` → `f=0.15: 0.1941 m` → `f=0.30: 0.3940 m`（≈ 线性，2.5×/2.0×） | PASS |
| `pitch_active` | 关掉铰链俯仰后轨迹指标明显改变（rmsVert ≥10%） | rmsVert **0.014152 → 0.003816（−73%，即相对 +271%）**；spanAlong 0.194109→0.152273（+27.5%）；spanPerp/rmsPerp **0.0%**（见下） | PASS |
| `flex_monotonic` | 同一叶片 aWind 越大位移越大（取平均），ratio>1.2 | RMS 位移 0.02456 / 0.02739 / 0.03250 / 0.03995 / 0.04962 / 0.05526 m（aWind=0.1…1.0），**ratio(1.0/0.1)=2.25**，逐档严格递增 | PASS |

关于 `pitch_active` 的两个数字，正好验证了算法结构（不是巧合）：

- 俯仰是**绕 `windPerp` 水平轴**的旋转，该轴上的分量在旋转中不变 ⇒ `rmsPerp`/`spanPerp` 变化恰为 **0.0%**；
- 旋转把"顺风↔竖直"平面内的分量来回翻 ⇒ `rmsVert` 与 `spanAlong` 显著变化。
  这正是 `docs/wind-port-spec.md` §0.2「只有弯曲 + 固定水平轴铰链俯仰、没有绕垂直轴自转」的结构性证据。
- "关掉俯仰"用的是**源实现自己的参数** `leaf_twist=0`（此时 `pitch ≡ 0`），没有给移植代码加任何私货开关。

`thinness` 的物理含义是"横向 RMS / 顺风 RMS"，0.373 表示最差的叶片轨迹也远未各向同性（不是绕圈）。

### 3.3 复现

```powershell
cd D:\sgames\CozyVale
pwsh -NoProfile -File tests\wind\run_headless.ps1 -Script res://tests/wind/test_wind_motion.gd -TimeoutSec 400
# 末行应为：RESULT: PASS  (7/7 assertions passed)
```

> 若 `assets/models/树/wind/Leaves.res` 不存在，脚本会自动回退到**合成属性**（固定种子、叶柄距 0.08–0.35 m）
> 跑同一套断言，并在日志里打印 `MODE=synthetic`。本次最终运行用的是真实烘焙数据。

---

## 4. C · 烘焙属性校验（`.res` ↔ GLB accessor）

### 4.1 方法

- 用 `tests/wind/glb_attrs.gd` 直接读 GLB 二进制（`JSON.parse_string` + BIN chunk + accessor 解码），
  取每个节点的 `POSITION / _AWIND / _APHASE / _AORIGIN / _ANODEID`（本 GLB 每个 mesh 只有 1 个 primitive，已核对）。
- 用**与 `tools/bake_tree_wind.gd` 完全相同的匹配逻辑**把 `.res` 顶点匹配回 GLB 顶点：
  `CELL=0.002` 分格（`floor`）→ 本格 + 26 邻格 → 取最近 → 容差 `MATCH_EPS=0.003 m`。
  （**不能用 1e-4 精确 key**：Godot 4.7 导入叶/花时压缩了顶点属性，见 §4.3。）
- 每个节点抽样 200 个顶点逐项比较；另外做了**全量**匹配统计（125,937 个顶点全部遍历）。

### 4.2 结果（11/11 PASS）

| 断言 | 期望 | 实际 | 结果 |
| --- | --- | --- | --- |
| `nodes_present` | GLB 含 8 个节点 | 8/8 | PASS |
| `res_present` | 8 个 `.res` 都在 | 8/8 | PASS |
| `sample_match` | 每节点 200 抽样全部命中 | 8 × 200 = 1600/1600 | PASS |
| `pos_roundtrip` | max \|Δpos\| ≤ 3e-3 m | **7.18e-4 m**（叶/花；树皮 0） | PASS |
| `pos_exact_bark` | 树皮位置位级一致 | max = **0 m** | PASS |
| `full_coverage` | 所有 `.res` 顶点都能匹配回 GLB | **125,937 / 125,937 = 100.0000%** | PASS |
| `attr_error` | aWind/phase/origin/nodeId 误差 < 1e-4 | **max = 0**（逐位相等） | PASS |
| `baked_flag` | `CUSTOM1.w == 1` | 1600/1600 全为 1 | PASS |
| `is_leaf_flags` | Leaves/Flowers=1；其余=0 | 符合 | PASS |
| `custom_format` | surface 声明 CUSTOM0/CUSTOM1 通道 | 符合（8/8 节点 1 surface） | PASS |
| `scene_wiring` | 场景 8 个 `MeshInstance3D` 都指向 `wind/<节点>.res` | 符合（只读检查 `big_sakura_tree.tscn`） | PASS |

### 4.3 关于"位置往返误差为 0"的说明（**重要，不是缺陷**）

任务原话要求"位置往返误差为 0"。实测：

- **6 个树皮节点（共 18,417 个顶点）位置位级一致，误差 = 0**；
- **Leaves 6.38e-4 m / Flowers 7.18e-4 m**，不为 0。

原因已在 `tools/bake_tree_wind.gd` L37-44 写明并被本次数据独立复现：
Godot 4.7 的 glTF 导入对这两个网格启用了顶点属性压缩（`ARRAY_FLAG_COMPRESS_ATTRIBUTES`，16-bit 归一化），
**导入后的 Godot 顶点坐标本身就不再是 GLB 的 float32 原值**（~5e-4 m 量化误差）。
因此 bake 工具才改用"2 mm 分格 + 邻格最近 + 3e-3 容差"。本验证把该判据写成 ≤ `MATCH_EPS`，并额外证明：

- 属性（aWind/phase/origin/nodeId）误差 **严格为 0** —— 说明匹配到的就是正确的 GLB 顶点；
- 全量 125,937 个顶点 **100%** 可匹配，没有落进 bake 的兜底分支；
- 树皮 6 节点位置 **严格为 0**，说明"非 0"确实只来自导入压缩，而不是烘焙逻辑。

若要"字面 0"，需在 GLB 导入设置里关掉顶点压缩并重导 —— 会影响全项目网格，**不在本移植范围**，也不建议为此改。

### 4.4 逐节点明细（含产物指纹，便于复算）

| 节点 | surface | .res 顶点 | GLB 顶点 | 抽样 | 全量匹配 | max\|Δpos\| | max\|Δattr\| | isLeaf | .res md5 | .res 字节 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Bark_Trunk | 1 | 291 | 291 | 200 | 291/291 | 0 | 0 | 0 | `0093b577…` | 65,571 |
| Bark_Branch_L1 | 1 | 941 | 941 | 200 | 941/941 | 0 | 0 | 0 | `b782260b…` | 113,795 |
| Bark_Branch_L2 | 1 | 2,765 | 2,765 | 200 | 2,765/2,765 | 0 | 0 | 0 | `854cbf73…` | 248,363 |
| Bark_Branch_L3 | 1 | 6,580 | 6,580 | 200 | 6,580/6,580 | 0 | 0 | 0 | `253af4e0…` | 525,283 |
| Bark_Branch_L4 | 1 | 4,200 | 4,200 | 200 | 4,200/4,200 | 0 | 0 | 0 | `81f511e4…` | 347,763 |
| Bark_Branch_L5 | 1 | 3,640 | 3,640 | 200 | 3,640/3,640 | 0 | 0 | 0 | `ffe8bb84…` | 306,883 |
| Leaves | 1 | 26,880 | 26,880 | 200 | 26,880/26,880 | 6.38e-4 | 0 | 1 | `c29b6b2e…` | 1,883,637 |
| Flowers | 1 | 80,640 | 80,640 | 200 | 80,640/80,640 | 7.18e-4 | 0 | 1 | `8e8deb0e…` | 5,929,096 |

（完整 md5 见 `.runtime/wind_port/baked_attrs.json`。）

### 4.5 复现

```powershell
cd D:\sgames\CozyVale
pwsh -NoProfile -File tests\wind\run_headless.ps1 -Script res://tests/wind/test_baked_attrs.gd -TimeoutSec 300
# 末行应为：RESULT: PASS  (11/11 assertions passed)
```

---

## 5. D · 视觉动 / 不动证据（真渲染）

### 5.1 场景与固定参数

`tests/wind/wind_visual.tscn` = `big_sakura_tree` 实例 + `Camera3D` + `DirectionalLight3D` + `WorldEnvironment`
+ 脚本 `wind_visual.gd`。脚本：

1. 遍历树的全部 `ShaderMaterial`（树皮 1 个 + 叶/花 2 个，树冠分块后仍共用同一实例，去重后 3 个）；
2. 写入**固定**风参（不读 Weather / 不读 `wind.gd`，保证可复现）：

   | uniform | 值 |
   | --- | --- |
   | `wind_enabled` | `true` |
   | `wind_direction` | `Vector2(0.866, 0.5)`（30°） |
   | `wind_force` | `0.5` m（可视化放大，便于像素差分） |
   | `wind_speed` / `wind_frequency` | `1.4` / `1.0` |
   | `wind_gust` / `wind_turbulence` | `0.2` / `0.25` |
   | `wind_gust_speed` / `wind_spatial_scale` | `0.16` / `0.22` |
   | `wind_bias` / `wind_flex_falloff` | `0.3` / `1.5` |
   | 树皮材质 | `wind_is_leaf=false, wind_sway=0.8` |
   | 叶/花材质 | `wind_is_leaf=true, wind_sway=1.0, wind_leaf_flutter=0.6, wind_leaf_twist=0.5` |

3. 相机按树 AABB 解析取景（`distance=34.14`，`fov=55`，1280×720）：树几乎撑满画面，树冠在上半部、树干根部在 y≈82–86% 处；
4. 着色器动画时钟是**内置 `TIME`**（include 里没有自定义 time uniform），所以按**真实经过时间**截帧：
   `t=0.016 s / 0.257 s / 0.508 s`（帧轮询等到目标时刻 + `await RenderingServer.frame_post_draw`）。
5. 关掉 `DirectionalLight3D.shadow_enabled`：树冠摆动投到树干上的**阴影变化**会把"树干没动"搅浑，本次只验证几何位移。

产物：`.runtime/wind_port/shots/t0.png`、`t0_25.png`、`t0_5.png`（1280×720）。

### 5.2 像素差分结果（`tests/wind/diff_visual.py`，阈值：单通道差 > 6 记为变化像素）

区域定义：

- **树冠** = 图像上半部 `y ∈ [0, 360)`，全宽（树冠主体都在这里，含少量天空，属于保守估计）；
- **树干根部** = `x ∈ [0.47w, 0.56w)`、`y ∈ [0.78h, 0.88h)` 内的**深色树皮像素**（RGB max ≤ 70）。
  用颜色把树干从旁边会摆动的红叶/天空里分离出来，避免区域混入叶子（否则会把"树干"测成 4%）；
  本取景下树干根部实际位于 x≈636–686、y≈588–618，该掩码共 **1092 px**。

| 图对 | 树冠变化像素 | 树干根部变化像素 | 树冠/树干 |
| --- | --- | --- | --- |
| `t0` vs `t0_25`（0.25 s） | **46,923 / 442,440 = 10.6055%**（mean\|Δ\|=5.288） | **0 / 1,092 = 0.0000%**（mean\|Δ\|=0.011） | ∞ |
| `t0` vs `t0_5`（0.5 s） | **49,119 / 442,440 = 11.1018%**（mean\|Δ\|=5.786） | **0 / 1,092 = 0.0000%**（mean\|Δ\|=0.013） | ∞ |

变化像素 bbox：`x[380..929] y[79..719]`，**y 中位数 ≈ 399**（≈ 图像 55%）—— 变化集中在树冠及其下方的垂枝，
树干根部区域**一个像素都没变**。

### 5.3 断言（6/6 PASS）

| 断言 | 期望 | 实际 | 结果 |
| --- | --- | --- | --- |
| `images_render` | 三帧都是有效渲染 | 1280×720，非空（亮度 std ≈ 29） | PASS |
| `canopy_moves_0.5s` | 树冠差异像素占比 ≥ 1% | **11.1018%** | PASS |
| `canopy_moves_0.25s` | 0.25 s 树冠差异 ≥ 0.5% | **10.6055%** | PASS |
| `canopy_dominant` | 树冠/树干差异比 ≥ 5 | **∞**（树干 0 变化） | PASS |
| `trunk_static` | 树干根部差异 ≤ 0.5% | **0.0000%**（0/1092） | PASS |
| `bark_sample_size` | 树皮像素样本 ≥ 200 | 1,092 px | PASS |

补充：运动中的树冠变化 11.1% 与集成方独立截图（`shots/anim_*`）测得的 ~17.9% 同一量级
（机位/风参/时间窗不同，不可逐值比较）。

### 5.4 复现

```powershell
cd D:\sgames\CozyVale
pwsh -NoProfile -File tests\wind\run_gui.ps1          # 非 headless！内部会先 sleep 3s 清残留进程
python tests\wind\diff_visual.py
# 末行应为：RESULT: PASS  (6/6 checks passed)
```

> ⚠ `--headless` 下是 dummy 渲染器，`get_viewport().get_texture().get_image()` 拿不到画面；
> 脚本检测到 headless 会直接报错退出（exit 2）。连续启动两个窗口化 Godot 偶发 exit 1，
> `run_gui.ps1` 已在启动前清残留进程并 sleep 3 s。

---

## 6. 一键复现（完整顺序）

```powershell
cd D:\sgames\CozyVale
# A · 移植等价
node tests\wind\crosscheck_windmodel.mjs
pwsh -NoProfile -File tests\wind\run_headless.ps1 -Script res://tests/wind/crosscheck_windmodel.gd
python tests\wind\compare_ref.py

# B · 轨迹指标
pwsh -NoProfile -File tests\wind\run_headless.ps1 -Script res://tests/wind/test_wind_motion.gd -TimeoutSec 400

# C · 烘焙属性
pwsh -NoProfile -File tests\wind\run_headless.ps1 -Script res://tests/wind/test_baked_attrs.gd -TimeoutSec 300

# D · 视觉（必须非 headless）
pwsh -NoProfile -File tests\wind\run_gui.ps1
python tests\wind\diff_visual.py
```

产物（均在 `res://.runtime/wind_port/`，不进版本库）：

| 文件 | 内容 |
| --- | --- |
| `js_ref.json` / `gd_ref.json` | A 的 JS / GDScript 参照输出 |
| `motion_results.json` | B 的断言表 + 逐项细节 |
| `baked_attrs.json` | C 的逐节点明细（含 `.res` md5/size） |
| `shots/t0.png`、`t0_25.png`、`t0_5.png` | D 的三帧截图 |
| `visual_diff.json` | D 的像素差分统计 |
| `compare_ref.log` / `visual_diff.log` | 上述两次 python 的完整输出 |

判读方式：**以各脚本最后一行 `RESULT:` 为准**。Godot 的 console 包装器有时不回传 exit code
（日志里 `exited code=` 为空），但 `quit(1)` 与断言表一致，不影响判读。

---

## 7. 未覆盖 / 已知限制

1. **GPU 着色器位移没有逐顶点对照 CPU 参照**。D 只证明"树冠在动、树干不动、方向/量级合理"，
   没有做"取一个已知顶点、把 shader 输出读回来与 `sample_leaf()` 比较"的像素级等价测试
   （Godot 没有便宜的顶点回读路径）。CPU 侧等价性由 A 证明，shader 侧一致性靠"逐行移植 + 视觉"间接保证。
2. **视觉截图不满足逐次可复现的相位**：动画时钟是内置 `TIME`（墙钟），每次运行的相位不同，
   所以树冠变化占比会在 ~10–12% 间小幅波动；结论（树冠 ≫ 树干）稳定。
3. **视觉测试固定了风参、绕过了 `wind.gd`**：`wind.gd` 每帧写 uniform 的集成链路（以及 Inspector 可调性）
   不在本任务范围，由集成方验收；本次直接把 uniform 写到材质，隔离了上游变量。
4. **只测了 `big_sakura_tree` 一棵树**。回退路径（`CUSTOM1.w < 0.5`，其它树/灌木）未做数值验证，
   但集成方的静态回归（新旧着色器同机位像素差 0）已覆盖"观感不变"。
5. **A 只移植了 `current` 分支**；`legacy` 是历史对照版本、产品不用（传入会明确报错）。生长动画
   `aGrow/uGrowth` 与节点选中 `uSelectMode` 与本移植无关，未移植（见 `wind_model_ref.gd` 头注释）。
6. **C 依赖"每个 mesh 只有 1 个 primitive"**：本 GLB 已核对 8/8 都是 1；若将来多 primitive，
   `glb_attrs.gd` 与 bake 工具都只读 `primitives[0]`，需要同步扩展。
7. **`位置往返误差 = 0` 只对树皮成立**；叶/花为 6.38e-4 / 7.18e-4 m，来源是 Godot 导入压缩（详见 §4.3），
   判据取 bake 自己的 `MATCH_EPS=3e-3`。
8. **环境噪音**：`user://` 在沙箱不可写 → Godot 每次启动打印若干 `Failed to open user://logs/...`；
   `VitalsHud` autoload 在截图上留了左下角 HUD（不在测量区域内）。二者与风摆无关。
9. 树冠中央的白色网格状斑点（`depth_prepass_alpha` + 花材质 alpha 抖动）是**改动前既有现象**，
   集成方静态对比已证明像素完全一致，本次不在范围内。
10. 本报告未验证 spec §3 的 `WindSystem` 节点改造（autoload → 场景节点、`@export` 可见），
    只验证了风摆算法/数据/视觉三层。

---

## 8. 附：本次运行的断言总数

| 层 | 检查项 | PASS | FAIL |
| --- | --- | --- | --- |
| A（compare_ref.py） | 14 | 14 | 0 |
| B（test_wind_motion.gd） | 7 | 7 | 0 |
| C（test_baked_attrs.gd） | 11 | 11 | 0 |
| D（diff_visual.py） | 6 | 6 | 0 |
| **合计** | **38** | **38** | **0** |

运行日志：`.runtime/wind_port/test_wind_motion_out.txt`、`test_baked_attrs_out.txt`、`visual_out.txt`、
`compare_ref.log`、`visual_diff.log`。

---

## 8. Lead 追加（2026-10-22 晚）：抖动频率"去同步化"

> 本报告 §2–§5 验证的是 **fast-tree 源公式的逐位移植**（里程碑快照）。之后根据用户反馈
> 「树叶/花朵/果实的抖动频率一致，观感较差」追加了一处**刻意增强**，不改变已通过的等价性结论
> （增强可用参数关掉，回到逐位等价）：

- 源实现里所有元素共用同一个抖动频率（`uWindFrequency` / `uWindSpeed` 是全局 uniform），
  只靠 `aPhase` 错开**相位**；在 3360 片叶 + 10080 朵花（实测元素数）的规模下，会呈现"整片同频振动"。
- 增强：每个元素（每叶/每花/每枝，由烘焙 `aPhase + nodeId` 唯一决定）获得稳定的频率/幅度微差：
  - `wind_variation`（默认 0.45）：局部抖动（弯曲/俯仰）的频率与幅度微差；
  - `wind_sway_variation`（默认 0.15）：刚性主波**次级项**的频率微差（主项保持同频，避免叶片相对枝条漂移）；
  - 材质级 `wind_flutter_rate`：叶 1.10 / 花 0.72，让树叶与花朵不再同频。
- `wind_variation = wind_sway_variation = 0` 且 `wind_flutter_rate = 1` 时，计算与 §2 验证的源实现逐位一致。
- 新增回归：`tests/wind_freq_diversity.gd` → `RESULT: PASS (10/10)`：
  叶片频率跨度 0.605–1.594（max/min 2.63）、标准差 0.283、花/叶均值比 0.658、
  2725/3360 元素有独立频率、同一元素内部频率不一致数 0（叶卡不会被撕开）。
- 静态外观未受影响：新旧着色器 `wind_enabled=false` 同机位全图像素差仍为 `mean=0.00000 / max=0.0000`。
