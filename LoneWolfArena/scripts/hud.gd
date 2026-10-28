class_name HUD
extends Control
## In-match HUD: multi-touch controls (floating joystick, look area, drag-fire buttons),
## crosshair, hit feedback, health/ammo, minimap, timer, kill feed and messages.
## Everything is drawn in _draw() so it stays cheap on phones and easy to re-layout.

signal pause_pressed

var player: Player
var arena: Node
var layout := {}
var active := true
var editor_mode := false
var selected_id := ""

var _touches := {}
var _joy_touch := -1
var _joy_center := Vector2.ZERO
var _joy_vec := Vector2.ZERO
var _pressed := {}
var _hitmarker := 0.0
var _hit_head := false
var _kill_marker := 0.0
var _dmg_numbers: Array = []
var _dmg_dirs: Array = []
var _kill_feed: Array = []
var _flash := 0.0
var _center_text := ""
var _center_sub := ""
var _center_t := 0.0
var _center_color := Color.WHITE
var _center_size := 96
var _enemy_hp_t := 0.0
var _enemy: Fighter
var _reveal := {}
var _fps_smooth := 60.0
var tips_time := 0.0
var match_over := false
var _time := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	reload_layout()


func reload_layout() -> void:
	layout = HudLayout.current()


func bind(p: Player, a: Node) -> void:
	player = p
	arena = a
	player.hit_landed.connect(_on_hit_landed)
	player.damaged.connect(_on_damaged)


# ---------------------------------------------------------------- feedback API

func show_center(text: String, seconds: float, color := Color.WHITE, fsize := 96, sub := "") -> void:
	_center_text = text
	_center_sub = sub
	_center_t = seconds
	_center_color = color
	_center_size = fsize


func add_kill_feed(killer: String, victim: String, weapon_name: String, _weapon_icon: String, headshot: bool, mine: bool) -> void:
	var text := "%s  [%s]  %s" % [killer, weapon_name, victim]
	if headshot:
		text += "  · HEADSHOT"
	_kill_feed.push_front({"text": text, "t": 5.0, "color": UI.ACCENT if mine else Color(1, 0.6, 0.55)})
	if _kill_feed.size() > 4:
		_kill_feed.pop_back()


func show_round_banner(round_index: int, area: String) -> void:
	show_center("ROUND %d" % round_index, 1.8, UI.ACCENT, 90, "AREA: " + area)


func open_weapon_pick(_options: Array, preselect: String, _seconds: float, on_pick: Callable) -> void:
	on_pick.call(preselect)


func close_weapon_pick() -> void:
	pass


func kill_banner(_victim: String, _headshot: bool) -> void:
	pass


func reveal(f: Fighter, seconds := 2.5) -> void:
	_reveal[f] = seconds


func _on_hit_landed(target: Fighter, amount: float, headshot: bool, pos: Vector3, killed: bool) -> void:
	_hitmarker = 0.22
	_hit_head = headshot
	_enemy = target
	_enemy_hp_t = 3.0
	if Game.settings.damage_numbers:
		_dmg_numbers.append({"pos": pos + Vector3(randf_range(-0.15, 0.15), 0.25, 0), "text": str(roundi(amount)), "head": headshot, "t": 0.0})
	Audio.play("hit_head" if headshot else "hit_body", -2.0 if headshot else -6.0)
	if killed:
		_kill_marker = 1.2
		Audio.play("kill_confirm", 0.0)
		Game.vibrate(60)


func _on_damaged(amount: float, from_pos: Vector3, _headshot: bool, _attacker: Fighter) -> void:
	_flash = minf(_flash + 0.25 + amount / 120.0, 0.6)
	_dmg_dirs.append({"pos": from_pos, "t": 1.4})
	if _dmg_dirs.size() > 4:
		_dmg_dirs.pop_front()
	Audio.play("hurt", -6.0, randf_range(0.95, 1.05))
	Game.vibrate(35)


# ---------------------------------------------------------------- touch input

func _input(event: InputEvent) -> void:
	if editor_mode or not active or player == null:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_on_down(t.index, t.position)
		else:
			_on_up(t.index)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_on_drag(d.index, d.position, d.relative)


func _pause_rect() -> Rect2:
	var vs := size
	return Rect2(Vector2(vs.x - 74, 10), Vector2(64, 64))


func _on_down(index: int, pos: Vector2) -> void:
	var vs := size
	if _pause_rect().has_point(pos):
		_touches[index] = {"kind": "ui"}
		pause_pressed.emit()
		return
	for id: String in HudLayout.ORDER:
		if id == "joystick":
			continue
		if id == "fire_l" and int(Game.settings.left_fire) == 2:
			continue
		var w: Dictionary = layout[id]
		if id == "weapons":
			var slots := HudLayout.weapon_slots(w, vs)
			for i in slots.size():
				if slots[i].grow(4).has_point(pos):
					player.select_weapon(i)
					_pressed["weapons"] = 0.15
					_touches[index] = {"kind": "ui"}
					return
			continue
		var c := HudLayout.center(w, vs)
		var r := HudLayout.radius(w, vs)
		if pos.distance_to(c) <= r * 1.12:
			_press(id, index)
			return
	if pos.x < vs.x * 0.42 and pos.y > vs.y * 0.24 and _joy_touch == -1:
		_joy_touch = index
		var jr := HudLayout.radius(layout.joystick, vs)
		_joy_center = Vector2(clampf(pos.x, jr + 8.0, vs.x * 0.42), clampf(pos.y, vs.y * 0.3, vs.y - jr - 8.0))
		_joy_vec = (pos - _joy_center) / jr
		_touches[index] = {"kind": "joy"}
		return
	_touches[index] = {"kind": "look"}


func _press(id: String, index: int) -> void:
	_pressed[id] = 0.18
	match id:
		"fire_r", "fire_l":
			_touches[index] = {"kind": "fire"}
			player.set_firing(true)
			return
		"scope":
			player.toggle_ads()
		"jump":
			player.do_jump()
		"crouch":
			player.toggle_crouch()
		"reload":
			player.do_reload()
		"medkit":
			player.use_medkit()
		"shield":
			player.use_shield()
		"grenade":
			player.use_grenade()
	_touches[index] = {"kind": "ui"}


func _on_drag(index: int, pos: Vector2, rel: Vector2) -> void:
	if not _touches.has(index):
		return
	match String(_touches[index].kind):
		"joy":
			var jr := HudLayout.radius(layout.joystick, size)
			_joy_vec = ((pos - _joy_center) / jr).limit_length(1.0)
		"look":
			player.add_look(rel, false)
		"fire":
			player.add_look(rel, true)


func _on_up(index: int) -> void:
	if not _touches.has(index):
		return
	var kind := String(_touches[index].kind)
	_touches.erase(index)
	if kind == "joy":
		_joy_touch = -1
		_joy_vec = Vector2.ZERO
	elif kind == "fire":
		var still := false
		for k in _touches:
			if String(_touches[k].kind) == "fire":
				still = true
		if not still:
			player.set_firing(false)


func release_all() -> void:
	tips_time = 0.0
	_touches.clear()
	_joy_touch = -1
	_joy_vec = Vector2.ZERO
	if player:
		player.set_firing(false)
		player.move_dir = Vector2.ZERO


# ---------------------------------------------------------------- tick

func _process(delta: float) -> void:
	_time += delta
	if player and not editor_mode:
		var m := Vector2(_joy_vec.x, -_joy_vec.y)
		if m.length() < 0.12:
			m = Vector2.ZERO
		player.move_dir = m
	for k in _pressed.keys():
		_pressed[k] -= delta
		if _pressed[k] <= 0.0:
			_pressed.erase(k)
	_hitmarker = maxf(_hitmarker - delta, 0.0)
	_kill_marker = maxf(_kill_marker - delta, 0.0)
	_flash = maxf(_flash - delta * 1.2, 0.0)
	_center_t = maxf(_center_t - delta, 0.0)
	tips_time = maxf(tips_time - delta, 0.0)
	_enemy_hp_t = maxf(_enemy_hp_t - delta, 0.0)
	for n in _dmg_numbers:
		n.t += delta
	_dmg_numbers = _dmg_numbers.filter(func(n: Dictionary) -> bool: return n.t < 0.85)
	for d in _dmg_dirs:
		d.t -= delta
	_dmg_dirs = _dmg_dirs.filter(func(d: Dictionary) -> bool: return d.t > 0.0)
	for k in _kill_feed:
		k.t -= delta
	_kill_feed = _kill_feed.filter(func(k: Dictionary) -> bool: return k.t > 0.0)
	for f in _reveal.keys():
		_reveal[f] -= delta
		if _reveal[f] <= 0.0:
			_reveal.erase(f)
	if delta > 0.0:
		_fps_smooth = lerpf(_fps_smooth, 1.0 / delta, 0.05)
	queue_redraw()


# ---------------------------------------------------------------- drawing helpers

func _text(t: String, pos: Vector2, fsize: int, col: Color, align := HORIZONTAL_ALIGNMENT_CENTER, outline := 4, kind := "bold") -> void:
	var f := UI.font(kind)
	var w := 900.0
	var x := pos.x
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		x -= w * 0.5
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		x -= w
	var base := pos.y + (f.get_ascent(fsize) - f.get_descent(fsize)) * 0.5
	if outline > 0:
		draw_string_outline(f, Vector2(x, base), t, align, w, fsize, outline, Color(0, 0, 0, col.a * 0.75))
	draw_string(f, Vector2(x, base), t, align, w, fsize, col)


func _ring(c: Vector2, r: float, col: Color, width: float, frac := 1.0, start := -PI * 0.5) -> void:
	draw_arc(c, r, start, start + TAU * frac, maxi(24, int(64 * frac)), col, width, true)


func _icon(id: String, c: Vector2, s: float, col: Color) -> void:
	var w := maxf(2.0, s * 0.11)
	match id:
		"fire_r", "fire_l":
			_ring(c, s * 0.42, col, w)
			draw_circle(c, s * 0.1, col)
			for a in 4:
				var dir := Vector2.RIGHT.rotated(a * PI * 0.5)
				draw_line(c + dir * s * 0.24, c + dir * s * 0.6, col, w, true)
		"scope":
			_ring(c, s * 0.4, col, w)
			_ring(c, s * 0.12, col, w * 0.8)
			draw_line(c + Vector2(-s * 0.62, 0), c + Vector2(-s * 0.2, 0), col, w, true)
			draw_line(c + Vector2(s * 0.2, 0), c + Vector2(s * 0.62, 0), col, w, true)
			draw_line(c + Vector2(0, -s * 0.62), c + Vector2(0, -s * 0.2), col, w, true)
			draw_line(c + Vector2(0, s * 0.2), c + Vector2(0, s * 0.62), col, w, true)
		"jump":
			for k in 2:
				var y := c.y + s * (0.05 + k * 0.28) - s * 0.2
				draw_polyline(PackedVector2Array([Vector2(c.x - s * 0.36, y + s * 0.2), Vector2(c.x, y - s * 0.12), Vector2(c.x + s * 0.36, y + s * 0.2)]), col, w * 1.2, true)
		"crouch":
			for k in 2:
				var y := c.y + s * (k * 0.28) - s * 0.2
				draw_polyline(PackedVector2Array([Vector2(c.x - s * 0.36, y - s * 0.12), Vector2(c.x, y + s * 0.2), Vector2(c.x + s * 0.36, y - s * 0.12)]), col, w * 1.2, true)
		"reload":
			draw_arc(c, s * 0.38, -PI * 0.15, PI * 1.45, 32, col, w * 1.1, true)
			var tip := c + Vector2.RIGHT.rotated(-PI * 0.15) * s * 0.38
			draw_colored_polygon(PackedVector2Array([tip + Vector2(-s * 0.18, -s * 0.02), tip + Vector2(s * 0.14, -s * 0.06), tip + Vector2(0.0, s * 0.22)]), col)
		"medkit":
			draw_rect(Rect2(c - Vector2(s * 0.12, s * 0.42), Vector2(s * 0.24, s * 0.84)), col)
			draw_rect(Rect2(c - Vector2(s * 0.42, s * 0.12), Vector2(s * 0.84, s * 0.24)), col)
		"shield":
			var pts := PackedVector2Array()
			for i in 7:
				pts.append(c + Vector2.UP.rotated(i * TAU / 6.0) * s * 0.45)
			draw_polyline(pts, col, w * 1.1, true)
			var inner := PackedVector2Array()
			for i in 7:
				inner.append(c + Vector2.UP.rotated(i * TAU / 6.0) * s * 0.2)
			draw_polyline(inner, col, w * 0.8, true)
		"grenade":
			draw_circle(c + Vector2(0, s * 0.08), s * 0.3, col)
			draw_rect(Rect2(c + Vector2(-s * 0.1, -s * 0.38), Vector2(s * 0.2, s * 0.16)), col)
			draw_line(c + Vector2(s * 0.1, -s * 0.32), c + Vector2(s * 0.32, -s * 0.12), col, w, true)
		"pause":
			draw_rect(Rect2(c + Vector2(-s * 0.26, -s * 0.3), Vector2(s * 0.18, s * 0.6)), col)
			draw_rect(Rect2(c + Vector2(s * 0.08, -s * 0.3), Vector2(s * 0.18, s * 0.6)), col)


func _button(id: String, w: Dictionary, vs: Vector2, badge := "", enabled := true, highlight := false) -> void:
	var c := HudLayout.center(w, vs)
	var r := HudLayout.radius(w, vs)
	var o := float(w.o)
	var pressed := _pressed.has(id) or highlight
	var bg := Color(0, 0, 0, 0.38 * o)
	if pressed:
		bg = Color(1, 0.74, 0.16, 0.45 * o)
	draw_circle(c, r, bg)
	var ring_col := Color(1, 1, 1, 0.55 * o) if enabled else Color(1, 1, 1, 0.2 * o)
	if id.begins_with("fire"):
		ring_col = Color(1, 0.35, 0.25, 0.85 * o)
	_ring(c, r - 1.5, ring_col, 3.0)
	var icol := Color(1, 1, 1, (0.95 if enabled else 0.35) * o)
	_icon(id, c, r * 1.05, icol)
	if badge != "":
		var bc := c + Vector2(r * 0.68, -r * 0.68)
		draw_circle(bc, 13.0, Color(1, 0.74, 0.16, 0.95 * o) if enabled else Color(0.4, 0.4, 0.4, 0.8 * o))
		_text(badge, bc, 17, Color(0.1, 0.07, 0.02), HORIZONTAL_ALIGNMENT_CENTER, 0)
	if editor_mode:
		_text(HudLayout.LABELS.get(id, id), c + Vector2(0, r + 14), 16, Color(1, 1, 1, 0.85))
		if id == selected_id:
			_ring(c, r + 6.0, UI.ACCENT, 3.0)


func _weapons_widget(w: Dictionary, vs: Vector2) -> void:
	var slots := HudLayout.weapon_slots(w, vs)
	var o := float(w.o)
	for i in slots.size():
		var rect := slots[i]
		var sel := player != null and player.current == i
		draw_rect(rect, Color(0, 0, 0, (0.55 if sel else 0.35) * o))
		draw_rect(rect, Color(1, 0.74, 0.16, 0.95 * o) if sel else Color(1, 1, 1, 0.25 * o), false, 2.0 if sel else 1.0)
		if player == null or i >= player.weapons.size():
			continue
		var def: Dictionary = player.weapons[i].def
		var name_col := Color(1, 1, 1, 0.95 * o) if sel else Color(1, 1, 1, 0.6 * o)
		_text(String(def.name), rect.position + Vector2(rect.size.x * 0.5, rect.size.y * 0.32), 18, name_col, HORIZONTAL_ALIGNMENT_CENTER, 0)
		var ammo_txt := "%d / %d" % [int(def.mag), int(def.mag)]
		if player:
			var st: WeaponState = player.weapons[i]
			ammo_txt = "%d / %d" % [st.ammo, int(def.mag)]
			if st.reloading:
				var pr := st.reload_progress()
				draw_rect(Rect2(rect.position + Vector2(4, rect.size.y - 7), Vector2((rect.size.x - 8) * pr, 4)), Color(1, 0.74, 0.16, 0.95 * o))
				ammo_txt = "RELOADING"
		var ammo_col := Color(1, 0.85, 0.3, 0.95 * o) if sel else Color(1, 1, 1, 0.55 * o)
		_text(ammo_txt, rect.position + Vector2(rect.size.x * 0.5, rect.size.y * 0.7), 17, ammo_col, HORIZONTAL_ALIGNMENT_CENTER, 0, "semi")
	if editor_mode:
		var all := slots[0].merge(slots[2])
		_text("WEAPONS", all.get_center() - Vector2(0, all.size.y * 0.5 + 14), 16, Color(1, 1, 1, 0.85))
		if selected_id == "weapons":
			draw_rect(all.grow(6), UI.ACCENT, false, 3.0)


func _joystick(vs: Vector2) -> void:
	var w: Dictionary = layout.joystick
	var r := HudLayout.radius(w, vs)
	var o := float(w.o)
	var c := _joy_center if _joy_touch != -1 else HudLayout.center(w, vs)
	draw_circle(c, r, Color(0, 0, 0, 0.25 * o))
	_ring(c, r, Color(1, 1, 1, 0.4 * o), 3.0)
	for a in 4:
		var dir := Vector2.RIGHT.rotated(a * PI * 0.5)
		var tip := c + dir * (r - 14.0)
		draw_colored_polygon(PackedVector2Array([tip + dir * 8.0, tip - dir * 2.0 + dir.orthogonal() * 7.0, tip - dir * 2.0 - dir.orthogonal() * 7.0]), Color(1, 1, 1, 0.45 * o))
	var knob := c + _joy_vec * r * 0.62
	draw_circle(knob, r * 0.36, Color(1, 1, 1, 0.55 * o))
	_ring(knob, r * 0.36, Color(1, 1, 1, 0.8 * o), 2.0)
	if editor_mode:
		_text("MOVE", c + Vector2(0, r + 14), 16, Color(1, 1, 1, 0.85))
		if selected_id == "joystick":
			_ring(c, r + 6.0, UI.ACCENT, 3.0)


func draw_controls(vs: Vector2) -> void:
	for id: String in HudLayout.ORDER:
		if id == "joystick":
			_joystick(vs)
		elif id == "weapons":
			_weapons_widget(layout.weapons, vs)
		elif id == "fire_l" and int(Game.settings.left_fire) == 2 and not editor_mode:
			continue
		else:
			var badge := ""
			var enabled := true
			var hl := false
			if player:
				match id:
					"medkit":
						badge = str(player.medkits)
						enabled = player.medkits > 0
						hl = player.healing
					"shield":
						badge = str(player.shields)
						enabled = player.shields > 0
					"grenade":
						badge = str(player.grenades)
						enabled = player.grenades > 0
					"scope":
						hl = player.ads
					"crouch":
						hl = player.crouching
					"fire_r", "fire_l":
						hl = player.firing
			_button(id, layout[id], vs, badge, enabled, hl)


# ---------------------------------------------------------------- main draw

func _draw() -> void:
	var vs := size
	if editor_mode:
		draw_controls(vs)
		return
	if player == null:
		return
	var center := vs * 0.5
	# Damage flash / low health vignette.
	var low := clampf(1.0 - player.hp / (Fighter.MAX_HP * 0.35), 0.0, 1.0) if player.alive else 0.0
	var vig := maxf(_flash, low * (0.25 + 0.1 * sin(_time * 6.0)))
	if vig > 0.01:
		_vignette(vs, Color(0.9, 0.05, 0.05, vig))
	_draw_damage_dirs(center, vs)
	if player.alive and not match_over:
		_draw_crosshair(center, vs)
	_draw_damage_numbers()
	if not match_over:
		draw_controls(vs)
		_draw_status(vs)
	_draw_top(vs)
	_draw_minimap(vs)
	_draw_kill_feed(vs)
	_button_pause(vs)
	if _center_t > 0.0 and _center_text != "":
		var a := clampf(_center_t * 3.0, 0.0, 1.0)
		_text(_center_text, Vector2(center.x, vs.y * 0.33), _center_size, Color(_center_color, a), HORIZONTAL_ALIGNMENT_CENTER, 10, "title")
		if _center_sub != "":
			_text(_center_sub, Vector2(center.x, vs.y * 0.33 + _center_size * 0.62), 30, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_CENTER, 5)
	if tips_time > 0.0:
		var ta := clampf(tips_time, 0.0, 1.0)
		var tip_rect := Rect2(Vector2(center.x - 330, vs.y * 0.6), Vector2(660, 84))
		draw_rect(tip_rect, Color(0, 0, 0, 0.45 * ta))
		_text("LEFT: MOVE   ·   RIGHT SIDE: DRAG TO AIM", tip_rect.position + Vector2(330, 24), 20, Color(1, 1, 1, ta), HORIZONTAL_ALIGNMENT_CENTER, 3)
		_text("HOLD FIRE AND DRAG IT TO AIM WHILE SHOOTING", tip_rect.position + Vector2(330, 58), 20, Color(1, 0.85, 0.35, ta), HORIZONTAL_ALIGNMENT_CENTER, 3)
	if Game.settings.show_fps:
		_text("%d FPS" % roundi(_fps_smooth), Vector2(14, vs.y * 0.34), 18, Color(0.6, 1, 0.6), HORIZONTAL_ALIGNMENT_LEFT, 3)


func _vignette(vs: Vector2, col: Color) -> void:
	var clear := Color(col, 0.0)
	var t := vs.y * 0.22
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(vs.x, 0), Vector2(vs.x, t), Vector2(0, t)]), PackedColorArray([col, col, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, vs.y - t), Vector2(vs.x, vs.y - t), Vector2(vs.x, vs.y), Vector2(0, vs.y)]), PackedColorArray([clear, clear, col, col]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(t, 0), Vector2(t, vs.y), Vector2(0, vs.y)]), PackedColorArray([col, clear, clear, col]))
	draw_polygon(PackedVector2Array([Vector2(vs.x - t, 0), Vector2(vs.x, 0), Vector2(vs.x, vs.y), Vector2(vs.x - t, vs.y)]), PackedColorArray([clear, col, col, clear]))


func _draw_crosshair(c: Vector2, vs: Vector2) -> void:
	var col := Game.crosshair_color()
	var scale := lerpf(0.7, 1.4, float(Game.settings.crosshair_size) / 100.0)
	var dot := 3.2 * scale
	if player.ads:
		dot = 4.2 * scale
	draw_circle(c, dot + 1.6, Color(0, 0, 0, 0.6))
	draw_circle(c, dot, col)
	if Game.settings.dynamic_crosshair and not player.ads:
		var spread := deg_to_rad(player.current_spread())
		var fov := deg_to_rad(player.camera.fov) if player.camera else deg_to_rad(68.0)
		var px := tan(spread) / tan(fov * 0.5) * vs.y * 0.5
		var gap := clampf(px, 6.0, 120.0) * scale + 4.0
		var len := 9.0 * scale
		for a in 4:
			var dir := Vector2.RIGHT.rotated(a * PI * 0.5)
			draw_line(c + dir * gap, c + dir * (gap + len), Color(0, 0, 0, 0.55), 4.0)
			draw_line(c + dir * gap, c + dir * (gap + len), col, 2.0)
	if player.assist_target and Game.settings.aim_assist:
		_ring(c, 14.0 * scale, Color(col, 0.35), 1.5)
	if _hitmarker > 0.0:
		var hc := Color(1, 0.25, 0.2) if _hit_head else Color(1, 1, 1)
		hc.a = clampf(_hitmarker / 0.22, 0.0, 1.0)
		for a in 4:
			var dir := Vector2(1, 1).normalized().rotated(a * PI * 0.5)
			draw_line(c + dir * 9.0, c + dir * 19.0, hc, 3.0, true)
	if _kill_marker > 0.0:
		var ka := clampf(_kill_marker, 0.0, 1.0)
		_ring(c, 26.0 + (1.2 - _kill_marker) * 18.0, Color(1, 0.3, 0.2, ka), 3.0)
	var w := player.weapon()
	if w.reloading:
		_ring(c, 30.0, Color(1, 1, 1, 0.25), 4.0)
		_ring(c, 30.0, UI.ACCENT, 4.0, w.reload_progress())
		_text("RELOADING", c + Vector2(0, 52), 18, Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER, 3)
	elif player.healing:
		_ring(c, 34.0, Color(1, 1, 1, 0.25), 5.0)
		_ring(c, 34.0, UI.GOOD, 5.0, player.heal_progress())
		_text("HEALING", c + Vector2(0, 58), 18, UI.GOOD, HORIZONTAL_ALIGNMENT_CENTER, 3)
	elif w.ammo == 0:
		_text("NO AMMO - RELOAD", c + Vector2(0, 52), 18, UI.BAD, HORIZONTAL_ALIGNMENT_CENTER, 3)


func _draw_damage_numbers() -> void:
	if player.camera == null:
		return
	for n in _dmg_numbers:
		var p3: Vector3 = n.pos + Vector3.UP * n.t * 0.9
		if player.camera.is_position_behind(p3):
			continue
		var sp := player.camera.unproject_position(p3)
		var a := clampf(1.0 - (n.t - 0.5) / 0.35, 0.0, 1.0)
		var col := Color(1.0, 0.35, 0.2, a) if n.head else Color(1, 1, 1, a)
		var fsize := 34 if n.head else 26
		var pop := 1.0 + maxf(0.0, 0.15 - n.t) * 3.0
		_text(String(n.text), sp, int(fsize * pop), col, HORIZONTAL_ALIGNMENT_CENTER, 5, "number")


func _draw_damage_dirs(c: Vector2, vs: Vector2) -> void:
	if player.camera == null:
		return
	var fwd := -player.camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := player.camera.global_basis.x
	right.y = 0.0
	right = right.normalized()
	for d in _dmg_dirs:
		var to: Vector3 = d.pos - player.global_position
		to.y = 0.0
		if to.length() < 0.1:
			continue
		to = to.normalized()
		var ang := atan2(to.dot(right), to.dot(fwd))
		var a := clampf(float(d.t) / 1.4, 0.0, 1.0)
		var r := vs.y * 0.24
		var start := ang - PI * 0.5 - 0.32
		draw_arc(c, r, start, start + 0.64, 16, Color(1, 0.15, 0.1, 0.85 * a), 9.0, true)


func _draw_status(vs: Vector2) -> void:
	var w := 320.0
	var x := vs.x * 0.5 - w * 0.5
	var y := vs.y * (layout.weapons.y as float) - float(layout.weapons.s) * vs.y * 0.41 - 30.0
	var hp_frac := player.hp / Fighter.MAX_HP
	draw_rect(Rect2(x, y, w, 14), Color(0, 0, 0, 0.5))
	var hc := UI.GOOD if hp_frac > 0.5 else (Color(1, 0.8, 0.2) if hp_frac > 0.25 else UI.BAD)
	draw_rect(Rect2(x + 2, y + 2, (w - 4) * hp_frac, 10), hc)
	for i in range(1, 4):
		draw_line(Vector2(x + w * i / 4.0, y + 2), Vector2(x + w * i / 4.0, y + 12), Color(0, 0, 0, 0.5), 1.0)
	_text("%d" % roundi(player.hp), Vector2(x - 8, y + 7), 22, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 3, "number")
	_text("VEST II  ·  HELMET II", Vector2(x + w + 10, y + 7), 15, Color(0.75, 0.85, 1.0, 0.9), HORIZONTAL_ALIGNMENT_LEFT, 3, "semi")


func _draw_top(vs: Vector2) -> void:
	if arena == null:
		return
	var cx := vs.x * 0.5
	var box := Rect2(cx - 120, 10, 240, 58)
	draw_rect(box, Color(0, 0, 0, 0.45))
	draw_rect(Rect2(box.position, Vector2(box.size.x, 3)), UI.ACCENT)
	_text("LONE WOLF  ·  1 VS 1", Vector2(cx, 26), 15, Color(1, 1, 1, 0.8), HORIZONTAL_ALIGNMENT_CENTER, 0, "semi")
	var t := maxf(arena.time_left, 0.0)
	var tc := Color.WHITE if t > 30.0 else UI.BAD
	_text("%d:%02d" % [int(t) / 60, int(t) % 60], Vector2(cx, 50), 28, tc, HORIZONTAL_ALIGNMENT_CENTER, 0, "number")
	if arena.zone_shrinking and player.alive and not arena.in_zone(player.global_position):
		_text("OUTSIDE SAFE ZONE!", Vector2(cx, 92), 22, UI.BAD, HORIZONTAL_ALIGNMENT_CENTER, 4)
	elif arena.zone_warning != "":
		_text(arena.zone_warning, Vector2(cx, 92), 20, Color(1, 0.85, 0.3), HORIZONTAL_ALIGNMENT_CENTER, 4)
	if _enemy_hp_t > 0.0 and _enemy != null and is_instance_valid(_enemy):
		var a := clampf(_enemy_hp_t, 0.0, 1.0)
		var bw := 220.0
		var by := 112.0
		_text(_enemy.display_name, Vector2(cx, by), 18, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_CENTER, 3)
		draw_rect(Rect2(cx - bw * 0.5, by + 14, bw, 8), Color(0, 0, 0, 0.5 * a))
		draw_rect(Rect2(cx - bw * 0.5 + 1, by + 15, (bw - 2) * (_enemy.hp / Fighter.MAX_HP), 6), Color(1, 0.3, 0.25, a))


func _draw_minimap(vs: Vector2) -> void:
	if arena == null:
		return
	var r := vs.y * 0.125
	var c := Vector2(r + 18, r + 18)
	draw_circle(c, r, Color(0.05, 0.08, 0.1, 0.78))
	_ring(c, r, Color(1, 1, 1, 0.35), 2.0)
	var mr: Rect2 = arena.map_rect
	var half: float = maxf(mr.size.x, mr.size.y) * 0.5
	var k := (r - 6.0) / (half * 1.414)
	for rect: Rect2 in arena.obstacles:
		var p0 := c + rect.position * k
		draw_rect(Rect2(p0, rect.size * k), Color(0.75, 0.8, 0.85, 0.45))
	var sq := PackedVector2Array([c + Vector2(-half, -half) * k, c + Vector2(half, -half) * k, c + Vector2(half, half) * k, c + Vector2(-half, half) * k, c + Vector2(-half, -half) * k])
	draw_polyline(sq, Color(1, 1, 1, 0.5), 1.5)
	if arena.zone_radius < 200.0:
		var zc: Vector3 = arena.zone_center
		draw_arc(c + Vector2(zc.x, zc.z) * k, arena.zone_radius * k, 0, TAU, 48, Color(1, 1, 1, 0.8), 1.5, true)
	for f: Fighter in arena.fighters:
		if f == player or not f.alive:
			continue
		if _reveal.has(f) or (player.camera and not player.camera.is_position_behind(f.chest_position()) and player.can_see(f.chest_position())):
			draw_circle(c + Vector2(f.global_position.x, f.global_position.z) * k, 5.0, UI.BAD)
	var pp := c + Vector2(player.global_position.x, player.global_position.z) * k
	var dir := Vector2(-sin(player.aim_yaw), -cos(player.aim_yaw))
	var side := dir.orthogonal()
	draw_colored_polygon(PackedVector2Array([pp + dir * 9.0, pp - dir * 5.0 + side * 6.0, pp - dir * 2.0, pp - dir * 5.0 - side * 6.0]), UI.ACCENT)


func _draw_kill_feed(vs: Vector2) -> void:
	var y := 96.0
	for k in _kill_feed:
		var a := clampf(float(k.t), 0.0, 1.0)
		var col: Color = k.color
		col.a = a
		_text(String(k.text), Vector2(vs.x - 18, y), 18, col, HORIZONTAL_ALIGNMENT_RIGHT, 4)
		y += 26.0


func _button_pause(vs: Vector2) -> void:
	var r := _pause_rect()
	var c := r.get_center()
	draw_circle(c, 24.0, Color(0, 0, 0, 0.4))
	_ring(c, 24.0, Color(1, 1, 1, 0.4), 2.0)
	_icon("pause", c, 30.0, Color(1, 1, 1, 0.9))
