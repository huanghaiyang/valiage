@tool
## 雾掩码资源：把掩码（Image）连同元数据存成一个**独立 .tres** 文件。
##   · 每场景一份、互不影响，跟随项目版本管理
##   · 不写进参数 .tres（那是共享参数），也不写进 .tscn（会把场景撑大）
##   · 驱动直接持有本资源引用 ⇒ 游戏里不需要猜场景名/路径，永远不会错位
class_name FogMaskResource
extends Resource

## 掩码数据：alpha = 权重（0 = 没有雾，1 = 满雾）
@export var mask : Image = null
## 掩码分辨率
@export var resolution : int = 512
## 写入时的覆盖宽度（km）—— 用于校验掩码与当前参数是否匹配
@export var width_km : float = 0.4
## 写入时的雾层参数（排查"掩码与参数对不上"用）
@export var base_height : float = 0.1
@export var thickness : float = 1.0