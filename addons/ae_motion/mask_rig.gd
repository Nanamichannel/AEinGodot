extends SubViewport
##
## mask_rig.gd —— 把逐帧蒙版多边形画进一个 SubViewport，输出成遮罩纹理
##
## 优点：着色器里只采一次纹理，不管蒙版有多少点，成本恒定。
##
## 由导入器自动创建。也可以手动用：
##   1. SubViewport（尺寸=合成尺寸，transparent_bg=true，update_mode=ALWAYS）
##      挂本脚本，子节点放一个 Polygon2D（白色）
##   2. 目标 Sprite2D 的 material 用 mask_tex.gdshader
##   3. 目标节点挂 mask_apply.gd，把 mask_viewport 指向这个 SubViewport
##

@export var frames: Array = []          # [[毫秒, [x1,y1,x2,y2,...]], ...] 合成坐标
@export var loop := false
@export var enabled := true
@export var comp_size := Vector2(1920.0, 1080.0)   # 多边形点所在的坐标系尺寸

var _t := 0.0
var _poly: Polygon2D


func _ready() -> void:
	_poly = null
	for c in get_children():
		if c is Polygon2D:
			_poly = c
			break
	if _poly == null:
		_poly = Polygon2D.new()
		_poly.name = "MaskPoly"
		add_child(_poly)
	_poly.color = Color(1, 1, 1, 1)
	_poly.antialiased = false
	_apply(0.0)


func _process(delta: float) -> void:
	if not enabled or frames.is_empty() or _poly == null:
		return
	_t += delta * 1000.0
	var total := float(frames[frames.size() - 1][0])
	if _t > total and total > 0.0:
		_t = fmod(_t, total) if loop else total
	_apply(_t)


func _apply(ms: float) -> void:
	if _poly == null or frames.is_empty():
		return
	var current: Array = frames[0]
	for f in frames:
		if float(f[0]) <= ms:
			current = f
		else:
			break
	var src: Array = current[1]
	# 视口可能比合成小（省性能），点要按比例缩放
	var k := Vector2(float(size.x), float(size.y)) / comp_size
	var pts := PackedVector2Array()
	for i in range(src.size()):
		pts.append(Vector2(float(src[i][0]), float(src[i][1])) * k)
	_poly.polygon = pts
