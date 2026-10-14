# FluidNinja（UE 插件）实现调研 —— 以及我们能抄什么

> 调研对象：**FluidNinja LIVE / LIVE-2**（作者 Andras Ketzer，UE Marketplace 付费插件）。
> 本机没有安装（只找到 `D:\ninja`，那是 C++ 的 **Ninja 构建工具**源码，与 FluidNinja 无关），
> UE 5.7 引擎里也没有该插件。因此本调研依据是**官方文档站与参数描述符**（公开、且细到参数级）。
>
> 资料：
> - [FluidNinja LIVE-2 官方文档](https://majorsmash.github.io/fnl-docs-v2/manual/ninjalive2-manual/)
> - [参数描述符（323 个组件参数）](https://majorsmash.github.io/fnl-docs-v2/descriptors/ninjalive2-params/)
> - [参数速查（可搜索）](https://majorsmash.github.io/fnl-docs-v2/parameters/)
> - [80.lv：LIVE 1.9.53 体渲染更新报道](https://80.lv/articles/fluidninja-live-gets-updated-volumetric-support-for-unreal-engine-5-3)
>
> **关于"扒源码"**：FluidNinja 是**闭源付费**插件，交付物是 `.uasset`（材质/Niagara 系统）而非 C++ 源码，
> 也没有官方公开仓库，所以没有"源码"可读。它的**参数描述符 + 手册就是它的规格说明**——
> 我按这个来还原实现思路。技术本身是公开的成熟做法（Stable Fluids 稳定流体 + flowmap + UE 原生体渲染），
> 我们完全可以自己实现等价物。

---

## 1. 架构（三层包装）

```
NinjaLiveCore (Niagara System)      ← GPU 仿真核心：网格 2D 仿真 + 压力求解，写入 RenderTarget
   ↑ 被包装
NinjaLive Component (323 参数)      ← 输入收集、仿真参数、输出渲染器
   ↑ 可选再包
NinjaLive Actor   (24 参数)         ← 场景交互收集（骨骼/网格/破坏物）
```

参数组的主序就是数据流：**Input（G.3/G.4）→ Simulation（G.5）→ Output（G.6~G.10）**。

## 2. 核心事实：**它是 2D 仿真**

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `ResolutionX/Y` | 256 × 256 | 仿真与 paint buffer 的分辨率（**2D 网格**） |
| `ExtentsXYZ` | (5,5,1) m | X,Y = 仿真区域；**Z 与仿真无关**，只决定"交互体积"的高度 |
| `SimSpeed` | 1 | *"faux method"*：靠**加大邻域采样距离**假装更快，而不是做子帧 |

文档原文（`ExtentsXYZ`）：*"ninja is a 2D simulation … The Z part of ExtentsXYZ is irrelevant for the sim area"*。

**结论：它的"3D"全部来自渲染层的挤出与光照，不是 3D 求解。** 这与我们当前 CozyVale 的实现
（2D NS + 渲染层）**架构一致** —— 我们没走错路，差的是渲染与输入这两层的完成度。

## 3. 仿真的数据布局（从输出 RT 参数反推）

`LiveOutputRenderTargets` 组直接暴露了求解器的中间量：

| RenderTarget | 含义 | 我们的对应物 |
| --- | --- | --- |
| `PaintVelocityDensityAndElevation` | 输入累积（paint buffer）+ 高度 | `FogBrushField` + 笔刷源 |
| `SimVelocityDensityAndWetmap` | 仿真后速度(RG)/密度/湿度 | 我们的 `gradient` / `composite` 通道 |
| `SimPressureDivergence` | **压力与散度** | 我们的 `jacobi_*` / `divergence` 通道 |
| `Pressure.EnableCrudePressureSolver` | 廉价压力求解（质量换速度） | 我们的 `jacobi_passes` 档位 |

→ 它跑的是**同一套 Stam 式投影法**（散度 → 压力泊松 → 减梯度）。我们不仅架构相同，
连中间量都几乎一一对应。

## 4. 输入层：交互是怎么做的（这是他们真正的强项）

分两类，**这就是"物体推动流体"的正解**：

**(a) 点状输入**（`LiveInputPoints`）：粒子、骨骼、物体 pivot、Unreal Data Channel。
- 上限 `MaxInteractionsPerSimArea = 16000` 点/帧
- **空间哈希网格**：`NeighborCellNumberXY = 16×16`（默认"每米一格"），
  每个仿真 texel 只处理**邻近格子**里的点 —— 否则每格都要遍历所有点
- 笔刷修饰：`BrushKillers`（按 Z 高度淡出笔刷 —— 脚踩地面才留痕）、`BrushNoise`、`BrushVelocity`
- `FadeBrushByZPos`：离地越近笔刷越强

**(b) 场状输入**（`LiveInputFields`）：**Mesh Distance Field（网格 SDF）**、高度图/RVT、Spline、Bitmap。
- `EnableMeshDistanceFieldReader` + `DistanceFieldMult` / `ContourMult` / `MeshVelocityMult` /
  `OutwardVelocityMult` / `ZvelocityMult`
- 即：**用物体的符号距离场把流体"挤开"**，还带法向速度与"外推速度" —— 比我们现在的点状 splat 高级一档
- 性能取舍：`FieldBufferDownScaleFactor = 4`（SDF 缓冲四分之一分辨率）、
  `PaintBufferDownScaleFactor = 2`

## 5. 渲染层（我们要抄的部分）

### 5.1 体渲染：统一 Volume 函数驱动 UE 三种原生体
LIVE 1.9.53 起用**一个通用 volume 函数**同时驱动 CVOL/FVOL/**HVOL（异质体）**，特性列表（官方）：

- Local / World 空间 UVW 变换
- **"Extruded and cross-section-based 3D density"** —— 2D 场**挤出**成 3D 密度（+截面剖面）
- **两个独立噪声混合器**
- **Velocity-based Flowmapping**（用速度场流动贴图 —— 关键）
- 高度图做表面对齐
- 环境光与 AO
- 按高度 / 相机距离 / 体积边界淡出
- **BlackBody 温度函数从密度出发做自发光**（火/余烬感的来源）
- 极坐标映射

### 5.2 内部 / 外部渲染器
- `LiveOutputInternalRenderers`：`Mesh`、**`HVolume`**、**`SVolume`（烟体）**、`FVolume`
  - 渲染体积的 Z 尺寸与交互体积**分开**：`HVolumeExtentsZ` / `FVolumeExtentsZ`
  - 文档举的例子：交互体积 Z = 5 cm（只有脚附近才留痕），渲染体积 Z = 50 cm（尘土扬得高）
- `LiveOutputExternalRenderers`：把场输出给外部材质/系统
- `LiveLegacy`：**`RayMarching` + `SlowPostProcessSwitch`** —— 他们的旧方案就是
  屏幕空间光线步进（≈ 我们那个被否掉的包围盒），现已被原生体渲染取代

### 5.3 只有 2D 场，为什么不像"一张片"
`CameraFacing` / `CamFaceBillboard`：**把仿真平面转向相机**，让玩家永远垂直看它；
并建议配合**立方交互体积**（如 5,5,5）以便平面前后的点也能参与。

## 6. 性能策略（可直接抄）

| 手段 | 参数 | 我们的对应做法 |
| --- | --- | --- |
| 输入缓冲降分辨率 | Paint ×2、Field ×4 | 笔刷底图 96² 已远低于模拟 96²（可再拆） |
| 不做子帧，改采样距离 | `SimSpeed` | 未实现（我们靠 `velocity_dissipation` 控手感） |
| 不可见就暂停 | `PauseSimWhenNotVisible` + `WaitBeforePause` | 已有 `enabled` 开关（可加"最近渲染过"判定） |
| 距离 LOD 降采样率 | 60 → 30 FPS | 已有 `apply_quality(tier)` |
| 廉价压力求解 | `EnableCrudePressureSolver` | 已有 `jacobi_passes` 档位 |
| 空间哈希限制输入量 | `NeighborCellNumberXY` | 我们的交互体扫描未做空间分桶（点多时要做） |

---

## 7. 差距清单：为什么我们的观感还不到参考图

按"抄得来 + 收益大"排序：

| # | FluidNinja 有、我们没有 | 直接后果 | Godot 实现路径 |
| --- | --- | --- | --- |
| 1 | **Flowmapping**（噪声/贴图被速度场**流动**） | 我们的烟只是"整体平移"，看不出被**拉伸/折叠** | 粒子/体积采样噪声时，UV 用速度场做一阶回溯：`uv -= flow(uv) * dt * k`，**几行代码** |
| 2 | **BlackBody 自发光**（密度→温度→颜色） | 参考图里的"热核/余烬"缺一层 | 在着色器里加一条 BlackBody 近似曲线，密度高→黄白、低→暗红 |
| 3 | **Mesh SDF 推动流体** | 我们的交互是点状 splat，物体**不排开**流体 | Godot 无 mesh SDF，但可用**解析 SDF**（球/胶囊/盒）在 GPU 侧挖洞+推速度，等价于小物体交互 |
| 4 | **两个独立噪声混合器** | 我们的两层噪声是同一张贴图不同缩放，形态偏单一 | 用两张不同频率/不同滚动的噪声（或 2D+3D 各一），各自独立流动 |
| 5 | **剖面积分（cross-section）** | 我们的高度剖面是纯 pow，缺少"越往上越碎" | 高度 → 噪声门限（高处更容易被裁掉），即"截面随高度变化" |
| 6 | 表面对齐（高度图） | 烟不贴着地形起伏 | Godot 有 `depth_tex`，可用**深度缓冲重建的地形高度**做纵向截断 |
| 7 | 空间哈希（点输入分桶） | 交互体一多就 O(格×点) | 我们目前每帧只扫组（≤几十个），暂不需要 |

## 8. 结论与建议

1. **架构不用推翻**：FluidNinja 同样是 2D 求解 + 渲染层造 3D。我们已经在这条路上。
2. **"不要包围盒"可以满足，但要知道代价**：FluidNinja 的现代体渲染用的就是**原生体积
   （异质体/雾体）——本质上仍是"一个盒子里参加介质"**；它的旧方案才是屏幕空间 raymarch。
   所以"盒子"本身不是错，问题在于**盒子的观感**（边缘、剖面、光照）。
   我们改成**纯粒子**是可行的另一条路（FluidNinja 也有 `NinjaSpawner` 粒子路线），
   但纯粒子要达到参考画的密度与层次，需要 **#1 flowmap + #4 双噪声 + 更高的粒子数与加法高光层**。
3. **最该先抄的三件事**（都不需要 3D 求解器）：
   - **Flowmapping**（#1）—— 让烟"被吹动/被拉扯"而不是平移；
   - **BlackBody 自发光**（#2）—— 参考图的热源质感；
   - **解析 SDF 交互**（#3）—— 物体真正排开烟。
4. 若之后还想要参考图那种**湍流团块**，再上分层 3D 场驱动粒子出生/消亡；
   那是"超出 FluidNinja"的部分（它靠美术调参 + 高质量噪声掩盖 2D 的局限）。
