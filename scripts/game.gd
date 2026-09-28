extends Node
## 游戏状态管理（自动加载单例）
## 记录当前工具、搭建状态、场景引用，供各系统间通信

## 工具集：植物不是独立工具，它作为额外变体挂在「树木」「花草」下面
## （见 vegetation.gd 的 _plant_extras），所以这里没有 PLANT。
enum Tool { NONE, WALL, TOWER, ROOF, TERRAIN_RAISE, TERRAIN_LOWER, TERRAIN_FLATTEN, TREE, FLOWER, PATH, DECOR, ERASE, MOUNTAIN }

const TOOL_NAMES := {
	Tool.NONE: "选择",
	Tool.WALL: "墙壁",
	Tool.TOWER: "塔楼",
	Tool.ROOF: "房屋",
	Tool.TERRAIN_RAISE: "地形抬升",
	Tool.TERRAIN_LOWER: "地形下陷",
	Tool.TERRAIN_FLATTEN: "地形平整",
	Tool.TREE: "树木",
	Tool.FLOWER: "花草",
	Tool.PATH: "小径",
	Tool.DECOR: "家具",
	Tool.ERASE: "橡皮擦",
	Tool.MOUNTAIN: "山体",
}

## 当前激活的工具
## 默认**不选中任何放置工具**：开局就举着塔楼/墙壁，点一下鼠标就误建，体验很差。
## 想建造时先在工具栏里点一个（工具列表第一项是"选择"= 无工具）。
var current_tool: int = Tool.NONE:
	set(v):
		current_tool = v
		tool_changed.emit(v)

signal tool_changed(tool: int)

## 生物质余额（操作地形/放置时回收植被获得）
var biomass := 0.0:
	set(v):
		biomass = v
		biomass_changed.emit(v)

signal biomass_changed(value: float)

## 石材余额（石头单独回收为石材，不混入生物质）
var stone := 0.0:
	set(v):
		stone = v
		stone_changed.emit(v)

signal stone_changed(value: float)

## 当前是否处于搭建（拖拽）状态
var is_building := false

## 场景根节点（由 main 注入）
var world: Node3D = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func get_tool_name() -> String:
	return TOOL_NAMES.get(current_tool, "未知")
