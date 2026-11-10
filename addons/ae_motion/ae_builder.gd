@tool
extends RefCounted
##
## ae_builder.gd —— 把 ae-motion/1 JSON 建成场景 + AnimationPlayer。
## 不依赖编辑器，也不依赖任何工程的路径，全部由参数传入。
##
## 图层两种形态：
##   - 普通层：一张 PNG（Sprite2D）
##   - 序列帧层：json 里带 frames 字段（AnimatedSprite2D），像素烘好，
##     位置/层级/时间窗仍然吃 json 的轨道
##

var _by_index := {}
var _nodes := {}
var _layer_list := []
var _root: Node2D
var _missing := []
var _missing_frames := []
var _blend_skipped := []
var _heavy_frames := []
var _frames_size_mismatch := []
var _lines: PackedStringArray = []
var _art_dir := ""
var _frames_root := ""
var _out_scene := ""
var _fps := 60.0
var _comp_size := Vector2(1920, 1080)
var _comp_space_layers := {}


func build(json_path: String, art_dir: String, out_scene: String, frames_dir: String = "") -> Dictionary:
	_by_index.clear()
	_nodes.clear()
	_missing.clear()
	_missing_frames.clear()
	_blend_skipped.clear()
	_heavy_frames.clear()
	_frames_size_mismatch.clear()
	_lines = PackedStringArray()
	_art_dir = art_dir
	_out_scene = out_scene
	_frames_root = frames_dir if frames_dir != "" else art_dir.path_join("Frames")

	if json_path == "" or not FileAccess.file_exists(json_path):
		return _fail("找不到 JSON：" + json_path)
	if art_dir == "" or not DirAccess.dir_exists_absolute(art_dir):
		return _fail("找不到素材目录：" + art_dir)
	if out_scene == "":
		return _fail("还没选输出场景")

	var f := FileAccess.open(json_path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()

	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return _fail("JSON 解析失败：" + json_path)

	_layer_list = data.get("layers", [])
	for L in _layer_list:
		_by_index[int(L["index"])] = L
	if _layer_list.is_empty():
		return _fail("JSON 里没有 layers")

	var clip: Dictionary = data["clip"]
	_fps = float(clip.get("sampleFps", clip.get("fps", 60.0)))
	var comp: Dictionary = clip.get("comp", {})
	_comp_size = Vector2(float(comp.get("width", 1920)), float(comp.get("height", 1080)))
	_comp_space_layers.clear()

	_root = Node2D.new()
	_root.name = _base_name(String(clip["name"]))

	var sorted: Array = _layer_list.duplicate()
	sorted.sort_custom(func(a, b): return int(a["z"]) > int(b["z"]))
	for L in sorted:
		_node_for(int(L["index"]))

	var stats := _build_animation(data)
	var err := _save()

	_lines.append("========== 完成 ==========")
	_lines.append("合成：%s  %sx%s  %.2fs" % [
		String(clip["name"]),
		str(clip.get("comp", {}).get("width", "?")),
		str(clip.get("comp", {}).get("height", "?")),
		float(clip.get("length", 0.0))
	])
	_lines.append("图层 %d 个｜动画层 %d 个｜轨道 %d 条｜关键帧 %d 个" % [
		_layer_list.size(), stats[0], stats[1], stats[2]
	])
	_lines.append("输出：" + _out_scene)

	if not _blend_skipped.is_empty():
		_lines.append("⚠ 混合模式未实现 %d 层：%s（现在是普通叠加）" % [
			_blend_skipped.size(), ", ".join(PackedStringArray(_blend_skipped))
		])
	if _missing.is_empty():
		_lines.append("贴图：全部找到")
	else:
		_lines.append("缺贴图 %d 张：%s" % [_missing.size(), ", ".join(PackedStringArray(_missing))])
	if not _frames_size_mismatch.is_empty():
		_lines.append("⚠ 序列帧和图层边界不一致，位置会偏：" + ", ".join(PackedStringArray(_frames_size_mismatch)))
	if not _heavy_frames.is_empty():
		_lines.append("⚠ 序列帧太重：%s —— 建议裁切/缩尺寸/降帧率，否则会爆显存" % [
			", ".join(PackedStringArray(_heavy_frames))
		])
	if not _missing_frames.is_empty():
		_lines.append("缺序列帧目录 %d 个：%s（在 %s 下找）" % [
			_missing_frames.size(), ", ".join(PackedStringArray(_missing_frames)), _frames_root
		])

	if err != OK:
		return _fail("保存场景失败：%d" % err)

	return {
		"ok": true,
		"lines": _lines,
		"scene": _out_scene,
		"missing": _missing,
		"missing_frames": _missing_frames
	}


func _fail(msg: String) -> Dictionary:
	_lines.append("失败：" + msg)
	return {"ok": false, "lines": _lines, "scene": "", "missing": _missing}


func _node_for(idx: int) -> Node2D:
	if _nodes.has(idx):
		return _nodes[idx]

	var L: Dictionary = _by_index[idx]
	var frames_name := String(L.get("frames", ""))
	var n: Node2D

	if String(L.get("type", "image")) == "null":
		n = Node2D.new()
		n.z_index = -int(L["z"])

	elif frames_name != "":
		var asp := AnimatedSprite2D.new()
		asp.sprite_frames = _build_sprite_frames(frames_name)
		asp.animation = "default"
		asp.autoplay = "default"
		asp.centered = false
		asp.z_index = -int(L["z"])

		var fa: Dictionary = L["asset"]
		var fanchor: Array = fa["anchor"]
		_check_frames_size(asp.sprite_frames, fa, String(L["name"]))
		if _is_comp_sized(asp.sprite_frames):
			# 整帧序列：像素已经是合成空间的了，位置改成"相对首帧的位移"
			asp.offset = Vector2.ZERO
			_comp_space_layers[idx] = true
		else:
			# 只含这一层内容的序列：按锚点摆
			asp.offset = -Vector2(float(fanchor[0]), float(fanchor[1]))
		n = asp

	else:
		var sp := Sprite2D.new()
		sp.centered = false
		sp.texture = _texture_for(L)
		sp.z_index = -int(L["z"])

		var asset: Dictionary = L["asset"]
		var anchor: Array = asset["anchor"]
		var wj := float(asset["width"])
		var hj := float(asset["height"])
		var tex_size := Vector2(wj, hj)
		if sp.texture != null:
			tex_size = sp.texture.get_size()
		sp.offset = -(Vector2(float(anchor[0]), float(anchor[1])) - (Vector2(wj, hj) - tex_size))
		n = sp

	# 静态值（动画层的轨道会覆盖）
	var p0: Array = L["tracks"]["position"][0]
	n.position = Vector2(float(p0[1]), float(p0[2]))
	var r0: Array = L["tracks"]["rotation"][0]
	n.rotation = deg_to_rad(float(r0[1]))
	var s0: Array = L["tracks"]["scale"][0]
	n.scale = Vector2(float(s0[1]), float(s0[2]))
	var a0: Array = L["tracks"]["alpha"][0]
	n.self_modulate = Color(1.0, 1.0, 1.0, float(a0[1]))

	var blend: Dictionary = L.get("blend", {})
	if String(blend.get("role", "normal")) != "normal":
		_blend_skipped.append("%s(%s)" % [String(L["name"]), String(blend.get("mode", "?"))])

	n.name = _base_name(String(L["name"]))
	_nodes[idx] = n

	var pid = L.get("parent")
	if pid != null and int(pid) > 0:
		var p := _node_for(int(pid))
		p.add_child(n)
		n.name = _unique_name(p, String(n.name), n)
	else:
		_root.add_child(n)
		n.name = _unique_name(_root, String(n.name), n)

	return n


func _build_sprite_frames(folder: String) -> SpriteFrames:
	var sf := SpriteFrames.new()
	sf.set_animation_speed("default", _fps)
	sf.set_animation_loop("default", true)

	var path := _frames_root.path_join(folder)
	var dir := DirAccess.open(path)
	if dir == null:
		_missing_frames.append(folder)
		return sf

	var files: Array = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.get_extension().to_lower() == "png":
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()

	files.sort()
	var loaded := 0
	var failed := 0
	var bytes := 0
	for name in files:
		var t = load(path.path_join(String(name)))
		if t is Texture2D:
			sf.add_frame("default", t as Texture2D)
			var ts: Vector2 = (t as Texture2D).get_size()
			bytes += int(ts.x * ts.y * 4.0)
			loaded += 1
		else:
			failed += 1
			# PNG 还没被 Godot 导入时，每张 load 都会失败并触发一次导入尝试。
			# 连续失败就立刻收手，别把编辑器卡死。
			if loaded == 0 and failed >= 3:
				_missing_frames.append(folder + "（PNG 未导入完成）")
				return sf

	if files.is_empty():
		_missing_frames.append(folder)
	elif bytes > 268435456:
		_heavy_frames.append("%s（%d 帧，约 %d MB 显存）" % [folder, loaded, bytes / 1048576])
	return sf


func _texture_for(L: Dictionary) -> Texture2D:
	var want := _norm(_base_name(String(L["name"])))
	var want_src := _norm(_base_name(String(L["asset"].get("source", ""))))

	var dir := DirAccess.open(_art_dir)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and f.get_extension().to_lower() == "png":
				var base := f.get_basename()
				var tail := base.get_slice("_", base.get_slice_count("_") - 1)
				var k1 := _norm(tail)
				var k2 := _norm(base)
				if k1 == want or k2 == want or (want_src != "" and (k1 == want_src or k2 == want_src)):
					var path := _art_dir.path_join(f)
					var t = load(path)
					if t is Texture2D:
						dir.list_dir_end()
						return t as Texture2D
			f = dir.get_next()
		dir.list_dir_end()

	_missing.append(_base_name(String(L["name"])))
	return null


func _build_animation(data: Dictionary) -> Array:
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	_root.add_child(ap)

	var anim := Animation.new()
	anim.length = float(data["clip"].get("length", 0.0))
	var lib := AnimationLibrary.new()
	lib.add_animation("play", anim)
	ap.add_animation_library("", lib)
	ap.root_node = NodePath("..")
	ap.autoplay = "play"

	var animated := 0
	var tracks := 0
	var keys := 0

	for L in _layer_list:
		if bool(L.get("isStatic", true)):
			continue
		var n = _nodes.get(int(L["index"]))
		if n == null:
			continue
		animated += 1
		var rel := String(_root.get_path_to(n))
		var tk: Dictionary = L["tracks"]

		if _varies(tk["position"], 3):
			var t1 := anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(t1, NodePath(rel + ":position"))
			anim.track_set_interpolation_type(t1, Animation.INTERPOLATION_LINEAR)
			var p_first: Array = tk["position"][0]
			var delta := bool(_comp_space_layers.get(int(L["index"]), false))
			for s in tk["position"]:
				var px := float(s[1])
				var py := float(s[2])
				if delta:
					px -= float(p_first[1])
					py -= float(p_first[2])
				anim.track_insert_key(t1, float(s[0]) / 1000.0, Vector2(px, py))
				keys += 1
			tracks += 1

		if _varies(tk["rotation"], 2):
			var t2 := anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(t2, NodePath(rel + ":rotation"))
			anim.track_set_interpolation_type(t2, Animation.INTERPOLATION_LINEAR)
			for s in tk["rotation"]:
				anim.track_insert_key(t2, float(s[0]) / 1000.0, deg_to_rad(float(s[1])))
				keys += 1
			tracks += 1

		if _varies(tk["scale"], 3):
			var t3 := anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(t3, NodePath(rel + ":scale"))
			anim.track_set_interpolation_type(t3, Animation.INTERPOLATION_LINEAR)
			for s in tk["scale"]:
				anim.track_insert_key(t3, float(s[0]) / 1000.0, Vector2(float(s[1]), float(s[2])))
				keys += 1
			tracks += 1

		if _varies(tk["alpha"], 2):
			var t4 := anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(t4, NodePath(rel + ":self_modulate:a"))
			anim.track_set_interpolation_type(t4, Animation.INTERPOLATION_LINEAR)
			for s in tk["alpha"]:
				anim.track_insert_key(t4, float(s[0]) / 1000.0, float(s[1]))
				keys += 1
			tracks += 1

	return [animated, tracks, keys]


func _save() -> int:
	_set_owner(_root, _root)
	var ps := PackedScene.new()
	var err := ps.pack(_root)
	if err != OK:
		return err

	var dir := _out_scene.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var err2 := ResourceSaver.save(ps, _out_scene)
	_root.free()
	return err2


func _set_owner(n: Node, owner_root: Node) -> void:
	for c in n.get_children():
		c.owner = owner_root
		_set_owner(c, owner_root)


func _varies(track: Array, dims: int) -> bool:
	if track.size() <= 1:
		return false
	var first: Array = track[0]
	for i in range(1, track.size()):
		var row: Array = track[i]
		for d in range(1, dims):
			if absf(float(row[d]) - float(first[d])) > 0.0005:
				return true
	return false


func _base_name(raw: String) -> String:
	var nm := raw.get_slice("/", 0)
	nm = nm.get_basename()
	for ch in [".", ":", "@", "#", "\"", "%", "\n", "\r", "\t"]:
		nm = nm.replace(ch, "_")
	nm = nm.strip_edges()
	if nm == "":
		nm = "layer"
	return nm


func _norm(s: String) -> String:
	var out := s.to_lower()
	for ch in [" ", "-", "_", ".", "(", ")", "（", "）"]:
		out = out.replace(ch, "")
	return out


func _unique_name(parent: Node, base: String, self_node: Node) -> String:
	var nm := base
	var i := 2
	while true:
		var existing := parent.get_node_or_null(NodePath(nm))
		if existing == null or existing == self_node:
			return nm
		nm = "%s_%d" % [base, i]
		i += 1
	return nm


func _is_comp_sized(sf: SpriteFrames) -> bool:
	if sf.get_frame_count("default") == 0:
		return false
	var tex := sf.get_frame_texture("default", 0)
	if tex == null:
		return false
	var ts := tex.get_size()
	return absf(ts.x - _comp_size.x) <= 2.0 and absf(ts.y - _comp_size.y) <= 2.0


func _check_frames_size(sf: SpriteFrames, asset: Dictionary, layer_name: String) -> void:
	if sf.get_frame_count("default") == 0:
		return
	var tex := sf.get_frame_texture("default", 0)
	if tex == null:
		return
	var ts := tex.get_size()
	var w := float(asset.get("width", 0))
	var h := float(asset.get("height", 0))
	if w <= 0.0 or h <= 0.0:
		return
	if _is_comp_sized(sf):
		return
	if absf(ts.x - w) > 2.0 or absf(ts.y - h) > 2.0:
		_frames_size_mismatch.append("%s：序列帧 %dx%d，图层边界 %dx%d" % [
			layer_name, int(ts.x), int(ts.y), int(w), int(h)
		])
