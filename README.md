# 温馨山谷 · Cozy Vale

原创卡通风格 3D 搭建沙盒游戏，使用 **Godot 4.5.2** 开发。
玩法体验致敬 Tiny Glade（无网格自由搭建 + 放松治愈氛围），但**所有代码、玩法设计均为原创实现**；美术模型使用 **CC0 免费第三方素材**（来源与许可见下文）。

---

## 🎮 核心玩法

| 工具 | 操作 | 说明 |
|------|------|------|
| 墙壁 | 左键拖拽 | 无网格自由画墙，使用 KayKit 中世纪城墙模块沿路径拼接 |
| 塔楼 | 左键点击 | 放置石砌圆塔（红顶），自动缩放适配 |
| 房屋 | 左键点击 | 放置 KayKit 卡通小屋（白墙红顶、拱形窗户） |
| 抬升 / 下陷 / 平整 | 按住涂抹 | 平滑笔刷编辑地形高度 |
| 树木 / 花草 | 左键点击 | 种植装饰植被（Kenney 低多边形模型） |

**移动视角**：WASD 移动 · 鼠标旋转视角 · Shift 加速 · Space/C 升降 · **T 切换第一/第三人称**（第三人称可见 KayKit 法师角色，角色自动面向移动方向并播放走路/待机动画）
**工具切换**：数字键 1-8（墙壁/塔楼/房屋/抬升/下陷/平整/树木/花草）或点击顶部工具栏
**快捷键**：Ctrl+Z 撤销 · R 重新生成地形 · Esc 释放/捕获鼠标（释放后可点击 UI）

---

## 🚀 运行方式

### 开发模式（推荐）
1. 安装 [Godot 4.5.2](https://godotengine.org/download/archive/4.5.2-stable/)（本目录已内置 `Godot_v4.5.2-stable_win64.exe`）
2. 用 Godot 打开 `CozyVale/project.godot`
3. 按 F5 运行

### 命令行运行
```powershell
.\Godot_v4.5.2-stable_win64_console.exe --path .\CozyVale
```

### 打包 Windows 可执行文件
1. 下载 Godot 4.5.2 Export Templates（编辑器菜单：编辑器 → 管理导出模板 → 下载并安装）
2. 导出预设已配置（`export_presets.cfg` → "Windows Desktop"）
3. 项目 → 导出 → Windows Desktop → 导出项目
4. 产物输出到 `CozyVale/export/CozyVale.exe`

---

## 🗂 项目结构

```
CozyVale/
├── project.godot              # 项目配置（渲染后端、窗口、自动加载）
├── export_presets.cfg         # Windows 导出预设
├── scenes/
│   └── main.tscn              # 主场景
├── scripts/
│   ├── game.gd                # 游戏状态单例（工具枚举、信号）
│   ├── settings.gd            # 渲染质量设置单例
│   ├── main.gd                # 主场景逻辑（世界构建、输入交互）
│   ├── camera_rig.gd          # 第一/第三人称相机控制器（T 键切换）
│   ├── player.gd              # KayKit 法师角色（骨骼动画：待机/走路）
│   ├── world/
│   │   ├── terrain.gd         # 高度图地形 + 刷子编辑 + 碰撞（岩石/草地斑块配色）
│   │   ├── vegetation.gd      # Kenney 模型 MultiMesh 植被系统（树/灌木/花/草/石）
│   │   └── building_manager.gd# KayKit 预制模型搭建系统（墙/塔/屋）+ 撤销栈
│   └── ui/
│       └── game_ui.gd         # 工具栏 UI
└── assets/
    ├── models/
    │   ├── characters/        # KayKit Adventurers（Mage 等 5 个角色，GLB）
    │   ├── buildings/         # KayKit Medieval Hexagon（建筑模块，glTF）
    │   └── nature/            # Kenney Nature Kit（329 个植被模型，GLB）
    ├── shaders/
    │   ├── toon.gdshader      # 卡通三阶渐变光照材质
    │   ├── grass.gdshader     # 草地风动材质
    │   └── fire_tornado.gdshader  # 火焰编织粒子着色器（螺旋前进 + 火舌拉长）
    └── textures/
        └── 法术特效/           # VFX 贴图：T_VFX_* 系列 / 龙卷风/ / kenney/（两个 CC0 贴图包）
```

---

## 🎨 素材来源与许可（CC0 公共领域）

所有第三方模型均为 **CC0 1.0 Universal（公有领域）**，可自由用于商业项目，无需署名（署名仍作为致谢保留）。

| 素材包 | 用途 | 来源 | 许可 |
|--------|------|------|------|
| **KayKit Adventurers** | 玩家角色（Mage/Barbarian/Knight/Rogue） | [KayKit（GitHub）](https://github.com/KayKit-Game-Assets) | CC0 |
| **KayKit Medieval Hexagon** | 建筑模块（城墙/塔楼/小屋） | [KayKit（GitHub）](https://github.com/KayKit-Game-Assets) | CC0 |
| **Kenney Nature Kit** | 植被（树/灌木/花/草/石/蘑菇） | [Kenney.nl](https://kenney.nl/assets/nature-kit) | CC0 |
| **Kenney Particle Pack** | 通用 VFX 贴图：魔法/火焰/火花/星光/拖尾/斩击/烟/光斑等 18 类（透明版 80 张 + 旋转变体 16 张） | [Kenney.nl](https://kenney.nl/assets/particle-pack) | CC0 |
| **Kenney Smoke Particles** | 烟雾/爆炸/闪光**逐帧序列**（whitePuff 25 帧、blackSmoke 25 帧、explosion 9 帧、flash 9 帧），可直接做翻页书动画 | [Kenney.nl](https://kenney.nl/assets/smoke-particles) | CC0 |

> 模型运行时从 `assets/models/` 加载：角色 GLB 附带骨骼动画；植被 GLB 提取 Mesh 后交给 MultiMesh 批量实例化；建筑 glTF 作为预制场景实例化并按 AABB 自动校准尺寸。
>
> VFX 贴图在 `assets/textures/法术特效/`（`kenney/` 子目录下为上述两个贴图包，各包原始许可文件随附为 `LICENSE_*.txt`）。**软 alpha 贴图**（发光/烟雾/噪声/法阵）统一用**无损**导入：`compress/mode=0` 且 `detect_3d/compress_to=0`——后者必须关掉，否则贴图一旦用于 3D 粒子，Godot 会自动改回 VRAM 块压缩，在渐变上产生可见色块。

---

## ⚡ 优化策略（Windows 10/11 · NVIDIA/AMD 双平台）

| 优化项 | 实现方式 |
|--------|---------|
| **渲染后端** | Godot 4 Forward+（Vulkan）——NVIDIA/AMD 均有原生驱动支持 |
| **低配兼容** | `settings.gd` 提供质量档位：可降 MSAA、阴影、分辨率缩放 |
| **植被实例化** | Kenney 模型全部走 MultiMesh，一次 draw call 渲染上千实例 |
| **建筑实例化** | KayKit 建筑按预制场景实例化，段数/缩放自动适配搭建操作 |
| **模型轻量化** | 低多边形 + 内嵌纹理，无额外 PBR 开销 |
| **地形优化** | 高度图 + 单网格重建，编辑区域增量更新 |
| **阴影策略** | 方向光单灯硬阴影，植被 cast_shadow 按需控制 |

---

## 🔧 可扩展方向

- **新增建筑件**：在 `building_manager.gd` 添加新预制模型路径与 `_place_*` 函数即可
- **新增工具**：在 `game.gd` 的 `Tool` 枚举 + `main.gd` 的 `_begin_tool/_end_tool` 添加分支
- **更多植被**：`vegetation.gd` 的模型路径常量添加新 Kenney GLB
- **更换角色**：`player.gd` 的 `CHARACTER_SCENE` 指向 `assets/models/characters/` 下任一 GLB（自带动画）
- **装饰系统**：`Tool.DECOR` / `Tool.PATH` 枚举已预留，可接入灯笼、旗帜、小径
- **场景保存**：`_undo_stack` 已记录全部操作历史，可直接序列化为存档
- **音效音乐**：接入 AudioStreamPlayer 播放环境音乐与搭建反馈音
- **多人/分享**：操作历史可编码为分享字符串，他人一键还原

---

## 📸 预览

项目目录内置开发截图：
- `screenshot_view2.png` —— 初始世界全景
- `screenshot_interaction.png` —— 搭建交互示例
- `screenshot_tps_view.png` —— 第三人称视角预览（可见卡通角色与丰富植被）
- `screenshot_third_party_view.png`（位于 `screenshots/`）—— **第三方模型替换后预览**（KayKit 法师角色 + 小屋/塔楼/围墙 + Kenney 植被）

---

## ⚠️ 说明

- 本项目为**原创代码实现**，未使用 Tiny Glade 的任何素材、代码或名称；仅借鉴其"放松式无网格搭建"的玩法方向。
- 第三方美术模型均为 **CC0 公共领域** 素材，来源见上表。
- 最低配置建议：支持 Vulkan 1.0 的 NVIDIA GTX 900 系 / AMD RX 400 系及以上显卡。
