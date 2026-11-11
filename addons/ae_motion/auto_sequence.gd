extends Node
##
## auto_sequence.gd —— 按顺序播放 AnimationPlayer 里的多段动画，最后一段循环。
## 由导入器自动挂上，不需要手写代码。
##
## 切段方式：等 animation_finished，推迟一帧后直接 play 下一段。
## 因为段与段的值在设计上就是连续的，一帧的间隔在画面上看不出来，
## 而且不会像 queue() 那样在播放器内部重置时停顿。
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

	_ap.animation_finished.connect(_on_finished)
	_ap.play(sequence[0])


func _on_finished(anim_name: String) -> void:
	var i := sequence.find(anim_name)
	if i < 0 or i + 1 >= sequence.size():
		return
	await get_tree().process_frame
	if is_instance_valid(_ap):
		_ap.play(sequence[i + 1])
