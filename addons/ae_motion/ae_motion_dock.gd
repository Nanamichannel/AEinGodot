@tool
extends VBoxContainer
##
## 面板：选 JSON / 选素材目录 / 选输出场景 → 自动生成
##

var _json_edit: LineEdit
var _art_edit: LineEdit
var _frames_edit: LineEdit
var _loop_start: LineEdit
var _loop_end: LineEdit
var _out_edit: LineEdit
var _log: TextEdit
var _auto: CheckBox
var _open_after: CheckBox
var _dlg: EditorFileDialog
var _target := ""
var _busy := false


func _ready() -> void:
	custom_minimum_size = Vector2(360, 220)
	add_theme_constant_override("separation", 6)
	_build_ui()


func _build_ui() -> void:
	var title := Label.new()
	title.text = "AE Motion → 场景"
	add_child(title)

	_json_edit = _row("AE 导出的 json", _browse_json)
	_art_edit = _row("素材目录（项目内）", _browse_art)
	_frames_edit = _row("序列帧目录（可选）", _browse_frames)

	var loop_box := VBoxContainer.new()
	var loop_label := Label.new()
	loop_label.text = "循环区间（秒，留空=不循环）"
	loop_box.add_child(loop_label)
	var loop_row := HBoxContainer.new()
	_loop_start = LineEdit.new()
	_loop_start.placeholder_text = "起"
	_loop_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loop_row.add_child(_loop_start)
	var dash := Label.new()
	dash.text = "–"
	loop_row.add_child(dash)
	_loop_end = LineEdit.new()
	_loop_end.placeholder_text = "止"
	_loop_end.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loop_row.add_child(_loop_end)
	var loop_btn := Button.new()
	loop_btn.text = "用全长"
	loop_btn.pressed.connect(_fill_full_length)
	loop_row.add_child(loop_btn)
	loop_box.add_child(loop_row)
	add_child(loop_box)
	_out_edit = _row("输出场景（项目内）", _browse_out)

	var opts := HBoxContainer.new()
	_auto = CheckBox.new()
	_auto.text = "选完自动生成"
	_auto.button_pressed = true
	opts.add_child(_auto)
	_open_after = CheckBox.new()
	_open_after.text = "生成后打开"
	_open_after.button_pressed = true
	opts.add_child(_open_after)
	add_child(opts)

	var run := Button.new()
	run.text = "生成场景"
	run.pressed.connect(_run)
	add_child(run)

	_log = TextEdit.new()
	_log.editable = false
	_log.custom_minimum_size = Vector2(0, 160)
	_log.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_log)

	_dlg = EditorFileDialog.new()
	_dlg.access = EditorFileDialog.ACCESS_FILESYSTEM
	_dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	add_child(_dlg)
	_dlg.file_selected.connect(_on_file_selected)
	_dlg.dir_selected.connect(_on_dir_selected)


func _row(label_text: String, cb: Callable) -> LineEdit:
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	box.add_child(l)
	var h := HBoxContainer.new()
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.placeholder_text = "点右边按钮选择"
	h.add_child(edit)
	var b := Button.new()
	b.text = "…"
	b.pressed.connect(cb)
	h.add_child(b)
	box.add_child(h)
	add_child(box)
	return edit


func _browse_json() -> void:
	_target = "json"
	_dlg.access = EditorFileDialog.ACCESS_FILESYSTEM
	_dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_dlg.clear_filters()
	_dlg.add_filter("*.json", "AE Motion JSON")
	var cur := _json_edit.text.strip_edges()
	if cur != "":
		_dlg.current_dir = cur.get_base_dir()
	_dlg.popup_centered_ratio(0.5)


func _browse_art() -> void:
	_target = "art"
	_dlg.access = EditorFileDialog.ACCESS_RESOURCES
	_dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_dlg.clear_filters()
	if _art_edit.text.strip_edges() != "":
		_dlg.current_dir = _art_edit.text.strip_edges()
	_dlg.popup_centered_ratio(0.5)


func _browse_frames() -> void:
	_target = "frames"
	_dlg.access = EditorFileDialog.ACCESS_RESOURCES
	_dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_dlg.clear_filters()
	if _frames_edit.text.strip_edges() != "":
		_dlg.current_dir = _frames_edit.text.strip_edges()
	elif _art_edit.text.strip_edges() != "":
		_dlg.current_dir = _art_edit.text.strip_edges()
	_dlg.popup_centered_ratio(0.5)


func _browse_out() -> void:
	_target = "out"
	_dlg.access = EditorFileDialog.ACCESS_RESOURCES
	_dlg.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_dlg.clear_filters()
	_dlg.add_filter("*.tscn", "Godot 场景")
	if _out_edit.text.strip_edges() == "":
		_dlg.current_dir = "res://generated"
	_dlg.popup_centered_ratio(0.5)


func _on_file_selected(path: String) -> void:
	match _target:
		"json":
			_json_edit.text = path
			if _out_edit.text.strip_edges() == "":
				var base := path.get_file().get_basename()
				_out_edit.text = "res://generated/%s.tscn" % _safe(base)
		"out":
			_out_edit.text = path
	_after_pick()


func _on_dir_selected(path: String) -> void:
	if _target == "art":
		_art_edit.text = path
		if _frames_edit.text.strip_edges() == "":
			_frames_edit.text = path.path_join("Frames")
	elif _target == "frames":
		_frames_edit.text = path
	_after_pick()


func _after_pick() -> void:
	if _auto.button_pressed:
		await get_tree().create_timer(0.2).timeout
		_run()


func _run() -> void:
	if _busy:
		return
	var j := _json_edit.text.strip_edges()
	var a := _art_edit.text.strip_edges()
	var o := _out_edit.text.strip_edges()
	if j == "" or a == "" or o == "":
		_log.text = "三项都选好才会生成。"
		return

	_busy = true
	_log.text = "生成中…"
	# 先扫一遍，让新放进去的 PNG 有机会被导入
	EditorInterface.get_resource_filesystem().scan()
	var b = load("res://addons/ae_motion/ae_builder.gd").new()
	var fdir := _frames_edit.text.strip_edges()
	var ls := -1.0
	var le := -1.0
	if _loop_start.text.strip_edges() != "" and _loop_end.text.strip_edges() != "":
		ls = float(_loop_start.text.strip_edges())
		le = float(_loop_end.text.strip_edges())
	var res: Dictionary = b.build(j, a, o, fdir, ls, le)
	var text := ""
	for line in res.get("lines", []):
		text += String(line) + "\n"
	_log.text = text
	_busy = false

	if res.get("ok", false):
		EditorInterface.get_resource_filesystem().scan()
		if _open_after.button_pressed:
			EditorInterface.open_scene_from_path(o)


func _safe(s: String) -> String:
	var out := s
	for ch in [".", ":", "@", "/", "\\", "\"", "%"]:
		out = out.replace(ch, "_")
	return out

func _fill_full_length() -> void:
	var j := _json_edit.text.strip_edges()
	if j == "" or not FileAccess.file_exists(j):
		return
	var f := FileAccess.open(j, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		return
	var length := float(data["clip"].get("length", 0.0))
	_loop_start.text = "0"
	_loop_end.text = str(length)