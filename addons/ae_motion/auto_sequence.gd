extends Node
##
## auto_sequence.gd —— 按顺序播放 AnimationPlayer 里的多段动画。
## 由导入器自动挂上，不需要手写代码。
##
## 用 AnimationPlayer.queue() 串接，段与段之间没有空帧。
##

@export var player_path: NodePath
@export var sequence: PackedStringArray = PackedStringArray()

var _ap: AnimationPlayer


func _ready() -> void:
	_ap = get_node_or_null(player_path) as AnimationPlayer
	if _ap == null:
		_ap = get_parent().get_node_or_null("AnimationPlayer") as AnimationPlayer
	if _ap == null or sequence.is_empty():
		return

	# 先排好队：第 0 段先播，其余依次 queue，播完自动接上，中间不会停
	_ap.play(sequence[0])
	for i in range(1, sequence.size()):
		_ap.queue(sequence[i])