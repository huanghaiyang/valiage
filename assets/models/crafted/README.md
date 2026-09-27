# Blender 自制资产

本目录放**用 Blender 脚本程序化生成**的模型与材质：不需要手工开界面建模，
全部通过命令行运行，可复现、可版本管理。

## 环境

```
D:\blender\blender.exe            Blender 5.2.2 LTS
  自带 Python 3.13.13
  自带 numpy 2.3.4、mathutils、bpy、bmesh
  导出器：glTF(.glb/.gltf)、FBX、OBJ
  渲染引擎：EEVEE（可在无头模式下渲染预览图）
```

无头运行（不弹窗，适合批处理）：

```powershell
& "D:\blender\blender.exe" --background --factory-startup --python "<脚本>.py"
```

要在界面里看建模过程，去掉 `--background`：

```powershell
Start-Process "D:\blender\blender.exe" -ArgumentList @("--factory-startup","--python","D:\sgames\CozyVale\.runtime\make_staffs.py")
```

## 已生成

| 文件 | 网格 | 三角面 | 材质 | 说明 |
| --- | --- | --- | --- | --- |
| `windmill.glb` | 16 | 404 | 5 | 低多边形中世纪风车 |
| `staff_ice.glb` | 7 | 396 | 2 | 冰晶法杖（银杖 + 冰晶簇） |
| `staff_flame.glb` | 6 | 409 | 4 | 烈焰法杖（焦木 + 自发光火焰） |
| `staff_gem.glb` | 8 | 796 | 2 | 宝石法杖（金杖 + 爪托 + 宝石） |
| `staff_thorn.glb` | 19 | 1296 | 3 | 荆棘法杖（树皮 + 藤蔓 + 叶冠 + 刺） |
| `staff_beast.glb` | 8 | 674 | 4 | 兽首法杖（铁杖 + 青铜兽头 + 双角） |
| `staff_angel.glb` | 11 | 800 | 3 | 圣羽法杖（白金 + 光环 + 羽翼） |

法杖共 18 个材质、4371 三角面。预览图：`staff_lineup.png`（6 根并排）。

### 第二批起（分组脚本）

| 批次 | 文件 | 预览图 | 脚本 |
| --- | --- | --- | --- |
| A | `staff_lamp/crescent/trident/swordstaff.glb` | `staff_batchA.png` | `.runtime/make_staffs_a.py` |
| B | `staff_skull/mushroom/cage/tentacle.glb` | `staff_batchB.png` | `.runtime/make_staffs_b.py` |
| C | `staff_lantern/lotus/hourglass/anchor.glb` | `staff_batchC.png` | `.runtime/make_staffs_c.py` |
| D | `staff_plume/sunfire/starorb/voidclaw.glb` | `staff_batchD.png` | `.runtime/make_staffs_d.py` |
| E | `staff_talon/gild/goldvine/frostfire.glb` | `staff_batchE.png` | `.runtime/make_staffs_e.py` |
| F | `staff_sapphire/axestaff/emberspire/sungold.glb` | `staff_batchF.png` | `.runtime/make_staffs_f.py` |
| G | `staff_demon/bramble/violetflame/thunder.glb` | `staff_batchG.png` | `.runtime/make_staffs_g.py` |
| H | `staff_scythe/stonemace/knotwood/prism.glb` | `staff_batchH.png` | `.runtime/make_staffs_h.py` |
| I | `staff_frostbone/duskcrystal/roseflame/crown.glb` | `staff_batchI.png` | `.runtime/make_staffs_i.py` |
| J | `staff_frostbrand/thornclaw/amberlantern/emerald/starfall/woodcrown.glb` | `staff_batchJ.png` | `.runtime/make_staffs_j.py` |
| K | `staff_moonstone/idol/verdant/spikedclub/waraxe/nightstar.glb` | `staff_batchK.png` | `.runtime/make_staffs_k.py` |
| L | `staff_icebloom/treefather/goldloop/pearl/voidhammer/paleblaze.glb` | `staff_batchL.png` | `.runtime/make_staffs_l.py` |
| M | `staff_cindergold/blackbriar/silvergild/royalcrystal/bluetrident/jadeorb.glb` | `staff_batchM.png` | `.runtime/make_staffs_m.py` |
| N | `staff_tealflame/lavender/tealring/palebranch/jadeleaf/duskrose.glb` | `staff_batchN.png` | `.runtime/make_staffs_n.py` |
| O | `staff_bonelance/goldidol/starflame/bluering/frostfan/warhammer.glb` | `staff_batchO.png` | `.runtime/make_staffs_o.py` |
| P | `staff_stoneblock/twinjewel/sunstone/steelblue/azurevine/blackaxe.glb` | `staff_batchP.png` | `.runtime/make_staffs_p.py` |
| Q | `staff_darkbloom/glacialspear/rosegem/opal/amberpearl/frostmace.glb` | `staff_batchQ.png` | `.runtime/make_staffs_q.py` |
| R | `staff_banner/brassflame/bonejewel/embercage/duskblaze/sunpearl.glb` | `staff_batchR.png` | `.runtime/make_staffs_r.py` |
| S | `staff_wingedmace/dragonfang/greatring/rosecage/silverclaw/sunburst.glb` | `staff_batchS.png` | `.runtime/make_staffs_s.py` |
| T | `staff_blossom/arrowhead/duskthorn/emberwreath/palespire/kite.glb` | `staff_batchT.png` | `.runtime/make_staffs_t.py` |
| U | `staff_vinebasket/crescentmoon/goldspear/goldstar/duskmagenta/blueorb.glb` | `staff_batchU.png` | `.runtime/make_staffs_u.py` |
| V | `staff_batwing/pennant/palecrown/sunbrass/starcage/plumflame.glb` | `staff_batchV.png` | `.runtime/make_staffs_v.py` |
| W | `staff_vinecluster/paleaxe/violetblaze/roseblaze/ashflame/jadeblaze.glb` | `staff_batchW.png` | `.runtime/make_staffs_w.py` |
| X | `staff_voidcoil/goldwing/vineice/darkcrescent/violettongue/gildamethyst.glb` | `staff_batchX.png` | `.runtime/make_staffs_x.py` |
| Y | `staff_radiantcross/duskclaw/stormcore/tealoracle/vinecrystal/stonemask/coilflare.glb` | `staff_batchY.png` | `.runtime/make_staffs_y.py` |
| Z | `staff_goldpetal/tripleband/broadaxe/frostburst/stormbraid/stardome/starblaze.glb` | `staff_batchZ.png` | `.runtime/make_staffs_z.py` |
| — | `elder_village/outpost_a/outpost_b.glb` | `elders.png` | `.runtime/make_elder.py` |

进度：**146 / 146** —— `refs/staff/_cut/` 的 146 张切图全部精做完毕，无剩余。
每根都是独立造型 + 独立材质 + 独立顶点色烘焙，没有模板批量套。
元素分布：冰 27 / 奥术 25 / 神圣 21 / 自然 20 / 火 18 / 大地 18 / 雷 17。
单根面数 870~2112，全库合计约 21 万三角面。

公用图元与渲染/导出逻辑在
`.runtime/blender_kit.py`（`lathe / shard / uv_sphere / torus / blade / feather / box /
tube / plate / crescent / mesh_obj / ring_of / spiral / zigzag / bake_vertex_colors /
clear_layout_offset`）。

生成脚本在 `.runtime/`：`make_windmill.py`、`make_staffs.py`、`make_staffs_a..z.py`。
`make_staffs_y.py` / `make_staffs_z.py` 支持 `STAFF_ONLY=a,b` 环境变量只重建指定的几根
（用于重导卡住的 glb）。

### 造型铁律

* **刃/叶/尖这类形状必须"截面渐尖"**。等截面图元（`torus` 圆环、`lathe` 回转体）
  压扁之后宽度还是均匀的，做出来是"马蹄铁"不是镰刀 —— 得沿路径扫出渐变的扁截面
  （参考 `make_staffs_h.py` 里的 `crescent()`）。
* **`plate()` 只吃凸轮廓**。它用质心扇形三角剖分，带深凹口的形状（冠齿、弯月）
  会自交；凹得深就拆成"凸底板 + 独立零件"（参考 `make_staffs_i.py` 的 `crown`）。
* **转 0.7~0.9 弧度是"斜向上"，超过 1.2 就"横着支棱出去"**。翅膀/冠齿/四肢这类
  零件按这个范围给角度，不然会变成横在旁边的两片叶子。**"贴/包"在杆上的装饰要压到
  0.5 以下**，不然会变成一圈倒刺。
* **环形排布的尖刺要放射，必须绕 Y 倾斜**。`rotate_axis` 是局部后乘，
  `Rz(a)` 之后绕 X 倾斜得到的方向水平分量是**切向**（方位角 +90°），
  一整圈会拧成螺旋扇；绕 Y 倾斜才是径向 `(cos a, sin a)`。
* **"从杆上伸出来"的零件，起点要落在杆/颈托的半径之内**，否则渲染出来是一块
  浮在轴外的碎片（黑刃战杖的背刺放在 `x=-0.135`、而颈托半径只有 0.06 就是这个坑）。
* **图元函数签名是 `(name, 造型参数..., mat, coll)`**，`mat` 和 `coll` 永远在图元参数之后。
* **要"不整齐"就用固定表而不是随机**（霜翎法杖九片冰翎的长度表）：随机每次跑出来
  不一样、出问题复现不了，固定表既可复现又能微调。
* **头部越大，杆在游戏里越细**。法杖按"总长 = 1.25m"归一化，头占了总高的一半时
  缩放系数只有约 0.5，0.03 的杆半径实际只剩 1.6cm，游戏里几乎看不见。
  巨环/大球/大笼这类头特别大的，杆要预先做粗 1.5 倍左右。
* **剩下这批优先找"主体形状"的差异**（旗、钟、镜、书、笼、网、伞、灯笼），
  而不是换宝石颜色 —— 1.25m 的尺度上颜色差异几乎看不出，形状差异看得出来。
* **`plate()` 最通用的用法是"正多边形当圆盘/菱盘"**：正多边形天然是凸的，
  正好满足质心扇形剖分的要求。`disc(r, seg, thick)` 一行生成任意边数的厚板，
  配上 `crescent()`（包边）和 `shard()`（刺/晶），一根杖的头就拼完了。
* **`plate()` 的边界**：凸多边形（任意边数）直接用；**凹多边形必须手动拆成若干凸块**
  （蝙蝠翼的膜 = 四块三角板，每块由两根"指骨"+翼根构成），或者改用 `tube` 扫
  （`curl()` / `crescent()` 就是扫出来的）。
* **同一构图骨架也能靠轮廓拉开差异**：四根"杆 + 焰"的杖分别做成
  六片焰冠 / 单片大泪滴 / 四片窄高焰 / 三瓣郁金香，在 1.25m 尺度上完全认得出是四根。
  换轮廓比换颜色有效。
* **比"换轮廓"更彻底的是换"头部主体类型"**：光面大球 + 四根钩爪框住（虚空缠）、
  羽毛扇（金翼）、分枝树冠（藤冰枝）、一对钩刃夹一颗钻（黑月）、空的金焰框（金焰紫晶）——
  在 132 根里各只有一根，一眼认得出。
* **别往杆下方挂太长/太斜的东西**。`normalize_base()` 只保证"底在 y=0"，
  **不保证总高**：底叶伸到 `z=-0.66` 会把整根抬到 2.21 高，运行时按 1.25m 归一化后
  杆和枝**整体细 1.47 倍**，渲染出来像豆芽。实测 `lift`（最低点相对 y=0 的深度）
  控制在 **≤0.4**（batch W/X 十二根实测 0.17~0.38）。这和"大主体会把杆压细"是同一个机制。
* **`crescent()` / `torus(arc<1)` 的 `start` 是"从 +X 逆时针算起的角度"**（0=右，π/2=上）。
  想做"向上外张的一对角"就把弧放在 `start≈-0.2` 到 `+1.0`；写成 `start=-1.0`
  会得到两只**朝下撇的八字胡**。角的位置一改，挂在这对角的尖上的珠子也要跟着改。
* **"一圈爪兜住中央主体"的构图，爪根半径 `r` 要大于主体半径 30% 以上**。
  这轮 `stormcore` 的 `r=0.070` 而核半径 0.064，爪贴着你长，把该露出来的琥珀核全挡住了。
* **衬托件被主体挡住时，要"放大衬托件 + 收窄主体"一起做**，只放大衬托件会让头变臃肿
  （`tealoracle` 的青焰叶 0.44→0.52 同时橙晶 0.105→0.088）。
* **新写盘的 `.glb` 若 `reimport` 一直返回 `skipped_non_imported`，直接用
  `godot --headless --path . --import`**。删档重导只能救回一部分，CLI 导入器一次过。

### 材质配色铁律（反复踩出来的）

Blender 5 默认用 AgX，脚本里已显式设成 `Standard`；但即使在 `Standard` 下，
**基色亮度 + 自发光强度一旦超过约 1.0，颜色就会被推到纯白**——玉石会变白球、
蓝晶会变白刃、紫色焰心会变白点，而且"看代码看不出来，只有渲染预览图才暴露"。
所以：想保留色相，就按 **基色压暗 + 自发光 ≤ 1.2** 来配。

## 约定（踩过的坑）

* **原点必须在底面中心**，且底面在 `y = 0`。游戏的 `_model_place_offset()` 会把模型
  底面抬到地表；原点偏了放置就会错位 —— 这是"模型高度偏差"那类问题的根源。
  本目录所有 GLB 都验证过 `base_y = +0.00`。
* **flat shading**：所有面 `use_smooth = False`，与游戏低多边形风格一致。
* **顶点色要烘**：每个面的材质基色写进 `Col` 顶点色通道。游戏里植被类材质会被风摇
  shader `material_override` 覆盖，颜色只能靠顶点色带过去，否则变白模
  （对应 `vegetation.gd` 的 `_bake_surface_colors()`）。本目录所有 GLB 都验证过
  `vcol_surfaces == 网格数`。
* **零件用局部空间建模再摆放**。如果把零件按世界坐标建好、再给 `object.rotation_euler`，
  旋转是绕**世界原点**做的，顶端零件会被甩到画面外。正确做法是图元在原点建好，
  统一用 `location` / `rotation_euler` 摆放。
* **色彩管理**：Blender 5 默认 AgX 会把高亮自发光去饱和成近白。低多边形卡通风格
  要"所见即所写"，脚本里显式设 `scene.view_settings.view_transform = "Standard"`。
* **自动取景**：改过 `location` 之后 `ob.matrix_world` 是懒更新的，算包围盒前必须
  `bpy.context.view_layer.update()`，否则拿到过期矩阵（实测包围盒只有一根杖宽）。
* **导出前必须还原"预览排布偏移"**。批量建模时为出一张并排预览图，会给每根杖加
  `ob.location.x += dx`。这个偏移如果没还原就会**烘进 GLB**，模型原点不再位于
  底面中心（实测冰杖偏 `x≈-2.30`、羽翎杖偏 `x≈-1.95`，逐根不同）。
  统一用 `blender_kit.clear_layout_offset(objs, dx)`，在 `export_objects()` 前调用。
  游戏侧另有一层兜底：`held_staff._shaft_axis()` 会取最下面那段网格的水平中心当杖轴。

## 另一条用途：图像处理

Blender 自带的 Python 有 **numpy 2.3.4**，可以在无头模式下当图像处理引擎用
（不依赖 Pillow，本机 pip 装不上 Pillow/numpy，这条路绕开了它）：
`bpy.data.images.load()` 解码 → `image.pixels.foreach_get()` 拿 float 缓冲 →
numpy 做 alpha 连通域分析 → 纯 Python 写 PNG。

`refs/staff` 的 5 张素材图（每张 2048×1152、6×4 网格）已用这条路切出 **146 根法杖**，
输出在 `refs/staff/_cut/`，联系表 `refs/staff/_cut/_contact_sheet.png`，
脚本 `.runtime/blender_cut_staff.py`。
