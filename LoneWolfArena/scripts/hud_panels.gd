class_name HudPanels
extends Control
## Overlay panels of the in-match HUD, drawn above everything else:
##  - the pre-round weapon pick: near-black panel with corner brackets, "SELECT WEAPON FOR
##    ROUND n", a "| WEAPON" label, a 4-column grid of gun cards (silhouette, name, class; the
##    choice gets a yellow outline and a tick), a countdown and a yellow SELECT button. It calls
##    on_pick exactly once: SELECT or the close X confirm the current choice, so does the timer;
##  - the scoreboard (rows from arena.scoreboard_rows()), usable while the match runs.
## The HUD sends taps here first (tap() returns true when a panel used the tap).

const CLASS_NAMES := {"AR": "ASSAULT RIFLE", "SMG": "SUBMACHINE GUN", "SG": "SHOTGUN", "PISTOL": "HAND CANNON",
	"SNIPER": "SNIPER RIFLE", "MELEE": "MELEE"}
const COLS := 4

var arena: Node
var pick_open := false
var pick_options: Array = []
var pick_choice := ""
var pick_left := 0.0
var pick_total := 1.0
var pick_round := 1
var board_open := false
var _pick_cb := Callable()
var _pick_done := true
var _anim := 0.0
var _rows: Array = []
var _rows_t := 0.0
var _flash := ""
var _flash_t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


# ---------------------------------------------------------------- weapon pick

func open_pick(options: Array, preselect: String, seconds: float, on_pick: Callable, round_index := 1) -> void:
	pick_options = options.duplicate()
	if pick_options.is_empty():
		pick_options = [Weapons.DEFAULT_PICK]
	pick_choice = preselect if pick_options.has(preselect) else String(pick_options[0])
	pick_total = maxf(seconds, 0.1)
	pick_left = pick_total
	pick_round = round_index
	_pick_cb = on_pick
	_pick_done = false
	pick_open = true
	board_open = false
	_anim = 0.0
	visible = true


## Closes the panel without a callback (the arena picked for the player).
func close_pick() -> void:
	_pick_done = true
	_pick_cb = Callable()
	pick_open = false
	visible = board_open


## Confirms the current choice: calls on_pick once and closes.
func finish_pick() -> void:
	if _pick_done:
		return
	_pick_done = true
	pick_open = false
	visible = board_open
	var cb := _pick_cb
	_pick_cb = Callable()
	Audio.play("ui_click", -4.0)
	if cb.is_valid():
		cb.call(pick_choice)


func select(id: String) -> void:
	if pick_options.has(id):
		pick_choice = id


# ---------------------------------------------------------------- scoreboard

func open_board() -> void:
	if pick_open:
		return
	board_open = true
	_rows_t = 0.0
	_anim = 0.0
	visible = true
	Audio.play("ui_select", -8.0)


func close_board() -> void:
	board_open = false
	visible = pick_open


## delta: game time (the pick timer follows the prep clock); real: unscaled time for animation.
func tick(delta: float, real: float) -> void:
	_anim += real
	_flash_t -= real
	if pick_open and not _pick_done:
		pick_left -= delta
		if pick_left <= 0.0:
			pick_left = 0.0
			finish_pick()
	if board_open and arena != null:
		_rows_t -= real
		if _rows_t <= 0.0:
			_rows_t = 0.25
			_rows = arena.call("scoreboard_rows")
	if visible:
		queue_redraw()


# ---------------------------------------------------------------- geometry

func _u() -> float:
	return HudLayout.unit(size)


func pick_rect() -> Rect2:
	var u := _u()
	var x0 := 0.025 * u
	var w := minf(1.42 * u, size.x - x0 - 0.47 * u)
	var rows := maxi(1, ceili(pick_options.size() / float(COLS)))
	var h := u * (0.08 + 0.06 + rows * 0.205 + (rows - 1) * 0.018 + 0.03 + 0.1)
	var y0 := clampf((size.y - h) * 0.5 - 0.03 * size.y, 0.105 * size.y, maxf(size.y - h - 4.0, 0.105 * size.y))
	return Rect2(x0, y0, w, h)


func _card_size() -> Vector2:
	var u := _u()
	var r := pick_rect()
	var gap := 0.018 * u
	return Vector2((r.size.x - 0.05 * u - gap * (COLS - 1)) / COLS, 0.205 * u)


func card_rect(i: int) -> Rect2:
	var u := _u()
	var r := pick_rect()
	var cs := _card_size()
	var gap := 0.018 * u
	var top := r.position.y + 0.14 * u
	return Rect2(Vector2(r.position.x + 0.025 * u + (i % COLS) * (cs.x + gap), top + (i / COLS) * (cs.y + gap)), cs)


func select_rect() -> Rect2:
	var u := _u()
	var r := pick_rect()
	var bs := Vector2(0.26 * u, 0.072 * u)
	return Rect2(Vector2(r.end.x - 0.025 * u - bs.x, r.end.y - 0.024 * u - bs.y), bs)


func pick_close_rect() -> Rect2:
	var u := _u()
	var r := pick_rect()
	var c := Vector2(r.end.x - 0.045 * u, r.position.y + 0.042 * u)
	return Rect2(c - Vector2(0.032, 0.032) * u, Vector2(0.064, 0.064) * u)


func board_rect() -> Rect2:
	var u := _u()
	var w := minf(1.34 * u, size.x - 0.1 * u)
	var h := (0.155 + maxi(_rows.size(), 2) * 0.085 + 0.075) * u
	return Rect2(Vector2((size.x - w) * 0.5, 0.17 * size.y), Vector2(w, h))


func board_close_rect() -> Rect2:
	var u := _u()
	var r := board_rect()
	var c := Vector2(r.end.x - 0.045 * u, r.position.y + 0.045 * u)
	return Rect2(c - Vector2(0.034, 0.034) * u, Vector2(0.068, 0.068) * u)


# ---------------------------------------------------------------- input

func tap(pos: Vector2) -> bool:
	if pick_open:
		if pick_rect().has_point(pos):
			if select_rect().grow(4).has_point(pos) or pick_close_rect().grow(6).has_point(pos):
				_flash = "select"
				_flash_t = 0.15
				finish_pick()
				return true
			for i in pick_options.size():
				if card_rect(i).has_point(pos):
					if pick_choice != String(pick_options[i]):
						Audio.play("ui_select", -6.0)
					pick_choice = String(pick_options[i])
					_flash = "card%d" % i
					_flash_t = 0.15
					return true
			return true
	if board_open:
		if board_close_rect().grow(8).has_point(pos):
			close_board()
			Audio.play("ui_back", -6.0)
			return true
		if board_rect().has_point(pos):
			return true
	return false


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if pick_open:
		_draw_pick()
	elif board_open:
		_draw_board()


func _draw_pick() -> void:
	var u := _u()
	var a := clampf(_anim / 0.18, 0.0, 1.0)
	var slide := (1.0 - a) * -0.06 * u
	draw_set_transform(Vector2(slide, 0))
	var r := pick_rect()
	draw_rect(r, Color(HudDraw.PANEL_BG, HudDraw.PANEL_BG.a * a))
	HudDraw.vband(self, Rect2(r.position, Vector2(r.size.x, 0.08 * u)), Color(1, 1, 1, 0.07 * a), Color(1, 1, 1, 0.02 * a))
	draw_line(Vector2(r.position.x, r.position.y + 0.08 * u), Vector2(r.end.x, r.position.y + 0.08 * u), Color(1, 1, 1, 0.1 * a), 1.0)
	HudDraw.corner_brackets(self, r.grow(-4), 0.035 * u, Color(1, 1, 1, 0.4 * a), 2.0)
	# Header: "SELECT WEAPON FOR ROUND 1" with the key part in yellow.
	HudDraw.text_parts(self, [["SELECT WEAPON FOR ", Color(1, 1, 1)], ["ROUND %d" % pick_round, HudDraw.YELLOW]],
		Vector2(r.get_center().x, r.position.y + 0.042 * u), int(0.038 * u), 1, 0, "bold", a)
	var xr := pick_close_rect()
	HudDraw.close_button(self, xr.get_center(), xr.size.x * 0.5, a)
	# "| WEAPON" label.
	var ly := r.position.y + 0.11 * u
	draw_rect(Rect2(Vector2(r.position.x + 0.025 * u, ly - 0.014 * u), Vector2(0.007 * u, 0.028 * u)), Color(HudDraw.YELLOW, a))
	HudDraw.text(self, "WEAPON", Vector2(r.position.x + 0.045 * u, ly), int(0.03 * u), Color(1, 1, 1, a), 0, 0, "bold")
	for i in pick_options.size():
		_draw_card(i, a, u)
	# Footer: rule text, countdown, SELECT.
	var sr := select_rect()
	var fy := sr.get_center().y
	HudDraw.text_parts(self, [["BOTH FIGHTERS USE THE ", Color(1, 1, 1, 0.85)], ["SELECTED WEAPON", HudDraw.YELLOW]],
		Vector2(r.position.x + 0.03 * u, fy), int(0.027 * u), 0, 0, "semi", a)
	var cc := Vector2(sr.position.x - 0.06 * u, fy)
	var cr := 0.03 * u
	HudDraw.disk(self, cc, cr, Color(0, 0, 0, 0.5 * a))
	HudDraw.ring(self, cc, cr, Color(1, 1, 1, 0.18 * a), 3.0)
	var urgent := pick_left <= 3.0
	HudDraw.ring(self, cc, cr, Color(HudDraw.RED if urgent else HudDraw.YELLOW, a), 3.0, pick_left / pick_total)
	HudDraw.text(self, str(ceili(pick_left)), cc, int(0.034 * u), Color(HudDraw.RED if urgent else Color.WHITE, a), 1, 0, "number")
	var pressed := _flash == "select" and _flash_t > 0.0
	var bc := HudDraw.YELLOW.darkened(0.15) if pressed else HudDraw.YELLOW
	draw_rect(sr, Color(bc, a))
	HudDraw.vband(self, Rect2(sr.position, Vector2(sr.size.x, sr.size.y * 0.5)), Color(1, 1, 1, 0.25 * a), Color(1, 1, 1, 0.0))
	HudDraw.text(self, "SELECT", sr.get_center(), int(0.036 * u), Color(0.1, 0.07, 0.02, a), 1, 0, "bold")
	draw_set_transform(Vector2.ZERO)


func _draw_card(i: int, a: float, u: float) -> void:
	var id := String(pick_options[i])
	var def: Dictionary = Weapons.DEFS.get(id, Weapons.DEFS[Weapons.DEFAULT_PICK])
	var r := card_rect(i)
	var sel := id == pick_choice
	var flash := _flash == "card%d" % i and _flash_t > 0.0
	draw_rect(r, Color(HudDraw.CARD_BG, HudDraw.CARD_BG.a * a))
	if sel or flash:
		HudDraw.vband(self, r, Color(1, 0.85, 0.3, 0.1 * a), Color(1, 0.85, 0.3, 0.02 * a))
	HudDraw.vband(self, Rect2(r.position, Vector2(r.size.x, 0.075 * u)), Color(1, 1, 1, 0.06 * a), Color(1, 1, 1, 0.0))
	HudDraw.corner_brackets(self, r.grow(-3), 0.02 * u, Color(1, 1, 1, (0.5 if sel else 0.28) * a), 1.5)
	var tc := Color(1, 1, 1, (1.0 if sel else 0.82) * a)
	HudDraw.text(self, String(def.name), r.position + Vector2(0.016 * u, 0.03 * u), int(0.03 * u), tc, 0, 0, "bold")
	HudDraw.text(self, String(CLASS_NAMES.get(String(def["class"]), String(def["class"]))), r.position + Vector2(0.016 * u, 0.062 * u),
		int(0.021 * u), Color(0.72, 0.76, 0.82, a), 0, 0, "semi")
	var mag := int(def.mag)
	if mag > 0:
		HudDraw.text(self, "MAG %d" % mag, Vector2(r.end.x - 0.016 * u, r.position.y + 0.062 * u), int(0.021 * u), Color(0.72, 0.76, 0.82, a), 2, 0, "semi")
	var gun_box := Vector2(r.size.x * 0.8, r.size.y * 0.46)
	HudDraw.icon(self, HudDraw.weapon_tex(def), Vector2(r.get_center().x, r.position.y + r.size.y * 0.66), gun_box,
		Color(1, 1, 1, (0.97 if sel else 0.62) * a))
	if sel:
		draw_rect(r, Color(HudDraw.YELLOW, a), false, maxf(2.0, 0.004 * u))
		var tcen := Vector2(r.end.x - 0.024 * u, r.position.y + 0.024 * u)
		HudDraw.disk(self, tcen, 0.017 * u, Color(HudDraw.YELLOW, a))
		HudDraw.icon(self, HudDraw.tex("v_tick"), tcen, Vector2(0.022, 0.022) * u, Color(0.1, 0.07, 0.02, a))


func _draw_board() -> void:
	var u := _u()
	var a := clampf(_anim / 0.15, 0.0, 1.0)
	var r := board_rect()
	draw_rect(r, Color(HudDraw.PANEL_BG, HudDraw.PANEL_BG.a * a))
	HudDraw.vband(self, Rect2(r.position, Vector2(r.size.x, 0.09 * u)), Color(1, 1, 1, 0.08 * a), Color(1, 1, 1, 0.02 * a))
	HudDraw.corner_brackets(self, r.grow(-4), 0.035 * u, Color(1, 1, 1, 0.4 * a), 2.0)
	var mode := "LONE WOLF"
	var map_name := "CARGO CAGE"
	var round_i := 1
	var goal := 1
	if arena != null:
		map_name = String(arena.get("map_name"))
		round_i = int(arena.get("round_index"))
		goal = int(arena.get("rounds_to_win"))
	var hy := r.position.y + 0.045 * u
	draw_rect(Rect2(Vector2(r.position.x + 0.03 * u, hy - 0.016 * u), Vector2(0.007 * u, 0.032 * u)), Color(HudDraw.YELLOW, a))
	HudDraw.text_parts(self, [["SCOREBOARD   ", Color(1, 1, 1)], [mode + "  ·  " + map_name, Color(0.72, 0.76, 0.82)]],
		Vector2(r.position.x + 0.05 * u, hy), int(0.032 * u), 0, 0, "bold", a)
	HudDraw.text_parts(self, [["ROUND %d   ·   OBJECTIVE " % round_i, Color(1, 1, 1, 0.85)], [str(goal), HudDraw.YELLOW]],
		Vector2(r.end.x - 0.1 * u, hy), int(0.026 * u), 2, 0, "semi", a)
	var xr := board_close_rect()
	HudDraw.close_button(self, xr.get_center(), xr.size.x * 0.5, a)
	# Columns.
	var cols := ["ROUNDS", "KILLS", "DAMAGE", "HEADSHOTS", "ACCURACY", "HP"]
	var name_w := r.size.x * 0.33
	var col_w := (r.size.x - name_w - 0.06 * u) / cols.size()
	var x0 := r.position.x + 0.03 * u
	var hy2 := r.position.y + 0.125 * u
	HudDraw.text(self, "PLAYER", Vector2(x0 + 0.03 * u, hy2), int(0.022 * u), Color(0.7, 0.74, 0.8, a), 0, 0, "semi")
	for c in cols.size():
		HudDraw.text(self, String(cols[c]), Vector2(x0 + name_w + col_w * (c + 0.5), hy2), int(0.022 * u), Color(0.7, 0.74, 0.8, a), 1, 0, "semi")
	var row_h := 0.085 * u
	var y := r.position.y + 0.155 * u
	var rows := _rows
	if rows.is_empty():
		rows = [{"name": "YOU", "me": true, "alive": true, "hp": 200, "kills": 0, "damage": 0, "headshots": 0, "accuracy": 0, "rounds": 0},
			{"name": "BOT", "me": false, "alive": true, "hp": 200, "kills": 0, "damage": 0, "headshots": 0, "accuracy": 0, "rounds": 0}]
	for row: Dictionary in rows:
		var me := bool(row.get("me", false))
		var team := HudDraw.BLUE if me else HudDraw.ORANGE
		var rr := Rect2(Vector2(x0, y), Vector2(r.size.x - 0.06 * u, row_h - 0.012 * u))
		HudDraw.band(self, rr, Color(team, 0.3 * a), Color(team, 0.06 * a))
		draw_rect(Rect2(rr.position, Vector2(0.008 * u, rr.size.y)), Color(team, a))
		var cy := rr.get_center().y
		var nw := HudDraw.text(self, String(row.get("name", "?")), Vector2(x0 + 0.03 * u, cy), int(0.032 * u), Color(1, 1, 1, a), 0, 0, "bold")
		if not bool(row.get("alive", true)):
			HudDraw.text(self, "ELIMINATED", Vector2(x0 + 0.045 * u + nw, cy), int(0.02 * u), Color(1, 0.4, 0.35, a), 0, 0, "bold")
		var vals := [str(row.get("rounds", 0)), str(row.get("kills", 0)), str(row.get("damage", 0)), str(row.get("headshots", 0)),
			"%d%%" % int(row.get("accuracy", 0)), str(row.get("hp", 0))]
		for c in vals.size():
			var vc := Color(1, 1, 1, a)
			if c == 0:
				vc = Color(team.lightened(0.35), a)
			HudDraw.text(self, String(vals[c]), Vector2(x0 + name_w + col_w * (c + 0.5), cy - (0.008 * u if c == 5 else 0.0)), int(0.032 * u), vc, 1, 0, "number")
		# HP mini bar under the number.
		var hpf := clampf(float(row.get("hp", 0)) / Fighter.MAX_HP, 0.0, 1.0)
		var bw := col_w * 0.6
		var bx := x0 + name_w + col_w * 5.5 - bw * 0.5
		draw_rect(Rect2(bx, cy + 0.016 * u, bw, 0.006 * u), Color(0, 0, 0, 0.5 * a))
		draw_rect(Rect2(bx, cy + 0.016 * u, bw * hpf, 0.006 * u), Color(HudDraw.HP_WHITE, a))
		y += row_h
	HudDraw.text(self, "TAP THE SCORE BAR OR THE LIST BUTTON TO OPEN / CLOSE", Vector2(r.get_center().x, r.end.y - 0.03 * u),
		int(0.019 * u), Color(1, 1, 1, 0.45 * a), 1, 0, "semi")
