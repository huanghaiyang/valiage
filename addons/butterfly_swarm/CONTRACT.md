# 蝴蝶飞舞插件 —— 接口契约（先冻结接口，再并行实现）

> 本文件是并行开发的**唯一口径**。任何一方要改接口，必须先改这里并通知对方。
> 锁定日期：本次开发。宿主：Godot 4.7.2（`D:\godot\Godot_v4.7.2-stable_win64_console.exe`）。

## 0. 已实测的事实（不要再猜）

| 事实 | 证据 |
| --- | --- |
| 20 张蝴蝶图**本身就是真透明底**，不需要抠白 | `corner_a=0.00`，`alpha=true`（`.runtime/butterfly_probe.gd` 实跑） |
| 每张图不透明区域占比不同：宽 0.74~0.90、高 0.74~0.95 | 同上，逐图 bbox |
| 蝶身横轴**不统一**（0.46~0.56，受单侧翅行包络影响） | 同上；因此**折叠轴用「不透明包围盒的水平中心」**，不用全图中心 |
| 图片是「正面展开的蝴蝶」：x = 沿翅展方向（左翅→右翅），y = 头→尾方向 | 肉眼看图（1186×802 的闪蝶） |
| **素材颜色不止一种**：蝴蝶-01 是蓝（源均值 0.176/0.438/0.730），蝴蝶-02 是**棕橙**（0.576/0.339/0.143），蝴蝶-03 偏亮（0.965/0.890/0.913） | `.runtime/bfly_uv_check.gd` 逐张统计；渲染均值与源均值逐张吻合（差异 <0.1） |
| 渲染是**忠实的**（没有系统性偏色） | 同上：渲染均值 vs 源 PNG 均值逐张对齐 |
| `Texture2D.get_image()` 在 BPTC/ETC2 导入下**不可信**（导入器补 2px 边 + 边缘全不透明 + 抽样 19550 点不符） | `.runtime/bfly_tex_vs_raw.gd` |
| `PackedScene.pack()` 只序列化 `owner == root` 的节点；不设 owner 会**静默保存出空场景** | 生成 demo 场景时实测（.tscn 里只剩一行根节点，而 `ResourceSaver.save()` 返回 OK） |
| `Mesh.ARRAY_CUSTOM0` 必须是 `PackedByteArray`；传 `PackedFloat32Array` 会让**整个 surface 建不出来**（`surface_count=0`，蝴蝶完全不可见且不报错） | `.runtime/bfly_mesh_diag.gd` 二分实测 |
| `Weather` 是 autoload；风系统是**场景内节点** `WindSystem`（分组 `wind_system`，旧版 `Wind` autoload 已移除），风是**独立可调维度** | `project.godot` [autoload]；`scripts/world/weather.gd`；`scenes/main.tscn`；`scripts/wind.gd` |
| Godot 4.7 下 `global_shader_parameter_*` 是坏的 | `scripts/wind.gd` 头注释 L10-13，本仓库已实测 |
| Godot 4.7 spatial shader 的顶点输出是**视图空间**，没有 `MODEL_MATRIX` | `scripts/wind.gd` 同源结论 + 着色器惯例；故折叠全部在**纹理空间/局部空间**解析算，不依赖 MODEL_MATRIX |

## 1. 坐标系与「居中折叠」的定义（核心，别改）

单个蝴蝶的**局部空间**（`Butterfly` 节点自身坐标系）：

```
        +Y  = 蝴蝶「头→尾」方向的**向后**（纹理 up = +Y）
         ^
         |
  -X <---+---> +X     +X = 纹理 +u 方向（翅尖一侧）
        / \
       /   \          翅面初始躺在 XZ 平面，法线 = +Z
      +Z = 额面法线（折叠后 -X 侧朝 +Z 折出，+X 侧朝 -Z 折出）
```

* 翅面初始：`p = (x, y, 0)`，`x,y ∈ [-0.5, 0.5]`（单位方块，缩放交给节点 `scale`）。
* **折叠轴 = 体轴 = 局部 +Y（头尾方向）**，折缝在 `x = 0`：
  * `θ = rad(dihedral)`
  * `x > 0` 一侧（右翅）：绕 **+Y** 转 `-θ`
  * `x < 0` 一侧（左翅）：绕 **+Y** 转 `+θ`
  * 结果：两翅尖都朝 **+Y** 抬起（并各自向 ∓Z 折出），形成「书脊朝下、双翅上举的 V」。
* `fold_dz`（额外前后折出量，米）：`z += fold_dz * x`（右翅向前 +Z、左翅向后 -Z）
* `bend_y`（翅面沿头尾方向的弯拱）：`z += bend_y * y * y`
* `flutter_u` / `flutter_v`：`x *= flutter_u`、`y *= flutter_v`（~1.0 ± 0.05，扑翼的形变感）

> **为什么是 +Y（体轴），以及为什么"改成 +Z"是个错（2026 三次修订的完整留痕）**：
> 1. 羽化后的头尾方向在本地空间就是 **Y**（纹理 up = +Y，GDScript 侧把飞行方向定成 -Z）。
>    绕 **Y** 转，翅面才会**离开原平面**、获得真实前后厚度 —— 这才是 3D 的 V 形折缝。
> 2. 中途曾以"绕 +Y 侧视会变成竖条"为理由改成绕 **+Z**，**那个改动是错的**（已回退）：
>    绕 +Z 是**平面内自转**（`z` 分量原样保留）⇒ 整块网格永远**共面于 z=0**，
>    **从任何视角都不可能出现 V 形折缝**，两片翅还会在身体附近共面交叉；
>    且法线的 z 分量恒为 0 ⇒ 法线**切于自身表面**，方向光打上去一片平光。
>    （真机实拍复核：折缝拍不到、翅面呈交叉刀片状。）
> 3. 侧视变窄是**真实的物理现象**：真实蝴蝶从正侧方看本来就窄（翅面近乎侧对镜头）。
>    要缓解观感应当另想办法（例如"限制最小侧视角"之类），**不要**靠把折叠改成平面内自转来"解决"。
>
> 为什么要折叠：素材是**正面展开图**，直接贴平面就是一块纸片。按上述折叠后，
> 侧视/斜视时它呈现真实的「V 形双翅」轮廓，正视时又回落到原图轮廓。

### ★★★ 体积感三件套（"蝴蝶像纸片"的正解）★★★

一片零厚度的平面，无论怎么折都只是**一张纸**：正视一片均匀色、侧视一条线、掠射没有高光。
2026 升级按三条独立手段解决，每条都可单独关闭（便于对比/回退）：

| 手段 | 位置 | 做什么 | 关掉它的参数 |
| --- | --- | --- | --- |
| ① **弧度 camber** | 着色器 | 二面角随翼展位置**线性增长**（根部平、翅尖翘）-> 翅面是**曲面**，于是出现连续明暗渐变 | `camber = 0` |
| ② **厚度外壳** | `butterfly.gd` 生成**几何** | 前层 + 后层 + 四条**侧壁**，构成闭合薄壳 -> 侧视有"有宽度的边"、边缘能吃到高光 | `thickness = 0`（退化成单片） |
| ③ **实体身体** | `butterfly.gd` 生成几何 | 沿头尾的 8 边形**纺锤实体**（颜色从素材中轴采样）-> 从任何角度看都有"质量" | `body_scale = 0` |

另外两个廉价但有效的强化：**边缘环压暗**（`v_rim`，代替没有 AO 的立体感）
与**一点镜面高光**（`SPECULAR = 0.45`，配合曲面法线会出现随姿态移动的高光条）。

> ⚠ 关键约束（实测）：**厚度不能在顶点着色器里"按正面/背面往外推"** ——
> Godot 的**顶点阶段没有 `FRONT_FACING`**（写了会 `Unknown identifier in expression: 'FRONT_FACING'`、
> 整份着色器编译失败）。所以厚度只能在**几何**里做出来（即 ② 的做法）。
> 代价：翅面顶点从 4 涨到约 900（20 只 ≈ 1.8 万顶点），对现代 GPU 可忽略，但**别把 GRID 调到 32 以上**。

> ⚠ 另一个实测：`camber` 的基准角要用 `max(th, 30°)` 而不是 `th` 本身，
> 否则张翼角调到 0（完全平飞）时曲率一起归零、翅面又变成平板。

## 2. 着色器契约

文件：`assets/shaders/butterfly_wings.gdshader`
材质：`ShaderMaterial`，**绝对路径硬编码**为 `res://assets/shaders/butterfly_wings.gdshader`。

### uniforms（名字**一个都不能改**）

| uniform | 类型 | 默认 | 含义 |
| --- | --- | --- | --- |
| `albedo_tex` | `sampler2D` | 白 | 蝴蝶 PNG |
| `tex_scale` | `vec2` | (1,1) | UV 裁剪：`uv = uv * tex_scale + tex_offset` |
| `tex_offset` | `vec2` | (0,0) | 同上 |
| `dihedral` | `float` | 30.0 | 二面角（度）：**根部**角度 |
| `camber` | `float` | 0.0 | ★ 弧度：二面角沿翼展的增量系数（体积感来源 1） |
| `fold_dz` | `float` | 0.0 | 前后折出量（模型单位） |
| `bend_y` | `float` | 0.0 | 头尾方向弯拱 |
| `thickness` | `float` | 0.0 | **已弃用**：厚度改由 GDScript 生成闭合外壳；保留仅为兼容 |
| `flutter_u` | `float` | 1.0 | 翼展形变 |
| `flutter_v` | `float` | 1.0 | 头尾形变 |
| `tint` | `Color` | 白 | 整体染色（受天气/光照影响时用） |
| `alpha` | `float` | 1.0 | 整体透明度 |
| `iridescence` | `float` | 0.25 | 掠射角虹彩（**只进 EMISSION，不改 ALBEDO**） |
| `backlight` | `float` | 0.15 | 逆光透光 |
| `view_dir` | `vec3` | (0,0,-1) | ★ 相机→蝴蝶 在**模型本地**空间的单位方向（面向镜头自适应用） |
| `min_edge` | `float` | 0.25 | ★ 最小正对度（0 = 关闭自适应） |
| `sprite_rot` | `float` | 0.0 | ★ GDScript 算出的面内自转量（弧度） |
| `rim` | `float` | 0.55 | ★ 厚度侧壁/边缘环压暗强度（廉价 AO） |

> 带 ★ 的 5 个（camber / view_dir / min_edge / sprite_rot / rim）+ thickness 是 **2026 立体感升级**新增的；
> 契约早期只冻结 12 个，现在这 18 个都算冻结项。新增项的理由见第 1 节末"体积感三件套"。

### ★★ 空间归属（实现折叠前必须先读）★★

Godot 4 的 spatial 顶点阶段里，**`VERTEX` 进来就已经是视图空间**，片元的 `NORMAL / VERTEX` 也是。
所以**不要**对 `VERTEX` 直接写 `vec3(x*c, y, -x*s)` 这种"假设 VERTEX 是模型空间"的式子。
正确做法：**所有折叠/弧度/自转都在模型空间用解析式算完**，最后一次性搬进视图空间：

```glsl
mat4 m = MODELVIEW_MATRIX;
vec3 p_view = (m * vec4(p_model, 1.0)).xyz;
vec3 n_view = normalize((m * vec4(n_model, 0.0)).xyz);
```

### 顶点程序必须实现（与当前实现一致；注意**全程在模型空间算**，再搬视图空间）

```glsl
// 1) flutter：翼展/头尾形变（几何与 UV 同步）
float x1 = VERTEX.x * flutter_u;
float y1 = VERTEX.y * flutter_v;
// 2) 可选：面向镜头自适应（绕模型 +Z 做面内自转；不改变飞行朝向）
//    facing = |view_dir.z|；facing < min_edge 时把翅面转到最小正对度
// 3) 折叠 + 弧度：绕模型 +Y 转 a
float th = radians(dihedral);
float camber_base = max(th, 0.5235988);          // 30°，见"体积感三件套"的注意项
float x_span = x1;
float fold_a = -(th + camber * abs(x_span) * camber_base) * sign(x_span);
float c = cos(fold_a);
float s = sin(fold_a);
vec3 tx = vec3(c, 0.0, -s);
vec3 ty = vec3(0.0, 1.0, 2.0 * bend_y * y1);
vec3 pm = vec3(x_span * c, y1, -x_span * s);
pm.z += fold_dz * x_span + bend_y * y1 * y1;
// 4) 解析法线 = 两切向叉乘（再统一朝 +Z）
vec3 nm = normalize(cross(tx, ty));
if (nm.z < 0.0) { nm = -nm; }
// 5) 搬进视图空间（**必须**，因为进来的 VERTEX 已经是视图空间）
mat4 m = MODELVIEW_MATRIX;
VERTEX = (m * vec4(pm, 1.0)).xyz;
NORMAL = normalize((m * vec4(nm, 0.0)).xyz);
// 6) UV 裁剪（flutter 的 UV 缩放发生在裁剪之前）
UV = UV * vec2(flutter_u, flutter_v) * tex_scale + tex_offset;
```

> 法线**不要**照抄 `vec3(sin(a), 0.0, cos(a))`：那个式子与 `(x·c, y, −x·s)` 的旋转**不同源**
> （差一个 x 分量符号），会让左右两翅的受光不对称。用**两切向的叉乘**最稳，再统一朝 +Z。
> 当前实现就是这样做的（`cross(tx, ty)` + `if (nm.z < 0.0) nm = -nm;`）。

> ⚠ 符号约定（这一处曾经真实写反过）：`fold_a = -(…) · sign(x)` 时两翅都抬向 **+Z**
> （V 的开口朝额面法线 / 相机常在的一侧）；写成 `+(…) · sign(x)` 会变成"从背后看 V"。
> **不要靠脑内推符号** —— 测试里有三条断言钉住它：折叠离面、左右对称（x_l=−x_r、y_l=y_r、**z_l=z_r**）、
> 折向（两翅 z > 0）。

> ⚠ 历史坑（保留记录，防止有人照抄错版）：
> 1. 契约最初写的是 `sx<0 ? vec3(sin(-a+PI),0,cos(-a+PI)) : vec3(-sin(a),0,cos(a))`。
>    那两行几何上就是错的：`sx>0` 把 x 分量取反、`sx<0` 把 z 分量取反，结果**左翅法线恒为 −Z**。
>    硬证据：`dihedral=0`（两翅共面，必须左右一致）时实测 **左/右亮度比 0.591**；
>    修正后 = **0.945**（≈对称）。
> 2. 折轴一度被改成 +Z（理由见第 1 节第 2 条，**那个改动是错的、已回退**）。
>    若折轴回 +Y，法线就必须回到上面这一行 —— 法线永远要与 `VERTEX` 的旋转**同源**。
> 3. `dihedral=0` 时 `a=0 -> nr=(0,0,1)`，两翅法线都是 +Z、方向完全一致，
>    所以"左右对称"是恒等式（0.945 那个数只是加上光照/混色后的实测近似）。
> 结论：数学要跟 `VERTEX` 的旋转**同源推导**，别凭手感写符号。

> 实现里请直接用上面这两段（可以加 `#define`，但**数学必须一致**）。
> 已经核对过：`sx=+1, a=-θ` → 翅尖 `(0.44cosθ, 0, 0.44sinθ)` 朝 **+Y 抬起** ✓。

### 渲染要求

* `render_mode` 必须含 `cull_disabled`（薄翅双面可见）+ `depth_prepass_alpha`。
* **不要**写 `shadows_disabled`：Godot 4.7 是否支持该 render_mode 未核实，名字写错会让**整份着色器**
  编译失败（实测结论：能省就省）。
* 双面法线翻转：`if (!FRONT_FACING) NORMAL = -NORMAL;`
* 片元：`ALBEDO = tex.rgb * tint.rgb`；`ALPHA = tex.a * alpha`（**必须**用 PNG 的 alpha 裁形）。
* **不要**写 `ALPHA_SCISSOR_THRESHOLD`：会把材质推进 alpha-scissor（不透明）管线，
  `alpha` 就只剩"遮罩"语义、不再混色（实测亮度比 1.010 vs 真混色 0.570，详见硬性校验第 6 条）。
* 着色器必须能被**无头模式编译通过**（不允许未定义标识符/错误 render_mode）。
  ⚠ headless 用的是 dummy 渲染器，**光靠 `--check-only` / headless 不能证明真机编译通过**；
  要真机确认必须带显卡跑一次（`.runtime/shader_check_bfly.gd` 的做法）。

### 硬性校验（会被测试逐条查）

1. 文件存在，且能被 `load()` 成 `Shader`。
2. 上述 12 个 uniform **全部存在**（`shader.get_shader_uniform_list()`）。
3. `render_mode` 里含 `cull_disabled`（并保留 `depth_prepass_alpha`）。
4. 源码里含 `FRONT_FACING`（双面法线翻转）。
5. **折叠存在且由 `dihedral` 驱动**（而不是被写成空的）。
   * 检查形态（**按语义查，不要逐字查**）：
     * 源码里 `dihedral` 被 `radians()` 成 `th`，`th` 参与一次对 `VERTEX` 的旋转；
     * 旋转必须让翅面**离开原平面**（z 分量随 x 变化）：源码里应出现
       `VERTEX.x * c` 与 `-VERTEX.x * s` 两个形态（即 `VERTEX = vec3(VERTEX.x * c, VERTEX.y, -VERTEX.x * s)` 这一族）。
   * ⚠ **反面教材（测试更该防的）**：曾一度改成绕 +Z 的"平面内自转"
     （`VERTEX.x*c - VERTEX.y*s` + `VERTEX.x*s + VERTEX.y*c`）。它**通过**了所有"折叠存在"的语法检查，
     却让网格永远共面于 z=0 —— **永远不可能有 V 形折缝**，法线还退化成切向（整只一片平光）。
     所以语义断言最好同时钉住"**z 分量依赖 x**"这一条（例如匹配 `-VERTEX.x * s` 或断言
     折叠后顶点 AABB 在 **z 方向有非零尺寸**），光看"有没有做一次旋转"是防不住的。
   * ⚠ 「左右对称」不必靠数值凑：`dihedral=0` 时 `a=0`，两翅法线都是 `(0,0,1)`，对称是恒等式。
   * ⚠ 侧视变窄**不是 bug**（真实蝴蝶从正侧方看也窄），不要为它改折轴。

### 其他实测出来的"必须"（都是踩过坑的）

6. `ALPHA = tex.a * alpha`，且**不要**写 `ALPHA_SCISSOR_THRESHOLD`：
   写了会把材质推进 alpha-scissor（不透明）管线，`alpha=0.25` 的亮度比实测 1.010（= 完全不混色）；
   不写才是真混色（0.570，对应线性 0.25 经 sRGB 的理论值 0.533）。
7. 虹彩 `iridescence` **只加进 `EMISSION`，绝不改写 `ALBEDO`**：
   早期 `ALBEDO = mix(ALBEDO, hue, ...)` 会把大面积掠射的薄翅整体染成紫红、盖掉素材本色
   （真机实测 `.runtime/bfly_demo_*.png`）。
8. autoload 查找**不要裸用 `get_tree()`**：节点刚 `add_child` 而树尚未刷新时 `get_tree()` 会返回 null，
   会误报成"没有天气系统"。统一走 `ButterflySwarm.scene_tree()` / `scene_root()`（内部有
   `Engine.get_main_loop()` 兜底）。
9. 素材列表**不要** `swarm.sprites = <无类型 Array>`，也不要 `swarm.get("sprites").append(...)`：
   `sprites` 是 `Array[Texture2D]`，前者直接报类型错，后者在强类型数组上是脆的。
   用 `set_sprite_textures(Array)` / `add_sprite_textures(Array)`（内部过滤非 Texture2D）。
10. 网格 arrays **不要给 `ARRAY_CUSTOM0` 传 `PackedFloat32Array`**：
    必须是 `PackedByteArray`，否则 Godot 报 `Invalid array format for surface`、
    **整个 surface 建不出来**（`surface_count=0`），蝴蝶完全不可见且不报错。
11. 生成 `.tscn` 必须递归设 `owner`：`PackedScene.pack()` 只序列化 `owner == root` 的节点，
    否则保存出空场景而 `ResourceSaver.save()` 返回 OK。
12. 无头/树外调 `advance()` 不能崩：`look_at()` 要求节点在树里，否则**每帧刷一条 ERROR**；
    `Butterfly._sync_transform()` 里有树外的手工基回退。
13. **厚度只能在几何里做**：Godot 顶点阶段**没有 `FRONT_FACING`**，想"按正反面往外推"会编译失败；
    正确做法是生成"前层 + 后层 + 四边侧壁"的闭合外壳（见 §1 体积感三件套）。
14. 给 `surface_override_material(1, …)` 前**必须确认 surface 1 存在**：
    `body_scale = 0` 时不建身体面，此时设 index 1 会报
    `Index p_surface = 1 is out of bounds (surface_override_materials.size() = 1)`。
15. `camber` 的基准角要用 `max(th, 30°)`：直接用 `th` 会让张翼角=0 时曲率归零、翅面退回平板。
16. **GDScript 的 `%` 不支持 `"%.3e"`**（会原样输出格式串、不做替换）→ 断言消息里看不到数值。
    诊断/断言里用 `str(v)` 或 `"%.4f"` 拼接。

## 3. GDScript 契约

### `addons/butterfly_swarm/butterfly_swarm.gd` —— `ButterflySwarm`（`@tool`，`Node3D`）

```gdscript
# ---- 素材 / 数量 / 区域（用户可自行决定）----
@export var sprites: Array[Texture2D]        # 可多选蝴蝶 PNG（留空则按清单兜底）
@export var count := 12
@export var region_size := Vector3(8, 3, 8)  # 区域（本地空间，以 region_offset 为中心）
@export var region_offset := Vector3(0, 1.5, 0)
@export_enum("Custom","小院 4×2×4","花园 8×3×8","草地 16×4×16","谷地 28×6×28") var region_preset := 0
@export var autofit_region := false          # 按地面自动抬高区域
@export var ground_clearance := 0.4
@export var debug_draw_region := false

# ---- 张翼角度（扑翼幅度的总闸）----
@export_range(0, 90, 1) var dihedral_min_deg := 6.0    # 下扑到底时的角度
@export_range(0, 90, 1) var dihedral_max_deg := 72.0   # 上扑到顶时的角度
@export_range(0.5, 30, 0.5) var flap_hz := 8.5
@export_range(0, 10, 0.1) var flap_hz_jitter := 2.5

# ---- 尺寸 / 立体感（体积）----
@export_range(0.03, 2, 0.01) var size_m := 0.22         # 翼展（米）
@export_range(0, 1.5, 0.01) var wing_camber := 0.30     # 弧度：曲面
@export_range(0, 0.25, 0.005) var wing_thickness := 0.035  # 厚度（占翼展比例）
@export_range(-0.3, 0.3, 0.005) var wing_bend_y := 0.0
@export_range(0, 3, 0.05) var body_scale := 1.0         # 身体粗细（0 = 不画身体）
@export_range(0, 1, 0.01) var edge_min_facing := 0.0    # 面向镜头自适应（默认关）
@export_range(0, 80, 1) var edge_min_deg := 14.0
@export_range(0, 1, 0.01) var rim_dark := 0.55          # 边缘环压暗

# ---- 行为 ----
@export var enabled := true
@export var seed_value := 12345
@export var wind_influence := 1.0
@export var ground_avoid := true
@export var flock_pulses := true
@export_node_path("Node3D") var threat_path: NodePath
@export var tuning: ButterflyTuning

func rebuild() -> void
func set_active(v: bool) -> bool
func respawn_all() -> void
func sprite_count() -> int
func live_count() -> int
func set_sprite_textures(Array) -> int      # ★ 宽松写入（过滤非 Texture2D）
func add_sprite_textures(Array) -> int
func autoload_all_sprites(load_textures := true) -> int
func randomize_sprites(n: int, rng_seed := 0) -> int
func regenerate_manifest() -> int
func bounds_world() -> AABB
func auto_fit_to_ground() -> bool
func scene_tree() -> SceneTree              # ★ 带 Engine.get_main_loop() 兜底，别裸用 get_tree()
func scene_root() -> Window
func wind_now() -> Dictionary               # {dir: Vector2(世界 XZ), strength, gust, turbulence, speed, source}
func weather_now() -> Dictionary            # {kind, name, wind, gust, rain, cloud, source}
func stats() -> Dictionary                  # 测试/调试用只读快照
```

### 网格结构（`Butterfly.build_unit_quad()`）

| surface | 内容 | 顶点数（GRID=8） |
| --- | --- | --- |
| 0 | 翅面**闭合外壳**：前层 + 后层 + 四条侧壁 | 162 + 768 = 930 |
| 1 | **身体**：8 边形 × 6 环纺锤 + 两端封口（`body_scale > 0` 时才建） | ~112 |

> `GRID_X` / `GRID_Y`（默认 8×8）是曲线质量的开关；**别超过 32**（顶点数按平方涨）。
> 两个 surface 都是"体积感"的一部分，测试里会断言 `surface_count == 2` 与"z 方向有非零厚度"。

* `@tool`：编辑器里改参数**立即重建**（用 `Engine.is_editor_hint()` 区分，编辑期只建静态姿态，不跑 AI）。
* 网格：`ArrayMesh` 单位方块，`ARRAY_TEX_UV` 必须是 `(u, v)`，且 `v=0` 在**纹理上边**。
* 每个蝴蝶 = `MeshInstance3D` + 自己的 `ShaderMaterial`（独立 `dihedral` 才能各自扑翼）。
* 找不到 shader / 没有 sprite 时**不崩**，只 `push_warning` 并留空。
* 风来源优先级：风系统 `WindSystem`/旧 `Wind` 节点（有 `cur_*`）→ `Weather`（`wind`/`wind_dir`/…）→ 内置兜底。**三者都必须有。**

### `addons/butterfly_swarm/butterfly.gd` —— `Butterfly`（`Node3D`）

```gdscript
enum State { CRUISE, SEEK, COURT, BASK, SHELTER, FLEE, DRINK }

@export var tuning: ButterflyTuning          # 见下；null 时用内置默认
var state: State
var energy: float                            # 0..1
var sprite_tex: Texture2D
var crop: Rect2i                             # PNG 上的不透明包围盒

func setup(tex: Texture2D, crop_rect: Rect2i, rng: RandomNumberGenerator, t: ButterflyTuning) -> void
func step_ai(delta: float, swarm: Node3D, wind: Dictionary, bounds: AABB) -> void
func stats() -> Dictionary
```

* AI 至少要有：**巡飞(wander+噪声)**、**趋花/趋目标(seek)**、**同群分离(separation)**、
  **风向漂移(风把蝴蝶吹偏)**、**边界回弹(不飞出区域)**、**避地(不钻地)**、
  **状态机**（能量驱动的 REST/SEEK 切换 + 受惊 FLEE）、**扑翼相位**（非同步）。
* `step_ai()` 必须是**纯数学**，不依赖渲染：无头模式下也能跑（测试要调它）。
* 随机数一律走注入的 `rng`（同 `seed_value` 应可复现）。

### `addons/butterfly_swarm/butterfly_tuning.gd` —— `ButterflyTuning`（`Resource`）

数值调参集中在此：`size_m`、`speed_max`、`flap_hz`、`dihedral_min/max`、
`wander_jitter`、`separation_m`、`wind_drag`、`seek_range_m`、`rest_energy`、
`shelter_wind`（风速超过它就去躲）、`iridescence`、`backlight`、`tint` 等。

#### 聚集 / 聚散 / ARS 段（**"聚散必须换坐标"是硬约定**）

| 参数 | 默认 | 契约 |
| --- | --- | --- |
| `heading_persistence` `turn_scale_deg` `turn_heavy_p/deg` `levy_alpha` `step_time_s` `lateral_weave(_hz)` | 0.72 / 25 / 0.06 / 110 / 1.6 / 0.45 / 0.55 / 1.1 | CRW + Lévy 飞行模型（出处见该文件顶部注释） |
| `area_restricted_search` `ars_radius_m` `ars_turn_scale_deg` `ars_speed_scale` `ars_participation` | true / 3.0 / 55 / 0.55 / 0.55 | ARS；`ars_participation` 让只有一部分个体响应（防整群同步聚散） |
| `ars_rotate_s` `ars_min_move_m` | 8.0 / 3.0 | **资源点必须按周期轮换**，且新点离旧点 ≥ `ars_min_move_m` |
| `seek_repeat_avoid_m` | 3.0 | 趋花目标必须避开"上一处"，不许总回同一朵 |
| `gather_min_move_m` `gather_history_n` | 4.0 / 3 | **每一轮聚散中心都必须离最近几轮 ≥ `gather_min_move_m`**（用户硬性要求） |
| `pulse_interval_min_s` `pulse_interval_max_s` `regroup_s` | 25 / 70 / 6.0 | 聚散周期与收拢时长 |

> ⚠ 实现约定（踩过坑，别改回去）：
> 1. **"聚/散"必须同时偏转 `_crw_heading`**，不能只加力 —— CRW 推进力最高约 7 m/s²，
>    光加力会被随机航向盖住，实测会出现"只散不聚"。
> 2. **候选排除集必须包含"当前值"**（`_gather_pos` 末尾才进历史），否则会"自己选回自己"。
> 3. ARS 资源点的计时器**必须真的递减**（旧代码只赋值不递减 -> 永久冻结，这是历史 bug）。

## 4. 素材清单契约

`addons/butterfly_swarm/sprite_manifest.json`（由 `tools/analyze_butterflies.gd` 生成）：

```json
{"generated_by":"analyze_butterflies.gd","source_dir":"res://assets/textures/活体/蝴蝶",
 "sprites":[{"file":"蝴蝶-01.png","path":"res://assets/textures/活体/蝴蝶/蝴蝶-01.png",
             "w":1186,"h":802,"min_x":113,"min_y":72,"max_x":1072,"max_y":721,
             "bbox_w":960,"bbox_h":650,"body_x":0.5508}]}
```

* `body_x` 只是**参考诊断值**；折叠轴一律用 `min_x + bbox_w/2` 的归一化值（即包围盒水平中心）。
* 测试要校验：条目数 = 目录里 `.png` 数、每条 `bbox` 落在图内、`path` 真实存在。

## 5. 写范围（并行时严禁越界）

| 角色 | 独占写范围 |
| --- | --- |
| Lead | `addons/butterfly_swarm/*.gd`、`plugin.cfg`、`tools/`、`project.godot`（仅注册插件） |
| teammate `wind-shader` | `assets/shaders/butterfly_wings.gdshader` **仅此一个文件** |
| teammate `tests-docs` | `tests/test_butterfly_swarm.gd`、`docs/蝴蝶飞舞插件-技术文档.md`、`tools/verify_butterfly.gd` |

## 6. 验收（Lead 最终必须自己跑一遍）

1. 无头脚本编译全部新增 `.gd` 无错误、无警告级错误。
2. `tests/test_butterfly_swarm.gd` 全绿。
3. 着色器 12 个 uniform 全在、`cull_disabled` 在、`FRONT_FACING` 在。
4. `sprite_manifest.json` 与素材目录一致。
5. 出图：截一张有蝴蝶在飞的照片（`--script` 截图脚本），确认轮廓是蝴蝶而不是方块。
