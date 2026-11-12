class_name ModeHelp
extends VBoxContainer
## The short picture help of a mode (the "?" on its SELECT MODE card opens it in a popup:
## LobbyDialogs.mode_help): a few pages, each a picture we draw ourselves from the game's own
## shapes and icons (the two fighters and the score to 5, the shared gun pick with the ROUNDS
## strip and the rest, the two-stage clock and the closing zone, the kit with SWITCH, a group and
## its GROUP CODE, the bot levels and the dummy) over a title and one or two lines of text. The
## page dots under it show where the reader is; the arrows either side (HelpPrev, HelpNext), a
## swipe across the picture, or a tap on a dot turns the page; the popup's X and Android back
## close it. HOW TO PLAY in SETTINGS stays the full text (scripts/how_to_play.gd).
## Node names: ModeHelp, HelpPicture, HelpTitle, HelpText, HelpDots (HelpDot_<i>), HelpPrev,
## HelpNext.

## Each mode's pages: [picture, title, text] (pictures: _draw_picture).
const PAGES := {
	"lonewolf": [
		["duel", "ONE ON ONE", "You against another player on CARGO CAGE. Take your opponent down to win the round; the first to 5 rounds wins the match."],
		["pick", "ONE GUN FOR BOTH", "Every 2 rounds one of you picks the gun you both fight with, taking turns: the ROUNDS strip shows whose pick it is. A gun picked rests for the next 4 rounds."],
		["clock", "TWO STAGES, ONE ZONE", "A round runs 20 s, then 90 s more while the safe zone closes in. Outside it you lose HP, faster the longer you stay; at time-out the higher HP wins."],
		["group", "PLAY WITH FRIENDS", "Pick DUO or SQUAD to play with your group against real players. INVITE friends who are online, or share your GROUP CODE so they join at once."],
	],
	"training": [
		["bot", "PRACTISE YOUR WAY", "Fight a bot at EASY, NORMAL or HARD, round by round as online, or pick DUMMY to train your aim: no zone, no clock, nothing counted. DUO and SQUAD put bot teammates beside you."],
		["pick", "ONE GUN FOR BOTH", "Every 2 rounds one side picks the gun both fight with, taking turns: the ROUNDS strip shows whose pick it is. A gun picked rests for the next 4 rounds."],
		["clock", "TWO STAGES, ONE ZONE", "A round runs 20 s, then 90 s more while the safe zone closes in. Outside it you lose HP, faster the longer you stay; at time-out the higher HP wins."],
		["kit", "YOUR KIT", "Every round: the gun picked, the WREN 9 sidearm and your fists. SWITCH beside RELOAD goes gun, sidearm, fists; a tap on a slot of the weapon panel draws that one."],
	],
}
## A swipe this far across the picture (px) turns the page.
const SWIPE_PX := 60.0
const PIC_H := 300.0

## The mode whose pages these are, and the page shown (0-based).
var mode := "lonewolf"
var page := 0
var picture: Control
var _title: Label
var _text: Label
var _dots: HBoxContainer
var _prev: Button
var _next: Button
var _press_x := NAN


## The mode's pages, [] for an unknown mode.
static func pages_of(m: String) -> Array:
	return PAGES.get(m, [])


## The page a turn by `step` (-1 back, +1 on) lands on: it stops at the first and the last.
static func turned(at: int, step: int, count: int) -> int:
	return clampi(at + step, 0, maxi(count - 1, 0))


## What a finished drag across the picture does: -1 (it went right: back), +1 (left: on), 0.
static func swipe_step(dx: float) -> int:
	if dx <= -SWIPE_PX:
		return 1
	if dx >= SWIPE_PX:
		return -1
	return 0


func _init(m := "lonewolf") -> void:
	mode = m if PAGES.has(m) else "lonewolf"
	name = "ModeHelp"
	add_theme_constant_override("separation", 8)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)
	_prev = _arrow("HelpPrev", false)
	row.add_child(_prev)
	picture = Control.new()
	picture.name = "HelpPicture"
	picture.custom_minimum_size = Vector2(760, PIC_H)
	picture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picture.clip_contents = true
	picture.mouse_filter = Control.MOUSE_FILTER_STOP
	picture.draw.connect(func() -> void: _draw_picture(picture, String(pages_of(mode)[page][0])))
	picture.gui_input.connect(_on_picture_input)
	row.add_child(picture)
	_next = _arrow("HelpNext", true)
	row.add_child(_next)
	_title = UI.label("", 24, UI.ACCENT, "heavy")
	_title.name = "HelpTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_title)
	_text = UI.label("", 17, UI.TEXT, "semi")
	_text.name = "HelpText"
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text.custom_minimum_size = Vector2(820, 50)
	add_child(_text)
	_dots = HBoxContainer.new()
	_dots.name = "HelpDots"
	_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots.add_theme_constant_override("separation", 0)
	add_child(_dots)
	for i in pages_of(mode).size():
		var d := Button.new()
		d.name = "HelpDot_%d" % i
		d.focus_mode = Control.FOCUS_NONE
		d.custom_minimum_size = Vector2(44, 32)
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			d.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		d.draw.connect(func() -> void:
			var c := d.size * 0.5
			if i == page:
				d.draw_rect(Rect2(c - Vector2(11, 4), Vector2(22, 8)), UI.ACCENT)
			else:
				d.draw_circle(c, 4.5, Color(1, 1, 1, 0.4), true, -1.0, true))
		d.pressed.connect(func() -> void: show_page(i))
		_dots.add_child(d)
	show_page(0)


## Shows page `i` (kept in range): picture, title, text, the lit dot, the arrows dimmed at the ends.
func show_page(i: int) -> void:
	var list := pages_of(mode)
	page = clampi(i, 0, list.size() - 1)
	_title.text = "%s   %d / %d" % [String(list[page][1]), page + 1, list.size()]
	_text.text = String(list[page][2])
	_prev.disabled = page == 0
	_next.disabled = page == list.size() - 1
	picture.queue_redraw()
	for d in _dots.get_children():
		(d as Control).queue_redraw()


## One page on (+1) or back (-1).
func turn(step: int) -> void:
	var to := turned(page, step, pages_of(mode).size())
	if to != page:
		Audio.play("ui_click", -6.0)
		show_page(to)


func _arrow(node_name: String, right: bool) -> Button:
	var b := Button.new()
	b.name = node_name
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(UI.TOUCH_MIN, PIC_H)
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var a := 0.18 if b.disabled else (1.0 if b.is_hovered() or b.is_pressed() else 0.8)
		b.draw_circle(c, 24.0, Color(0, 0, 0, 0.5 * a), true, -1.0, true)
		b.draw_circle(c, 24.0, Color(1, 1, 1, 0.3 * a), false, 1.5, true)
		var s := 1.0 if right else -1.0
		b.draw_polyline(PackedVector2Array([c + Vector2(-5 * s, -10), c + Vector2(5 * s, 0), c + Vector2(-5 * s, 10)]),
			Color(UI.ACCENT, a), 3.5, true))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		b.connect(sig, b.queue_redraw)
	b.pressed.connect(turn.bind(1 if right else -1))
	return b


## A swipe across the picture: a touch (or a real mouse; an emulated one from the touch is skipped)
## pressed and let go SWIPE_PX or more to the side.
func _on_picture_input(e: InputEvent) -> void:
	var down := false
	var up := false
	var x := 0.0
	if e is InputEventScreenTouch:
		down = (e as InputEventScreenTouch).pressed
		up = not down
		x = (e as InputEventScreenTouch).position.x
	elif e is InputEventMouseButton and e.device != InputEvent.DEVICE_ID_EMULATION \
			and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		down = (e as InputEventMouseButton).pressed
		up = not down
		x = (e as InputEventMouseButton).position.x
	else:
		return
	if down:
		_press_x = x
	elif up and not is_nan(_press_x):
		var step := swipe_step(x - _press_x)
		_press_x = NAN
		if step != 0:
			turn(step)


# ---------------------------------------------------------------- the pictures

## Draws picture `kind` into `ci` (its whole rect): a dark plate with a hazard edge, then the
## diagram.
static func _draw_picture(ci: Control, kind: String) -> void:
	var s := ci.size
	ci.draw_rect(Rect2(Vector2.ZERO, s), Color(0.06, 0.065, 0.075, 0.96))
	for i in range(1, 12):                      # the arena floor's slab joints
		ci.draw_line(Vector2(s.x * i / 12.0, 0), Vector2(s.x * i / 12.0, s.y), Color(1, 1, 1, 0.035), 1.0)
	for i in range(1, 5):
		ci.draw_line(Vector2(0, s.y * i / 5.0), Vector2(s.x, s.y * i / 5.0), Color(1, 1, 1, 0.035), 1.0)
	UI.draw_hazard(ci, Rect2(0, s.y - 8, s.x, 8), 8.0)
	match kind:
		"duel":
			_pic_duel(ci, s)
		"pick":
			_pic_pick(ci, s)
		"clock":
			_pic_clock(ci, s)
		"group":
			_pic_group(ci, s)
		"bot":
			_pic_bot(ci, s)
		"kit":
			_pic_kit(ci, s)
	ci.draw_rect(Rect2(Vector2(0.5, 0.5), s - Vector2(1, 1)), Color(1, 1, 1, 0.16), false, 1.0)


## A fighter seen from the front in our flat style: head, shoulders, body, legs; `face` -1 / +1
## turns the gun arm to that side (0: none).
static func _fighter(ci: CanvasItem, foot: Vector2, h: float, col: Color, face := 0) -> void:
	var w := h * 0.36
	var dark := col.darkened(0.45)
	ci.draw_rect(Rect2(foot + Vector2(-w * 0.38, -h * 0.4), Vector2(w * 0.3, h * 0.4)), dark)
	ci.draw_rect(Rect2(foot + Vector2(w * 0.08, -h * 0.4), Vector2(w * 0.3, h * 0.4)), dark)
	var body := PackedVector2Array([foot + Vector2(-w * 0.5, -h * 0.78), foot + Vector2(w * 0.5, -h * 0.78),
		foot + Vector2(w * 0.4, -h * 0.38), foot + Vector2(-w * 0.4, -h * 0.38)])
	ci.draw_colored_polygon(body, col)
	ci.draw_circle(foot + Vector2(0, -h * 0.88), h * 0.11, col.lightened(0.15), true, -1.0, true)
	if face != 0:
		var sh := foot + Vector2(w * 0.4 * face, -h * 0.7)
		ci.draw_line(sh, sh + Vector2(w * 0.75 * face, h * 0.06), dark, h * 0.07)
		ci.draw_line(sh + Vector2(w * 0.5 * face, h * 0.02), sh + Vector2(w * 1.15 * face, h * 0.02), Color(0.12, 0.12, 0.13), h * 0.06)


## A score plate: a box in the side's colour with the rounds won.
static func _score_box(ci: CanvasItem, c: Vector2, n: int, col: Color, sz := 46.0) -> void:
	ci.draw_rect(Rect2(c - Vector2(sz, sz * 0.8) * 0.5, Vector2(sz, sz * 0.8)), col)
	HudDraw.text(ci, str(n), c, int(sz * 0.6), Color.WHITE, 1, 2, "number")


static func _pic_duel(ci: CanvasItem, s: Vector2) -> void:
	var g := s.y * 0.88
	_fighter(ci, Vector2(s.x * 0.3, g), s.y * 0.56, HudDraw.BLUE, 1)
	_fighter(ci, Vector2(s.x * 0.7, g), s.y * 0.56, HudDraw.ORANGE, -1)
	HudDraw.text(ci, "VS", Vector2(s.x * 0.5, g - s.y * 0.3), int(s.y * 0.14), UI.ACCENT, 1, 4, "heavy")
	# The score bar: 3 : 4, first to 5.
	var cy := s.y * 0.14
	_score_box(ci, Vector2(s.x * 0.42, cy), 3, HudDraw.BLUE)
	_score_box(ci, Vector2(s.x * 0.58, cy), 4, HudDraw.ORANGE)
	HudDraw.text(ci, "OBJECTIVE: 5", Vector2(s.x * 0.5, cy), 15, Color.WHITE, 1, 2, "bold")
	for i in 5:
		var on_l := i < 3
		var on_r := i < 4
		ci.draw_circle(Vector2(s.x * 0.42 - 44 - i * 16, cy), 5.0, HudDraw.BLUE if on_l else Color(1, 1, 1, 0.2), true, -1.0, true)
		ci.draw_circle(Vector2(s.x * 0.58 + 44 + i * 16, cy), 5.0, HudDraw.ORANGE if on_r else Color(1, 1, 1, 0.2), true, -1.0, true)
	HudDraw.text(ci, "YOU", Vector2(s.x * 0.3, g + 0.0 - s.y * 0.62), 16, HudDraw.BLUE.lightened(0.3), 1, 2, "heavy")
	HudDraw.text(ci, "THEM", Vector2(s.x * 0.7, g - s.y * 0.62), 16, HudDraw.ORANGE.lightened(0.2), 1, 2, "heavy")


static func _pic_pick(ci: CanvasItem, s: Vector2) -> void:
	# The ROUNDS strip: pairs of rounds, blue yours, orange theirs, the current pair ringed.
	HudDraw.text(ci, "ROUNDS", Vector2(s.x * 0.12, s.y * 0.14), 16, UI.TEXT_DIM, 1, 0, "bold")
	for i in 9:
		var c := Vector2(s.x * 0.22 + i * 46.0, s.y * 0.14)
		var mine := (i / 2) % 2 == 0
		ci.draw_circle(c, 15.0, HudDraw.BLUE if mine else HudDraw.ORANGE, true, -1.0, true)
		HudDraw.text(ci, str(i + 1), c, 15, Color.WHITE, 1, 0, "number")
	ci.draw_rect(Rect2(Vector2(s.x * 0.22 + 4 * 46.0 - 21, s.y * 0.14 - 21), Vector2(46 + 42, 42)), UI.ACCENT, false, 2.5)
	# Four gun cards: one picked (yellow), one resting with the clock and its rounds.
	var icons := ["weapon_ar", "weapon_smg", "weapon_sg", "weapon_sniper"]
	var cw := s.x * 0.15
	var ch := s.y * 0.36
	for i in 4:
		var r := Rect2(Vector2(s.x * 0.08 + i * (cw + 12), s.y * 0.32), Vector2(cw, ch))
		var resting := i == 2
		var picked := i == 1
		ci.draw_rect(r, Color(0.13, 0.14, 0.16, 0.95))
		HudDraw.icon(ci, HudDraw.tex(String(icons[i])), r.get_center() - Vector2(0, ch * 0.08), r.size * Vector2(0.86, 0.6),
			Color(1, 1, 1, 0.3 if resting else 0.95))
		if resting:
			HudDraw.icon(ci, HudDraw.tex("v_timer"), r.get_center() + Vector2(0, ch * 0.22), Vector2(20, 20), Color(1, 1, 1, 0.8))
			HudDraw.text(ci, "4 ROUNDS", r.get_center() + Vector2(0, ch * 0.38), 13, Color(1, 1, 1, 0.8), 1, 0, "bold")
		ci.draw_rect(r, UI.ACCENT if picked else Color(1, 1, 1, 0.18), false, 3.0 if picked else 1.0)
	# The pick goes to both fighters: the gun over the two of them.
	var from := Vector2(s.x * 0.08 + (cw + 12) + cw * 0.5, s.y * 0.32 + ch)
	_fighter(ci, Vector2(s.x * 0.84, s.y * 0.9), s.y * 0.4, HudDraw.BLUE)
	_fighter(ci, Vector2(s.x * 0.94, s.y * 0.9), s.y * 0.4, HudDraw.ORANGE)
	var gun := Vector2(s.x * 0.89, s.y * 0.3)
	var lane := s.x * 0.77
	var bottom := from.y + 22.0
	ci.draw_polyline(PackedVector2Array([from + Vector2(0, 6), Vector2(from.x, bottom), Vector2(lane, bottom), Vector2(lane, gun.y),
		Vector2(gun.x - 44, gun.y)]), Color(UI.ACCENT, 0.85), 3.0, true)
	ci.draw_colored_polygon(PackedVector2Array([Vector2(gun.x - 36, gun.y), Vector2(gun.x - 46, gun.y - 7), Vector2(gun.x - 46, gun.y + 7)]), UI.ACCENT)
	HudDraw.icon(ci, HudDraw.tex("weapon_smg"), gun, Vector2(64, 30), Color.WHITE)
	HudDraw.text(ci, "BOTH", gun + Vector2(0, 28), 15, UI.ACCENT, 1, 2, "heavy")


static func _pic_clock(ci: CanvasItem, s: Vector2) -> void:
	# The top clock: stage 1 then stage 2.
	var c1 := Vector2(s.x * 0.16, s.y * 0.3)
	var c2 := Vector2(s.x * 0.16, s.y * 0.68)
	for pair: Array in [[c1, "00:20", "STAGE 1", Color.WHITE], [c2, "01:30", "STAGE 2", Color.WHITE]]:
		var c: Vector2 = pair[0]
		ci.draw_rect(Rect2(c - Vector2(78, 26), Vector2(156, 52)), Color(0, 0, 0, 0.6))
		HudDraw.text(ci, String(pair[1]), c, 34, pair[3], 1, 2, "number")
		HudDraw.text(ci, String(pair[2]), c + Vector2(0, -40), 14, UI.TEXT_DIM, 1, 0, "bold")
	ci.draw_line(c1 + Vector2(0, 30), c2 + Vector2(0, -58), Color(UI.ACCENT, 0.8), 3.0)
	ci.draw_colored_polygon(PackedVector2Array([c2 + Vector2(0, -50), c2 + Vector2(-7, -62), c2 + Vector2(7, -62)]), UI.ACCENT)
	# The hall from above and the closing zone: outside tinted, the circle shrinking to its last spot.
	var hall := Rect2(Vector2(s.x * 0.36, s.y * 0.1), Vector2(s.x * 0.56, s.y * 0.76))
	ci.draw_rect(hall, Color(0.14, 0.2, 0.34, 0.85))
	var zc := hall.get_center() + Vector2(hall.size.x * 0.08, -hall.size.y * 0.06)
	var zr := hall.size.y * 0.42
	ci.draw_circle(zc, zr, Color(0.11, 0.12, 0.13, 1.0), true, -1.0, true)
	for blk: Rect2 in [Rect2(0.1, 0.18, 0.18, 0.1), Rect2(0.62, 0.7, 0.2, 0.1), Rect2(0.45, 0.3, 0.06, 0.32), Rect2(0.2, 0.66, 0.12, 0.12)]:
		ci.draw_rect(Rect2(hall.position + blk.position * hall.size, blk.size * hall.size), Color(0.55, 0.6, 0.66, 0.35))
	ci.draw_arc(zc, zr, 0.0, TAU, 72, Color.WHITE, 2.0, true)
	ci.draw_arc(zc, zr * 0.55, 0.0, TAU, 56, Color(1, 1, 1, 0.45), 1.5, true)
	ci.draw_arc(zc, zr * 0.18, 0.0, TAU, 32, Color(1, 1, 1, 0.3), 1.5, true)
	for a in 6:
		var d := Vector2.from_angle(TAU * a / 6.0 + 0.3)
		var p0 := zc + d * zr * 0.94
		var p1 := zc + d * zr * 0.66
		ci.draw_line(p0, p1, Color(UI.ACCENT, 0.9), 2.5)
		ci.draw_colored_polygon(PackedVector2Array([p1 - d * 6.0, p1 + d.orthogonal() * 5.0 + d * 3.0, p1 - d.orthogonal() * 5.0 + d * 3.0]), UI.ACCENT)
	ci.draw_rect(hall, Color(1, 1, 1, 0.5), false, 1.5)
	HudDraw.text(ci, "OUTSIDE: HP DRAINS", hall.position + Vector2(10, hall.size.y - 18), 14, Color(0.6, 0.78, 1.0), 0, 2, "bold")


static func _pic_group(ci: CanvasItem, s: Vector2) -> void:
	var g := s.y * 0.72
	for i in 4:
		var foot := Vector2(s.x * (0.14 + i * 0.12), g)
		_fighter(ci, foot, s.y * (0.5 if i == 0 else 0.42), HudDraw.BLUE if i == 0 else HudDraw.BLUE.lightened(0.18))
		if i == 0:
			HudDraw.icon(ci, HudDraw.tex("v_star"), foot + Vector2(0, -s.y * 0.58), Vector2(22, 22), UI.ACCENT)
	HudDraw.text(ci, "LEADER", Vector2(s.x * 0.14, g + 18), 14, UI.ACCENT, 1, 2, "heavy")
	HudDraw.text(ci, "DUO 2 VS 2   ·   SQUAD 4 VS 4", Vector2(s.x * 0.32, s.y * 0.9), 16, Color.WHITE, 1, 2, "bold")
	# The GROUP CODE plate with its copy glyph, and an invite arrow.
	var r := Rect2(Vector2(s.x * 0.62, s.y * 0.2), Vector2(s.x * 0.32, s.y * 0.3))
	ci.draw_rect(r, Color(0, 0, 0, 0.55))
	ci.draw_rect(r, Color(UI.ACCENT, 0.7), false, 2.0)
	HudDraw.text(ci, "GROUP CODE", r.position + Vector2(r.size.x * 0.5, 22), 15, UI.TEXT_DIM, 1, 0, "bold")
	HudDraw.text(ci, "48213 07956", r.position + Vector2(r.size.x * 0.44, r.size.y * 0.62), 26, UI.ACCENT, 1, 0, "number")
	var cp := r.position + Vector2(r.size.x * 0.9, r.size.y * 0.62)
	ci.draw_rect(Rect2(cp + Vector2(-8, -10), Vector2(13, 15)), Color.WHITE, false, 2.0)
	ci.draw_rect(Rect2(cp + Vector2(-4, -6), Vector2(13, 15)), Color.WHITE, false, 2.0)
	var inv := Rect2(Vector2(s.x * 0.62, s.y * 0.58), Vector2(s.x * 0.32, s.y * 0.18))
	ci.draw_rect(inv, Color(1, 1, 1, 0.08))
	HudDraw.text(ci, "+ INVITE", inv.get_center(), 20, Color.WHITE, 1, 0, "heavy")
	ci.draw_line(Vector2(s.x * 0.6, s.y * 0.48), Vector2(s.x * 0.53, s.y * 0.48), Color(UI.ACCENT, 0.8), 3.0)
	ci.draw_colored_polygon(PackedVector2Array([Vector2(s.x * 0.52, s.y * 0.48), Vector2(s.x * 0.535, s.y * 0.46), Vector2(s.x * 0.535, s.y * 0.5)]), UI.ACCENT)


static func _pic_bot(ci: CanvasItem, s: Vector2) -> void:
	var g := s.y * 0.86
	_fighter(ci, Vector2(s.x * 0.18, g), s.y * 0.56, HudDraw.BLUE, 1)
	_fighter(ci, Vector2(s.x * 0.48, g), s.y * 0.56, Color(0.62, 0.64, 0.68), -1)
	HudDraw.text(ci, "BOT", Vector2(s.x * 0.48, g - s.y * 0.59), 16, Color.WHITE, 1, 2, "heavy")
	var levels := ["EASY", "NORMAL", "HARD"]
	for i in 3:
		var r := Rect2(Vector2(s.x * 0.3 + i * 92.0, s.y * 0.08), Vector2(84, 34))
		ci.draw_rect(r, UI.ACCENT if i == 1 else Color(0, 0, 0, 0.55))
		HudDraw.text(ci, String(levels[i]), r.get_center(), 14, UI.INK if i == 1 else Color.WHITE, 1, 0, "bold")
	# The target dummy: a post with rings, and an aim reticle on it.
	var d := Vector2(s.x * 0.8, g)
	ci.draw_rect(Rect2(d + Vector2(-5, -s.y * 0.5), Vector2(10, s.y * 0.5)), Color(0.45, 0.38, 0.3))
	var tc := d + Vector2(0, -s.y * 0.5)
	for k in 3:
		ci.draw_circle(tc, 40.0 - k * 13.0, Color.WHITE if k % 2 == 0 else HudDraw.RED, true, -1.0, true)
	HudDraw.ring(ci, tc, 52.0, Color(1, 1, 1, 0.8), 2.0)
	ci.draw_line(tc + Vector2(-64, 0), tc + Vector2(-44, 0), Color.WHITE, 2.0)
	ci.draw_line(tc + Vector2(44, 0), tc + Vector2(64, 0), Color.WHITE, 2.0)
	HudDraw.text(ci, "DUMMY", tc + Vector2(0, -68), 16, UI.ACCENT, 1, 2, "heavy")
	HudDraw.text(ci, "OR", Vector2(s.x * 0.64, s.y * 0.5), 20, UI.TEXT_DIM, 1, 2, "heavy")


static func _pic_kit(ci: CanvasItem, s: Vector2) -> void:
	# The weapon panel's three slots in SWITCH's order, the one in hand lit.
	var slots := [["weapon_ar", "GUN", "30"], ["weapon_sidearm", "WREN 9", "12"], ["v_fist", "FISTS", ""]]
	var sw := s.y * 0.34
	var y := s.y * 0.2
	for i in 3:
		var r := Rect2(Vector2(s.x * 0.1 + i * (sw + 40), y), Vector2(sw, sw))
		ci.draw_rect(r, Color(HudDraw.SLOT_BG, 0.85))
		ci.draw_rect(r, HudDraw.GOLD if i == 1 else Color(1, 1, 1, 0.2), false, 3.0 if i == 1 else 1.0)
		HudDraw.icon(ci, HudDraw.tex(String(slots[i][0])), r.get_center() - Vector2(0, sw * 0.08), r.size * 0.7, Color.WHITE)
		HudDraw.text(ci, String(slots[i][1]), r.get_center() + Vector2(0, sw * 0.62), 15, Color.WHITE, 1, 2, "bold")
		if String(slots[i][2]) != "":
			HudDraw.text(ci, String(slots[i][2]), r.get_center() + Vector2(0, sw * 0.36), 14, HudDraw.YELLOW, 1, 2, "number")
		if i < 2:
			var a := Vector2(r.end.x + 6, r.get_center().y)
			ci.draw_line(a, a + Vector2(26, 0), Color(UI.ACCENT, 0.8), 3.0)
			ci.draw_colored_polygon(PackedVector2Array([a + Vector2(32, 0), a + Vector2(24, -6), a + Vector2(24, 6)]), UI.ACCENT)
	# Back to the gun, and the SWITCH button with its cycle.
	var l := Vector2(s.x * 0.1 + sw * 0.5, y + sw + 44)
	var rr := Vector2(s.x * 0.1 + 2 * (sw + 40) + sw * 0.5, y + sw + 44)
	ci.draw_polyline(PackedVector2Array([rr + Vector2(0, -6), rr + Vector2(0, 14), l + Vector2(0, 14), l + Vector2(0, -2)]), Color(UI.ACCENT, 0.6), 2.5, true)
	ci.draw_colored_polygon(PackedVector2Array([l + Vector2(0, -8), l + Vector2(-6, 2), l + Vector2(6, 2)]), Color(UI.ACCENT, 0.6))
	var bc := Vector2(s.x * 0.84, s.y * 0.42)
	HudDraw.button(ci, bc, s.y * 0.17, HudDraw.tex("weapon_sidearm"), 1.0, false, false, true, 0.8)       # (SWITCH shows the one it goes to)
	HudDraw.text(ci, "SWITCH", bc + Vector2(0, s.y * 0.26), 18, Color.WHITE, 1, 3, "heavy")
