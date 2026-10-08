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

## 实现位置

- 面板：`addons/simplegrasstextured/gui/grass_list_dock.gd`（纯代码构建 UI，无场景文件）
- 挂载 / 定位 / 删除：`addons/simplegrasstextured/plugin.gd`
  - `_enter_tree()` 里 `add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, _gui_grass_list)`
  - `focus_grass_point(world_position)`：移动编辑器 3D 相机 + 高亮环
  - `set_selection_highlights(positions)` / `clear_selection_highlights()`：多选时给每一株放一个高亮环（最多 `LOCATE_MAX_MARKERS = 256` 个）
  - `delete_grass_instances(grass, indices)`：走 `get_undo_redo()`，`add_do_method` / `add_undo_method` 指向 `grass.replace_multimesh_with()`
- 只读/删除接口：`addons/simplegrasstextured/grass.gd`
  - `get_instance_count()` / `get_instance_position()` / `get_instance_positions()` / `get_instance_transform_safe()`
  - `delete_instances_by_indices(indices)`（返回删除前的 MultiMesh 与高度图，供撤销）
  - `replace_multimesh_with(multi_new, height_map)`（撤销 / 重做统一入口）

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

## 注意（升级插件时）

本改动直接写在 addon 原文件里（`grass.gd` / `plugin.gd` 中带 `★ 本项目改动` 注释），
从上游重新安装 SimpleGrassTextured 会覆盖这些改动，需要重新补：

1. `grass.gd`：实例读取与按下标删除的接口；
2. `plugin.gd`：`_enter_tree` 里的停靠面板挂载、选择变化同步、`focus_grass_point`、`delete_grass_instances`、`_exit_tree` 清理；
3. `plugin.gd` 里保留上游原有的「burnable 组」等其他本项目改动。
