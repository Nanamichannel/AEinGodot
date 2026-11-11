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
var _frame_ms := 16.666667
var _comp_size := Vector2(1920, 1080)
var _comp_space_layers := {}


func build(json_path: String, art_dir: String, out_scene: String, frames_dir: String = "", segments_spec: String = "") -> Dictionary:
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
	var segments := _parse_segments(segments_spec, float(clip.get("length", 0.0)))
	for seg in segments:
		if bool(seg["loop"]):
			var drift := _seam_drift(data, float(seg["start"]), float(seg["end"]))
			var off := _best_seam_offset(data, float(seg["start"]), float(seg["end"]), float(clip.get("sampleFps", 60.0)))
			if absf(off) > 0.0001:
				seg["start"] = float(seg["start"]) + off
				seg["end"] = float(seg["end"]) + off
			var drift2 := _seam_drift(data, float(seg["start"]), float(seg["end"]))
			_lines.append("段 %s：%.2fs – %.2fs（循环，接缝微调 %+.2fs，首末差 %.1f → %.1f px）" % [
				seg["name"], seg["start"], seg["end"], off, drift, drift2
			])
		else:
			_lines.append("段 %s：%.2fs – %.2fs（一次性）" % [seg["name"], seg["start"], seg["end"]])
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

	var stats := _build_animation(data, segments)
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
		asp.sprite_frames = _build_sprite_frames(frames_name, bool(L.get("framesLoop", true)))
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

	# AE 的层序是全局的：必须关掉相对父级累加，否则子层会被父级的 z 拖到底下
	n.z_as_relative = false

	# 静态值（动画层的轨道会覆盖）
	if bool(_comp_space_layers.get(idx, false)):
		# 整帧序列：像素已经含位置，姿态归零，位移只由轨道给（相对首帧）
		n.position = Vector2.ZERO
		n.rotation = 0.0
		n.scale = Vector2.ONE
	else:
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


func _build_sprite_frames(folder: String, loop_anim: bool = true) -> SpriteFrames:
	var sf := SpriteFrames.new()
	sf.set_animation_speed("default", _fps)
	sf.set_animation_loop("default", loop_anim)

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


func _build_animation(data: Dictionary, segments: Array) -> Array:
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	_root.add_child(ap)

	var lib := AnimationLibrary.new()
	var animated := 0
	var tracks := 0
	var keys := 0
	var first_name := ""

	for L in _layer_list:
		if not bool(L.get("isStatic", true)):
			animated += 1

	for seg in segments:
		var s := float(seg["start"])
		var e := float(seg["end"])
		var loop := bool(seg["loop"])
		var anim := Animation.new()
		anim.length = maxf(e - s, 0.001)
		if loop:
			anim.loop_mode = Animation.LOOP_LINEAR

		var seg_name := String(seg["name"])
		if first_name == "":
			first_name = seg_name

		for L in _layer_list:
			if bool(L.get("isStatic", true)):
				continue
			var n = _nodes.get(int(L["index"]))
			if n == null:
				continue
			var rel := String(_root.get_path_to(n))
			var tk: Dictionary = L["tracks"]
			var comp_space := bool(_comp_space_layers.get(int(L["index"]), false))

			var kp := _slice(tk["position"], s, e, loop)
			if _varies(kp, 3):
				var t1 := anim.add_track(Animation.TYPE_VALUE)
				anim.track_set_path(t1, NodePath(rel + ":position"))
				anim.track_set_interpolation_type(t1, Animation.INTERPOLATION_LINEAR)
				var base_p := Vector2(float(kp[0][1]), float(kp[0][2]))
				for row in kp:
					var v := Vector2(float(row[1]), float(row[2]))
					if comp_space:
						v -= base_p
					anim.track_insert_key(t1, float(row[0]) / 1000.0, v)
					keys += 1
				tracks += 1

			var kr := _slice(tk["rotation"], s, e, loop)
			if _varies(kr, 2):
				var t2 := anim.add_track(Animation.TYPE_VALUE)
				anim.track_set_path(t2, NodePath(rel + ":rotation"))
				anim.track_set_interpolation_type(t2, Animation.INTERPOLATION_LINEAR)
				var base_r := float(kr[0][1])
				for row in kr:
					var rv := float(row[1])
					if comp_space:
						rv -= base_r
					anim.track_insert_key(t2, float(row[0]) / 1000.0, deg_to_rad(rv))
					keys += 1
				tracks += 1

			var ks := _slice(tk["scale"], s, e, loop)
			if _varies(ks, 3):
				var t3 := anim.add_track(Animation.TYPE_VALUE)
				anim.track_set_path(t3, NodePath(rel + ":scale"))
				anim.track_set_interpolation_type(t3, Animation.INTERPOLATION_LINEAR)
				var base_sx := maxf(float(ks[0][1]), 0.0001)
				var base_sy := maxf(float(ks[0][2]), 0.0001)
				for row in ks:
					var sv := Vector2(float(row[1]), float(row[2]))
					if comp_space:
						sv = Vector2(sv.x / base_sx, sv.y / base_sy)
					anim.track_insert_key(t3, float(row[0]) / 1000.0, sv)
					keys += 1
				tracks += 1

			var ka := _slice(tk["alpha"], s, e, loop)
			if _varies(ka, 2):
				var t4 := anim.add_track(Animation.TYPE_VALUE)
				anim.track_set_path(t4, NodePath(rel + ":self_modulate:a"))
				anim.track_set_interpolation_type(t4, Animation.INTERPOLATION_LINEAR)
				for row in ka:
					anim.track_insert_key(t4, float(row[0]) / 1000.0, float(row[1]))
					keys += 1
				tracks += 1

		if loop:
			var last_t := 0.0
			for i in range(anim.get_track_count()):
				var kc := anim.track_get_key_count(i)
				if kc > 0:
					last_t = maxf(last_t, anim.track_get_key_time(i, kc - 1))
			if last_t > 0.0:
				anim.length = last_t

		lib.add_animation(seg_name, anim)

	ap.add_animation_library("", lib)
	ap.root_node = NodePath("..")
	if first_name != "":
		ap.autoplay = first_name

	return [animated, tracks, keys]


func _slice(track: Array, s: float, e: float, loop: bool) -> Array:
	var out: Array = []
	var end_ms := int(round((e - s) * 1000.0))
	for row in track:
		var t := float(row[0]) / 1000.0
		if t + 0.0001 >= s and t - 0.0001 <= e:
			var nr: Array = row.duplicate()
			nr[0] = int(round((t - s) * 1000.0))
			out.append(nr)

	if out.is_empty():
		var only: Array = track[0].duplicate()
		only[0] = 0
		out.append(only)

	out[0][0] = 0

	if loop and out.size() >= 2:
		# 去漂移：把首末差值按时间比例平摊到整段，末帧自然回到首帧。
		# 15 秒里 21px 的漂移，摊到 900 帧是每帧 0.024px，肉眼不可见；
		# 这样闭合帧就不需要"一帧内猛拉"，突变消失。
		var f0: Array = out[0]
		var ln: Array = out[out.size() - 1]
		var total_ms := float(end_ms)
		if total_ms > 0.0:
			for row in out:
				var w := float(row[0]) / total_ms
				for j in range(1, row.size()):
					row[j] = float(row[j]) - (float(ln[j]) - float(f0[j])) * w

	if loop:
		var first: Array = out[0]
		# 闭合帧必须严格贴在上一帧之后一帧，否则间隔可能是两帧，看起来像跳
		var close_ms := end_ms + int(round(_frame_ms))
		if out.size() >= 2:
			close_ms = int(out[out.size() - 1][0]) + int(round(_frame_ms))
		var extra: Array = first.duplicate()
		extra[0] = close_ms
		out.append(extra)
	return out


func _parse_segments(spec: String, total: float) -> Array:
	var segs: Array = []
	var txt := spec.strip_edges()
	if txt != "":
		for chunk in txt.split(";", false):
			var part := chunk.strip_edges()
			if part == "":
				continue
			var loop := false
			if part.ends_with("*"):
				loop = true
				part = part.substr(0, part.length() - 1).strip_edges()
			var nm := "seg"
			var range_txt := part
			var colon := part.find(":")
			if colon >= 0:
				nm = part.substr(0, colon).strip_edges()
				range_txt = part.substr(colon + 1).strip_edges()
			var dash := range_txt.find("-")
			if dash < 0:
				continue
			var a := float(range_txt.substr(0, dash).strip_edges())
			var b := float(range_txt.substr(dash + 1).strip_edges())
			if b <= a:
				continue
			segs.append({"name": nm, "start": a, "end": b, "loop": loop})

	if segs.is_empty():
		segs.append({"name": "play", "start": 0.0, "end": total, "loop": false})
	return segs

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


func _apply_loop(data: Dictionary, s: float, e: float) -> void:
	var dur := e - s
	var end_ms := int(round(dur * 1000.0))
	for L in data.get("layers", []):
		var tracks: Dictionary = L.get("tracks", {})
		for ch in ["position", "rotation", "scale", "alpha"]:
			var arr: Array = tracks.get(ch, [])
			if arr.is_empty():
				continue

			var out: Array = []
			for row in arr:
				var t := float(row[0]) / 1000.0
				if t + 0.0001 >= s and t - 0.0001 <= e:
					var nr: Array = row.duplicate()
					nr[0] = int(round((t - s) * 1000.0))
					out.append(nr)

			if out.is_empty():
				var only: Array = arr[0].duplicate()
				only[0] = 0
				out.append(only)

			var first: Array = out[0]
			first[0] = 0

			var last: Array = out[out.size() - 1]
			if int(last[0]) >= end_ms - 1:
				# 区间正好有末帧：把它的值换成首帧的值
				last[0] = end_ms
				for i in range(1, last.size()):
					last[i] = first[i]
			else:
				# 区间里没有末帧：补一个和首帧一样的
				var extra: Array = first.duplicate()
				extra[0] = end_ms
				out.append(extra)

			tracks[ch] = out

	data["clip"]["length"] = dur


func _sample_nearest(track: Array, ms: float) -> Array:
	if track.is_empty():
		return []
	var best: Array = track[0]
	var bd := absf(float(track[0][0]) - ms)
	for row in track:
		var d := absf(float(row[0]) - ms)
		if d < bd:
			bd = d
			best = row
	return best


func _seam_drift(data: Dictionary, s: float, e: float) -> float:
	var worst := 0.0
	for L in data.get("layers", []):
		if bool(L.get("isStatic", true)):
			continue
		var arr: Array = L["tracks"]["position"]
		var a := _sample_nearest(arr, s * 1000.0)
		var b := _sample_nearest(arr, e * 1000.0)
		if a.is_empty() or b.is_empty():
			continue
		var d := Vector2(float(b[1]) - float(a[1]), float(b[2]) - float(a[2])).length()
		if d > worst:
			worst = d
	return worst


func _best_seam_offset(data: Dictionary, s: float, e: float, fps: float) -> float:
	var step := 1.0 / maxf(fps, 1.0)
	var best := 0.0
	var best_score := 1e30
	var d := -0.5
	while d <= 0.5 + 0.0001:
		var score := 0.0
		for L in data.get("layers", []):
			if bool(L.get("isStatic", true)):
				continue
			var arr: Array = L["tracks"]["position"]
			var a := _sample_nearest(arr, (s + d) * 1000.0)
			var b := _sample_nearest(arr, (e + d) * 1000.0)
			if a.is_empty() or b.is_empty():
				continue
			var a2 := _sample_nearest(arr, (s + d + step) * 1000.0)
			var b2 := _sample_nearest(arr, (e + d - step) * 1000.0)
			var dv := Vector2(float(b[1]) - float(a[1]), float(b[2]) - float(a[2])).length()
			var v0 := Vector2(float(a2[1]) - float(a[1]), float(a2[2]) - float(a[2]))
			var v1 := Vector2(float(b[1]) - float(b2[1]), float(b[2]) - float(b2[2]))
			score += dv + 0.5 * (v0 - v1).length()
		if score < best_score:
			best_score = score
			best = d
		d += step
	return best
