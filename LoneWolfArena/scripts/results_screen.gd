class_name ResultsScreen
extends Control
## End-of-match results over the (still rendering) arena. setup(result) gets the dictionary
## built by arena.gd: won, draw, invalid, kills, damage, headshots, accuracy, time, xp, enemy,
## mode (the name shown: TRAINING GROUND / LONE WOLF), mode_id ("training" / "lonewolf"), map,
## weapon, score_player, score_bot, hp_left, difficulty (the bot's level, or ONLINE against a
## player), taken; shots, hits, deaths and enemy_id go to the profile (Game.record_match).
## Layout (reference result screens, original art): mode + map top-left; a medal emblem with
## the big title (gold VICTORY / grey DEFEAT / white DRAW / red INVALID) top centre; the round
## score; a stats table (ELIMINATIONS, DAMAGE, HEADSHOTS, ACCURACY, TIME, HP LEFT) with your
## row in blue and, when the arena offers scoreboard_rows(), the opponent's row in orange; an
## honour tag (x ~0.18-0.37 W, y 0.83-0.88 H); XP gained with an animated level bar in the
## bottom-left band; PLAY AGAIN (yellow, node PlayAgain, 0.661-0.819 W) and LOBBY (grey, node
## Lobby, 0.836-0.992 W) in the 0.88-0.96 H band. Works unpaused at time scale 1. Android back
## = LOBBY (ignored while PLAY AGAIN's match loading runs).
## DUO / SQUAD (result.team, built by TeamArena._match_result): the plates read YOUR TEAM and the
## other side (ORANGE TEAM, or the other player's name in a match against them); both teams' tables
## side by side (TeamTables: TeamTable_0 blue, the player's team with the player first, and
## TeamTable_1 orange; rows TeamRow_<n>, n the row's index in result.rows: name, K, KNOCKS, REVIVES,
## DAMAGE, HS, ACC); PLAY AGAIN for a match on this phone. A match between two phones offers the
## same two humans another one (see _build_online): PLAY AGAIN TOGETHER (node PlayAgainTogether) after
## a co-op TEAM INVITE match, REMATCH (node Rematch) after one against the other player, in PLAY
## AGAIN's place; none after a forfeit or once a player left (LOBBY only). ADD FRIEND for the other
## player of an online match against them.

const COLUMNS := ["ELIMINATIONS", "DAMAGE", "HEADSHOTS", "ACCURACY", "TIME", "HP LEFT"]
const NAME_W := 250.0
const MEDAL_SCALE := 0.86

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
var _enemy := {}                  # the opponent's scoreboard row ({} when the scene has none)
var _shades: Array[Control] = []  # the full-screen shades behind the content (see _fit_cutout)
var _team := false                # a DUO / SQUAD result (result.team)
var _team_online := false         # ... played between two phones
var _team_again := false          # ... that offers PLAY AGAIN TOGETHER / REMATCH (team_again_offered)
var _again_team := {}             # ... the same team again: {"size", "coop"} (Game.team_match)
const TEAM_COLUMNS := ["K", "KNOCKS", "REVIVES", "DAMAGE", "HS", "ACC"]
# An internet match (not one without internet): REMATCH and ADD FRIEND (see _build_online).
const INVITE_DELAY_MS := 700      # the fresh challenge goes out this long after the old session is left
const AWAIT_MS := 12000           # how long a phone waits for the other's fresh challenge
const GUEST_GRACE_MS := 2500      # with the session gone the old guest first waits this long for the host's
var _online := false
var _enemy_id := ""
var _peer_id := ""                # the other phone's player (the 1 vs 1 opponent, the teammate or the other team's player)
var _peer_name := ""
var _rematch: Button
var _friend: Button
var _status: Label
var _want := false                # this player tapped REMATCH
var _they_want := false           # the other player asked for it (their "rm", or their challenge came)
var _they_take := true            # the other phone takes this one's challenges (their "rm" said)
var _starting := false            # both want it: a fresh challenge is on its way
var _loading := false             # the rematch's match is loading
var _invite_ms := 0               # when this phone sends the fresh challenge (0: not now)
var _await_ms := 0                # until when this phone waits for the other's (0: not waiting)


func setup(result: Dictionary) -> void:
	_result = result
	UI.full_rect(self)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _built:
		return
	_built = true
	var won: bool = result.get("won", false)
	var is_draw: bool = result.get("draw", false)
	var invalid: bool = result.get("invalid", false)
	_kind = "invalid" if invalid else ("draw" if is_draw else ("victory" if won else "defeat"))
	_enemy_id = String(result.get("enemy_id", ""))
	_online = String(result.get("mode_id", "")) == "lonewolf" and result.get("local", false) != true and Game.is_player_id(_enemy_id)
	_peer_id = _enemy_id
	_peer_name = String(result.get("enemy", "THE OPPONENT"))
	_team = result.get("team", false) == true
	if _team:
		_online = false                   # (the 1 vs 1's REMATCH; a team match's own: _team_again)
		_team_online = result.get("online", Game.online or Game.team_match.get("online", false) == true) == true
		var other := other_player(Game.team_match)
		_team_again = _team_online and team_again_offered(result, Game.team_match)
		if _team_again:
			_peer_id = String(other.id)
			_peer_name = String(other.name)
			_again_team = {"size": int(Game.team_match.size), "coop": bool(Game.team_match.coop)}
	_hide_match_hud()
	_enemy = {} if _team else _enemy_row()
	_build()
	_animate_in()


## The in-match HUD (score bar, buttons, kill feed) goes away under the results.
func _hide_match_hud() -> void:
	var scene := get_tree().current_scene if is_inside_tree() else null
	var h: Variant = scene.get("hud") if scene else null
	if h is CanvasItem:
		(h as CanvasItem).visible = false


## The opponent's row from the arena's scoreboard (Arena.scoreboard_rows(), see
## design/INTERFACES.txt): kills, damage, headshots, accuracy, hp. {} without one.
func _enemy_row() -> Dictionary:
	var scene := get_tree().current_scene if is_inside_tree() else null
	if scene == null or not scene.has_method("scoreboard_rows"):
		return {}
	var rows: Variant = scene.call("scoreboard_rows")
	if rows is Array:
		for row: Variant in rows:
			if row is Dictionary and not bool((row as Dictionary).get("me", false)):
				return row
	return {}


static func honour(result: Dictionary) -> String:
	if result.get("invalid", false):
		return ""
	var alive := int(result.get("hp_left", 0)) > 0
	if int(result.get("headshots", 0)) >= 2:
		return "SHARPSHOOTER"
	if int(result.get("taken", 999)) < 50 and alive:
		return "UNTOUCHABLE"
	if bool(result.get("won", false)) and alive and int(result.get("hp_left", 0)) < 30:
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


## The screen's content stays clear of a camera cutout (UI.safe_margins); its shades reach under it.
func _fit_cutout() -> void:
	if not is_inside_tree():
		return
	var m := UI.safe_margins(get_viewport())
	offset_left = m.x
	offset_right = -m.y
	for s: Control in _shades:
		s.offset_left = -m.x
		s.offset_right = m.y


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
	# Off a camera cutout: the screen keeps its content clear of it, its shades still reach the edges.
	_shades = [shade, side, low]
	var fit := Timer.new()
	fit.wait_time = 1.0
	fit.autostart = true
	fit.timeout.connect(_fit_cutout)
	add_child(fit)
	_fit_cutout.call_deferred()
	# Mode + map, top-left.
	var head := VBoxContainer.new()
	head.position = Vector2(40, 24)
	head.add_theme_constant_override("separation", -6)
	add_child(head)
	head.add_child(UI.shadowed(UI.label(String(r.get("mode", Game.mode_name(String(r.get("mode_id", ""))))).to_upper(), 36, UI.TEXT, "heavy")))
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
	_medal.offset_top = 0
	_medal.offset_bottom = 170
	_medal.pivot_offset = Vector2(190, 85)
	_medal.scale = Vector2.ONE * MEDAL_SCALE
	_medal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_medal.draw.connect(_draw_medal)
	if _kind == "defeat":
		_medal.material = _desaturate()
	add_child(_medal)
	var title := UI.shadowed(UI.outlined(UI.label(_title_text(), 94, Color.WHITE, "italic"), 11, Color(0.06, 0.04, 0.02, 0.95)), Vector2(0, 6), Color(0, 0, 0, 0.45))
	title.name = "Title"
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.offset_top = 112
	title.offset_bottom = 230
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.material = Loading.gradient_text_material(pal[0], pal[1], 118.0)
	title.pivot_offset = Vector2(0, 59)
	UI.center_italic(title, 94)
	add_child(title)
	# Round score: [YOU n] : [n BOT]
	var score := HBoxContainer.new()
	score.anchor_left = 0.5
	score.anchor_right = 0.5
	score.offset_left = -200
	score.offset_right = 200
	score.offset_top = 222
	score.offset_bottom = 258
	score.alignment = BoxContainer.ALIGNMENT_CENTER
	score.add_theme_constant_override("separation", 8)
	add_child(score)
	score.add_child(_score_plate("YOUR TEAM" if _team else "YOU", int(r.get("score_player", 0)), UI.BLUE, true))
	var colon := UI.label(":", 30, UI.TEXT, "number")
	colon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score.add_child(colon)
	score.add_child(_score_plate(String(r.get("enemy", "ORANGE TEAM" if _team else "BOT")).to_upper(), int(r.get("score_bot", 0)), UI.ORANGE, false))
	var note := ""
	if _kind == "invalid":
		note = "INTEGRITY CHECK FAILED  -  THIS MATCH DOES NOT COUNT"
	elif bool(r.get("opponent_left", false)):
		note = "%s LEFT THE MATCH  -  THE WIN IS YOURS" % String(r.get("enemy", "THE OPPONENT")).to_upper()
	if note != "":
		var why := UI.outlined(UI.label(note, 18, Color(1, 0.6, 0.55) if _kind == "invalid" else Color(1.0, 0.86, 0.45), "bold"), 4)
		why.name = "InvalidNote" if _kind == "invalid" else "OpponentLeft"
		why.anchor_left = 0.0
		why.anchor_right = 1.0
		why.offset_top = 438
		why.offset_bottom = 464
		if _team:
			why.offset_top = 258
			why.offset_bottom = 282
		why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(why)
	if _team:
		_build_team_tables()
	else:
		_build_table()
	_build_footer()


func _score_plate(who: String, n: int, col: Color, left: bool) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	var name_p := PanelContainer.new()
	name_p.add_theme_stylebox_override("panel", UI.chamfer(Color(0, 0, 0, 0.55), 8, 0, Color.TRANSPARENT, 12.0, ["tl"] if left else ["br"]))
	var nl := UI.ellipsis(UI.label(who, 17, UI.TEXT, "bold"))
	nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nl.custom_minimum_size = Vector2(110, 0)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if left else HORIZONTAL_ALIGNMENT_LEFT
	name_p.add_child(nl)
	var num_p := PanelContainer.new()
	num_p.add_theme_stylebox_override("panel", UI.box(col, 0, 0, Color.TRANSPARENT, 12.0))
	num_p.custom_minimum_size = Vector2(46, 36)
	var num := UI.label(str(n), 28, UI.TEXT, "number")
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
	table.offset_top = 272
	table.offset_bottom = 430
	table.add_theme_constant_override("separation", 2)
	add_child(table)
	_table = table
	resized.connect(_layout_table)
	_layout_table.call_deferred()
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", UI.box(Color(0.19, 0.185, 0.18, 0.92), 0, 0, Color.TRANSPARENT, 0.0))
	header.custom_minimum_size = Vector2(0, 34)
	table.add_child(header)
	var hh := HBoxContainer.new()
	header.add_child(hh)
	var name_h := UI.label("PLAYER", 16, UI.TEXT_DIM, "bold")
	name_h.custom_minimum_size = Vector2(NAME_W, 0)
	name_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hh.add_child(name_h)
	for c in COLUMNS:
		var l := UI.label(c, 16, UI.TEXT_DIM, "bold")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hh.add_child(l)
	# Your row (blue), then the opponent's (orange) when the arena has a scoreboard.
	var t := float(r.get("time", 0.0))
	table.add_child(_stat_row("YourRow", String(Game.profile.get("name", "PLAYER")), "LV %d" % Game.level(), [
		[float(r.get("kills", 0)), "%d"], [float(r.get("damage", 0)), "%d"], [float(r.get("headshots", 0)), "%d"],
		[float(r.get("accuracy", 0.0)), "%d%%"], [t, "time"], [float(r.get("hp_left", 0)), "%d"],
	], true))
	if not _enemy.is_empty():
		var e := _enemy
		# Under the opponent's name: ONLINE (LOCAL without internet) for another player (LEFT once they
		# left the match), else BOT and its level.
		var online := String(r.get("mode_id", "")) == "lonewolf"
		var tag := "LEFT" if r.get("opponent_left", false) == true else ("LOCAL" if r.get("local", false) == true else "ONLINE")
		table.add_child(_stat_row("EnemyRow", String(e.get("name", r.get("enemy", "BOT"))).to_upper(),
			tag if online else "BOT  ·  %s" % String(r.get("difficulty", "")).to_upper(), [
			[float(e.get("kills", 0)), "%d"], [float(e.get("damage", 0)), "%d"], [float(e.get("headshots", 0)), "%d"],
			[float(e.get("accuracy", 0)), "%d%%"], [t, "time"], [float(e.get("hp", 0)), "%d"],
		], false))


## One table row: [avatar | name + sub] then the six values. Own row: blue, 64 px, bigger
## digits; opponent: orange tint, 54 px. Final values at once (a screenshot or a slow frame
## never shows placeholders); each number pops in turn.
func _stat_row(node_name: String, who_name: String, sub: String, values: Array, own: bool) -> Control:
	var row := Control.new()
	row.name = node_name
	row.custom_minimum_size = Vector2(0, 64 if own else 54)
	var base := Color(0.0, 0.32, 0.55, 0.92) if own else Color(0.36, 0.15, 0.06, 0.9)
	var cells := Color(0.02, 0.39, 0.6, 0.95) if own else Color(0.50, 0.21, 0.07, 0.9)
	var edge := Color(0.35, 0.75, 1.0, 0.9) if own else Color(1.0, 0.55, 0.3, 0.75)
	row.draw.connect(func() -> void:
		var s := row.size
		row.draw_rect(Rect2(Vector2.ZERO, s), base)
		row.draw_rect(Rect2(NAME_W, 0, s.x - NAME_W, s.y), cells)
		row.draw_rect(Rect2(NAME_W, 0, s.x - NAME_W, 2), edge)
		row.draw_rect(Rect2(NAME_W, s.y - 2, s.x - NAME_W, 2), edge)
		row.draw_rect(Rect2(0, 0, NAME_W, s.y), Color(0, 0, 0, 0.35)))
	var rh := HBoxContainer.new()
	UI.full_rect(rh)
	row.add_child(rh)
	var who := HBoxContainer.new()
	who.custom_minimum_size = Vector2(NAME_W, 0)
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
		a.custom_minimum_size = Vector2(50, 50) if own else Vector2(42, 42)
		a.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not own:
			a.modulate = Color(1.0, 0.62, 0.48)
		who.add_child(a)
	var nv := VBoxContainer.new()
	nv.alignment = BoxContainer.ALIGNMENT_CENTER
	nv.add_theme_constant_override("separation", -4)
	var pname := UI.ellipsis(UI.label(who_name, 24 if own else 21, UI.TEXT, "bold"))
	pname.custom_minimum_size = Vector2(168, 0)
	nv.add_child(pname)
	nv.add_child(UI.label(sub, 15 if own else 13, UI.ACCENT if own else Color(1.0, 0.72, 0.55), "bold"))
	who.add_child(nv)
	var i := 0
	for v in values:
		var l := UI.label(_fmt(float(v[0]), String(v[1])), 36 if own else 30, UI.TEXT, "number")
		l.name = "Value_" + COLUMNS[i].replace(" ", "_")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		rh.add_child(l)
		l.resized.connect(func() -> void: l.pivot_offset = l.size * 0.5)
		var tw := create_tween()
		tw.tween_interval(0.3 + i * 0.06 + (0.0 if own else 0.2))
		tw.tween_property(l, "scale", Vector2(1.3, 1.3), 0.08)
		tw.tween_property(l, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		i += 1
	return row


## DUO / SQUAD: both teams' tables side by side (rows: result.rows, else the arena's scoreboard).
func _build_team_tables() -> void:
	var rows: Array = _result.get("rows", []) if _result.get("rows") is Array else []
	if rows.is_empty():
		var scene := get_tree().current_scene if is_inside_tree() else null
		if scene != null and scene.has_method("scoreboard_rows"):
			rows = scene.call("scoreboard_rows")
	var box := HBoxContainer.new()
	box.name = "TeamTables"
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.offset_left = -560
	box.offset_right = 560
	box.offset_top = 286 if bool(_result.get("opponent_left", false)) else 268
	box.offset_bottom = 560
	box.add_theme_constant_override("separation", 20)
	add_child(box)
	_table = box
	resized.connect(_layout_table)
	_layout_table.call_deferred()
	var n := maxi(int(_result.get("team_size", 0)), 1)
	for side in 2:
		var mine := side == 0
		var col := VBoxContainer.new()
		col.name = "TeamTable_%d" % side
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 2)
		box.add_child(col)
		var head := PanelContainer.new()
		head.add_theme_stylebox_override("panel", UI.box(Color(UI.BLUE if mine else UI.ORANGE, 0.9), 0, 0, Color.TRANSPARENT, 10.0))
		var hh := HBoxContainer.new()
		head.add_child(hh)
		var tl := UI.label("YOUR TEAM" if mine else String(_result.get("enemy", "ORANGE TEAM")).to_upper(), 19, UI.TEXT, "heavy")
		tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hh.add_child(UI.ellipsis(tl))
		hh.add_child(UI.label("ROUNDS %d" % int(_result.get("score_player" if mine else "score_bot", 0)), 17, UI.TEXT, "bold"))
		col.add_child(head)
		col.add_child(_team_cells("TeamHeader_%d" % side, "PLAYER", "", TEAM_COLUMNS, Color(0.19, 0.185, 0.18, 0.92), UI.TEXT_DIM, 14, 26))
		var shown := 0
		for i in rows.size():
			var row: Variant = rows[i]
			if not row is Dictionary:
				continue
			var d: Dictionary = row
			if bool(d.get("ally", bool(d.get("me", false)))) != mine:
				continue
			shown += 1
			var me := bool(d.get("me", false))
			var sub := "YOU" if me else ("BOT" if bool(d.get("bot", false)) else ("LEFT" if String(d.get("status", "")) == "left" else "PLAYER"))
			var vals := [str(int(d.get("kills", 0))), str(int(d.get("knocks", 0))), str(int(d.get("revives", 0))), str(int(d.get("damage", 0))),
				str(int(d.get("headshots", 0))), "%d%%" % int(d.get("accuracy", 0))]
			var base := Color(0.0, 0.32, 0.55, 0.92) if mine else Color(0.36, 0.15, 0.06, 0.9)
			if me:
				base = Color(0.02, 0.42, 0.68, 0.96)
			var line := _team_cells("TeamRow_%d" % i, String(d.get("name", "?")).to_upper(), sub, vals, base, UI.TEXT, 22 if n <= 2 else 19,
				44 if n <= 2 else 36)
			col.add_child(line)
		if shown == 0:
			col.add_child(UI.label("NO PLAYERS", 15, UI.TEXT_DIM, "bold"))


## One row of a team table: name (+ a small line under it) then the values, each in its own cell.
func _team_cells(node_name: String, who: String, sub: String, values: Array, bg: Color, ink: Color, fs: int, h: int) -> Control:
	var row := PanelContainer.new()
	row.name = node_name
	row.add_theme_stylebox_override("panel", UI.box(bg, 0, 0, Color.TRANSPARENT, 4.0))
	row.custom_minimum_size = Vector2(0, h)
	var rh := HBoxContainer.new()
	rh.add_theme_constant_override("separation", 0)
	row.add_child(rh)
	var nv := VBoxContainer.new()
	nv.alignment = BoxContainer.ALIGNMENT_CENTER
	nv.add_theme_constant_override("separation", -4)
	nv.custom_minimum_size = Vector2(150, 0)
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.size_flags_stretch_ratio = 2.3
	var nl := UI.ellipsis(UI.label(who, fs if sub != "" else 14, ink, "bold"))
	nl.name = "Name"
	nv.add_child(nl)
	if sub != "":
		nv.add_child(UI.label(sub, 11, UI.ACCENT if sub == "YOU" else Color(1, 1, 1, 0.65), "bold"))
	rh.add_child(nv)
	for i in values.size():
		var l := UI.label(String(values[i]), fs if sub != "" else 13, ink, "number" if sub != "" else "bold")
		l.name = "Value_%d" % i
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.clip_text = true
		rh.add_child(l)
	return row


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
	# Honour tag: right end at 0.37 W, just above the XP row (reference tag: x .18-.37, y .83-.88).
	var tag := honour(r)
	if tag != "":
		var slot := HBoxContainer.new()
		slot.name = "HonourSlot"
		slot.anchor_left = 0.026
		slot.anchor_right = 0.37
		slot.anchor_top = 0.828
		slot.anchor_bottom = 0.882
		slot.alignment = BoxContainer.ALIGNMENT_END
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(slot)
		var tp := PanelContainer.new()
		tp.name = "Honour"
		var st := UI.chamfer(UI.ACCENT, 10, 0, Color.TRANSPARENT, 14.0, ["tl", "br"], 0.0)
		st.content_margin_top = 2
		st.content_margin_bottom = 2
		tp.add_theme_stylebox_override("panel", st)
		tp.size_flags_vertical = Control.SIZE_FILL
		tp.draw.connect(func() -> void:
			UI.draw_hazard(tp, Rect2(tp.size.x - 34, tp.size.y - 6, 24, 4), 4.0, Color(UI.INK, 0.6), Color.TRANSPARENT))
		var th := HBoxContainer.new()
		th.add_theme_constant_override("separation", 8)
		var icon_name: String = {"SHARPSHOOTER": "v_headshot", "UNTOUCHABLE": "v_helmet", "CLUTCH": "v_medkit"}.get(tag, "v_fist")
		var ic := UI.icon(icon_name, 26, UI.INK)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		th.add_child(ic)
		var tl := UI.label(tag, 25, UI.INK, "heavy")
		tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		th.add_child(tl)
		var note := UI.label({"SHARPSHOOTER": "2+ HEADSHOTS", "UNTOUCHABLE": "UNDER 50 DAMAGE TAKEN", "CLUTCH": "WON UNDER 30 HP"}.get(tag, "STOOD YOUR GROUND"), 13, Color(UI.INK, 0.7), "bold")
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		th.add_child(note)
		tp.add_child(th)
		slot.add_child(tp)
	# XP gained + level bar, bottom-left in the buttons' band: [+XP]  [LV n ... a / b XP][bar].
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
	xr.name = "XpRow"
	xr.anchor_left = 0.026
	xr.anchor_right = 0.37
	xr.anchor_top = 0.88
	xr.anchor_bottom = 0.96
	xr.add_theme_constant_override("separation", 14)
	xr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(xr)
	var xpl := UI.shadowed(UI.label("+%d XP" % xp, 32, UI.ACCENT if xp > 0 else UI.TEXT_DIM, "number_italic"))
	xpl.name = "XpGain"
	xpl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xr.add_child(xpl)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 3)
	xr.add_child(col)
	var top := HBoxContainer.new()
	col.add_child(top)
	_level_label = UI.label("LV %d" % lv_before, 17, UI.TEXT, "bold")
	_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_level_label)
	var lv_note := UI.label("%d / %d XP" % [after % Game.XP_PER_LEVEL, Game.XP_PER_LEVEL], 14, UI.TEXT_DIM, "bold")
	lv_note.name = "XpNote"
	top.add_child(lv_note)
	_xp_bar = Control.new()
	_xp_bar.custom_minimum_size = Vector2(0, 12)
	_xp_bar.draw.connect(_draw_xp)
	col.add_child(_xp_bar)
	_xp_fill = _xp_from
	_levelled = lv_after != lv_before
	_xp_to = to
	_lv_before = lv_before
	_xp_t0 = Time.get_ticks_msec() + 450
	# Buttons in the reference band: PLAY AGAIN (yellow) 0.661-0.819 W, LOBBY (grey) 0.836-0.992 W;
	# an internet match has REMATCH in PLAY AGAIN's place and ADD FRIEND left of it.
	if _online:
		_build_online()
	elif _team and _team_online:
		_build_team_online()
	else:
		var again := UI.hero_button("PLAY AGAIN", 30, Vector2(0, 46))
		again.name = "PlayAgain"
		_place(again, 0.661, 0.819)
		_again = again
		again.pressed.connect(_play_again)
		add_child(again)
	var lobby := UI.button("LOBBY", 26, "light", Vector2(0, 46))
	lobby.name = "Lobby"
	_place(lobby, 0.836, 0.992)
	lobby.pressed.connect(Game.goto_lobby)
	add_child(lobby)


func _place(c: Control, x0: float, x1: float) -> void:
	c.anchor_left = x0
	c.anchor_right = x1
	c.anchor_top = 0.88                # 58 px on the 720 px canvas: a full touch target
	c.anchor_bottom = 0.96
	c.offset_left = 0
	c.offset_right = 0
	c.offset_top = 0
	c.offset_bottom = 0


func _play_again() -> void:
	if _again.disabled:
		return
	_again.disabled = true
	if Game.online:
		Game.goto_lobby()          # (a match without internet: the next one is paired in the lobby)
		return
	Loading.start_match(get_tree().current_scene)


## Android back = LOBBY, except while PLAY AGAIN's (or a rematch's) match loading runs.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree() and _built:
		if (_again and _again.disabled) or _loading:
			return
		Game.goto_lobby()


# ---------------------------------------------------------------- online: REMATCH and ADD FRIEND

## An internet match's buttons: REMATCH (yellow, PLAY AGAIN's place), ADD FRIEND left of it while
## the two are not friends, and a status line above them.
## REMATCH needs both players. While the match's session is still up a tap tells the other phone
## ("rm", Arena.ask_rematch, with whether this phone takes their challenges), whose screen then says
## "<NAME> WANTS A REMATCH". Once both want it, both leave the old session and a fresh duel
## challenge goes from the phone whose challenge the other takes (the old host when both do: no two
## challenges crossing), INVITE_DELAY_MS later; the other phone takes it at once. With the session
## gone (the other went back to the lobby) a tap sends the fresh challenge itself (the old guest
## first waits GUEST_GRACE_MS for the host's). A challenge from the old opponent that comes here is
## their rematch: REMATCH takes it. After a forfeit (they left the match) REMATCH is off.
## DUO / SQUAD between two phones (_team_again) works the same way with the other phone's player:
## PLAY AGAIN TOGETHER after a co-op match ("<NAME> WANTS TO PLAY AGAIN"), REMATCH after one against
## them. The fresh invite is a team invite with the same size and coop (Cloud.team_invite, not
## quick), and once both want it only the old host sends it (it runs the bots: the same roles and
## sides); the tap also tells Cloud (Cloud.play_again) so that player's invite reaches this screen,
## friend or not. The new match is the team match of the session it starts (_on_session).
func _build_online() -> void:
	_status = UI.outlined(UI.label("", 19, UI.TEXT, "bold"), 4)
	_status.name = "RematchStatus"
	_status.anchor_left = 0.40
	_status.anchor_right = 0.992
	_status.anchor_top = 0.815
	_status.anchor_bottom = 0.87
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)
	_rematch = UI.hero_button(_caption(), 22 if _coop_again() else 30, Vector2(0, 46))
	_rematch.name = "PlayAgainTogether" if _coop_again() else "Rematch"
	_place(_rematch, 0.56 if _coop_again() else 0.661, 0.819)      # (co-op: no ADD FRIEND, room for the longer word)
	# Its Caption shows the state (_set_rematch); the button's own text stays for checks, never drawn.
	_rematch.clip_text = true
	for c: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		_rematch.add_theme_color_override(c, Color.TRANSPARENT)
	_rematch.pressed.connect(_on_rematch)
	add_child(_rematch)
	if bool(_result.get("opponent_left", false)):
		_set_rematch(_caption(), false)
		_say("%s LEFT: NO REMATCH" % _name(), UI.TEXT_DIM)
	if not _coop_again() and not Game.is_friend(_peer_id) and not Game.is_blocked(_peer_id):
		var asked := Game.cloud_service().friend_asked(_peer_id)
		_friend = UI.button("REQUEST SENT" if asked else "ADD FRIEND", 22, "dark" if asked else "light", Vector2(0, 46))
		_friend.name = "AddFriend"
		_friend.disabled = asked
		_place(_friend, 0.47, 0.645)
		_friend.pressed.connect(_on_add_friend)
		add_child(_friend)
	if _rematch.disabled:
		return
	var cl := Game.cloud_service()
	cl.invited.connect(_on_invited)
	cl.invite_answered.connect(_on_answered)
	cl.invite_cancelled.connect(_on_their_challenge_gone)
	cl.invite_failed.connect(_on_failed)
	cl.session_started.connect(_on_session)
	cl.session_ended.connect(_on_session_ended)
	var a := _arena()
	if a != null and a.has_signal("rematch_asked"):
		a.connect("rematch_asked", _on_they_want)
		if a.get("rematch_wanted") == true:
			_on_they_want.call_deferred()


## DUO / SQUAD between two phones: PLAY AGAIN TOGETHER / REMATCH as the 1 vs 1's REMATCH
## (_build_online) when the results offer it (_team_again). Otherwise (a forfeit, a player left) no
## PLAY AGAIN: LOBBY, and ADD FRIEND for the other player of a match against them (in PLAY AGAIN's
## place) while the two are not friends.
func _build_team_online() -> void:
	if _team_again:
		_build_online()
		return
	if not Game.is_player_id(_enemy_id) or Game.is_friend(_enemy_id) or Game.is_blocked(_enemy_id):
		return
	_status = UI.outlined(UI.label("", 19, UI.TEXT, "bold"), 4)
	_status.name = "RematchStatus"
	_status.anchor_left = 0.40
	_status.anchor_right = 0.992
	_status.anchor_top = 0.815
	_status.anchor_bottom = 0.87
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)
	var asked := Game.cloud != null and Game.cloud.friend_asked(_enemy_id)
	_friend = UI.button("REQUEST SENT" if asked else "ADD FRIEND", 22, "dark" if asked else "light", Vector2(0, 46))
	_friend.name = "AddFriend"
	_friend.disabled = asked
	_place(_friend, 0.661, 0.819)
	_friend.pressed.connect(_on_add_friend)
	add_child(_friend)


## The other phone's player in an online team match (`tm`: Game.team_match): {"id", "name"} of the
## roster's human who is not this player, {} when there is none.
static func other_player(tm: Dictionary) -> Dictionary:
	var roster: Variant = tm.get("roster")
	if not roster is Array or not bool(tm.get("online", false)):
		return {}
	for e: Variant in roster:
		if e is Dictionary and not bool((e as Dictionary).get("bot", true)) and int((e as Dictionary).get("slot", -1)) != int(tm.get("my_slot", 0)) \
				and Game.is_player_id((e as Dictionary).get("id")):
			return {"id": String(e.id), "name": String((e as Dictionary).get("name", "PLAYER"))}
	return {}


## Whether an online team match's results offer PLAY AGAIN TOGETHER / REMATCH (`r`: the result, `tm`:
## Game.team_match): only with the other phone's player known, never after a forfeit (they left:
## result.opponent_left), once a player left (a row LEFT), or after a match that ended early or was
## left (result.ended / left).
static func team_again_offered(r: Dictionary, tm: Dictionary) -> bool:
	if other_player(tm).is_empty() or bool(r.get("opponent_left", false)) or bool(r.get("ended", false)) or bool(r.get("left", false)) \
			or bool(r.get("invalid", false)):
		return false
	var rows: Variant = r.get("rows")
	if rows is Array:
		for row: Variant in rows:
			if row is Dictionary and String((row as Dictionary).get("status", "")) == "left":
				return false
	return true


## PLAY AGAIN TOGETHER after a co-op team match between two phones, else REMATCH.
func _caption() -> String:
	return "PLAY AGAIN TOGETHER" if _coop_again() else "REMATCH"


func _coop_again() -> bool:
	return _team_again and bool(_again_team.get("coop", false))


## The word in the status line: PLAY AGAIN (co-op) or REMATCH.
func _word() -> String:
	return "PLAY AGAIN" if _coop_again() else "REMATCH"


## What starts or loads: THE NEXT MATCH (co-op) or THE REMATCH.
func _what() -> String:
	return "THE NEXT MATCH" if _coop_again() else "THE REMATCH"


func _wants() -> String:
	return "WANTS TO PLAY AGAIN" if _coop_again() else "WANTS A REMATCH"


## The arena behind (the current scene) when it offers the rematch's calls, else null.
func _arena() -> Node:
	var s := get_tree().current_scene if is_inside_tree() else null
	return s if s != null and s.has_method("leave_session") and s.has_method("ask_rematch") else null


func _name() -> String:
	return _peer_name.to_upper()


## Whether this phone's DUEL CHALLENGES FROM lets the opponent's challenge through.
func _takes_challenges() -> bool:
	var who := int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE))
	return who == Game.CHALLENGES_EVERYONE or (who == Game.CHALLENGES_FRIENDS and Game.is_friend(_peer_id))


func _say(text: String, col := UI.TEXT) -> void:
	if _status:
		_status.text = text
		_status.add_theme_color_override("font_color", col)


func _set_rematch(text: String, enabled: bool) -> void:
	if _rematch:
		_rematch.text = text
		UI.set_caption(_rematch, text)
		_rematch.disabled = not enabled
		_rematch.modulate.a = 1.0 if enabled else 0.6


func _on_rematch() -> void:
	if _starting or _rematch.disabled:
		return
	var cl := Game.cloud_service()
	if cl.has_invite() and String(cl.invite_from().get("id", "")) == _peer_id:
		_take_challenge()                # their fresh challenge is here already: this tap takes it
		return
	_want = true
	if _team_again:
		cl.play_again = {"id": _peer_id, "size": int(_again_team.size), "coop": bool(_again_team.coop)}
	var a := _arena()
	if a != null and bool(a.call("ask_rematch", _takes_challenges())):
		if _they_want:
			_agree()
		else:
			_set_rematch("ASKED", false)
			_say("%s ASKED: WAITING FOR %s" % [_word(), _name()])
		return
	_challenge_now()                     # the match's session is gone


## The other player tapped REMATCH ("rm"): this screen asks, or both want it now.
func _on_they_want() -> void:
	if _they_want:
		return
	_they_want = true
	var a := _arena()
	_they_take = a == null or a.get("rematch_they_take") != false
	if _want:
		_agree()
	elif not _starting:
		_set_rematch(_caption(), true)
		_say("%s %s" % [_name(), _wants()], UI.ACCENT)


## Both want the rematch: out of the old session; the phone whose challenge the other takes sends
## a fresh one a moment later, the other one waits for it (and takes it at once). A team match's
## comes from the old host only (it runs the bots), so the old guest must take the host's.
func _agree() -> void:
	var a := _arena()
	var i_take := _takes_challenges()
	var host := a == null or bool(a.call("hosted"))
	# Who invites: the host when the guest takes its challenge, else the guest when the host takes
	# theirs (both phones work it out alike from the two answers).
	var guest_takes := _they_take if host else i_take
	var host_takes := i_take if host else _they_take
	var i_invite := guest_takes if host else (not guest_takes and host_takes)
	if _team_again and not guest_takes:
		_say("DUEL CHALLENGES FROM LEAVES THE HOST OUT: NO %s" % _word(), UI.BAD)
		_set_rematch(_caption(), false)
		return
	if not guest_takes and not host_takes:
		_say("DUEL CHALLENGES ARE OFF ON BOTH PHONES: NO REMATCH", UI.BAD)
		_set_rematch("REMATCH", false)
		return
	_starting = true
	_set_rematch("STARTING", false)
	_say("STARTING %s..." % _what(), UI.ACCENT)
	if a != null:
		a.call("leave_session")
	if i_invite:
		_invite_ms = Time.get_ticks_msec() + INVITE_DELAY_MS
	else:
		_await_ms = Time.get_ticks_msec() + AWAIT_MS
		var cl := Game.cloud_service()
		if cl.has_invite() and String(cl.invite_from().get("id", "")) == _peer_id:
			_take_challenge()


## The match's session is gone: a fresh challenge from here (the old guest first gives the old
## host's a moment, so two do not cross).
func _challenge_now() -> void:
	_starting = true
	_set_rematch("STARTING", false)
	_say(("INVITING %s AGAIN..." if _coop_again() else "SENDING %s A REMATCH CHALLENGE...") % _name())
	var a := _arena()
	if a != null:
		a.call("leave_session")
	var host := a == null or bool(a.call("hosted"))
	_invite_ms = Time.get_ticks_msec() + (INVITE_DELAY_MS if host else GUEST_GRACE_MS)


func _send_challenge() -> void:
	var cl := Game.cloud_service()
	if cl.has_invite() and String(cl.invite_from().get("id", "")) == _peer_id:
		_take_challenge()                # theirs came first: take it rather than cross it
		return
	if cl.waiting_for() != "" and String(cl.opponent.get("id", "")) == _peer_id:
		return                           # (already sent)
	if not cl.peers.has(_peer_id):
		_give_up("%s IS NOT ONLINE NOW" % _name())
	elif not (cl.team_invite(_peer_id, int(_again_team.size), bool(_again_team.coop)) if _team_again else cl.invite(_peer_id)):
		_give_up("COULD NOT SEND THE CHALLENGE: TAP %s AGAIN" % _caption())
	else:
		_say("%s: WAITING FOR %s..." % [_word(), _name()], UI.ACCENT)


## Takes the old opponent's fresh challenge (out of the old session first: the new room is not
## this match's, which the arena leaving the tree later must not end).
func _take_challenge() -> void:
	_starting = true
	_invite_ms = 0
	_await_ms = 0
	var a := _arena()
	if a != null:
		a.call("leave_session")
	Game.cloud_service().answer(true)
	_set_rematch("STARTING", false)
	_say("STARTING %s..." % _what(), UI.ACCENT)


func _give_up(why: String) -> void:
	_starting = false
	_want = false
	_invite_ms = 0
	_await_ms = 0
	_forget_play_again()
	_say(why, UI.BAD)
	_set_rematch(_caption(), true)


## Cloud stops showing that player's team invite here (Cloud.play_again: set by this screen's tap).
func _forget_play_again() -> void:
	if _team_again and Game.cloud != null and String(Game.cloud.play_again.get("id", "")) == _peer_id:
		Game.cloud.play_again = {}


## A challenge came in here: the old opponent's is their rematch (taken at once when this player
## wants one too); anyone else's is declined (no lobby to show it). After a team match only that
## player's team invite with the same size and coop is theirs.
func _on_invited(_who: String) -> void:
	var cl := Game.cloud_service()
	if not cl.has_invite():
		return                           # (answered already)
	var inv := cl.invite_from()
	if String(inv.get("id", "")) != _peer_id or _loading or (_team_again and inv.get("team", {}) != _again_team):
		cl.answer(false)
		return
	if _want or _starting:
		_take_challenge()
	else:
		_they_want = true
		_set_rematch("ACCEPT", true)
		_say("%s %s" % [_name(), _wants()], UI.ACCENT)


func _on_answered(accepted: bool, _who: String) -> void:
	if not accepted and _starting and not _loading:
		_give_up("%s DID NOT TAKE %s" % [_name(), _what()])


func _on_their_challenge_gone() -> void:
	if _they_want and not _starting and not _loading:
		_they_want = false
		_set_rematch(_caption(), true)
		_say("%s CALLED %s OFF" % [_name(), _what()], UI.TEXT_DIM)


func _on_failed(_who: String) -> void:
	if _starting and not _loading:
		_give_up("COULD NOT REACH %s" % _name())


## The rematch's session is up: its match loads (as an accepted challenge does in the lobby). After
## a team match it is the team match of that session (LobbyFriends.session_team_match: the same two
## humans, the old host hosting again), so team_arena_net loads.
func _on_session(_host: bool) -> void:
	if not _starting or _loading:
		return
	var cl := Game.cloud_service()
	if _team_again:
		var tm := LobbyFriends.session_team_match(cl) if cl.session_team == _again_team else {}
		if tm.is_empty():
			cl.end_session("left")         # (not the team asked for: nothing loads)
			_give_up("COULD NOT START %s" % _what())
			return
		Game.team_match = tm
	_loading = true
	_invite_ms = 0
	_await_ms = 0
	_forget_play_again()
	Game.online = true
	Game.session = cl
	Game.room_rules = cl.session_rules.duplicate()
	_set_rematch("LOADING", false)
	if _friend:
		_friend.disabled = true
	_say("LOADING %s..." % _what(), UI.ACCENT)
	Loading.start_match(get_tree().current_scene)


## The match's session ended: the other player went back to the lobby. One that wanted the
## rematch gets a fresh challenge there.
func _on_session_ended(_reason: String) -> void:
	if _want and not _starting and not _loading:
		_challenge_now()


func _on_add_friend() -> void:
	if _friend == null or _friend.disabled:
		return
	if Game.cloud_service().request_friend(_enemy_id):
		_friend.text = "REQUEST SENT"
		_friend.disabled = true
	else:
		_say("COULD NOT SEND THE FRIEND REQUEST: TRY AGAIN", UI.BAD)


func _step_rematch() -> void:
	var now := Time.get_ticks_msec()
	if _invite_ms > 0 and now >= _invite_ms:
		_invite_ms = 0
		_send_challenge()
	if _await_ms > 0 and now >= _await_ms:
		_await_ms = 0
		if not _loading:
			_give_up("NO CHALLENGE CAME FROM %s" % _name())    # (a team match's play-again stops here too)


## Leaving (LOBBY, back): the old opponent's challenge waiting here is declined (the lobby would not
## show it), and Cloud no longer takes a team invite for this screen (Cloud.play_again).
func _exit_tree() -> void:
	if not (_online or _team_again) or Game.cloud == null:
		return
	_forget_play_again()
	if _loading:
		return
	var cl := Game.cloud_service()
	if cl.has_invite() and String(cl.invite_from().get("id", "")) == _peer_id:
		cl.answer(false)


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
			var bar := 92.0 - k * 22.0
			var pts := PackedVector2Array([Vector2(x0, y), Vector2(x0 + sgn * bar, y - 10), Vector2(x0 + sgn * (bar - 14), y + 8), Vector2(x0, y + 14)])
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
	_medal.scale = Vector2.ONE * lerpf(0.4, 1.0, pop) * MEDAL_SCALE
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
	_step_rematch()
	if _medal and (_kind == "victory" or _kind == "draw"):
		_medal.queue_redraw()
	if _again:
		_again.queue_redraw()
