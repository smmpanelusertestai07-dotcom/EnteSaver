class_name RoomCreate
extends RefCounted
## The CUSTOM ROOM create page (FRIENDS > CUSTOM ROOM, LobbyFriends._build_room_tab), laid out as
## the reference's: small left tabs ROOM and GAME beside the options, CREATE ROOM under them.
## ROOM: room name, password, the mode (LONE WOLF), TEAM MODE SOLO (1 VS 1) / DUO (2 VS 2) / SQUAD
## (4 VS 4) and the players it holds. GAME: presets CLASSIC (today's rules) / CUSTOM and every rule
## RoomRules plays: ROUNDS, HP, MOVEMENT SPEED, JUMP HEIGHT as dark dropdown fields (a tap steps to
## the next choice), the GUN rule, and YES / NO rows with small notched radio tags and a "?" help.
## The draft lives in LobbyFriends (`room_draft`), so a tap that redraws the tab keeps it.
## Node names: RoomPage_<room|game>, RoomName, RoomPin, RoomMode_<1|2|4>, RoomPlayers,
## RoomPreset_<classic|custom>, Rule_<rounds|hp|speed|jump|gun_id> (fields), Rule_gun_<pick|fixed|random>,
## Rule_<key>_<yes|no> (ammo, throw, walls, frags, zone, aim), RoomHelp_<key>, RoomCreate.

const LABEL_W := 170.0
const FIELD_W := 190.0
const ROW_H := 48.0
const YES_NO := [["ammo", "UNLIMITED AMMO", "Reserve ammo never runs out."],
	["throw", "WALLS AND FRAGS", "NO: nobody has shield walls or frags in this room."],
	["walls", "UNLIMITED WALLS", "Shield walls come back as they are used (up to 30 a round)."],
	["frags", "UNLIMITED FRAGS", "Frags come back as they are thrown (up to 30 a round)."],
	["zone", "SAFE ZONE", "NO: the safe zone never closes; a round that runs out of time goes to the higher health."],
	["aim", "AIM ASSIST", "NO: manual aim for everyone, whatever their own setting says."]]


## The page: `lf` holds the draft (room_draft: {page, name, pin, size, rules}) and redraws on a change.
static func build(lf: LobbyFriends) -> Control:
	var d: Dictionary = lf.room_draft
	var page := HBoxContainer.new()
	page.name = "RoomCreatePage"
	page.add_theme_constant_override("separation", 16)
	var tabs := VBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	page.add_child(tabs)
	for t: Array in [["room", "ROOM"], ["game", "GAME"]]:
		var key := String(t[0])
		var b := UI.side_tab(String(t[1]), String(d.page) == key, 18, Vector2(140, 56))
		b.name = "RoomPage_" + key
		b.pressed.connect(func() -> void:
			d.page = key
			lf.redraw_room())
		tabs.add_child(b)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	page.add_child(body)
	if String(d.page) == "game":
		_game(lf, body, d)
	else:
		_room(lf, body, d)
	var make := UI.button("CREATE ROOM", 20, "primary", Vector2(230, 56))
	make.name = "RoomCreate"
	make.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	make.pressed.connect(lf.create_room)
	body.add_child(make)
	return page


static func _room(lf: LobbyFriends, body: VBoxContainer, d: Dictionary) -> void:
	var nm := LineEdit.new()
	nm.name = "RoomName"
	nm.max_length = RoomRules.NAME_MAX
	nm.placeholder_text = "%s'S ROOM" % String(Game.profile.name)
	nm.text = String(d.name)
	_style_edit(nm)
	nm.text_changed.connect(func(s: String) -> void: d.name = s)
	body.add_child(_row("ROOM NAME", nm))
	var pin := LineEdit.new()
	pin.name = "RoomPin"
	pin.max_length = 6
	pin.placeholder_text = "4-6 DIGITS"
	pin.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	pin.text = String(d.pin)
	_style_edit(pin)
	pin.text_changed.connect(func(s: String) -> void:
		var only := ""
		for ch in s:
			if ch >= "0" and ch <= "9":
				only += ch
		if only != s:
			pin.text = only
			pin.caret_column = only.length()
		d.pin = only)
	body.add_child(_row("PASSWORD", pin))
	# PUBLIC (default NO: private as before): the room is listed for every player online
	var pub := HBoxContainer.new()
	pub.add_theme_constant_override("separation", 18)
	for o: Array in [[false, "NO (PRIVATE)"], [true, "YES (LISTED)"]]:
		var on := bool(o[0])
		var r := radio(String(o[1]), bool(d.get("public", false)) == on)
		r.name = "RoomPublic_%s" % ("yes" if on else "no")
		r.pressed.connect(func() -> void:
			d.public = on
			lf.redraw_room())
		pub.add_child(r)
	body.add_child(_row("PUBLIC", pub, help(lf, "public", "PUBLIC",
		"YES: every player online sees the room's name, your name and its ID in CUSTOM ROOM while it is open (a password stays yours; with one, they need it to join). NO: only players you give the ID join.")))
	if bool(d.get("public", false)):
		pin.placeholder_text = "OPTIONAL"
	var mode := field("LONE WOLF", false)
	mode.name = "RoomGameMode"
	body.add_child(_row("MODE", mode, help(lf, "mode", "MODE", "Custom rooms play LONE WOLF on CARGO CAGE: rounds of one life each, the gun picked as the room's rules say.")))
	body.add_child(_row("MAP", _map_tile()))
	var radios := HBoxContainer.new()
	radios.add_theme_constant_override("separation", 18)
	for m: Array in [[1, "SOLO (1 VS 1)"], [2, "DUO (2 VS 2)"], [4, "SQUAD (4 VS 4)"]]:
		var n := int(m[0])
		var r := radio(String(m[1]), int(d.size) == n)
		r.name = "RoomMode_%d" % n
		r.pressed.connect(func() -> void:
			var r0: Dictionary = d.rules
			if RoomRules.is_classic(r0, int(d.size) > 1):
				d.rules = RoomRules.classic(n, String(r0.get("name", "")))     # (CLASSIC follows the mode's rounds)
			d.size = n
			lf.redraw_room())
		radios.add_child(r)
	body.add_child(_row("TEAM MODE", radios))
	var players := field("%d" % (2 * int(d.size)), false)
	players.name = "RoomPlayers"
	body.add_child(_row("PLAYERS", players))


static func _game(lf: LobbyFriends, body: VBoxContainer, d: Dictionary) -> void:
	var team := int(d.size) > 1
	var r: Dictionary = d.rules
	var classic := RoomRules.is_classic(r, team)
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 12)
	for p: Array in [["classic", "CLASSIC"], ["custom", "CUSTOM"]]:
		var key := String(p[0])
		var on := classic == (key == "classic")
		var b := UI.button(String(p[1]), 17, "light" if on else "dark", Vector2(200, 48))
		b.name = "RoomPreset_" + key
		b.pressed.connect(func() -> void:
			if key == "classic":
				d.rules = RoomRules.classic(int(d.size), String(r.get("name", "")))
			d.page = "game"
			lf.redraw_room())
		presets.add_child(b)
	body.add_child(presets)
	var desc := UI.label("Today's rules: the gun pick, 200 HP, the closing zone." if classic
		else "Your own rules: every player in the room plays by them.", 15, UI.TEXT, "semi")
	body.add_child(desc)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	var steps := [["rounds", "ROUNDS", RoomRules.ROUNDS, "FIRST TO %d"], ["hp", "HP", RoomRules.HP, "%d"],
		["speed", "MOVEMENT SPEED", RoomRules.SPEED, "%d%%"], ["jump", "JUMP HEIGHT", RoomRules.JUMP, "%d%%"]]
	for s: Array in steps:
		var key := String(s[0])
		var choices: Array = s[2]
		var f := field(String(s[3]) % int(r[key]), true)
		f.name = "Rule_" + key
		f.pressed.connect(func() -> void:
			var i := choices.find(int(r[key]))
			r[key] = choices[(i + 1) % choices.size()]
			lf.redraw_room())
		grid.add_child(_cell_label(String(s[1])))
		grid.add_child(f)
	body.add_child(grid)
	var guns := HBoxContainer.new()
	guns.add_theme_constant_override("separation", 16)
	for g: Array in [["pick", "PICK"], ["fixed", "ONE GUN"], ["random", "RANDOM"]]:
		var key := String(g[0])
		var b := radio(String(g[1]), String(r.gun) == key)
		b.name = "Rule_gun_" + key
		b.pressed.connect(func() -> void:
			r.gun = key
			lf.redraw_room())
		guns.add_child(b)
	if String(r.gun) == "fixed":
		var gf := field(String(Weapons.DEFS[String(r.gun_id)].name), true)
		gf.name = "Rule_gun_id"
		gf.custom_minimum_size.x = 170
		gf.pressed.connect(func() -> void:
			var list: Array = Weapons.PICKABLE
			r.gun_id = list[(list.find(String(r.gun_id)) + 1) % list.size()]
			lf.redraw_room())
		guns.add_child(gf)
	body.add_child(_row("GUN", guns, help(lf, "gun", "GUN", "PICK: the pick panel as in every match (each side picks for two rounds). ONE GUN: everyone holds the chosen gun all match. RANDOM: a gun drawn for every two rounds, the same for everyone.")))
	var yn := GridContainer.new()
	yn.columns = 2
	yn.add_theme_constant_override("h_separation", 24)
	yn.add_theme_constant_override("v_separation", 6)
	for y: Array in YES_NO:
		yn.add_child(_yes_no(lf, r, String(y[0]), String(y[1]), String(y[2])))
	body.add_child(yn)


## One "LABEL ? (YES) (NO)" option.
static func _yes_no(lf: LobbyFriends, r: Dictionary, key: String, text: String, tip: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Rule_" + key
	row.add_theme_constant_override("separation", 10)
	var l := _cell_label(text)
	row.add_child(l)
	row.add_child(help(lf, key, text, tip))
	for v: Array in [[true, "YES"], [false, "NO"]]:
		var want := bool(v[0])
		var b := radio(String(v[1]), bool(r[key]) == want)
		b.name = "Rule_%s_%s" % [key, "yes" if want else "no"]
		b.custom_minimum_size.x = 76
		b.pressed.connect(func() -> void:
			r[key] = want
			lf.redraw_room())
		row.add_child(b)
	return row


static func _cell_label(text: String) -> Label:
	var l := UI.label(text, 16, UI.TEXT, "bold")
	l.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func _row(text: String, c: Control, extra: Control = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_cell_label(text))
	row.add_child(c)
	if extra != null:
		row.add_child(extra)
	return row


static func _style_edit(le: LineEdit) -> void:
	le.custom_minimum_size = Vector2(380, 46)
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 18)
	var st := UI.box(Color(0, 0, 0, 0.5), 0, 0, Color.TRANSPARENT, 12.0)
	le.add_theme_stylebox_override("normal", st)
	var fs := st.duplicate() as StyleBoxFlat
	fs.border_width_bottom = 2
	fs.border_color = UI.ACCENT
	le.add_theme_stylebox_override("focus", fs)


## A radio choice in the reference's style: a small notched tag (yellow filled when chosen, a grey
## outline otherwise) left of its word.
static func radio(text: String, on: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, ROW_H)
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 16)
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, UI.TEXT if on else UI.TEXT_DIM)
	var st := StyleBoxEmpty.new()
	st.content_margin_left = 26
	st.content_margin_right = 4
	for s: String in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(s, st)
	b.set_meta("on", on)
	b.draw.connect(func() -> void:
		var cy := b.size.y * 0.5
		var pts := PackedVector2Array([Vector2(2, cy - 6), Vector2(12, cy - 6), Vector2(17, cy), Vector2(12, cy + 6), Vector2(2, cy + 6)])
		if on:
			b.draw_colored_polygon(pts, UI.ACCENT)
		else:
			pts.append(pts[0])
			b.draw_polyline(pts, Color(0.7, 0.7, 0.72), 1.5))
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


## A dark dropdown field with a light square and a dark caret at its right end (`live` false: a
## value that cannot change, the square greyed).
static func field(text: String, live: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(FIELD_W, 44)
	b.disabled = not live
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 17)
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_disabled_color"]:
		b.add_theme_color_override(c, UI.TEXT)
	var st := UI.box(Color(0, 0, 0, 0.5), 0, 0, Color.TRANSPARENT, 12.0)
	st.content_margin_right = 52
	var hv := st.duplicate() as StyleBoxFlat
	hv.bg_color = Color(0.1, 0.1, 0.1, 0.6)
	for s: String in ["normal", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(s, st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("hover_pressed", hv)
	b.draw.connect(func() -> void:
		var sq := Rect2(b.size.x - 44, 0, 44, b.size.y)
		b.draw_rect(sq, Color(0.86, 0.86, 0.86) if live else Color(0.45, 0.45, 0.47))
		var c := sq.get_center()
		b.draw_colored_polygon(PackedVector2Array([c + Vector2(-8, -4), c + Vector2(8, -4), c + Vector2(0, 5)]), UI.INK))
	if live:
		b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


## The small grey "?" square: its option's help in a notice.
static func help(lf: LobbyFriends, key: String, title: String, text: String) -> Button:
	var b := Button.new()
	b.name = "RoomHelp_" + key
	b.text = "?"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(30, 30)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", UI.font("heavy"))
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", UI.INK)
	var st := UI.box(Color(0.62, 0.62, 0.64), 2, 0, Color.TRANSPARENT, 4.0)
	for s: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(s, st)
	b.pressed.connect(func() -> void: lf.room_help(title, text))
	return b


## The map: one picture tile (CARGO CAGE, the only map: selected, yellow frame), node RoomMap.
static func _map_tile() -> Control:
	var t := Control.new()
	t.name = "RoomMap"
	t.custom_minimum_size = Vector2(190, 96)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pic := UI.texture("mode_lonewolf.jpg")
	t.draw.connect(func() -> void:
		var r := Rect2(Vector2.ZERO, t.size)
		if pic:
			t.draw_texture_rect(pic, r, false)
		t.draw_rect(Rect2(0, r.end.y - 24, r.size.x, 24), Color(0, 0, 0, 0.62))
		HudDraw.text(t, "CARGO CAGE", Vector2(r.get_center().x, r.end.y - 12), 15, UI.TEXT, 1, 0, "heavy")
		t.draw_rect(r.grow(-1.5), UI.ACCENT, false, 3.0)
		UI.draw_tick_corner(t, r.size, 26.0))
	return t
