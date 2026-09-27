# Blender 自制资产

本目录（以及其父级的 `.runtime/*.py`）用来放**用 Blender 脚本程序化生成**的模型与材质。
不需要手工开界面建模：全部通过命令行无头运行，可复现、可版本管理。

## 环境

```
D:\blender\blender.exe            Blender 5.2.2 LTS
  自带 Python 3.13.13
  自带 numpy 2.3.4、mathutils、bpy、bmesh
  导出器：glTF(.glb/.gltf)、FBX、OBJ
  渲染引擎：EEVEE（可在无头模式下渲染预览图）
```

运行方式（无头、不弹窗）：

```powershell
& "D:\blender\blender.exe" --background --factory-startup --python "<脚本>.py"
```

## 已生成

| 文件 | 说明 |
| --- | --- |
| `windmill.glb` | 低多边形中世纪风车。16 个网格、404 三角面、5 个材质 |
| `windmill_preview.png` | EEVEE 渲染的预览图（确认造型用） |
| `.runtime/make_windmill.py` | 生成脚本（造型 + 材质 + 自动取景渲染 + 导出 GLB） |

风车配色对齐游戏现有 KayKit 资源：木 `#F2BD9E`、深木 `#6F4C38`、屋顶红 `#C84A4A`、
石基 `#BDBDBD`、帆布 `#ECE6D4`。整体高约 8.6m（含叶片跨度 9.2m）。

Godot 侧已验证：`GLB meshes=16 surfaces=16 tris=404 materials=5 importable=true`。

## 新增自定资产的写法

1. 复制 `.runtime/make_windmill.py`，改造型参数与材质；
2. 脚本里 `bpy.ops.export_scene.gltf(..., export_format="GLB", use_selection=True)`；
3. 把 `.glb` 放到本目录，Godot 会自动导入（编辑器需 `filesystem_manage(op="scan")`）；
4. 在 `scripts/world/vegetation.gd` 的对应分类数组里加上 `res://assets/models/crafted/xxx.glb`。

### 约定

* **原点放在底面中心**：游戏的放置逻辑（`_model_place_offset`）会把模型底面抬到地表，
  原点居中才不会偏。
* **flat shading**：所有面 `use_smooth = False`，与游戏的低多边形风格一致。
* **材质用 Principled BSDF**，导出后是 `StandardMaterial3D`；游戏对植被类会
  `material_override` 换成风摇材质（那时颜色靠顶点色承载，见下）。
* **顶点色**：如果模型要当植被（会被风摇材质覆盖），需要把每个 surface 的基色烘进
  顶点色，否则会变白模 —— 参考 `vegetation.gd` 的 `_bake_surface_colors()`。

## 另一条用途：图像处理

Blender 自带的 Python 有 **numpy 2.3.4**，可以在无头模式下当图像处理引擎用
（不依赖 Pillow）：用 `bpy.data.images.load()` 解码 PNG → `image.pixels` 拿 float
缓冲 → numpy 做 alpha 连通域分析 → 再用纯 Python 写 PNG。适合批量切图这类任务。
