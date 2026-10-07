# Blender 预览导出（TSCN）技术文档

> 覆盖：`addons/blend_tools/`（预览窗口 + 导出）、`tools/glb_simplify.py`、`tools/glb_split.py`
> 适用：Godot 4.7.2 / forward_plus / 本项目「警告即错误」
> 本文所有 API 行为与数值均为**本项目实测**结论 ✓（非推测 ✗）

---

## 1. 它是什么

文件系统里右键 `.blend` →「预览并导出 TSCN…」→ 打开预览窗口：

```
┌─────────────┬────────────────────────────┐
│ 对象 / 三角  │  3D 预览（可旋转/平移/缩放） │
├─────────────┴────────────────────────────┤
│ 全选 全不选                                │
│ [导出选中 -> 单个 .tscn…] [-> 文件夹…]      │
│ 保留面数比例  [1.0]                        │
└──────────────────────────────────────────┘
```

- **预览**：把 `.blend` 导入后的网格画出来（**始终画全部节点** ✓，与勾选无关 ✗）
- **导出**：把**勾选**的 `MeshInstance3D` 写成 `.tscn`，材质**单独**写成 `.tres`

---

## 2. 原导出流程（未减面时，这是基线 ✓）

```
export_nodes(nodes, out_path, single_file, init_wind, shader_path, ratio)
 └─ _build_scene(nodes, src_dir, out_dir, mat_cache, single, …)
      ① root = Node3D.new()                        根节点名取自对象名
      ② 对每个勾选的 MeshInstance3D（mi）：
           src_mesh = mi.get_meta("blend_orig_mesh")    ★ **原始网格**（不是预览那份替身 ✓）
           mesh = src_mesh.duplicate(true)
           逐 surface：
               src   = mesh.surface_get_material(s)
               key   = _mat_key(src)
               mat   = _build_material(src, src_dir, out_dir, key, init_wind, shader_path)
                       └─ ResourceSaver.save(mat, "<out_dir>/_blend_mat_<名字>.tres")   ★ 材质独立成 .tres
               mesh.surface_set_material(s, mat)
           copy = MeshInstance3D.new(); copy.mesh = mesh
           轴心归位（single=逐文件导出时归位；合并时保留相对布局 ✓）
      ③ ps = PackedScene.new(); ps.pack(root)
 └─ ResourceSaver.save(ps, out_path)                  ★ 写出 .tscn（内嵌网格数据 ✓）
```

### 关键事实（决定了"减面"该插在哪 ✓）

| 事实 | 结论 |
|---|---|
| `.tscn` 里内嵌的是**网格数据**（顶点/索引） | `.tscn` 体积 ≈ 网格大小 ✓ |
| 材质在**独立 `.tres`** 里，且**引用贴图路径** | 贴图**不会**被拷进 `.tscn` ✓ |
| 这条链路里**没有 `.glb`** | `blend_src` 只是 `.blend` 所在目录 ✓ |
| `mi.get_meta("blend_orig_mesh")` | 导出用的是**原始网格** ✓（预览会把 `mi.mesh` 换成带贴图的替身 ✗） |

---

## 3. 减面链路（本次新增 ✓）

### 3.1 为什么必须经过一个临时 glb

- **Godot 没有网格减面 API** ✗（`tools/glb_simplify.py` 开头原文：只有内置 LOD 链，**不能指定比例** ✓）
- 项目里唯一能按比例减面的是外部工具 `@gltf-transform/cli simplify`（内含 meshoptimizer ✓）
- 它是**文件型**工具：**只吃 `.glb`，只吐 `.glb`**
- ⇒ 网格 → 临时 glb → 减面 → 读回 → **只取 Mesh**

### 3.2 正确插入点

```
_build_scene() 里，取到 src_mesh 之后、duplicate 之前：
    if _ratio > 0 and _ratio < 1:
        src_mesh = _decimate_mesh(src_mesh, _ratio, mi)      # ★ mi = **预览里那个真实节点** ✓
```

**为什么必须借"真实节点"** ✓：实测自建游离子树（`Node3D + MeshInstance3D`）导出时，
`GLTFDocument.append_from_scene` 会写出**只有 276 字节的空 glb** ✗
→ 下游 `glb_simplify.py` 直接 `struct.error` ✗。

### 3.3 `_decimate_mesh(src, ratio, mi)` 的完整步骤

```
① bare = src.duplicate(true)；逐 surface 把材质置 null      ← 只几何进 glb ✓（否则贴图被写进 glb ✗ → 1GB ✗）
   prev = mi.mesh ; mi.mesh = bare                          ← 借用真实节点 ✓
② doc.append_from_scene(mi, st) → write_to_filesystem(临时 glb)
   mi.mesh = prev                                           ← 立刻还原 ✓（预览不受影响 ✓）
   校验：临时 glb ≥ 2048 字节 ✓（276 那种空 glb 挡下 ✗）
③ python tools/glb_simplify.py --in 临时.glb --out 低模.glb --ratio R
   （依次试 `python` → `py` ✓；工具自己解决 npx ✓ 见 §5）
④ doc2.append_from_file(低模.glb, st2, 0, base_dir) → generate_scene()
   ★ 鸭子类型取网格 ✓（见 §3.4）
⑤ 把 **src 的材质按 surface 序号回填**到低模 ✓（否则白模 ✗）
⑥ 删临时文件 ✓
任何一步失败 → 返回**原网格** ✓ + 明确 warning ✓（导出永远安全 ✓）
```

### 3.4 ★ 最容易踩的坑：编辑器里的网格节点不是 `MeshInstance3D`

| 环境 | glTF 导入产生的节点 | 网格属性类型 |
|---|---|---|
| **编辑器**（= 插件实际运行环境 ✓） | **`ImporterMeshInstance3D`** ✗（`Node3D` 子类，**不是** `MeshInstance3D` ✗） | **`ImporterMesh`** ✗（不是 `Mesh` ✗） |
| 无头/非编辑器（自测环境 ✗） | `MeshInstance3D` ✓ | `ArrayMesh` ✓ |

⇒ 只认 `MeshInstance3D` + `.mesh` 的扫描在编辑器里**一个都找不到** ✗
→ 表现为 `[BlendExport] 低模里没找到网格 ✗`（而同一段代码 headless 自测却**通过** ✓ —— 极易误判 ✗）。

**正确写法（鸭子类型 ✓）**：

```gdscript
var mm = x.get("mesh") if x is Node3D else null
if mm is Mesh:                      got = mm as Mesh
elif mm != null and mm.has_method("get_mesh"):
    var conv = mm.call("get_mesh")  # ImporterMesh → ArrayMesh
    if conv is Mesh:                got = conv
```

### 3.5 材质规则（★ 树叶/植被问题的根源）

`_build_material()` 的判定链：

```
albedo / normal / rough  ← 先取源材质自身的贴图 ✓
                          再按名字回链：_find_tex(src_dir, base, ["diff","albedo","col","_d."]) 等 ✓
alpha  = _find_tex(src_dir, base, ["alpha","mask","_a."])      ← ★ 独立遮罩
if alpha != null:  → 换成 ShaderMaterial(grass_wind.gdshader)  ← 判据就是"找到了 alpha 贴图"
                    wind_enabled = init_wind（勾选框**只**管这一项 ✓）
else:              → StandardMaterial3D
```

**两条硬性结论** ✓：

| 结论 | 原因 |
|---|---|
| 树/灌木叶片**必须**走 `grass_wind.gdshader` ✓ | 该 shader 第 126/128 行：`albedo_tex` 取颜色、`ALPHA = texture(alpha_tex, UV).r` —— 它支持**颜色 + 独立遮罩**两路 ✓；而 **`StandardMaterial3D` 无法使用独立 alpha 贴图** ✗ → 叶子会变**实心片** ✗ |
| 该 shader **不依赖顶点色** ✓ | 全文无 `COLOR` ✓ —— 曾误以为"树叶片无顶点色所以不能用" ✗，实测**推翻** ✓ |

**albedo 的坑** ✓：若 `albedo` 解析到路径含 `alpha` / `mask` 的贴图 ✗
→ 颜色就会用**遮罩图** ✓ → 表现为"树叶纹理不对/发白" ✓。
已加规则：**自动改用同前缀的 `diff` 颜色图** ✓ 并打印一行：
```
[BlendExport]   albedo 原为遮罩图 ✗ → 已改用颜色图 ✓：…/tree_small_02_leaves_diff_4k.png
```

---

## 4. 导出日志速查（失败时看这几行就能定位 ✓）

```
[BlendExport]   临时 glb 43382936 字节 ✓                      ← <2048 就是空 glb ✗
[BlendExport] ② 外部减面：python …/glb_simplify.py --in … --out … --ratio 0.5000
[BlendExport]   用 python 执行完毕，rc=0
[glb_simplify] 输入 495533 面 -> 输出 247256 面（实际 49.897%，目标 50.000%）   ← 工具自身输出 ✓
[BlendExport]   产物 low.glb = 25569820 字节 ｜ 临时目录：D:/sgames/CozyVale/.runtime/blend_decimate
[BlendExport] 网格减面 ✓ ratio=0.500 ｜ surface 3→3 ｜ 顶点 680089→409399（60.2%）
[BlendExport]   surface 0 ← res://…blend::StandardMaterial3D_td5c8
[BlendExport]   原网格 surface 0：顶点=62772 ｜ UV=62772 ｜ 顶点色=无 ✗
[BlendExport]   低模   surface 0：顶点=33519 ｜ UV=33519 ｜ 顶点色=无 ✗
```

| 日志 | 含义 / 处置 |
|---|---|
| `临时 glb 只有 N 字节 ✗` | 写 glb 失败 ✓（节点未挂树 ✗ / 网格为空 ✓） |
| `glb_simplify 失败 ✗（rc=…, low=… 字节）` | 外部工具失败 ✓（其 stderr 紧随其后 ✓ 见 §5） |
| `读回低模失败 ✗` | `append_from_file` 出错 ✓（检查 `low.glb` 是否存在 ✓） |
| `低模里没找到网格 ✗ ｜ 读回节点统计：{…}` | 节点类型不匹配 ✓（§3.4 ✓） |
| `UV=无 ✗` 或 UV ≪ 顶点数 | UV 丢失/塌缩 ✓ |
| `surface N→M`（N≠M） | 序号对齐会错位 ✓（材质可能贴串 ✓） |

---

## 5. 外部工具与路径约定

### `tools/glb_simplify.py`
```
npx --yes @gltf-transform/cli weld     in.glb  tmp.glb
npx --yes @gltf-transform/cli simplify tmp.glb out.glb --ratio R --error E
python tools/glb_simplify.py --in a.glb --out b.glb --ratio 0.5
```
- `weld` 是必须的 ✓（simplify 只对焊接后的顶点有效 ✓）
- `resolve_executable("npx")` 处理 Windows 上 `npx.cmd` ✓
- **npm 缓存**：优先 `<项目>/.runtime/npm-cache` ✓；建不了就**不设缓存** ✓ ——
  ★ 曾经因为 `makedirs` 抛 `PermissionError` ✗ 导致**整个降模挂掉** ✓ → 上层读回空场景 ✓ → 误报"低模里没找到网格" ✓（已修 ✓）

### 临时文件位置（**项目内** ✓，不写 C 盘 ✗）
```
D:/sgames/CozyVale/.runtime/blend_decimate/
    mesh_raw.glb    我的临时 glb（只几何 ✓）
    mesh_low.glb    glb_simplify 产物（读完即删 ✓）
```
> 历史坑：临时文件曾写在 `user://` ✗ = `%APPDATA%\Godot\app_userdata\…`（**C 盘** ✗）→ 已改为 `res://.runtime/` ✓

---

## 6. 自测方法（不依赖编辑器桥接 ✓）

### 6.1 语法检查（改完必跑 ✓）
```powershell
& "D:\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path D:\sgames\CozyVale `
  --check-only --script res://addons/blend_tools/blend_export.gd
# exit=0 即通过 ✓（user:// 日志告警是沙箱噪音 ✓ 可忽略）
```

### 6.2 端到端自测脚本
`res://.runtime/selftest_decimate.gd`（`extends SceneTree` ✓）
```powershell
& "D:\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path D:\sgames\CozyVale `
  --script res://.runtime/selftest_decimate.gd
```
输出示例（**通过** ✓）：
```
源网格       : surface=1  tris=95204
① 写临时 glb : ok=true  raw=3547260 字节
② glb_simplify: rc=0  low=349140 字节
   | 输入 95204 面 -> 输出 4760 面（实际 5.000%，目标 5.000%）
③ append_from_file: err=0
③ generate_scene : true  读回 MeshInstance3D 数 = 1
```
> ⚠ 脚本要改 `src_glb`（默认取一个 `res://…glb` ✓）；临时文件写在 `res://.runtime/` ✓（`user://` 在沙箱里不可写 ✗）

### 6.3 GDScript 陷阱（本会话踩过的 ✓）
| 陷阱 | 正确写法 |
|---|---|
| `var x := <Variant 调用>` 无法推断 ✗ | 显式标注：`var tn: String = x.get_class()` ✓ |
| 循环变量与**参数重名** ✗ | 换名 ✓（`for node in …` ✓） |
| 删掉变量却漏改引用 ✗ | 删/改后**立刻** `--check-only` ✓ |
| 项目自有 `.gd` 是 **CRLF** ✗ | 多行锚点常失败 ✗ → 用**单行锚点** ✓ 或本地 `edit`（按字节匹配 ✓） |

---

## 7. 兼容性 / 回归清单（改这里时逐条过一遍 ✓）

1. **不减面**（比例 1.0 ✓）时，导出结果必须与**旧版逐项一致** ✓（`.tscn` + `.tres` ✓）
2. 树干（`StandardMaterial3D` ✓）与树叶（`ShaderMaterial(grass_wind)` ✓）**各自正确** ✓
3. 预览窗口的网格**不受导出影响** ✓（材质/网格都要还原 ✓；`duplicate` 后再改 ✓）
4. 导出失败必须**安全回退**（原网格 ✓）且**不破坏** `.tscn` ✓
5. 临时文件只在 `res://.runtime/` ✓，用完清理 ✓
6. 全程**不写 C 盘** ✓
7. 节点勾选：一个模型可能有 `LOD0` / `LOD1` / `trunk` / `leaves_*` 多个**独立**节点 ✓
   → 导"完整一棵树"要勾 **一套 LOD（二选一 ✓）+ trunk + leaves_*** ✓；预览里看到的叠影是 LOD0+LOD1 都画 ✓（正常 ✓）

---

## 8. 待办（不影响功能 ✓）

| # | 内容 |
|---|---|
| ① | 删 `blend_export.gd` 中**无调用点**的废弃函数：`_apply_decimate` / `_decimate_source_glb` / `_find_src_glb` / `_count_tris` / `_copy_materials_by_surface` + `DECIMATE_ENABLED` / `_last_src_dir` / `_last_out_dir`（做法：**整文件读 → 整段删 → `--check-only`** ✓） |
| ② | `tree_small_02_4k.blend` 内部引用了**不存在的** `tree_small_02_rough_4k.exr` ✗ → 每次加载都报错 ✓（与导出无关 ✓）；在 Blender 里删掉该引用即可 ✓ |
| ③ | 右侧"素材块/状态"树的状态列宽 60 → 160 ✓（`名字 (495533 三角)` 会被截断 ✗） |
| ④ | `.runtime/` 加入 `.gitignore` ✓ |
| ⑤ | 减面后若 **surface 数量变化** ✗ → 材质按序号对齐可能错位 ✓ → 建议改成**按材质名匹配** ✓ |
