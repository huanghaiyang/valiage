# fast-tree GLB → Godot 资产（一条命令）

> 解决什么问题：fast-tree 导出的 `.glb` 里带着 `_AWIND / _APHASE / _AORIGIN`（枝条柔度、每枝相位、
> 叶柄基点）三组自定义顶点属性，**Godot 的 glTF 导入器会把它们丢掉**，于是"导入 GLB"得到的只是一棵
> 静态树。这条流水线把它们烘回 `ARRAY_CUSTOM0/1`，并顺手生成树着色器材质和可直接拖进场景的 `.tscn`。

---

## 1. 用法

### 推荐：PowerShell 包装器（自动找 Godot、自动把绝对路径转 `res://`）

```powershell
cd D:\sgames\CozyVale
.\tools\import_fasttree.ps1 -Glb "assets/models/树/大樱花树.glb"
# 覆盖重烤 + 生成碰撞：
.\tools\import_fasttree.ps1 -Glb "res://assets/models/树/大樱花树.glb" -Name BigSakura -Collision convex -Force
# 只看会发生什么，不写文件：
.\tools\import_fasttree.ps1 -Glb "assets/models/树/大樱花树.glb" -DryRun
```

### 直接调 Godot（等价）

```powershell
& 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path . `
  --script res://tools/fasttree_import.gd -- --glb=res://assets/models/树/大樱花树.glb
```

**前置条件**：这个 GLB 必须已经被 Godot 导入过（打开过编辑器，或跑过一次
`godot --headless --import`），否则脚本会提示 `加载失败…先让 Godot 导入一次`。

---

## 2. 产物（默认按项目现有约定放）

| 产物 | 默认路径 | 内容 |
| --- | --- | --- |
| 烘焙网格 | `assets/models/树/<名字>/wind/<节点>.res` | 每个网格节点一个 `ArrayMesh`：`VERTEX/NORMAL/TANGENT/COLOR/TEX_UV/INDEX`（与原网格一致）+ `CUSTOM0=(aOrigin, aWind)`、`CUSTOM1=(aPhase, isLeaf, nodeId, 1)` |
| 材质 | `scenes/树/<名字>/_ft_mat_bark.tres`<br>`_ft_mat_leaves.tres`<br>`_ft_mat_flowers.tres` | 自动套 `tree_burn_keep_ds`（树干/枝/果）或 `tree_leaves_burn_ds`（叶/花），贴图直接引用 GLB 导入出来的 PNG，写入风摆/燃烧/法线参数 |
| 场景 | `scenes/树/<名字>/<名字>.tscn` | 独立场景（不依赖 GLB 实例）：`<名字>` → `FastTree` → 8 个 `MeshInstance3D`（烘焙网格 + 材质覆盖）+ `CanopyCull`（树冠分块剔除）+ `FallingLeaves`（落叶 / 落花，有树叶/花朵时才挂） |

---

## 3. 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--glb=` | 必填 | `res://` 路径（包装器也接受磁盘路径并自动转换） |
| `--name=` | GLB 文件名 | 决定目录名、场景根节点名、材质 `resource_name` |
| `--res-dir=` | `res://assets/models/树/<name>/wind` | 烘焙 `.res` 输出目录 |
| `--scene-dir=` | `res://scenes/树/<name>` | `.tscn` / `.tres` 输出目录 |
| `--leaf-nodes=` | 按名字猜 | 显式指定哪些节点算"叶片"（逗号分隔；名字里含 `flower` 的仍归花朵） |
| `--collision=` | `none` | `none` / `convex`（每个树皮网格一个凸包）/ `trimesh`（精确但贵） |
| `--force` | 关 | 覆盖已存在文件（不加时只警告，不覆盖） |
| `--dry-run` | 关 | 只解析 + 打印计划，不落盘 |

---

## 4. 生成规则（改默认值看这里）

- **角色判定**（决定用哪个着色器/风参数）：节点名含 `flower/blossom` → `flowers`；含 `leaf/leaves/foliage`
  → `leaves`；其余（`trunk/branch/bark/fruit/...`）→ `bark`。果实按源实现合并进树皮几何，所以跟枝条刚性摆。
- **贴图映射**：从 GLB 导入材质里直接取
  `albedo_texture` → `albedo_tex`；`normal_texture` → `normal_tex`（`has_normal=true`）；
  `roughness_texture`（没有则 `orm_texture` 的 G 通道）→ `rough_tex`；
  带透明（glTF MASK）时 `alpha_tex = albedo`、`alpha_channel=3`、`alpha_scissor=0.35`（与现有樱花树一致）。
- **风参数**：`bark` → `wind_sway=0.8 / wind_is_leaf=false`；`leaves` → `wind_sway=1.0 / is_leaf=true /
  flutter=0.6 / twist=0.5 / flutter_rate=1.10`；`flowers` → 同上但 `flutter_rate=0.72 / twist=0.42`（花比叶慢）。
  全局风（方向/强度/阵风/湍流…）由 `WindSystem` 节点每帧写，不在材质里写死。
- **燃烧**：`height_ref / wind_height_ref = 全树高度`，并写 `metadata/burn_mode`（wood/leaf）与 `cull_mode`，
  与项目现有树保持一致（供 `scripts/vfx/foliage_burn.gd` / `burn_toggle` 用）。
- **树冠剔除**：只要存在叶片材质就挂 `CanopyCull`（`scripts/world/canopy_chunk_cull.gd`，2×2×2 分块）。
- **落叶 / 落花**：只要存在树叶或花朵网格，就在它们所在的父节点下挂 `FallingLeaves`
  （`scripts/vfx/falling_leaves.gd`），路径用 `get_path_to` 写成相对路径，**只打开实际存在的来源**
  （有树叶就落树叶、有花朵就落花朵、两者都有就一起落）；卡片尺寸按树高自适应
  （`clamp(树高 × 0.033, 0.25, 2.0)`，树叶用该值、花朵 ×0.89）。数量/贴图/下落速度/风力跟随
  可在 Inspector 里分开调，详见 `docs/落叶与落花-技术文档.md`。

---

## 5. 实测（2026-10-22，`大樱花树.glb`）

```
网格节点 8 个  烘焙 125,937 顶点 / 108,452 三角形  未匹配 0  树高 27.13 m
材质 3 个（bark/leaves/flowers）  贴图全部自动接上（albedo/normal/rough，叶花带 alpha）
场景 8/8 网格带 CUSTOM、3 材质、CanopyCull 就位
静态渲染 vs 现有手工制作版本：像素差 mean=0.00120 / max=0.549，差异像素 0.85%
（差异来自树皮 normal_strength / radial_normal 的默认值不同，肉眼不可辨）
```

验证脚本：`tests/ft_import_check.gd`（校验产物结构）、`tests/wind_res_inspect.gd`（看 `.res` 里到底存了什么）。

---

## 6. 已知限制

1. **一个网格节点 → 一个角色/一套材质**（按节点名判定）。fast-tree 的导出本来就是一个节点一种材质，
   但如果 GLB 里 树干和叶子合并在同一个节点，需要手动拆分或给 `--leaf-nodes` 显式指定。
2. 不生成 LOD / 碰撞的精细形状：`convex` 是整块网格的凸包（细枝会被包成一大块），
   `trimesh` 精确但面数大，按需选。
3. 不会自动改 **已存在的引用**：如果场景里已经放了旧版本树，重烤后需要重新实例化或手动替换。
4. 覆盖 `.res` 后，**正在打开的编辑器**可能仍缓存旧网格；重新加载场景/编辑器即可。
5. 只处理 `.glb`（fast-tree 导出格式）；fast-tree 的 `.ftree` JSON 不在这条链路里。
6. 若 GLB 后续换了贴图/改了名，直接重跑（加 `--force`）即可，产物路径稳定。

---

## 7. 编辑器右键插件（日常推荐）

插件：`addons/fasttree_import/`（已在 `project.godot` 的 `editor_plugins/enabled` 里启用；也可以在
「项目 → 项目设置 → 插件」里勾选/取消「fast-tree 一键烘烤」）。

用法：

1. 在 FileSystem 面板里**右键一个或多个 `.glb`**（只对 `.glb` 出现这一项，文件夹/其它文件不会出现）；
2. 点 **「fast-tree 一键烘烤（场景/材质/网格）…」**；
3. 弹窗里选：
   - **资产名**（默认 GLB 文件名；多选时不可改，各自用文件名）
   - **碰撞**：不生成 / 凸包 / 三角网
   - **覆盖已存在**（重烤时必须勾，否则遇到已存在文件会跳过并报"已存在"）
   - **完成后打开生成的场景**（默认勾）
4. 点「开始烘烤」→ 逐个转换（状态栏显示进度），结束后弹出结果汇总；文件系统面板会自动刷新。

行为说明：

- 菜单项与 `convert.gd` **共用同一份实现**（和命令行完全等价，不存在两套逻辑）。
- 转换在主线程跑：一棵 27 m 的樱花树约 4 s，期间编辑器会短暂无响应（这是 Godot 编辑器插件的常规限制：
  `ResourceSaver`/`ResourceLoader` 不适合跨线程）。
- 只对 `.glb` 生效；`.gltf`、`.blend`、`.tscn` 等不会出现该菜单项。
- 若 GLB 还没被 Godot 导入（面板里没有 `.import`），结果汇总会显示「加载失败（先让 Godot 导入一次）」。
