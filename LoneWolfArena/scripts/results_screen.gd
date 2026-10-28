class_name ResultsScreen
extends Control
## End-of-round results over the (still rendering) arena. setup(result) gets the dictionary
## built by arena.gd: won, draw, invalid, kills, damage, headshots, accuracy, time, xp, enemy,
## mode, map, weapon, score_player, score_bot, hp_left, difficulty, taken.
## Layout (reference result screens, original art): mode + map top-left; a medal emblem with
## the big title (gold VICTORY / grey DEFEAT / white DRAW / red INVALID) top centre; the round
## score; a stats table (ELIMINATIONS, DAMAGE, HEADSHOTS, ACCURACY, TIME, HP LEFT) with your
## row in blue; an honour tag; XP gained with an animated level bar; PLAY AGAIN (yellow, node
## PlayAgain) and LOBBY (grey, node Lobby) bottom-right. Works unpaused at time scale 1.

const COLUMNS := ["ELIMINATIONS", "DAMAGE", "HEADSHOTS", "ACCURACY", "TIME", "HP LEFT"]

var _result := {}
var _kind := "victory"            # victory | defeat | draw | invalid
var _medal: Control
var _xp_bar: Control
var _xp_fill := 0.0               # 0..1 shown in the bar
var _xp_from := 0.0
var _level_label: Label
var _t := 0.0
var _built := false
var _again: Button
var _table: Control
var _levelled := false
var _xp_to := 0.0
var _lv_before := 1
var _xp_t0 := 0                   # ticks (ms) when the XP bar starts filling (real time)
var _intro_t0 := 0                # ticks (ms) of the intro (fade, medal pop, title slide)
var _title: Control
var _title_x := 0.0


func setup(result: Dictionary) -> void:
	_result = result
	UI.full_rect(self)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _built:
		return
	_built = true
	var won: bool = result.get("won", false)
	var draw: bool = result.get("draw", false)
	var invalid: bool = result.get("invalid", false)
	_kind = "invalid" if invalid else ("draw" if draw else ("victory" if won else "defeat"))
	_hide_match_hud()
	_build()
	_animate_in()


## The in-match HUD (score bar, buttons, kill feed) goes away under the results.
func _hide_match_hud() -> void:
	var scene := get_tree().current_scene if is_inside_tree() else null
	var h: Variant = scene.get("hud") if scene else null
	if h is CanvasItem:
		(h as CanvasItem).visible = false


static func honour(result: Dictionary) -> String:
	if result.get("invalid", false):
		return ""
	var alive := int(result.get("hp_left", 0)) > 0
	if int(result.get("headshots", 0)) >= 2:
		return "SHARPSHOOTER"
	if int(result.get("taken", 999)) < 50 and alive:
		return "UNTOUCHABLE"
	if alive and int(result.get("hp_left", 0)) < 30:
		return "CLUTCH"
	return "FIGHTER"


func _title_text() -> String:
	return {"victory": "VICTORY", "defeat": "DEFEAT", "draw": "DRAW", "invalid": "INVALID"}[_kind]


func _palette() -> Array:
	# [title top, title bottom, medal light, medal dark]
	match _kind:
		"victory":
			return [Color(1, 0.97, 0.8), Color(1.0, 0.70, 0.08), Color(1.0, 0.84, 0.32), Color(0.78, 0.48, 0.02)]
		"defeat":
			return [Color(0.86, 0.86, 0.88), Color(0.52, 0.53, 0.56), Color(0.66, 0.67, 0.70), Color(0.33, 0.34, 0.37)]
		"draw":
			return [Color(1, 1, 1), Color(0.78, 0.84, 0.92), Color(0.86, 0.9, 0.96), Color(0.45, 0.52, 0.62)]
		_:
			return [Color(1, 0.62, 0.55), Color(0.86, 0.18, 0.14), Color(0.95, 0.4, 0.32), Color(0.55, 0.1, 0.08)]


func _build() -> void:
	var r := _result
	var pal := _palette()
	# Backdrop: darken the arena, more on the left and at the bottom.
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.04, 0.42)
	UI.full_rect(shade)
	add_child(shade)
	var side := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.55)], [0.45, Color(0, 0, 0, 0.1)], [1.0, Color(0, 0, 0, 0.35)]], true)
	UI.full_rect(side)
	add_child(side)
	var low := UI.gradient_rect([[0.0, Color(0, 0, 0, 0)], [0.6, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.7)]])
	UI.full_rect(low)
	add_child(low)
	# Mode + map, top-left.
	var head := VBoxContainer.new()
	head.position = Vector2(40, 24)
	head.add_theme_constant_override("separation", -6)
	add_child(head)
	head.add_child(UI.shadowed(UI.label(String(r.get("mode", "LONE WOLF")).to_upper(), 36, UI.TEXT, "heavy")))
	head.add_child(UI.shadowed(UI.label(String(r.get("map", "CARGO CAGE")).to_upper(), 28, Color(0.72, 0.72, 0.74), "heavy")))
	var sub := UI.label("VS %s  ·  %s  ·  %s" % [String(r.get("enemy", "BOT")).to_upper(), String(r.get("difficulty", "")).to_upper(),
		String(r.get("weapon", "")).to_upper()], 16, UI.TEXT_DIM, "bold")
	head.add_child(UI.spacer(8))
	head.add_child(sub)
	# Medal + title, top centre.
	_medal = Control.new()
	_medal.anchor_left = 0.5
	_medal.anchor_right = 0.5
	_medal.offset_left = -190
	_medal.offset_right = 190
	_medal.offset_top = 6
	_medal.offset_bottom = 176
	_medal.pivot_offset = Vector2(190, 85)
	_medal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_medal.draw.connect(_draw_medal)
	if _kind == "defeat":
		_medal.material = _desaturate()
	add_child(_medal)
	var title := UI.shadowed(UI.outlined(UI.label(_title_text(), 104, Color.WHITE, "italic"), 12, Color(0.06, 0.04, 0.02, 0.95)), Vector2(0, 6), Color(0, 0, 0, 0.45))
	title.name = "Title"
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.offset_top = 118
	title.offset_bottom = 248
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.material = Loading.gradient_text_material(pal[0], pal[1], 130.0)
	title.pivot_offset = Vector2(0, 65)
	add_child(title)
	# Round score: [YOU n] : [n BOT]
	var score := HBoxContainer.new()
	score.anchor_left = 0.5
	score.anchor_right = 0.5
	score.offset_left = -200
	score.offset_right = 200
	score.offset_top = 244
	score.offset_bottom = 284
	score.alignment = BoxContainer.ALIGNMENT_CENTER
	score.add_theme_constant_override("separation", 8)
	add_child(score)
	score.add_child(_score_plate("YOU", int(r.get("score_player", 0)), UI.BLUE, true))
	var colon := UI.label(":", 30, UI.TEXT, "number")
	colon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score.add_child(colon)
	score.add_child(_score_plate(String(r.get("enemy", "BOT")).to_upper(), int(r.get("score_bot", 0)), UI.ORANGE, false))
	if _kind == "invalid":
		var why := UI.outlined(UI.label("INTEGRITY CHECK FAILED  -  THIS MATCH DOES NOT COUNT", 18, Color(1, 0.6, 0.55), "bold"), 4)
		why.anchor_left = 0.0
		why.anchor_right = 1.0
		why.offset_top = 290
		why.offset_bottom = 316
		why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(why)
	_build_table()
	_build_footer()


func _score_plate(who: String, n: int, col: Color, left: bool) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	var name_p := PanelContainer.new()
	name_p.add_theme_stylebox_override("panel", UI.chamfer(Color(0, 0, 0, 0.55), 8, 0, Color.TRANSPARENT, 12.0, ["tl"] if left else ["br"]))
	var nl := UI.label(who, 17, UI.TEXT, "bold")
	nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nl.custom_minimum_size = Vector2(110, 0)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if left else HORIZONTAL_ALIGNMENT_LEFT
	nl.clip_text = true
	name_p.add_child(nl)
	var num_p := PanelContainer.new()
	num_p.add_theme_stylebox_override("panel", UI.box(col, 0, 0, Color.TRANSPARENT, 12.0))
	num_p.custom_minimum_size = Vector2(48, 40)
	var num := UI.label(str(n), 30, UI.TEXT, "number")
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num_p.add_child(num)
	if left:
		h.add_child(name_p)
		h.add_child(num_p)
	else:
		h.add_child(num_p)
		h.add_child(name_p)
	return h


func _build_table() -> void:
	var r := _result
	var table := VBoxContainer.new()
	table.name = "Stats"
	table.anchor_left = 0.5
	table.anchor_right = 0.5
	table.offset_left = -560
	table.offset_right = 560
	table.offset_top = 328
	table.offset_bottom = 450
	table.add_theme_constant_override("separation", 2)
	add_child(table)
	_table = table
	resized.connect(_layout_table)
	_layout_table.call_deferred()
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", UI.box(Color(0.19, 0.185, 0.18, 0.92), 0, 0, Color.TRANSPARENT, 0.0))
	header.custom_minimum_size = Vector2(0, 38)
	table.add_child(header)
	var hh := HBoxContainer.new()
	header.add_child(hh)
	var name_h := UI.label("PLAYER", 16, UI.TEXT_DIM, "bold")
	name_h.custom_minimum_size = Vector2(250, 0)
	name_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hh.add_child(name_h)
	for c in COLUMNS:
		var l := UI.label(c, 16, UI.TEXT_DIM, "bold")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hh.add_child(l)
	# Your row.
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, 74)
	row.name = "YourRow"
	row.draw.connect(func() -> void:
		var s := row.size
		row.draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.32, 0.55, 0.92))
		row.draw_rect(Rect2(250, 0, s.x - 250, s.y), Color(0.02, 0.39, 0.6, 0.95))
		row.draw_rect(Rect2(250, 0, s.x - 250, 2), Color(0.35, 0.75, 1.0, 0.9))
		row.draw_rect(Rect2(250, s.y - 2, s.x - 250, 2), Color(0.35, 0.75, 1.0, 0.9))
		row.draw_rect(Rect2(0, 0, 250, s.y), Color(0, 0, 0, 0.35)))
	table.add_child(row)
	var rh := HBoxContainer.new()
	UI.full_rect(rh)
	row.add_child(rh)
	var who := HBoxContainer.new()
	who.custom_minimum_size = Vector2(250, 0)
	who.add_theme_constant_override("separation", 10)
	rh.add_child(who)
	who.add_child(UI.spacer(0))
	var av := UI.texture("emblem.png")
	if av:
		var a := TextureRect.new()
		a.texture = av
		a.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		a.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		a.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		a.custom_minimum_size = Vector2(56, 56)
		a.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		who.add_child(a)
	var nv := VBoxContainer.new()
	nv.alignment = BoxContainer.ALIGNMENT_CENTER
	nv.add_theme_constant_override("separation", -4)
	var pname := UI.label(String(Game.profile.get("name", "PLAYER")), 24, UI.TEXT, "bold")
	pname.clip_text = true
	pname.custom_minimum_size = Vector2(160, 0)
	nv.add_child(pname)
	nv.add_child(UI.label("LV %d" % Game.level(), 15, UI.ACCENT, "bold"))
	who.add_child(nv)
	var t := float(r.get("time", 0.0))
	var values := [
		[float(r.get("kills", 0)), "%d"], [float(r.get("damage", 0)), "%d"], [float(r.get("headshots", 0)), "%d"],
		[float(r.get("accuracy", 0.0)), "%d%%"], [t, "time"], [float(r.get("hp_left", 0)), "%d"],
	]
	# Final values at once (a screenshot or a slow frame never shows placeholders); each
	# number pops in turn.
	var i := 0
	for v in values:
		var l := UI.label(_fmt(float(v[0]), String(v[1])), 38, UI.TEXT, "number")
		l.name = "Value_" + COLUMNS[i].replace(" ", "_")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		rh.add_child(l)
		l.resized.connect(func() -> void: l.pivot_offset = l.size * 0.5)
		var tw := create_tween()
		tw.tween_interval(0.3 + i * 0.06)
		tw.tween_property(l, "scale", Vector2(1.3, 1.3), 0.08)
		tw.tween_property(l, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		i += 1


func _layout_table() -> void:
	if _table == null:
		return
	var vw := size.x if size.x > 10.0 else get_viewport_rect().size.x
	var w := minf(vw - 80.0, 1120.0)
	_table.offset_left = -w * 0.5
	_table.offset_right = w * 0.5


func _fmt(x: float, fmt: String) -> String:
	if fmt == "time":
		var s := int(x)
		return "%d:%02d" % [s / 60, s % 60]
	return fmt % roundi(x)


func _build_footer() -> void:
	var r := _result
	# Honour tag + XP (bottom-left).
	var box := VBoxContainer.new()
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 40
	box.offset_right = 560
	box.offset_top = -214
	box.offset_bottom = -30
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	var tag := honour(r)
	if tag != "":
		var tp := PanelContainer.new()
		tp.name = "Honour"
		tp.add_theme_stylebox_override("panel", UI.chamfer(UI.ACCENT, 12, 0, Color.TRANSPARENT, 16.0, ["tl", "br"], 0.0))
		tp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var th := HBoxContainer.new()
		th.add_theme_constant_override("separation", 10)
		var icon_name: String = {"SHARPSHOOTER": "v_headshot", "UNTOUCHABLE": "v_helmet", "CLUTCH": "v_medkit"}.get(tag, "v_fist")
		th.add_child(UI.icon(icon_name, 30, UI.INK))
		var tl := UI.label(tag, 28, UI.INK, "heavy")
		tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		th.add_child(tl)
		var note := UI.label({"SHARPSHOOTER": "2+ HEADSHOTS", "UNTOUCHABLE": "UNDER 50 DAMAGE TAKEN", "CLUTCH": "WON UNDER 30 HP"}.get(tag, "STOOD YOUR GROUND"), 14, Color(UI.INK, 0.7), "bold")
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		th.add_child(note)
		tp.add_child(th)
		box.add_child(tp)
	# XP gained + level bar.
	var xp := int(r.get("xp", 0))
	var total := int(Game.profile.get("xp", 0))
	var recorded := Game.last_result == r
	var before := maxi(total - xp, 0) if recorded else total
	var after := before + xp
	var lv_before := 1 + before / Game.XP_PER_LEVEL
	var lv_after := 1 + after / Game.XP_PER_LEVEL
	_xp_from = float(before % Game.XP_PER_LEVEL) / Game.XP_PER_LEVEL
	var to := float(after % Game.XP_PER_LEVEL) / Game.XP_PER_LEVEL + float(lv_after - lv_before)
	var xr := HBoxContainer.new()
	xr.add_theme_constant_override("separation", 12)
	box.add_child(xr)
	var xpl := UI.shadowed(UI.label("+%d XP" % xp, 34, UI.ACCENT if xp > 0 else UI.TEXT_DIM, "number_italic"))
	xpl.name = "XpGain"
	xr.add_child(xpl)
	_level_label = UI.label("LV %d" % lv_before, 22, UI.TEXT, "bold")
	_level_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xr.add_child(_level_label)
	_xp_bar = Control.new()
	_xp_bar.custom_minimum_size = Vector2(400, 14)
	_xp_bar.draw.connect(_draw_xp)
	box.add_child(_xp_bar)
	var lv_note := UI.label("%d / %d XP TO LEVEL %d" % [after % Game.XP_PER_LEVEL, Game.XP_PER_LEVEL, lv_after + 1], 14, UI.TEXT_DIM, "bold")
	box.add_child(lv_note)
	_xp_fill = _xp_from
	_levelled = lv_after != lv_before
	_xp_to = to
	_lv_before = lv_before
	_xp_t0 = Time.get_ticks_msec() + 450
	# Buttons (bottom-right).
	var btns := HBoxContainer.new()
	btns.anchor_left = 1.0
	btns.anchor_right = 1.0
	btns.anchor_top = 1.0
	btns.anchor_bottom = 1.0
	btns.offset_left = -560
	btns.offset_right = -32
	btns.offset_top = -96
	btns.offset_bottom = -30
	btns.alignment = BoxContainer.ALIGNMENT_END
	btns.add_theme_constant_override("separation", 16)
	add_child(btns)
	var again := UI.hero_button("PLAY AGAIN", 34, Vector2(270, 66))
	again.name = "PlayAgain"
	_again = again
	again.pressed.connect(func() -> void:
		again.disabled = true
		Loading.start_match(get_tree().current_scene))
	btns.add_child(again)
	var lobby := UI.button("LOBBY", 30, "light", Vector2(230, 66))
	lobby.name = "Lobby"
	lobby.pressed.connect(Game.goto_lobby)
	btns.add_child(lobby)


## The XP bar fills over 0.9 s of real time (it never lags behind on slow frames).
func _step_xp() -> void:
	if _xp_bar == null or _xp_t0 == 0:
		return
	var k := clampf((Time.get_ticks_msec() - _xp_t0) / 900.0, 0.0, 1.0)
	if k <= 0.0:
		return
	var x := lerpf(_xp_from, _xp_to, 1.0 - pow(1.0 - k, 2.0))
	var lv := _lv_before + int(floor(x))
	_xp_fill = x - floor(x)
	if lv != _lv_before and _level_label.text != "LV %d" % lv:
		_level_label.text = "LV %d" % lv
		Audio.play("kill_confirm", -8.0)
	_xp_bar.queue_redraw()
	if k >= 1.0:
		_xp_t0 = 0


func _draw_xp() -> void:
	var s := _xp_bar.size
	var pts := UI.chamfer_points(Rect2(Vector2.ZERO, s), 5.0, ["br"])
	_xp_bar.draw_colored_polygon(pts, Color(0, 0, 0, 0.55))
	var w := s.x * clampf(_xp_fill, 0.0, 1.0)
	if w > 1.0:
		_xp_bar.draw_rect(Rect2(2, 2, w - 4, s.y - 4), UI.ACCENT)
		_xp_bar.draw_rect(Rect2(2, 2, w - 4, 3), Color(1, 0.95, 0.75))
	var old := s.x * clampf(_xp_from, 0.0, 1.0)
	if old > 1.0 and not _levelled:
		_xp_bar.draw_rect(Rect2(2, 2, old - 4, s.y - 4), Color(0.85, 0.6, 0.05))
	_xp_bar.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(1, 1, 1, 0.25), 1.0)


func _draw_medal() -> void:
	var pal := _palette()
	var light: Color = pal[2]
	var dark: Color = pal[3]
	var c := Vector2(_medal.size.x * 0.5, 80)
	var shine := _kind == "victory" or _kind == "draw"
	# rays
	if shine:
		var n := 18
		for i in n:
			var a := TAU * i / n + _t * 0.15
			var a2 := a + TAU / n * 0.35
			_medal.draw_colored_polygon(PackedVector2Array([c, c + Vector2(cos(a), sin(a)) * 150.0, c + Vector2(cos(a2), sin(a2)) * 150.0]),
				Color(light, 0.10))
	# wings: three slanted bars each side
	for sgn: float in [-1.0, 1.0]:
		for k in 3:
			var y := c.y - 30 + k * 22
			var x0 := c.x + sgn * (78 + k * 6)
			var len := 92.0 - k * 22.0
			var pts := PackedVector2Array([Vector2(x0, y), Vector2(x0 + sgn * len, y - 10), Vector2(x0 + sgn * (len - 14), y + 8), Vector2(x0, y + 14)])
			var cols := PackedColorArray([light, light.lerp(dark, 0.4), dark, dark])
			_medal.draw_polygon(pts, cols)
	# hexagon shield
	var hexo := PackedVector2Array()
	var hexi := PackedVector2Array()
	var colso := PackedColorArray()
	for i in 6:
		var a := TAU * i / 6.0 + PI / 6.0
		hexo.append(c + Vector2(cos(a), sin(a)) * 78.0)
		hexi.append(c + Vector2(cos(a), sin(a)) * 64.0)
		colso.append(light.lerp(dark, clampf((sin(a) + 1.0) * 0.5, 0.0, 1.0)))
	_medal.draw_polygon(hexo, colso)
	_medal.draw_colored_polygon(hexi, Color(0.07, 0.065, 0.06))
	var em := UI.texture("emblem.png")
	if em:
		var tint := Color.WHITE if _kind == "victory" else (Color(0.75, 0.75, 0.78) if _kind != "invalid" else Color(1, 0.5, 0.45))
		_medal.draw_texture_rect(em, Rect2(c - Vector2(56, 56), Vector2(112, 112)), false, tint)
	var outline := hexo.duplicate()
	outline.append(hexo[0])
	_medal.draw_polyline(outline, Color(1, 1, 1, 0.5), 2.0, true)


## Grey-out for the DEFEAT medal (the emblem art is orange).
static func _desaturate() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nvoid fragment() {\n\tvec4 c = texture(TEXTURE, UV) * COLOR;\n\tfloat l = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n\tCOLOR = vec4(vec3(l) * vec3(0.95, 0.97, 1.0), c.a);\n}\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


## Intro in real time (it finishes on time even when frames are slow): fade in, the medal pops,
## the title slides in from the left.
func _animate_in() -> void:
	_title = get_node_or_null("Title") as Control
	if _title:
		_title_x = _title.position.x
	_intro_t0 = Time.get_ticks_msec()
	_step_intro()


func _step_intro() -> void:
	if _intro_t0 == 0:
		return
	var e := (Time.get_ticks_msec() - _intro_t0) / 1000.0
	modulate.a = clampf(e / 0.25, 0.0, 1.0)
	var k := clampf(e / 0.5, 0.0, 1.0) - 1.0
	var pop := 1.0 + 2.70158 * k * k * k + 1.70158 * k * k          # back ease-out
	_medal.scale = Vector2.ONE * lerpf(0.4, 1.0, pop)
	if _title:
		var kt := clampf((e - 0.1) / 0.4, 0.0, 1.0)
		_title.modulate.a = kt
		_title.position.x = _title_x - 60.0 * pow(1.0 - kt, 3.0)
	if e >= 0.6:
		_intro_t0 = 0


func _process(delta: float) -> void:
	_t += delta
	_step_intro()
	_step_xp()
	if _medal and (_kind == "victory" or _kind == "draw"):
		_medal.queue_redraw()
	if _again:
		_again.queue_redraw()
