# 草地实例面板（SimpleGrassTextured 本项目改动）

左侧停靠面板 **「SimpleGrassTexturedInstances」**，用来查看 / 定位 / 删除某个草地节点上刷出的每一株草。

## 入口

- 编辑器左侧停靠区（和「场景」等面板同一区域）新增一个页签：**SimpleGrassTexturedInstances**。
- 选中场景里的 `SimpleGrassTextured` 节点时，面板自动切换到这个节点（顶部会显示节点名与草总数）。
- 也可以用面板上的 **「草地节点」** 下拉框，列出当前场景里所有 SimpleGrassTextured 节点并切换查看对象。

## 面板内容

| 区域 | 说明 |
| --- | --- |
| 顶部 | 当前草地节点名 + **刷出的草总数**，以及该节点是否处于编辑器选中状态 |
| 工具行 | `刷新` / `草地节点`（下拉切换）/ `过滤`（按序号或坐标片段筛选行，只影响显示） |
| 列表 | 每株草一行：**序号**、**世界坐标 (X, Y, Z)**、缩放、绕 Y 轴旋转角度 |
| 状态栏 | 当前选中/定位结果、总数、操作提示 |

## 操作

| 操作 | 行为 |
| --- | --- |
| **左键单击**某一行 | 选中该株草：把编辑器 3D 相机移到该株草（保持原距离、绝不拉近），并在该位置放一个橙色**高亮环** `SGTLocateMarker`；同时把该草节点加入编辑器选中 |
| **双击**某一行 | 同上（定位） |
| **Ctrl / Shift 多选** | 一次选中多行：**每一株都会出现一个橙色高亮环**（最多 256 个），视角不变，方便一眼看清选中了哪几株 |
| **右键单击**某一行 | 弹出菜单：`定位到该株草` / `删除选中项` / `仅删除该项` / `复制选中项坐标` |
| **右键删除** | 删除选中（或该项）的草实例；**操作进入编辑器撤销堆栈**，`Ctrl+Z` 可完整还原（数量、每株坐标、`baked_height_map` 都会还原），`Ctrl+Y` 可重做 |
| 取消选择 / 切换草地节点 / 删除实例 | 高亮环自动清除：列表重建时会先把高亮环清空，所以删掉的那几株不会留下圆形残影 |
| 过滤框 | 输入序号或坐标片段（如 `-149.7`、`1.500`）即可只显示匹配行 |

## 草地数据太大？把 MultiMesh 外挂成 .res（推荐）

`MultiMesh` 是 `Resource`，插件全程都支持它指向**外部资源**（`grass.gd` 里所有替换/清空逻辑都会
`take_over_path()` 保留原路径）。差别只在存储位置：

| 写法 | 场景文件里的样子 | 数据编码 |
| --- | --- | --- |
| 内联（默认，SubResource） | `multimesh = SubResource("MultiMesh_xxx")`，`buffer = PackedFloat32Array(...)` 一大行 | 文本浮点，最占地方 |
| 外挂（ExtResource） | `multimesh = ExtResource("N_xxxx")`，指向 `xxx.res` | 二进制，更紧凑 |

**实测（1079 株，RandomNumberGenerator 生成）**：

| | 内联 | 外挂 |
| --- | --- | --- |
| 场景文件 | 126,159 B | **304 B** |
| 资源文件 | — | 69,606 B |
| 合计 | 126,159 B | **69,910 B（省 44.6%）** |

也就是说 `main.tscn` 里那一大行 buffer（1079 株 ≈ 110 KB，占场景 32%）完全可以从场景里挪出去，
而且外挂后场景文件干净到几乎只剩节点结构。

### 怎么外挂（两种）

1. **一键（已实现）**：选中草地节点 → 工具栏 `SimpleGrassTextured ▸` 菜单里的
   **`Externalize grass data (.res)`**。
   - 把当前 MultiMesh 写进 `res://maps/`，文件名是 **`<场景名>_<节点id>_grass.res`**，例如
     `main_g0_1a2b3c4d_grass.res`。
   - **命名用节点 id，不用节点名**：Godot 没把 `.tscn` 里的 `unique_id` 暴露给 GDScript
     （`Node.get_scene_unique_id()` 不存在，`get_path(unique)` 只给 `".."`），所以采用
     「首次外挂时生成一个 id 写进节点 meta `sgt_external_id`」——meta 随场景保存，
     **之后你把节点改成任何名字、再点一次外挂，都复用同一个文件**，不会再多出几个 `.res`。
   - 再把节点指针换成这个外挂资源；整个替换**进撤销堆栈**，`Ctrl+Z` 回到内联。
   - 之后笔刷 / 擦除 / 删除都会继续写回该文件。
   - 菜单项文字会显示当前内联株数（超过 100 株时带 ⚠ 提示）；已经是外挂资源时该项自动禁用。
2. **手动**：把 MultiMesh 另存为 `.res` 再在 Inspector 里把 `multimesh` 指过去，效果相同。

> ⚠ 新建的草地节点**默认仍是内联**（`_ready()` 里 `multimesh = _new_multimesh()`，没有 resource_path），
> 需要手动点一次「外挂」，或者把它另存为 `.res`。

> ⚠ 判断「是否已外挂」不能只看 `resource_path` 是否为空：**内联子资源在编辑器里也会带路径**，
> 形如 `res://scenes/main.tscn::MultiMesh_c6pm6`（`场景文件::子资源ID`）。只有**不含 `::`** 的独立路径
> （如 `res://maps/xxx_grass.res`）才是真正的外挂文件。代码里统一用
> `is_external_multimesh()` / `_is_external_file_grass()` 判断。
>
> 这里的守卫方向很容易写反：应该是「**已经是外挂文件才提前返回**」，
> 即 `if _is_external_file_grass(mm): return`。写成 `if not ...` 会导致内联草永远外挂不了，
> 只打印一句「已经是外挂资源」就返回（这个 bug 已修，见 2026-10-08 修复记录）。

> 提示：外挂资源不要放在 `addons/` 里（插件重装会被删），默认目录是 `res://maps/`，
> 可在 `plugin.gd` 顶部常量 `EXTERNALIZE_DIR` 改。

### 撤销数据为什么要用「值快照 / 新建对象」

外挂 `.res` 时，Godot 的资源缓存对同一路径只保留**一个**对象：`ResourceLoader.load()` 同一个
`.res` 永远返回同一实例，而替换时又 `take_over_path()`。结果是「删除前的 MultiMesh」与节点
替换后的对象指同一实例，撤销重新加载又会把它同步成节点当前内容 —— 撤销退化成「什么都没变」。
所以删除的撤销数据存 transform 值快照（`restore_multimesh_from_snapshot()` 重建全新对象），
外挂的撤销则用一个「没有路径的内联副本对象」（`_assign_multimesh()` 装回去）。

## 实现位置

- 面板：`addons/simplegrasstextured/gui/grass_list_dock.gd`（纯代码构建 UI，无场景文件）
- 挂载 / 定位 / 删除：`addons/simplegrasstextured/plugin.gd`
  - `_enter_tree()` 里 `add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, _gui_grass_list)`
  - `focus_grass_point(world_position)`：移动编辑器 3D 相机 + 高亮环
  - `set_selection_highlights(positions)` / `clear_selection_highlights()`：多选时给每一株放一个高亮环（最多 `LOCATE_MAX_MARKERS = 256` 个）
  - `delete_grass_instances(grass, indices)`：走 `get_undo_redo()`，`add_do_method` / `add_undo_method` 指向 `grass.replace_multimesh_with()`
- 只读/删除接口：`addons/simplegrasstextured/grass.gd`
  - `get_instance_count()` / `get_instance_position()` / `get_instance_positions()` / `get_instance_transform_safe()`
  - `delete_instances_by_indices(indices)`（返回 **[存活实例 transform 快照, 删除前的高度图]** 供撤销）
  - `restore_multimesh_from_snapshot(transforms, height_map)`（撤销 / 重做统一入口，永远新建对象）
- 风：`scripts/wind.gd`（**项目脚本，不在 addon 里，重装插件不会丢**）
  - 它每帧给注册到的 SGT 材质写 `sgt_wind_*` / `sgt_player_*`；材质收集见 `_take_from_multimesh()`

## 风为什么曾经完全不起作用（2026-10-08 修复）

`scripts/wind.gd` 的材质收集原来只判 `n is MeshInstance3D`，而
**`MultiMeshInstance3D` 不是 `MeshInstance3D` 的子类**（Godot 4 两条独立继承链）——
SimpleGrassTextured 的整片草用的正是 `MultiMeshInstance3D`，于是从来没被收进 `_mats_sgt`，
`_write_sgt()` 里 `if _mats_sgt.is_empty(): return` 每帧直接返回，风参数从没人写。
表现就是「simplegrass 的草不受风」。

修法：`_scan()` 里补 `elif n is MultiMeshInstance3D: _take_from_multimesh(...)`。
注意这个分支**不能用** `MeshInstance3D` 的 API：

| 想拿的东西 | MeshInstance3D | MultiMeshInstance3D |
| --- | --- | --- |
| 网格 | `mi.mesh` | `mmi.multimesh.mesh`（没有 `mesh` 属性） |
| surface 覆盖材质 | `get_surface_override_material(i)` | ✗ 没有这个函数 |

运行时可自检：日志出现 `[Wind] 新增 N 个受风材质（累计 … ｜ SGT ≥1）` 就说明草已被接管。

### 为什么撤销数据存「快照」而不是存旧的 MultiMesh

外挂 `.res` 时，Godot 的资源缓存对同一路径只保留**一个**对象：`ResourceLoader.load()` 同一个
`.res` 永远返回同一实例，而 `replace_multimesh_with()` 在替换时会 `take_over_path()`。
结果是「删除前的 MultiMesh」与节点替换后的对象指同一实例，撤销时重新加载又会把它同步成节点
当前内容 —— 撤销会退化成「什么都没变」。改成存 transform 值快照后，撤销时用
`restore_multimesh_from_snapshot()` 重建一个全新对象，与磁盘/缓存彻底脱钩。
（`plugin.gd` 里还保留了 `_undo_snapshot()`：万一拿到旧接口返回的 MultiMesh，会就地导出快照兜底。）

## 定位取景（不拉近）

`plugin.gd` 顶部三个常量控制「定位」时的相机：

| 常量 | 默认 | 作用 |
| --- | --- | --- |
| `LOCATE_MIN_DISTANCE` | `18.0` | 相机到草的最小距离。原本更远 → **保持原距离**；比这更近 → 被推远到 18 米。绝不会拉近 |
| `LOCATE_TILT` | `0.35` | 视线俯角（约 19°），相机守在草的斜上方俯视 |
| `LOCATE_VIEW_HEIGHT` | `4.0` | 视野中心相对草抬高 4 米（按俯角换算成目标点位置），草因此落在画面偏下部，上方留出环境 |

实测：相机在 14.7 米处点「定位」→ 相机退到 18 米、比草高约 6 米，草在画面高度约 66% 处。
想更远/更俯视，把 `LOCATE_MIN_DISTANCE` 调大即可。

## 性能说明

草的数量可能上万，因此：

- 列表**分帧构建**（每帧最多 400 行 / 6ms），刷新面板不会卡住编辑器；
- 一次最多列出 **20000 行**，超出部分请用过滤框定位；
- 每 0.5s 的兜底检查只在**数量变化**时才重建列表；数量不变时用首/中/尾三株坐标做指纹，指纹相同就不重写行文本。

## 风位移公式（2026-10-08 按反馈重调）

改的是 `addons/simplegrasstextured/shaders/grass.gdshaderinc` 的 `vertex()` 风段
（8 个 `grass*.gdshader` 变体都 `#include` 这个文件，改一处全生效）。

原来那版的毛病（反馈：**倒伏过狠** + **小风大风都看不出摆动**）：
静态推力被算了两次（`text_wind` 项 + `sgt_wind_strength` 项，合计约 `lev×0.04`），
而随时间变化的摆动项只有 `sin(...)×0.01` —— 于是只剩下"被压住"的姿态。

新公式对齐项目里已验证可用的 `assets/shaders/grass_wind.gdshader`：

| 项 | 作用 |
| --- | --- |
| `w_dir = normalize(sgt_wind_direction.xz)` | 风向（同时修掉 2D 风向长度造成的 1.41 倍放大） |
| `w_row = dot(world_xz, w_dir) * 0.16` | 沿风向的相位梯度 → 风"一阵一阵扫过"整片草，而非齐刷刷同步 |
| `w_gust = 1 + 0.9*(0.5+0.5*sin(...))` | 阵风包络，幅度在 0.55~1.45 之间起伏 |
| `w_stiff = 1 - grass_strength*0.35` | 草越"硬"越不易动（0.55 时约打八折） |
| `w_along = sin(...)*0.55 + 0.65` | 沿风向的呼吸（恒为正，保证不会朝反向抽动） |
| `w_across = cos(...) * turbulence` | 垂直风向的小幅左右晃 |
| 位移 = 高度 × 0.22 × 风强 × 阵风 × 硬软 × `lev` | 小风（0.18）≈ 每米高 3~5 厘米 |

**整体调幅就改 `w_sway_scale` 里的 `0.22`**（越大越明显，越小越静）。
`lev` 仍是 SGT 原有的高度权重（`pow(高度/grass_size_y, 1.7+风强)`）：根部不动、梢部摆得最多。

## 角色倒伏 / 分开（2026-10-08 修复：原来完全没效果）

原来是**四重失效**，所以草对人物走动毫无反应：

| # | 问题 |
| --- | --- |
| 1 | 插件自带的交互是**贴图管线**（高度图 + 法线位移 + 运动图），而 `singleton.gd:101` 在运行时会 `set_interactive(false)`；本项目**没有任何脚本**调用 `SimpleGrass.set_interactive(true)` / `set_player_position()` → 那条路根本没开 |
| 2 | 着色器把玩家参数声明成 `global uniform sgt_player_position / sgt_player_mov`，而 `scripts/wind.gd` 写的是**逐材质同名参数** → 两个不同 uniform，写了没用 |
| 3 | 它依赖的两张采样图 `sgt_normal_displacement` / `sgt_motion_texture` 也是 `global uniform` → 4.7 运行时全局参数本就失效 |
| 4 | 采样 UV 还按「世界 x 除以 50 分块」，依赖那张全局位移图 |

**改法**（和风同一套做法，不走贴图、不依赖全局参数）：

- 着色器新增逐材质 uniform：`sgt_player_pos` / `sgt_player_bend_radius` / `sgt_player_bend` /
  `sgt_player_radial` / `sgt_player_edge`；
- 顶点阶段用**局部坐标**算到玩家的距离：半径内权重 1，到 `半径×edge` 用 `smoothstep` 平滑收到 0
  → 边缘不会出现硬边；两种位移叠加：**径向分开**（以玩家为圆心往外推）+ **沿移动方向倒伏**；
- `scripts/wind.gd` 每帧写这些参数：位置优先用 `SimpleGrass.player_position`，
  本项目没调它 → 兜底直接读 `"player"` 组节点的 `global_position`（启动时会打印一条说明）；
  位移用位置差分得到，跳变 >1.5 米（传送）不计推力；
  站着时倒伏强度降到 25%（避免出生点一圈草永远是倒的）；
- 位移量按「米」标定并乘 `inter_soft = 1 - grass_strength*0.45`：**草越硬越拨不动**。
  想更明显就调 `wind.gd::_write_sgt()` 里的 `sgt_player_radial`（默认 0.30）与
  `sgt_player_bend`（默认 0.24）以及 `sgt_player_bend_radius`（默认 1.25 米）。

> `foliage_burn.gd` 的 `WIND_PARAMS` 也补了这几个新名字，燃烧材质副本才会继续跟随人物。

### 调手感：**项目设置 → Wind → sgt_player**

⚠ `Wind` 是**脚本型 autoload**（`project.godot` 里 `Wind="*res://scripts/wind.gd"`），
编辑器场景树里根本没有它的节点，所以 `@export` 在 Inspector 里**永远看不到**。

参数改为读写**项目设置**（`project.godot` 的 `[Wind]` 段），改完**立即生效**、不必重启编辑器：

| 项目设置项 | 默认 | 作用 |
| --- | --- | --- |
| `Wind/sgt_player/bend_radius_m` | `1.4` | 以玩家为圆心多大范围内动草（米） |
| `Wind/sgt_player/radial` | `1.2` | 径向"分开"位移（米级手柄） |
| `Wind/sgt_player/bend` | `1.0` | 沿移动方向"倒伏"位移（米级手柄；站着只剩 25%） |
| `Wind/sgt_player/gain` | `0.10` | 位移总增益，收敛量级 |
| `Wind/sgt_player/debug_log` | `true` | 移动时每秒一条日志（稳定后可关） |

位移最终量级 = `radial/bend × gain × w(0~1)`；半径内生效、边缘平滑到 0。
`_ready()` 的 `_ensure_project_settings()` 会自动补齐缺失项并写入 `_doc` 中文说明。

> ⚠ **读取项目设置必须逐类型判断**：设置里可能是非数值，
> 直接 `float(_sgt_setting(...))` 会每帧抛 `Nonexistent 'float' constructor`。
> 统一走 `_sgt_num()` / `_sgt_bool()`。

> ⚠ **键名必须用 ASCII**。实测中文键名（如 `Wind/SGT草人物交互/影响半径_米`）在
> Godot 读取 `project.godot` 时会失配：`ProjectSettings.has_setting()` 返回 `false`，
> 脚本拿不到值（自检输出 `has=false`）。中文只放在 `_doc` 前缀字段里做说明。

> ⚠ **改完 `wind.gd` 必须重启编辑器**。Godot 不会在 `.gd` 文件变动后重载脚本缓存，
> 连它启动的游戏进程用的也是缓存版本 —— 表现为报错行号与磁盘文件对不上
> （曾出现"磁盘 421 行是注释，却报 421 行 `float()` 构造错误"）。

### ★ 关键教训：权重不能用「门限式」写法（2026-10-08 排查记录）

角色倒伏前两版**完全没效果**，原因不是 uniform 进不了 GPU（实测：整片草能被诊断色染绿），
而是权重被写成了门限式：

```glsl
// ✗ 失败写法：w = 1.0 - smoothstep(pr, pr*1.05, pd);  w *= lev * dist;
//   smoothstep 的过渡区间只有 5%，稍微远一点立刻变 0；再乘 lev（根部≈0）与 dist（远景可能≈0）
//   → 绝大多数顶点 w = 0 → 位移为 0，看起来就是"完全没反应"
```

```glsl
// ✓ 有效写法：线性权重 + 平方，clamp 到 0..1，不拿 dist/lev 当门限
float w = clamp(1.0 - pd / pr, 0.0, 1.0);  w = w * w;
```

排查用的手段（已全部清理，但值得记住）：

1. **诊断染色**：给材质写一个 `sgt_player_edge` 之类的开关参数，让着色器把 ALBEDO 改成纯色
   （注意 `ALBEDO` 只能在 `fragment()` 里改，vertex 里要经 varying 传下去）；
   整片草变色 → 逐材质 uniform 确实进 GPU ✓
2. **常量位移试验**：`if(diag>1.5) VERTEX.x += 20.0 * lev;` —— 草被整片拉飞 → 顶点写入有效 ✓
3. **中间量着色**：把 `pd / w / lev` 映射成 RGB，一眼看出哪一段恒为 0（本次就是靠这个定位到权重）

## 内置草叶面数：1 / 2 / 3 面（工具栏下拉）

插件自带草叶是**十字形 2 个面**（`default_mesh.tres`：8 顶点 / 4 三角形，互成 90°），
约 45° 斜看时有一半草叶接近侧视、视觉上会"发薄"。

**用法**（两处入口，值互相同步）：
- **Inspector**：选中草节点 → `Grass settings` → `Mesh Planes`（显示为 `1 面 / 2 面 / 3 面`）
- **工具栏**：3D 视图上方的 SGT 工具栏里也有一个 `1 面 / 2 面 / 3 面` 下拉

改完立即生效（整片草丛共用网格，
不用重新刷草；已刷的实例顶点数据不变）。

| 面数 | 顶点 / 三角形 | 说明 |
| --- | --- | --- |
| 1 面 | 4 / 2 | 单片，最省；适合超远距离或不需要多角度覆盖的密植 |
| 2 面 | 8 / 4 | 插件原始十字（**默认，行为与升级前完全一致**：直接复用自带 `default_mesh.tres`） |
| 3 面 | 12 / 6 | 互成 60° 的三片，8 个观察方向都有覆盖；顶点数 +50% |

### 实现要点（`grass.gd`）

- `@export_enum("1 面","2 面","3 面") var mesh_planes := 2`，带 `STORAGE` 用法 →
  随场景保存（自检：属性列表含 `mesh_planes`，`usage=4102`；`hint_string="1 面,2 面,3 面"`）
- **网格必须落盘成共享资源**：`addons/simplegrasstextured/generated/plane_{1,3}.tres`
  （2 面仍用插件自带 `default_mesh.tres`）。`_get_shared_plane_mesh()` 优先读文件，
  没有才生成并 `ResourceSaver.save()` 落盘。

> ⚠ **踩坑（重要）：不要在代码里 `new` 一个网格塞给 `multimesh.mesh`**。
> 外部 MultiMesh（`maps/*_grass.res`）保存时会把它**内联复制进自己的文件**
> （表现为 `res://maps/xxx_grass.res::ArrayMesh_yyyy`），于是每换一次面数：
> ① 所有引用它的 `.res` 都被整体改写（git 里一片 modified）；
> ② 每个 `.res` 里都塞了一份网格副本。
> 修复后自检确认：面数 2/1/3 分别指向
> `default_mesh.tres` / `generated/plane_1.tres` / `generated/plane_3.tres`，
> 全部是**外部资源引用**（`resource_path` 非空且不含 `::`）。

> ⚠ 也不要在 `apply_mesh_planes()` 里调 `surface_set_material()`：
> 那会把材质写进**共享**网格文件，污染其他草节点。节点级 `material_override` 优先级更高，足够。
- `_build_plane_mesh(planes)` 代码生成：面片 k 绕 Y 轴转 `2π·k/planes`，
  切线 = 面片右方向，法线 = `right.cross(UP)`，UV 与插件默认逐值一致；
  AABB 与默认网格一致（高度 1、底面在 y=0），所以草的尺寸/贴地不变
- `mesh`（自定义网格）非空时**不覆盖**，面数设置不生效
- `apply_mesh_planes()` 同步替换 `multimesh.mesh` 并挂回材质；`_ready()` 里按 `mesh_planes` 重建

> ⚠ **实测踩坑：Godot 的 `Vector3.cross()` 是左手系** ——
> `Vector3.UP.cross(Vector3(1,0,0))` 返回 `(0,0,-1)`，与数学上的右手叉乘**符号相反**。
> 要拿"朝正面"的法线必须写 `right.cross(UP)`；写成 `UP.cross(right)` 法线会整个翻面。
> （插件自带网格的 plane1 也满足 `right.cross(UP)` 这个约定。）

> ⚠ **实测踩坑：不要对动态属性直接写 `int(x)`**。
> `_grass_selected` 是弱类型（旧版节点 / 换过脚本），`int(_grass_selected.mesh_planes)`
> 一旦值类型不对就每帧抛 `Invalid call. Nonexistent 'int' constructor.`。
> 必须像 `plugin.gd::_read_planes()` 那样**逐类型判断**：
> `is int → clampi` / `is float → 四舍五入再夹` / 其它一律退回 2。
> （自检覆盖 int/float/越界/null/字符串/Vector3/bool/无该属性 共 15 例，全部安全。）

> 自检结果：面数 1/2/3 顶点数 4/8/12 正确；3 面两两线夹角 60.00°/59.996°/60.004°；
> 每片法线⟂面片；切 2→1→3 面时 `multimesh.mesh` 顶点数 8→4→12 正确。

## 注意（升级插件时）

本改动直接写在 addon 原文件里（`grass.gd` / `plugin.gd` 中带 `★ 本项目改动` 注释），
从上游重新安装 SimpleGrassTextured 会覆盖这些改动，需要重新补：

1. `grass.gd`：实例读取与按下标删除的接口；
2. `plugin.gd`：`_enter_tree` 里的停靠面板挂载、选择变化同步、`focus_grass_point`、`delete_grass_instances`、外挂相关方法、`_exit_tree` 清理；
3. `plugin.gd` 里保留上游原有的「burnable 组」等其他本项目改动。

> `scripts/wind.gd` 的修复**不在 addon 目录里**，重装插件不会丢。
