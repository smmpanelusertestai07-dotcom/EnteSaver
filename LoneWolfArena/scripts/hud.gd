class_name HUD
extends Control
## In-match HUD of the Lone Wolf duel, laid out like the reference mobile shooters (positions
## from HudLayout, editable in the HUD editor). Everything is drawn in _draw (cheap on phones,
## icon textures loaded once):
##  - multi-touch controls: floating joystick (sprint by pushing past the ring) + sprint button,
##    look area, right / left FIRE (drag to aim while firing), scope, jump, crouch, prone,
##    reload, medkit, wall, grenade, settings (pause) and scoreboard buttons, the weapon panel;
##  - crosshair: spread ring / wide ring / dot by gun, red on target, red dot when aiming, full
##    sniper scope, reload and heal progress rings;
##  - feedback: damage numbers, hit marker, headshot icon, the elimination X and badge, damage
##    direction arcs, low-HP pulse;
##  - match info: duel score bar with timer, prep countdown, round banner, minimap (hud_minimap.gd)
##    with the safe-zone strip, HP block, kill feed; weapon pick + scoreboard (hud_panels.gd).

signal pause_pressed

const BUTTONS := ["fire_r", "fire_l", "scope", "jump", "crouch", "prone", "sprint", "reload", "medkit", "wall",
	"grenade", "settings", "scoreboard"]
const GLYPHS := {
	"fire_r": "v_fire", "fire_l": "v_fire", "scope": "v_scope", "jump": "stance_jump", "crouch": "stance_crouch",
	"prone": "stance_prone", "sprint": "stance_sprint", "reload": "v_reload", "medkit": "v_medkit", "wall": "v_wall",
	"grenade": "item_grenade", "settings": "v_settings", "scoreboard": "v_scoreboard",
}
const GLYPH_FALLBACK := {"prone": "v_prone", "sprint": "v_sprint", "jump": "v_chevron"}
const GLYPH_SCALE := {
	"fire_r": 0.54, "fire_l": 0.56, "scope": 0.58, "jump": 0.72, "crouch": 0.72, "prone": 0.84, "sprint": 0.72,
	"reload": 0.56, "medkit": 0.52, "wall": 0.54, "grenade": 0.62, "settings": 0.56, "scoreboard": 0.5,
}
const EXTRA_ICONS := ["v_fist", "v_mag", "v_headshot", "v_helmet", "v_vest", "v_zone", "badge_elim", "v_tick",
	"weapon_ar", "weapon_smg", "weapon_sg", "weapon_sg_lever", "weapon_pistol", "weapon_sniper", "v_skull"]
const SHORT_LABELS := {"settings": "MENU", "scoreboard": "SCORES"}
const DMG_LIFE := 0.95
const DMG_MERGE := 0.32            # hits on the same target within this much GAME time add up into one number
const FEED_LIFE := 6.0
const ROUND_BANNER_TIME := 1.9
const KILL_BANNER_TIME := 2.8
const KILL_X_TIME := 0.9
const SPRINT_PUSH := 1.12          # joystick deflection (in ring radii) that counts as past the ring
const SPRINT_HOLD := 0.3           # seconds past the ring before the sprint locks
const JOY_ZONE_X := 0.4            # floating joystick: the left 40 % of the screen
const FEED_Y := [0.853, 0.81, 0.767]

var player: Player
var arena: Node
var layout := {}
var editor_mode := false
var selected_id := ""
var match_over := false
var tips_time := 0.0
var minimap: HudMinimap
var panels: HudPanels
var seen := {}                     # fighter -> in sight (refreshed 10x per second)

var _touches := {}                 # touch index -> {"kind": joy|look|fire|ui, "id": String}
var _joy_touch := -1
var _joy_center := Vector2.ZERO
var _joy_vec := Vector2.ZERO       # finger offset in ring radii (can exceed 1)
var _joy_out_t := 0.0
var _sprint_lock := false          # run mode drag / mixed: pushed past the ring
var _auto_sprint := false          # run mode tap / mixed: sprint button
var _sprint_wanted := false
var _pressed := {}                 # widget id -> seconds of press highlight
var _held := {}                    # fire buttons held down
var _hit_t := 0.0
var _hit_head := false
var _head_icon_t := 0.0
var _kill_x_t := 0.0
var _kill_x_pos := Vector3.ZERO
var _dmg_numbers: Array = []
var _dmg_dirs: Array = []
var _kill_feed: Array = []
var _flash := 0.0
var _zone_hurt := 0.0
var _hurt_sound_t := 0.0
var _center := {"text": "", "sub": "", "t": 0.0, "dur": 1.0, "col": Color.WHITE, "size": 96}
var _round_banner := {"t": 0.0, "round": 1, "area": ""}
var _kill_banner := {"t": 0.0, "name": "", "head": false}
var _reveal := {}
var _vis_t := 0.0
var _hp_lag := Fighter.MAX_HP
var _hp_last := Fighter.MAX_HP
var _lag_hold := 0.0
var _fps_smooth := 60.0
var _time := 0.0
var _lens_tex: Texture2D
var _ui_marked := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if layout.is_empty():
		reload_layout()
	HudDraw.preload_icons(GLYPHS.values() + GLYPH_FALLBACK.values() + EXTRA_ICONS)
	minimap = HudMinimap.new()
	minimap.name = "Minimap"
	minimap.hud = self
	add_child(minimap)
	panels = HudPanels.new()
	panels.name = "Panels"
	panels.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panels.visible = false
	add_child(panels)
	_lens_tex = _make_lens_texture()
	resized.connect(func() -> void: _place_minimap(size))
	_place_minimap(size)


func reload_layout() -> void:
	layout = HudLayout.current()
	if minimap != null:
		_place_minimap(size)


func bind(p: Player, a: Node) -> void:
	player = p
	arena = a
	panels.arena = a
	player.hit_landed.connect(_on_hit_landed)
	player.damaged.connect(_on_damaged)
	_hp_lag = player.hp
	_hp_last = player.hp


# ---------------------------------------------------------------- arena -> HUD API

func show_center(text: String, seconds: float, color := Color.WHITE, fsize := 96, sub := "") -> void:
	# During the prep the HUD draws its own block (weapon pick, then PREPARE + red countdown +
	# the match-up), so the arena's intro and countdown digits are not repeated on top of it.
	if arena != null and int(arena.get("phase")) == 0:
		return
	_center = {"text": text, "sub": sub, "t": seconds, "dur": maxf(seconds, 0.01), "col": color, "size": fsize}


func show_round_banner(round_index: int, area: String) -> void:
	_round_banner = {"t": ROUND_BANNER_TIME, "round": round_index, "area": area}


func open_weapon_pick(options: Array, preselect: String, seconds: float, on_pick: Callable) -> void:
	var r := 1
	if arena != null:
		r = int(arena.get("round_index"))
	panels.open_pick(options, preselect, seconds, on_pick, r)


func close_weapon_pick() -> void:
	panels.close_pick()


func add_kill_feed(killer: String, victim: String, weapon_name: String, weapon_icon: String, headshot: bool, mine: bool) -> void:
	_kill_feed.push_front({"killer": killer, "victim": victim, "weapon": weapon_name, "icon": weapon_icon,
		"head": headshot, "mine": mine, "t": FEED_LIFE})
	if _kill_feed.size() > 3:
		_kill_feed.pop_back()


## Big elimination feedback when the player takes someone out: a red X on them and the badge.
func kill_banner(victim_name: String, headshot: bool) -> void:
	_kill_banner = {"t": KILL_BANNER_TIME, "name": victim_name, "head": headshot}
	if arena != null:
		for f: Fighter in arena.get("fighters"):
			if f.display_name == victim_name:
				_kill_x_pos = f.chest_position()
				_kill_x_t = KILL_X_TIME


func reveal(f: Fighter, seconds := 2.5) -> void:
	_reveal[f] = maxf(float(_reveal.get(f, 0.0)), seconds)


func release_all() -> void:
	tips_time = 0.0
	_touches.clear()
	_held.clear()
	_joy_touch = -1
	_joy_vec = Vector2.ZERO
	_joy_out_t = 0.0
	_sprint_lock = false
	_auto_sprint = false
	if player:
		player.cancel_input()
		player.move_dir = Vector2.ZERO
		if _sprint_wanted:
			player.set_sprint(false)
	_sprint_wanted = false


# ---------------------------------------------------------------- hit feedback

func _on_hit_landed(target: Fighter, amount: float, headshot: bool, pos: Vector3, killed: bool) -> void:
	_hit_t = 0.22
	_hit_head = headshot
	if headshot:
		_head_icon_t = 0.7
	if Game.settings.damage_numbers:
		_add_damage_number(target, amount, headshot, pos)
	Audio.play("hit_head" if headshot else "hit_body", -2.0 if headshot else -6.0)
	if killed:
		_kill_x_pos = pos if target == null else target.chest_position()
		_kill_x_t = KILL_X_TIME
		Audio.play("kill_confirm", 0.0)
		Game.vibrate(60)


## Rapid hits on the same target (automatic fire, shotgun pellets) add up into one number that
## grows and pops at each hit, like the reference; body and head damage keep separate numbers.
## The merge window is GAME time (physics ticks), so it follows the fire rate at any frame rate.
## A new number is placed beside the ones still showing (a row like the reference's "22 22 22",
## then a row above), never on top of them; every number then rises at the same speed, so the
## row keeps its shape.
func _add_damage_number(target: Fighter, amount: float, headshot: bool, pos: Vector3) -> void:
	var tick := Engine.get_physics_frames()
	var merge_ticks := roundi(DMG_MERGE * Engine.physics_ticks_per_second)
	for i in range(_dmg_numbers.size() - 1, -1, -1):
		var n: Dictionary = _dmg_numbers[i]
		if n.target == target and bool(n.head) == headshot and tick - int(n.tick) <= merge_ticks:
			n.amount = float(n.amount) + amount
			n.tick = tick
			n.hits = int(n.hits) + 1
			n.t = minf(float(n.t), 0.15)
			n.bump = 0.14
			return
	# tick0 / tick: physics frame of the first / latest hit in this number, hits: how many
	var nn := {"pos": pos + Vector3(0, 0.2, 0), "amount": amount, "head": headshot, "t": 0.0, "tick0": tick, "tick": tick,
		"hits": 1, "bump": 0.0, "target": target, "off": Vector2.ZERO}
	nn.off = _dmg_free_offset(nn)
	_dmg_numbers.append(nn)
	if _dmg_numbers.size() > 8:
		_dmg_numbers.pop_front()


## Font size of a damage number: grows a little with the damage, headshots larger.
func _dmg_size(amount: float, head: bool, u: float) -> int:
	return int(clampf(0.044 * u + amount * 0.09, 0.044 * u, 0.085 * u) * (1.25 if head else 1.0))


## Screen centre of a damage number now: its hit point (rising) plus its place in the row.
func _dmg_point(n: Dictionary, u: float) -> Vector2:
	var t := float(n.t)
	var p3: Vector3 = n.pos + Vector3.UP * t * 0.55
	return player.camera.unproject_position(p3) + (n.off as Vector2) * u + Vector2(0, -t * 0.03 * u)


## Screen rect of a damage number now; min_digits keeps room for a number that may still grow.
func _dmg_rect(n: Dictionary, u: float, min_digits := 1) -> Rect2:
	var fs := _dmg_size(float(n.amount), bool(n.head), u)
	var txt := str(maxi(roundi(float(n.amount)), 1)).lpad(min_digits, "8")
	var w := UI.font("number").get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var c := _dmg_point(n, u)
	return Rect2(c - Vector2(w * 0.5 + 0.004 * u, fs * 0.42), Vector2(w + 0.008 * u, fs * 0.84))


## Row offset (in HUD units) that keeps a new damage number clear of the ones still showing.
func _dmg_free_offset(n: Dictionary) -> Vector2:
	var u := HudLayout.unit(size)
	if player == null or player.camera == null or u <= 0.0 or player.camera.is_position_behind(n.pos):
		return Vector2.ZERO
	var taken: Array[Rect2] = []
	for o: Dictionary in _dmg_numbers:
		if float(o.t) < DMG_LIFE - 0.15 and not player.camera.is_position_behind(o.pos):
			taken.append(_dmg_rect(o, u, 3))
	var base := _dmg_rect(n, u, 3)
	var off := Vector2.ZERO
	for attempt in 8:
		var r := Rect2(base.position + off * u, base.size)
		var hit := false
		for other in taken:
			if other.intersects(r):
				# step to the right of the number in the way; far from the hit, start a row above
				off.x = (other.end.x - base.position.x) / u + 0.006
				if off.x > 0.2:
					off = Vector2(0.0, (other.position.y - base.end.y) / u - 0.004)
				hit = true
				break
		if not hit:
			break
	return off


func _on_damaged(amount: float, from_pos: Vector3, _headshot: bool, attacker: Fighter) -> void:
	if attacker == null:
		# Zone (or a fall): a soft edge glow instead of a hit flash every frame.
		_zone_hurt = 0.6
		if _hurt_sound_t <= 0.0:
			_hurt_sound_t = 0.8
			Audio.play("hurt", -10.0, randf_range(0.95, 1.05))
		return
	_flash = minf(_flash + 0.22 + amount / 140.0, 0.6)
	_dmg_dirs.append({"pos": from_pos, "t": 1.4})
	if _dmg_dirs.size() > 4:
		_dmg_dirs.pop_front()
	if _hurt_sound_t <= 0.0:
		_hurt_sound_t = 0.12
		Audio.play("hurt", -6.0, randf_range(0.95, 1.05))
	Game.vibrate(35)


# ---------------------------------------------------------------- touch input

func _input(event: InputEvent) -> void:
	if editor_mode or player == null:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_on_down(t.index, t.position)
		else:
			_on_up(t.index, t.canceled)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_on_drag(d.index, d.position, d.relative)


func _on_down(index: int, pos: Vector2) -> void:
	var vs := size
	if panels.visible and panels.tap(pos):
		_touches[index] = {"kind": "ui", "id": "panel"}
		return
	if match_over:
		_touches[index] = {"kind": "ui", "id": ""}
		return
	if score_rect().has_point(pos):
		_toggle_scoreboard()
		_touches[index] = {"kind": "ui", "id": "score"}
		return
	var id := _widget_at(pos, vs)
	if id != "":
		_press(id, index)
		return
	if _joy_touch == -1 and _in_joy_zone(pos, vs):
		_start_joystick(index, pos, vs)
		return
	_touches[index] = {"kind": "look", "id": ""}


## Topmost control under the finger ("" = none). Overlapping buttons: the closest centre wins.
func _widget_at(pos: Vector2, vs: Vector2) -> String:
	var best := ""
	var best_d := INF
	for id: String in HudLayout.ORDER:
		if id == "joystick" or id == "minimap" or not _button_visible(id):
			continue
		var w: Dictionary = layout[id]
		if id == "weapons":
			if HudLayout.weapon_main(w, vs).grow(4).has_point(pos):
				return "weapons:main"
			var slots := HudLayout.weapon_slots(w, vs)
			for i in [0, 2]:
				if slots[i].grow(4).has_point(pos):
					return "weapons:%d" % i
			continue
		var r := HudLayout.touch_radius(w, vs)
		var d := pos.distance_to(HudLayout.center(w, vs)) / maxf(r, 1.0)
		if d <= 1.15 and d < best_d:
			best = id
			best_d = d
	return best


func _button_visible(id: String) -> bool:
	if editor_mode:
		return true
	match id:
		"fire_l":
			var lf := int(Game.settings.get("left_fire", 0))
			return lf == 0 or (lf == 1 and player != null and player.ads)
		"sprint":
			return int(Game.settings.get("run_mode", 2)) != 1
	return true


func _press(id: String, index: int) -> void:
	_pressed[id] = 0.16
	_touches[index] = {"kind": "ui", "id": id}
	match id:
		"fire_r", "fire_l":
			_touches[index] = {"kind": "fire", "id": id}
			_held[id] = true
			_cancel_auto_sprint()
			player.set_firing(true)
		"scope":
			_cancel_auto_sprint()
			player.toggle_ads()
		"jump":
			player.do_jump()
		"crouch":
			_cancel_auto_sprint()
			player.toggle_crouch()
		"prone":
			_cancel_auto_sprint()
			player.toggle_prone()
		"sprint":
			_toggle_auto_sprint()
		"reload":
			player.do_reload()
		"medkit":
			_cancel_auto_sprint()
			player.use_medkit()
		"wall":
			player.use_shield()
		"grenade":
			player.use_grenade()
		"settings":
			release_all()
			pause_pressed.emit()
		"scoreboard":
			_toggle_scoreboard()
		"weapons:main":
			if player.current == 0:
				player.do_reload()
			else:
				player.select_weapon(0)
		"weapons:0":
			player.select_weapon(0)
		"weapons:2":
			player.select_weapon(1)


func _on_drag(index: int, pos: Vector2, rel: Vector2) -> void:
	if not _touches.has(index):
		return
	match String(_touches[index].kind):
		"joy":
			var jr := _joy_radius(size)
			_joy_vec = (pos - _joy_center) / jr
			# Floating stick: the base follows a finger that runs far past the ring.
			if bool(Game.settings.get("dynamic_joystick", true)) and _joy_vec.length() > 1.6:
				_joy_center = pos - _joy_vec.normalized() * jr * 1.6
				_joy_vec = (pos - _joy_center) / jr
		"look":
			player.add_look(rel, false)
		"fire":
			player.add_look(rel, true)


## canceled: the system took the touch away (app switch, notification shade), so a held FIRE
## lets go without the release shooting (a held sniper scope closes).
func _on_up(index: int, canceled := false) -> void:
	if not _touches.has(index):
		return
	var t: Dictionary = _touches[index]
	_touches.erase(index)
	match String(t.kind):
		"joy":
			_joy_touch = -1
			_joy_vec = Vector2.ZERO
			_joy_out_t = 0.0
			_sprint_lock = false
		"fire":
			_held.erase(String(t.id))
			var still := false
			for k in _touches:
				if String(_touches[k].kind) == "fire":
					still = true
			if not still:
				if canceled:
					player.cancel_input()
				else:
					player.set_firing(false)


func _in_joy_zone(pos: Vector2, vs: Vector2) -> bool:
	var w: Dictionary = layout.joystick
	if bool(Game.settings.get("dynamic_joystick", true)):
		return pos.x < vs.x * JOY_ZONE_X and pos.y > vs.y * 0.34
	return pos.distance_to(HudLayout.center(w, vs)) < HudLayout.radius(w, vs) * 1.4


func _joy_radius(vs: Vector2) -> float:
	return HudLayout.radius(layout.joystick, vs)


func _start_joystick(index: int, pos: Vector2, vs: Vector2) -> void:
	var r := _joy_radius(vs)
	_joy_touch = index
	if bool(Game.settings.get("dynamic_joystick", true)):
		_joy_center = Vector2(clampf(pos.x, r + 6.0, maxf(vs.x * JOY_ZONE_X, r + 6.0)), clampf(pos.y, vs.y * 0.34 + r * 0.4, vs.y - r - 6.0))
	else:
		_joy_center = HudLayout.center(layout.joystick, vs)
	_joy_vec = (pos - _joy_center) / r
	_joy_out_t = 0.0
	_touches[index] = {"kind": "joy", "id": "joystick"}
	if _auto_sprint and Vector2(_joy_vec.x, -_joy_vec.y).y < 0.3:
		_cancel_auto_sprint()


func _toggle_auto_sprint() -> void:
	if _auto_sprint:
		_cancel_auto_sprint()
		return
	if not player.alive:
		return
	if player.stance == Fighter.Stance.CROUCH:
		player.toggle_crouch()
	elif player.stance == Fighter.Stance.PRONE:
		player.toggle_prone()
	if player.ads:
		player.toggle_ads()
	_auto_sprint = true


func _cancel_auto_sprint() -> void:
	_auto_sprint = false


func _toggle_scoreboard() -> void:
	if panels.board_open:
		panels.close_board()
	else:
		panels.avoid = _board_avoid()
		panels.open_board()


## Widgets the scoreboard keeps clear of: the minimap (with its zone strip) and the weapon panel.
func _board_avoid() -> Array[Rect2]:
	var mr := HudLayout.minimap_rect(layout.minimap, size)
	mr.size.y += mr.size.x * HudLayout.STRIP_H + 2.0
	var wp := HudLayout.weapon_main(layout.weapons, size).merge(HudLayout.weapon_slots(layout.weapons, size)[2])
	var out: Array[Rect2] = [mr, wp]
	return out


# ---------------------------------------------------------------- tick

func _process(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.01)
	_time += real
	if editor_mode:
		_place_minimap(size)
		queue_redraw()
		minimap.queue_redraw()
		return
	if player != null:
		_update_movement(delta)
		if player.hp < _hp_last:
			_lag_hold = 0.35
		_hp_last = player.hp
		_lag_hold = maxf(_lag_hold - real, 0.0)
		if _hp_lag <= player.hp:
			_hp_lag = player.hp
		elif _lag_hold <= 0.0:
			_hp_lag = maxf(player.hp, _hp_lag - Fighter.MAX_HP * 0.6 * real)
	for k in _pressed.keys():
		_pressed[k] -= real
		if _pressed[k] <= 0.0:
			_pressed.erase(k)
	_hit_t = maxf(_hit_t - real, 0.0)
	_head_icon_t = maxf(_head_icon_t - real, 0.0)
	_kill_x_t = maxf(_kill_x_t - real, 0.0)
	_flash = maxf(_flash - real * 1.1, 0.0)
	_zone_hurt = maxf(_zone_hurt - real, 0.0)
	_hurt_sound_t = maxf(_hurt_sound_t - real, 0.0)
	_center.t = maxf(float(_center.t) - real, 0.0)
	_round_banner.t = maxf(float(_round_banner.t) - real, 0.0)
	_kill_banner.t = maxf(float(_kill_banner.t) - real, 0.0)
	tips_time = maxf(tips_time - real, 0.0)
	for n in _dmg_numbers:
		n.t += real
		n.bump = maxf(float(n.bump) - real, 0.0)
	_dmg_numbers = _dmg_numbers.filter(func(n: Dictionary) -> bool: return float(n.t) < DMG_LIFE)
	for d in _dmg_dirs:
		d.t -= real
	_dmg_dirs = _dmg_dirs.filter(func(d: Dictionary) -> bool: return float(d.t) > 0.0)
	for k in _kill_feed:
		k.t -= real
	_kill_feed = _kill_feed.filter(func(k: Dictionary) -> bool: return float(k.t) > 0.0)
	for f in _reveal.keys():
		_reveal[f] -= delta
		if _reveal[f] <= 0.0:
			_reveal.erase(f)
	_vis_t -= real
	if _vis_t <= 0.0:
		_vis_t = 0.1
		_update_seen()
	if real > 0.0:
		_fps_smooth = lerpf(_fps_smooth, 1.0 / real, 0.05)
	panels.tick(delta, real)
	if panels.board_open:
		panels.avoid = _board_avoid()
	_place_minimap(size)
	if not _ui_marked and player != null and size.y >= 240.0:
		# Where FIRE and the joystick are on screen, for the on-device CI test (logged once).
		_ui_marked = true
		Game.mark_ui("fire", self, HudLayout.center(layout.fire_r, size))
		Game.mark_ui("joystick", self, HudLayout.center(layout.joystick, size))
	queue_redraw()
	minimap.queue_redraw()


func _update_movement(delta: float) -> void:
	if match_over or not player.alive:
		player.move_dir = Vector2.ZERO
		_auto_sprint = false
		_sprint_lock = false
		_apply_sprint(false)
		return
	var m := Vector2.ZERO
	if _joy_touch != -1:
		var v := _joy_vec.limit_length(1.0)
		if v.length() > 0.12:
			m = Vector2(v.x, -v.y)
	var run_mode := int(Game.settings.get("run_mode", 2))
	if _joy_touch != -1 and run_mode != 0:
		var push := _joy_vec.length()
		var forward := -_joy_vec.y > push * 0.6
		_joy_out_t = _joy_out_t + delta if (push > SPRINT_PUSH and forward) else 0.0
		if _joy_out_t >= SPRINT_HOLD:
			_sprint_lock = true
		if _sprint_lock and (push < 0.85 or not forward):
			_sprint_lock = false
	else:
		_sprint_lock = false
		_joy_out_t = 0.0
	if _auto_sprint:
		if player.ads or player.healing or player.firing or player.stance != Fighter.Stance.STAND:
			_auto_sprint = false
		elif m == Vector2.ZERO:
			m = Vector2(0, 1)
		elif m.y < 0.3:
			_auto_sprint = false
	player.move_dir = m
	_apply_sprint((_sprint_lock or _auto_sprint) and m.y > 0.3)


func _apply_sprint(want: bool) -> void:
	if want:
		player.set_sprint(true)
	elif _sprint_wanted:
		player.set_sprint(false)
	_sprint_wanted = want


func _update_seen() -> void:
	if arena == null or player == null or player.camera == null:
		return
	for f: Fighter in arena.get("fighters"):
		if f == player:
			continue
		var p := f.chest_position()
		seen[f] = f.alive and not player.camera.is_position_behind(p) and player.can_see(p)


func _place_minimap(vs: Vector2) -> void:
	if minimap == null or not layout.has("minimap"):
		return
	var w: Dictionary = layout.minimap
	var r := HudLayout.minimap_rect(w, vs)
	minimap.position = r.position
	minimap.size = r.size
	minimap.opacity = float(w.o)


## Area of the duel score bar at the top (tap = scoreboard).
func score_rect() -> Rect2:
	var u := HudLayout.unit(size)
	return Rect2(Vector2(size.x * 0.5 - 0.33 * u, 0.0), Vector2(0.66 * u, 0.09 * u))


# ---------------------------------------------------------------- drawing

func _glyph(id: String) -> Texture2D:
	return HudDraw.tex(String(GLYPHS.get(id, "")), String(GLYPH_FALLBACK.get(id, "")))


func _draw() -> void:
	var vs := size
	var u := HudLayout.unit(vs)
	var c := vs * 0.5
	if editor_mode:
		_draw_editor(vs, u)
		return
	if player == null:
		return
	var alive := player.alive and not match_over
	var scoped := alive and player.is_scoped()
	_draw_vignette(vs)
	if scoped:
		_draw_scope(c, vs)
	_draw_damage_dirs(c, u)
	if alive:
		if not scoped:
			_draw_crosshair(c, u)
		_draw_heal(c, u)
	_draw_kill_x(u)
	_draw_damage_numbers(u)
	if not match_over:
		_draw_controls(vs)
		_draw_weapon_panel(vs)
	_draw_hp_block(vs, u)
	_draw_kill_feed(vs, u)
	_draw_score_bar(vs, u)
	_draw_zone_strip(vs)
	_draw_zone_banner(vs, u)
	_draw_prep(vs, u)
	_draw_round_banner(vs, u)
	_draw_kill_banner(vs, u)
	_draw_center_text(vs, u)
	_draw_tips(vs, u)
	if Game.settings.show_fps:
		var mr := HudLayout.minimap_rect(layout.minimap, vs)
		HudDraw.text(self, "%d FPS" % roundi(_fps_smooth), Vector2(mr.position.x, mr.end.y + mr.size.x * HudLayout.STRIP_H + 0.035 * u),
			int(0.026 * u), Color(0.6, 1, 0.6), 0, 3, "bold")


# ---------------------------------------------------------------- controls

func _draw_controls(vs: Vector2) -> void:
	_draw_joystick(vs)
	for id: String in BUTTONS:
		if _button_visible(id):
			_draw_button(id, vs)


func _draw_button(id: String, vs: Vector2) -> void:
	var w: Dictionary = layout[id]
	var c := HudLayout.center(w, vs)
	var r := HudLayout.radius(w, vs)
	var o := float(w.o)
	var pressed := _pressed.has(id) or _held.has(id)
	var act := false
	var en := true
	var count := -1
	if player != null and not editor_mode:
		var ws := player.weapon()
		match id:
			"fire_r", "fire_l":
				en = not player.hold_fire
			"scope":
				act = player.ads
				en = not Weapons.is_melee(ws.def)
			"crouch":
				act = player.stance == Fighter.Stance.CROUCH
			"prone":
				act = player.stance == Fighter.Stance.PRONE
			"sprint":
				act = player.sprinting or _auto_sprint or _sprint_lock
			"reload":
				act = ws.reloading
				en = ws.can_reload() or ws.reloading
			"medkit":
				count = player.medkits
				act = player.healing
				en = player.medkits > 0
			"wall":
				count = player.shields
				en = player.shields > 0
			"grenade":
				count = player.grenades
				en = player.grenades > 0
	elif editor_mode:
		match id:
			"medkit", "wall":
				count = 2
			"grenade":
				count = 1
	if id == "settings":
		HudDraw.glyph_button(self, c, r, _glyph(id), o, pressed)
		return
	var glyph := _glyph(id)
	if (id == "fire_r" or id == "fire_l") and player != null and not editor_mode and Weapons.is_melee(player.weapon().def):
		glyph = HudDraw.tex("v_fist")       # fists out: the fire buttons punch
	if id == "fire_r":
		_draw_fire_halo(c, r, o, pressed)
	HudDraw.button(self, c, r, glyph, o, pressed, act, en, float(GLYPH_SCALE.get(id, 0.6)))
	if count >= 0:
		HudDraw.count_badge(self, c, r, count, o)
	if id == "medkit" and act and player != null:
		HudDraw.ring(self, c, r + 2.0, Color(HudDraw.GOLD, 0.95 * o), 3.0, player.heal_progress())
	if id == "reload" and act and player != null:
		HudDraw.ring(self, c, r + 2.0, Color(1, 1, 1, 0.9 * o), 3.0, player.weapon().reload_progress())


## The main fire button's outer dotted ring (reference look), warm while firing.
func _draw_fire_halo(c: Vector2, r: float, o: float, pressed: bool) -> void:
	var rr := r * 1.17
	var col := Color(1.0, 0.55, 0.3, 0.7 * o) if pressed else Color(1, 1, 1, 0.22 * o)
	var n := 30
	for i in n:
		var a0 := TAU * i / n
		draw_arc(c, rr, a0, a0 + TAU / n * 0.45, 3, col, 2.0, true)


func _draw_joystick(vs: Vector2) -> void:
	var w: Dictionary = layout.joystick
	var r := HudLayout.radius(w, vs)
	var o := float(w.o)
	var touching := _joy_touch != -1 and not editor_mode
	var c := _joy_center if touching else HudLayout.center(w, vs)
	var a := o * (1.0 if touching else 0.8)
	HudDraw.disk(self, c, r, Color(1, 1, 1, 0.07 * a))
	HudDraw.ring(self, c, r, Color(1, 1, 1, 0.34 * a), 2.0)
	HudDraw.ring(self, c, r * 0.64, Color(1, 1, 1, 0.07 * a), 1.0)
	for k in 4:
		var d := Vector2.UP.rotated(k * PI * 0.5)
		var tip := c + d * r * 0.86
		var side := d.orthogonal() * r * 0.07
		draw_polyline(PackedVector2Array([tip - d * r * 0.07 + side, tip, tip - d * r * 0.07 - side]), Color(1, 1, 1, 0.5 * a), 2.0, true)
	var kv := _joy_vec.limit_length(1.0) if touching else Vector2.ZERO
	var kp := c + kv * r * 0.62
	HudDraw.disk(self, kp, r * 0.36, Color(0.86, 0.87, 0.9, 0.72 * a))
	HudDraw.ring(self, kp, r * 0.36, Color(1, 1, 1, 0.85 * a), 1.5)
	# Sprint lock cue above the ring (drag / mixed run mode).
	if touching and int(Game.settings.get("run_mode", 2)) != 0 and player != null:
		var lc := c + Vector2(0, -r * 1.32)
		var prog := clampf(_joy_out_t / SPRINT_HOLD, 0.0, 1.0)
		if _sprint_lock or prog > 0.0:
			var col := HudDraw.GOLD if _sprint_lock else Color(1, 1, 1, 0.8)
			HudDraw.disk(self, lc, r * 0.24, Color(0, 0, 0, 0.45 * a))
			HudDraw.ring(self, lc, r * 0.24, Color(col, a), 2.0, 1.0 if _sprint_lock else prog)
			HudDraw.icon(self, _glyph("sprint"), lc, Vector2(r, r) * 0.32, Color(col, a))


# ---------------------------------------------------------------- weapon panel

func _draw_weapon_panel(vs: Vector2) -> void:
	var w: Dictionary = layout.weapons
	var o := float(w.o)
	var s := HudLayout.size_px(w, vs)
	var main := HudLayout.weapon_main(w, vs)
	var slots := HudLayout.weapon_slots(w, vs)
	var def: Dictionary = Weapons.DEFS[Weapons.DEFAULT_PICK]
	var ammo := int(def.mag)
	var reserve := int(def.reserve)
	var reloading := false
	var progress := 0.0
	var gun_sel := true
	if player != null and not editor_mode:
		var g: WeaponState = player.weapons[0]
		def = g.def
		ammo = g.ammo
		reserve = g.reserve
		reloading = g.reloading
		progress = g.reload_progress()
		gun_sel = player.current == 0
	var dim := 1.0 if gun_sel else 0.55
	var pressed := _pressed.has("weapons:main")
	# Near-black slots at ~70 % (the reference), the main one with its top-right corner cut.
	HudDraw.slot_rect(self, main, s * 0.2, Color(HudDraw.SLOT_BG, (0.86 if pressed else 0.76) * o))
	HudDraw.vband(self, Rect2(main.position, Vector2(main.size.x - s * 0.2, main.size.y * 0.4)), Color(1, 1, 1, 0.05 * o), Color(1, 1, 1, 0.0))
	# Ammo: big magazine number + small "/reserve".
	var ax := main.position.x + s * 0.16
	var ay := main.position.y + s * 0.38
	var mag_col := Color(1, 1, 1, 0.98 * dim * o) if ammo > 0 else Color(1.0, 0.36, 0.3, o)
	var aw := HudDraw.text(self, str(ammo), Vector2(ax, ay), int(s * 0.56), mag_col, 0, 2, "number")
	HudDraw.text(self, "/%d" % reserve, Vector2(ax + aw + s * 0.02, ay + s * 0.08), int(s * 0.3), Color(1, 1, 1, 0.85 * dim * o), 0, 2, "number")
	var status := "QUICK RELOAD" if gun_sel else "TAP TO EQUIP"
	var st_col := Color(1, 1, 1, 0.8 * dim * o)
	if reloading:
		status = "RELOADING"
		st_col = Color(HudDraw.YELLOW, o)
	elif ammo == 0 and int(def.mag) > 0:
		status = "RELOAD"
		st_col = Color(1.0, 0.33, 0.28, o)
	HudDraw.text(self, status, Vector2(ax, main.position.y + s * 0.76), int(s * 0.23), st_col, 0, 2, "bold")
	HudDraw.icon(self, HudDraw.weapon_tex(def), Vector2(main.end.x - main.size.x * 0.3, main.position.y + s * 0.44),
		Vector2(main.size.x * 0.5, s * 0.66), Color(1, 1, 1, 0.97 * dim * o))
	var ul := Rect2(main.position.x + s * 0.12, main.end.y - s * 0.09, main.size.x - s * 0.24, maxf(2.0, s * 0.035))
	draw_rect(ul, Color(1, 1, 1, 0.22 * o))
	draw_rect(Rect2(ul.position, Vector2(ul.size.x * (progress if reloading else 1.0), ul.size.y)),
		Color(HudDraw.YELLOW, o) if reloading else Color(1, 1, 1, 0.92 * dim * o))
	# Fire mode next to the slot.
	HudDraw.text(self, "AUTO" if bool(def.get("auto", false)) else "SINGLE", Vector2(main.position.x - s * 0.14, main.position.y + s * 0.26),
		int(s * 0.27), Color(1, 1, 1, 0.92 * o), 2, 3, "bold")
	# Small slots: the gun, an empty slot, fists.
	for i in 3:
		var r := slots[i]
		var sel := (i == 0 and gun_sel) or (i == 2 and not gun_sel)
		var sp := _pressed.has("weapons:%d" % i)
		draw_rect(r, Color(HudDraw.SLOT_BG, (0.86 if sp else 0.76) * o))
		if sel:
			HudDraw.vband(self, r, Color(HudDraw.GOLD, 0.7 * o), Color(HudDraw.GOLD.darkened(0.3), 0.62 * o))
			draw_rect(Rect2(r.position.x, r.end.y - 2.0, r.size.x, 2.0), Color(1, 0.93, 0.6, o))
		if i == 0:
			HudDraw.icon(self, HudDraw.weapon_tex(def), r.get_center() + Vector2(0, -s * 0.08), Vector2(r.size.x * 0.8, r.size.y * 0.5),
				Color(1, 1, 1, (1.0 if sel else 0.75) * o))
			HudDraw.text(self, str(ammo + reserve), Vector2(r.position.x + s * 0.08, r.end.y - s * 0.17), int(s * 0.25), Color(1, 1, 1, 0.92 * o), 0, 2, "number")
		elif i == 2:
			HudDraw.icon(self, HudDraw.tex("v_fist"), r.get_center() + Vector2(0, -s * 0.1), Vector2(r.size.y, r.size.y) * 0.5,
				Color(1, 1, 1, (1.0 if sel else 0.8) * o))
			_infinity(r.get_center() + Vector2(0, r.size.y * 0.3), s * 0.13, Color(1, 1, 1, 0.9 * o))


## "∞" drawn as a lemniscate (the UI fonts are latin subsets).
func _infinity(c: Vector2, half_w: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 33:
		var t := TAU * i / 32.0
		var d := 1.0 + sin(t) * sin(t)
		pts.append(c + Vector2(cos(t) / d, sin(t) * cos(t) / d * 1.25) * half_w)
	draw_polyline(pts, col, maxf(1.6, half_w * 0.2), true)


# ---------------------------------------------------------------- crosshair & scopes

func _spread_px() -> float:
	var fov := player.camera.fov if player.camera else 68.0
	return tan(deg_to_rad(player.current_spread())) / tan(deg_to_rad(fov) * 0.5) * size.y * 0.5


func _draw_crosshair(c: Vector2, u: float) -> void:
	var w := player.weapon()
	var on := player.crosshair_on_target
	var hit := _hit_t > 0.0
	var col := Color(1.0, 0.16, 0.13) if (on or hit) else Game.crosshair_color()
	var sc := lerpf(0.75, 1.35, float(Game.settings.crosshair_size) / 100.0)
	var dyn := bool(Game.settings.dynamic_crosshair)
	var outline := Color(0, 0, 0, 0.45)
	var ring_r := 0.0
	if player.ads and player.scope_type() == "reddot":
		ring_r = _draw_red_dot(c, u, sc, on or hit)
	else:
		match String(w.def.get("crosshair", "ring")):
			"dot":
				HudDraw.disk(self, c, 3.6 * sc, outline)
				HudDraw.disk(self, c, 2.4 * sc, col)
				ring_r = 9.0 * sc
				if Weapons.is_melee(w.def):
					HudDraw.ring(self, c, 9.0 * sc, Color(col, 0.35), 1.2)
			"wide":
				ring_r = clampf(maxf(0.055 * u, _spread_px() if dyn else 0.0), 0.05 * u, 0.14 * u) * sc
				for k in (0 if w.reloading and Game.settings.get("reload_on_crosshair", true) else 4):
					var a0 := -PI * 0.5 + PI * 0.5 * k + 0.32
					draw_arc(c, ring_r, a0, a0 + PI * 0.5 - 0.64, 16, outline, 3.6, true)
					draw_arc(c, ring_r, a0, a0 + PI * 0.5 - 0.64, 16, col, 1.8, true)
				HudDraw.disk(self, c, 2.8 * sc, outline)
				HudDraw.disk(self, c, 1.8 * sc, col)
			_:
				# the ring shows the real spread (reference: ~0.05-0.07 h across, blooming a little)
				ring_r = clampf(maxf(0.026 * u, _spread_px() if dyn else 0.0), 0.024 * u, 0.07 * u) * sc
				if not (w.reloading and Game.settings.get("reload_on_crosshair", true)):
					HudDraw.ring(self, c, ring_r, outline, 3.4)
					HudDraw.ring(self, c, ring_r, col, 1.6)
				HudDraw.disk(self, c, 3.0 * sc, outline)
				HudDraw.disk(self, c, 2.0 * sc, col)
	# Reload progress on the crosshair (setting), with a small magazine mark at the upper right.
	if w.reloading and bool(Game.settings.get("reload_on_crosshair", true)):
		var rr := maxf(ring_r, 0.03 * u)
		HudDraw.ring(self, c, rr, Color(0, 0, 0, 0.4), 4.4)
		HudDraw.ring(self, c, rr, Color(1, 1, 1, 0.25), 2.4)
		HudDraw.ring(self, c, rr, Color(1, 1, 1, 0.95), 2.4, w.reload_progress())
		var mp := c + Vector2(1, -1).normalized() * (rr + 0.022 * u)
		HudDraw.icon(self, HudDraw.tex("v_mag"), mp, Vector2(0.026, 0.026) * u, Color(1, 1, 1, 0.95))
	# Hit marker: short diagonal ticks (headshots in red-orange) + the headshot icon.
	if hit:
		var ha := clampf(_hit_t / 0.22, 0.0, 1.0)
		var hc := Color(1.0, 0.36, 0.2, ha) if _hit_head else Color(1, 1, 1, ha)
		var r0 := maxf(ring_r, 10.0) + 4.0
		for k in 4:
			var d := Vector2(1, 1).normalized().rotated(k * PI * 0.5)
			draw_line(c + d * r0, c + d * (r0 + 0.017 * u), Color(0, 0, 0, 0.5 * ha), 4.0, true)
			draw_line(c + d * r0, c + d * (r0 + 0.017 * u), hc, 2.2, true)
	if _head_icon_t > 0.0:
		var ia := clampf(_head_icon_t / 0.25, 0.0, 1.0)
		var pop := 1.0 + 0.4 * clampf((_head_icon_t - 0.55) / 0.15, 0.0, 1.0)
		var ip := c + Vector2(0.075 * u, -0.06 * u)
		HudDraw.disk(self, ip, 0.026 * u * pop, Color(0.6, 0.06, 0.04, 0.75 * ia))
		HudDraw.icon(self, HudDraw.tex("v_headshot"), ip, Vector2(0.04, 0.04) * u * pop, Color(1.0, 0.85, 0.75, ia))


## Red-dot sight while aiming: a faint sight frame and a glowing red dot. Returns its radius.
func _draw_red_dot(c: Vector2, u: float, sc: float, hot: bool) -> float:
	var fr := 0.11 * u
	HudDraw.ring(self, c, fr, Color(0, 0, 0, 0.32), 6.0)
	HudDraw.ring(self, c, fr, Color(1, 1, 1, 0.3), 1.4)
	HudDraw.ring(self, c, fr * 0.97, Color(0.4, 0.9, 1.0, 0.08), 3.0)
	var g := 1.4 if hot else 1.0
	HudDraw.disk(self, c, 7.5 * sc * g, Color(1, 0.08, 0.06, 0.16))
	HudDraw.disk(self, c, 4.4 * sc * g, Color(1, 0.12, 0.08, 0.42))
	HudDraw.disk(self, c, 2.5 * sc, Color(1, 0.3, 0.22))
	return 12.0 * sc


## Sniper scope: black housing around a round lens, edge shading and a stadia reticle.
func _draw_scope(c: Vector2, vs: Vector2) -> void:
	var rad := vs.y * 0.47
	var far := vs.length()
	draw_arc(c, rad + far * 0.5, 0.0, TAU, 96, Color(0.015, 0.015, 0.018), far, false)
	if _lens_tex:
		draw_texture_rect(_lens_tex, Rect2(c - Vector2(rad, rad), Vector2(rad, rad) * 2.0), false)
	HudDraw.ring(self, c, rad + vs.y * 0.022, Color(0.1, 0.1, 0.11), vs.y * 0.045)
	HudDraw.ring(self, c, rad + vs.y * 0.002, Color(0.42, 0.14, 0.1, 0.9), 2.0)
	HudDraw.ring(self, c, rad + vs.y * 0.044, Color(1, 1, 1, 0.08), 1.5)
	var ink := Color(0.02, 0.02, 0.02, 0.92)
	var gap := rad * 0.05
	draw_line(c + Vector2(-rad, 0), c + Vector2(-gap, 0), ink, 1.6, true)
	draw_line(c + Vector2(gap, 0), c + Vector2(rad, 0), ink, 1.6, true)
	draw_line(c + Vector2(0, -rad), c + Vector2(0, -gap), ink, 1.4, true)
	draw_rect(Rect2(c.x - rad, c.y - 3.0, rad * 0.42, 6.0), ink)
	draw_rect(Rect2(c.x + rad * 0.58, c.y - 3.0, rad * 0.42, 6.0), ink)
	draw_rect(Rect2(c.x - 3.5, c.y + rad * 0.14, 7.0, rad * 0.86), ink)
	draw_line(c + Vector2(0, gap), c + Vector2(0, rad * 0.14), ink, 1.4, true)
	for i in range(1, 6):
		var x := gap + (rad * 0.58 - gap) * i / 6.0
		var h := 7.0 if i % 2 == 0 else 4.5
		draw_line(c + Vector2(x, -h), c + Vector2(x, h), ink, 1.3, true)
		draw_line(c + Vector2(-x, -h), c + Vector2(-x, h), ink, 1.3, true)
	var hot := player.crosshair_on_target or _hit_t > 0.0
	HudDraw.disk(self, c, 2.2, Color(1, 0.15, 0.1) if hot else Color(0.05, 0.05, 0.05))


func _make_lens_texture() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.72, 0.93, 1.0])
	g.colors = PackedColorArray([Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.04), Color(0, 0, 0, 0.42), Color(0, 0, 0, 0.85)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	return t


## Heal in progress: medkit icon with a gold progress ring and the seconds left, under the crosshair.
func _draw_heal(c: Vector2, u: float) -> void:
	if not player.healing:
		return
	var p := Vector2(c.x, size.y * 0.635)
	var r := 0.036 * u
	HudDraw.disk(self, p, r, Color(0, 0, 0, 0.5))
	HudDraw.ring(self, p, r, Color(1, 1, 1, 0.2), 3.0)
	HudDraw.ring(self, p, r, HudDraw.GOLD, 3.0, player.heal_progress())
	HudDraw.icon(self, HudDraw.tex("v_medkit"), p, Vector2(r, r) * 1.05, Color(1, 1, 1, 0.95))
	HudDraw.text(self, "%.1fs" % maxf(player.heal_left, 0.0), p + Vector2(0, r + 0.022 * u), int(0.025 * u), Color.WHITE, 1, 3, "bold")


# ---------------------------------------------------------------- feedback

func _draw_vignette(vs: Vector2) -> void:
	var low := 0.0
	if player.alive and not match_over:
		low = clampf(1.0 - player.hp / (Fighter.MAX_HP * 0.35), 0.0, 1.0)
	var pulse := low * (0.26 + 0.12 * sin(_time * 6.5))
	var vig := maxf(_flash, pulse)
	if vig > 0.01:
		_edge_glow(vs, Color(0.85, 0.04, 0.04, vig), vs.y * 0.24)
	if _zone_hurt > 0.0:
		_edge_glow(vs, Color(0.55, 0.15, 0.85, 0.22 * clampf(_zone_hurt / 0.3, 0.0, 1.0)), vs.y * 0.16)


func _edge_glow(vs: Vector2, col: Color, t: float) -> void:
	var clear := Color(col, 0.0)
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(vs.x, 0), Vector2(vs.x, t), Vector2(0, t)]), PackedColorArray([col, col, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, vs.y - t), Vector2(vs.x, vs.y - t), Vector2(vs.x, vs.y), Vector2(0, vs.y)]), PackedColorArray([clear, clear, col, col]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(t, 0), Vector2(t, vs.y), Vector2(0, vs.y)]), PackedColorArray([col, clear, clear, col]))
	draw_polygon(PackedVector2Array([Vector2(vs.x - t, 0), Vector2(vs.x, 0), Vector2(vs.x, vs.y), Vector2(vs.x - t, vs.y)]), PackedColorArray([clear, col, col, clear]))


func _draw_damage_dirs(c: Vector2, u: float) -> void:
	if player.camera == null or _dmg_dirs.is_empty():
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
		var ang := atan2(to.dot(right), to.dot(fwd)) - PI * 0.5
		var a := clampf(float(d.t) / 1.4, 0.0, 1.0)
		var r := 0.2 * u
		draw_arc(c, r, ang - 0.36, ang + 0.36, 20, Color(0.9, 0.05, 0.04, 0.35 * a), 0.026 * u, true)
		draw_arc(c, r, ang - 0.3, ang + 0.3, 20, Color(1.0, 0.18, 0.12, 0.9 * a), 0.012 * u, true)


func _draw_damage_numbers(u: float) -> void:
	if player.camera == null:
		return
	var f := UI.font("number")
	for n in _dmg_numbers:
		var t := float(n.t)
		if player.camera.is_position_behind(n.pos + Vector3.UP * t * 0.55):
			continue
		var sp := _dmg_point(n, u)
		var head := bool(n.head)
		var amount := float(n.amount)
		var a := clampf(1.0 - (t - 0.6) / 0.35, 0.0, 1.0)
		# pop when it appears and again at every hit that adds to it
		var pop := 1.0 + clampf(0.12 - t, 0.0, 0.12) * 4.0 + float(n.bump) * 1.6
		var fs := int(_dmg_size(amount, head, u) * pop)
		var col := HudDraw.DMG_HEAD if head else HudDraw.DMG_BODY
		var txt := str(maxi(roundi(amount), 1))
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		# Bold italic: skew the glyphs to the right around their centre.
		draw_set_transform_matrix(Transform2D(0.0, Vector2.ONE, -0.22, sp))
		var base := Vector2(-w * 0.5, (f.get_ascent(fs) - f.get_descent(fs)) * 0.5)
		draw_string_outline(f, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(4, fs / 7), Color(0.05, 0.02, 0.0, 0.85 * a))
		draw_string(f, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, a))
	draw_set_transform_matrix(Transform2D.IDENTITY)


## The big red X on an eliminated enemy.
func _draw_kill_x(u: float) -> void:
	if _kill_x_t <= 0.0 or player.camera == null or player.camera.is_position_behind(_kill_x_pos):
		return
	var p := player.camera.unproject_position(_kill_x_pos)
	var age := KILL_X_TIME - _kill_x_t
	var a := clampf(_kill_x_t / 0.25, 0.0, 1.0)
	var k := (0.075 * u) * (1.0 + 0.5 * clampf(1.0 - age / 0.12, 0.0, 1.0))
	var wd := 0.016 * u
	for d in [Vector2(1, 1), Vector2(1, -1)]:
		var v: Vector2 = d.normalized() * k
		draw_line(p - v, p + v, Color(0, 0, 0, 0.55 * a), wd + 4.0, true)
		draw_line(p - v, p + v, Color(HudDraw.KILL_RED, a), wd, true)


# ---------------------------------------------------------------- HP, kill feed

func _bottom_limits(vs: Vector2, u: float) -> Vector2:
	var lo := 0.0
	var hi := vs.x
	for id in ["medkit", "grenade", "crouch", "prone", "reload", "wall"]:
		if not layout.has(id) or not _button_visible(id):
			continue
		var w: Dictionary = layout[id]
		var c := HudLayout.center(w, vs)
		var r := HudLayout.radius(w, vs)
		if c.y + r < vs.y * 0.94:
			continue
		if c.x < vs.x * 0.5:
			lo = maxf(lo, c.x + r + 0.012 * u)
		else:
			hi = minf(hi, c.x - r - 0.012 * u)
	return Vector2(lo, hi)


func _draw_hp_block(vs: Vector2, u: float) -> void:
	var hp := Fighter.MAX_HP
	var healing_rem := 0.0
	if player != null and not editor_mode:
		hp = player.hp
		if player.healing:
			healing_rem = minf(Fighter.HEAL_RATE * minf(player.heal_left, Fighter.HEAL_AMOUNT / Fighter.HEAL_RATE), Fighter.MAX_HP - hp)
	var mx := Fighter.MAX_HP
	var lim := _bottom_limits(vs, u)
	var avail := lim.y - lim.x
	var by := vs.y * 0.968
	var bh := maxf(4.0, 0.0105 * u)
	var label := "HP %d/%d" % [ceili(hp), int(mx)]
	# Inline like the reference: [helmet][vest] HP 200/200 [bar]. The layout is measured on the
	# widest label so the bar does not shift while the number changes. Short of room (16:9
	# between the medkit and grenade buttons) the label and icons get a little smaller first;
	# only a very narrow gap puts the label above the bar.
	var fs := int(0.03 * u)
	var isz := 0.05 * u
	var lw := HudDraw.text_width("HP %d/%d" % [int(mx), int(mx)], fs, "bold")
	var icons_w := isz * 2.0 + 0.008 * u
	var fixed := icons_w + 0.016 * u + lw + 0.014 * u
	var bar_w := minf(0.38 * u, avail - fixed)
	if bar_w < 0.25 * u:
		fs = int(0.027 * u)
		isz = 0.045 * u
		lw = HudDraw.text_width("HP %d/%d" % [int(mx), int(mx)], fs, "bold")
		icons_w = isz * 2.0 + 0.008 * u
		fixed = icons_w + 0.012 * u + lw + 0.012 * u
		bar_w = minf(0.38 * u, avail - fixed)
	var stacked := bar_w < 0.13 * u
	if stacked:
		fixed = icons_w + 0.014 * u
		bar_w = clampf(avail - fixed, 0.14 * u, 0.38 * u)
	# The bar sits on the screen centre when there is room, else the block shifts between limits.
	var x0 := clampf(vs.x * 0.5 - bar_w * 0.5 - fixed, lim.x, maxf(lim.y - fixed - bar_w, lim.x))
	var bar := Rect2(x0 + fixed, by - bh * 0.5, bar_w, bh)
	draw_rect(bar.grow(1.0), Color(0, 0, 0, 0.5))
	var frac := clampf(hp / mx, 0.0, 1.0)
	var lag := clampf(_hp_lag / mx, 0.0, 1.0)
	if lag > frac:
		draw_rect(Rect2(bar.position + Vector2(bar_w * frac, 0), Vector2(bar_w * (lag - frac), bh)), Color(0.95, 0.25, 0.2, 0.85))
	var fill := HudDraw.HP_WHITE if frac > 0.3 else Color(1.0, 0.45, 0.4)
	draw_rect(Rect2(bar.position, Vector2(bar_w * frac, bh)), fill)
	if healing_rem > 0.0:
		draw_rect(Rect2(bar.position + Vector2(bar_w * frac, 0), Vector2(bar_w * healing_rem / mx, bh)), Color(HudDraw.HEAL_GREEN, 0.85 + 0.15 * sin(_time * 8.0)))
	if stacked:
		HudDraw.text(self, label, Vector2(bar.position.x, by - bh - 0.02 * u), int(fs * 0.9), Color(1, 1, 1, 0.95), 0, 3, "bold")
	else:
		HudDraw.text(self, label, Vector2(bar.position.x - 0.012 * u, by), fs, Color(1, 1, 1, 0.95), 2, 3, "bold")
	# Helmet + vest (level 2) at the left end of the block.
	for k in 2:
		_armor_icon(Vector2(x0 + isz * 0.5 + k * (isz + 0.008 * u), by - isz * 0.12), isz, "v_helmet" if k == 0 else "v_vest", 2)


func _armor_icon(c: Vector2, sz: float, icon_name: String, level: int) -> void:
	HudDraw.disk(self, c, sz * 0.5, Color(0, 0, 0, 0.45))
	HudDraw.icon(self, HudDraw.tex(icon_name), c + Vector2(-sz * 0.06, 0), Vector2(sz, sz) * 0.6, Color(1.0, 0.8, 0.18))
	for i in level:
		var y := c.y + sz * (0.12 + i * 0.12)
		draw_line(Vector2(c.x + sz * 0.16, y), Vector2(c.x + sz * 0.36, y - sz * 0.05), Color(1, 1, 1, 0.95), maxf(1.5, sz * 0.06), true)


func _draw_kill_feed(vs: Vector2, u: float) -> void:
	var fs := int(0.03 * u)
	for i in mini(_kill_feed.size(), FEED_Y.size()):
		var k: Dictionary = _kill_feed[i]
		var t := float(k.t)
		var a := clampf(t / 0.5, 0.0, 1.0) * clampf((FEED_LIFE - t) / 0.15, 0.0, 1.0)
		var head := bool(k.head)
		var parts := [[String(k.killer) + "  ", Color(1, 1, 1) if not bool(k.mine) else Color(0.75, 0.9, 1.0)],
			[("HEADSHOT" if head else "ELIMINATED") + "  ", HudDraw.FEED_HEAD if head else HudDraw.FEED_ELIM],
			[String(k.victim), Color(1, 1, 1)]]
		if String(k.weapon) != "":
			parts.append(["  (%s)" % String(k.weapon), Color(1, 1, 1, 0.82)])
		# A dark plate keeps the line readable over the white shirt, the yellow pads and the floor.
		var tw := HudDraw.parts_width(parts, fs)
		var y := vs.y * float(FEED_Y[i])
		draw_rect(Rect2(vs.x * 0.5 - tw * 0.5 - fs * 0.6, y - fs * 0.72, tw + fs * 1.2, fs * 1.44), Color(0.03, 0.03, 0.04, 0.5 * a))
		HudDraw.text_parts(self, parts, Vector2(vs.x * 0.5, y), fs, 1, 3, "bold", a)


# ---------------------------------------------------------------- top: score bar, zone, prep

func _draw_score_bar(vs: Vector2, u: float) -> void:
	var cx := vs.x * 0.5
	var ph := 0.078 * u
	var pw := 0.066 * u
	var sl := 0.017 * u
	var cw := 0.1 * u
	var mine := 0
	var theirs := 0
	var t := 90.0
	var red := false
	var goal := 1
	var hp_me := 1.0
	var hp_bot := 1.0
	if arena != null and not editor_mode:
		var sc: Dictionary = arena.get("score")
		mine = int(sc.get("player", 0))
		theirs = int(sc.get("bot", 0))
		goal = int(arena.get("rounds_to_win"))
		var phase := int(arena.get("phase"))
		t = float(arena.get("prep_left")) if phase == 0 else float(arena.get("time_left"))
		red = phase == 0 or t <= 10.0
		if player != null:
			hp_me = clampf(player.hp / Fighter.MAX_HP, 0.0, 1.0)
		var b: Variant = arena.get("bot")
		if b is Fighter:
			hp_bot = clampf((b as Fighter).hp / Fighter.MAX_HP, 0.0, 1.0)
	HudDraw.vband(self, Rect2(cx - cw, 0.0, cw * 2.0, ph), Color(0, 0, 0, 0.5), Color(0, 0, 0, 0.32))
	# Blue plate (your rounds) and bar, orange plate (enemy rounds) and bar, slanted like a V.
	var bx0 := cx - cw - pw - sl
	HudDraw.slanted(self, bx0, bx0 + pw, 0.0, ph, sl, HudDraw.BLUE)
	HudDraw.slanted(self, bx0, bx0 + pw, 0.0, ph * 0.45, sl * 0.45, Color(1, 1, 1, 0.1))
	var ox0 := cx + cw + sl
	HudDraw.slanted(self, ox0, ox0 + pw, 0.0, ph, -sl, HudDraw.ORANGE)
	HudDraw.slanted(self, ox0, ox0 + pw, 0.0, ph * 0.45, -sl * 0.45, Color(1, 1, 1, 0.1))
	var nfs := int(0.064 * u)
	HudDraw.text(self, str(mine), Vector2(bx0 + pw * 0.5 + sl * 0.5, ph * 0.52), nfs, Color.WHITE, 1, 0, "number")
	HudDraw.text(self, str(theirs), Vector2(ox0 + pw * 0.5 - sl * 0.5, ph * 0.52), nfs, Color.WHITE, 1, 0, "number")
	var bh := 0.03 * u
	var by := 0.018 * u
	var bw := 0.13 * u
	var gap := 0.012 * u
	var bs := sl * bh / ph
	var bxr := bx0 + sl * by / ph - gap
	HudDraw.slanted(self, bxr - bw, bxr, by, bh, bs, Color(0.08, 0.1, 0.12, 0.55))
	HudDraw.slanted(self, bxr - bw * hp_me, bxr, by, bh, bs, HudDraw.BLUE)
	var oxl := ox0 + pw - sl * by / ph + gap
	HudDraw.slanted(self, oxl, oxl + bw, by, bh, -bs, Color(0.08, 0.1, 0.12, 0.55))
	HudDraw.slanted(self, oxl, oxl + bw * hp_bot, by, bh, -bs, HudDraw.ORANGE)
	HudDraw.text(self, HudDraw.time_text(t), Vector2(cx, ph * 0.36), int(0.046 * u), HudDraw.RED if red else Color.WHITE, 1, 2, "number")
	HudDraw.text_parts(self, [["OBJECTIVE: ", Color(1, 1, 1, 0.95)], [str(goal), HudDraw.YELLOW]], Vector2(cx, ph * 0.8), int(0.025 * u), 1, 2, "bold")


func _draw_zone_strip(vs: Vector2) -> void:
	var w: Dictionary = layout.minimap
	var o := float(w.o)
	var mr := HudLayout.minimap_rect(w, vs)
	var h := mr.size.x * HudLayout.STRIP_H
	var r := Rect2(mr.position.x, mr.end.y + 2.0, mr.size.x, h)
	draw_rect(r, Color(0, 0, 0, 0.55 * o))
	var state := "STATIONARY"
	var left := 25.0
	var closed := false
	if arena != null and not editor_mode:
		var zs := String(arena.get("zone_state"))
		left = float(arena.call("zone_next"))
		if zs == "shrinking":
			state = "SHRINKING"
		elif zs == "closed":
			state = "CLOSED"
			closed = true
	HudDraw.icon(self, HudDraw.tex("v_zone"), Vector2(r.position.x + h * 0.55, r.get_center().y), Vector2(h, h) * 0.62, Color(1, 1, 1, 0.9 * o))
	var parts := [["SAFE ZONE  ", Color(0.72, 0.76, 0.82)], [state, Color(1, 0.4, 0.35) if closed else Color.WHITE]]
	if not closed:
		var s := ceili(maxf(left, 0.0))
		parts.append(["  %d:%02d" % [s / 60, s % 60], HudDraw.YELLOW])
	var fs := int(h * 0.56)
	var avail := r.size.x - h * 1.25
	var tw := HudDraw.parts_width(parts, fs)
	if tw > avail:
		fs = maxi(8, int(fs * avail / tw))
	HudDraw.text_parts(self, parts, Vector2(r.position.x + h * 1.1, r.get_center().y), fs, 0, 0, "bold", o)


## Zone warnings under the score bar ("SAFE ZONE SHRINKS IN 7s" / "OUTSIDE THE SAFE ZONE").
func _draw_zone_banner(vs: Vector2, u: float) -> void:
	if arena == null or editor_mode or match_over:
		return
	var msg := String(arena.get("zone_warning"))
	var danger := false
	if player != null and player.alive and int(arena.get("phase")) == 1 and float(arena.get("zone_radius")) < 200.0 \
			and not bool(arena.call("in_zone", player.global_position)):
		msg = "OUTSIDE THE SAFE ZONE - MOVE IN!"
		danger = true
	if msg == "":
		return
	var fs := int(0.028 * u)
	var tw := HudDraw.text_width(msg, fs, "bold")
	var h := 0.05 * u
	var r := Rect2(vs.x * 0.5 - tw * 0.5 - h * 1.1, 0.105 * vs.y, tw + h * 1.6, h)
	HudDraw.band(self, r, Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.6))
	HudDraw.band(self, Rect2(r.position + Vector2(r.size.x * 0.5, 0), Vector2(r.size.x * 0.5, h)), Color(0, 0, 0, 0.6), Color(0, 0, 0, 0.0))
	var ic := Vector2(r.position.x + h * 0.75, r.get_center().y)
	var tri := PackedVector2Array([ic + Vector2(0, -h * 0.32), ic + Vector2(h * 0.32, h * 0.26), ic + Vector2(-h * 0.32, h * 0.26)])
	draw_colored_polygon(tri, HudDraw.RED if danger else HudDraw.YELLOW)
	HudDraw.text(self, "!", ic + Vector2(0, h * 0.04), int(h * 0.42), Color(0.1, 0.07, 0.02), 1, 0, "bold")
	var col := Color(1, 0.45, 0.4) if danger else Color.WHITE
	if danger:
		col.a = 0.75 + 0.25 * sin(_time * 9.0)
	HudDraw.text(self, msg, Vector2(ic.x + h * 0.6, r.get_center().y), fs, col, 0, 2, "bold")


## Prep phase with the pick panel closed: PREPARE + big red countdown.
func _draw_prep(vs: Vector2, u: float) -> void:
	if arena == null or editor_mode or int(arena.get("phase")) != 0 or panels.pick_open:
		return
	var left := maxf(float(arena.get("prep_left")), 0.0)
	var n := ceili(left)
	if n <= 0:
		return
	var frac := left - floorf(left)
	var pop := 1.0 + 0.3 * clampf((frac - 0.8) / 0.2, 0.0, 1.0)
	var cx := vs.x * 0.5
	HudDraw.text(self, "PREPARE", Vector2(cx, vs.y * 0.215), int(0.042 * u), Color(1, 1, 1, 0.95), 1, 4, "bold")
	HudDraw.text(self, str(n), Vector2(cx, vs.y * 0.315), int(0.15 * u * pop), Color(1.0, 0.2, 0.16), 1, 6, "title")
	var b: Variant = arena.get("bot")
	if player != null and b is Fighter:
		# The match-up on a dark plate: readable over the bright, red-tinted alcove.
		var parts := [[player.display_name, Color(0.62, 0.86, 1.0)], ["   VS   ", Color(1, 1, 1, 0.85)],
			[(b as Fighter).display_name, Color(1.0, 0.72, 0.52)]]
		var mfs := int(0.032 * u)
		var mw := HudDraw.parts_width(parts, mfs)
		var my := vs.y * 0.415
		HudDraw.plate(self, Rect2(cx - mw * 0.5 - 0.09 * u, my - 0.032 * u, mw + 0.18 * u, 0.064 * u), 0.62)
		HudDraw.text_parts(self, parts, Vector2(cx, my), mfs, 1, 3, "bold")


## "ROUND n / AREA: name" on a band fading from blue (left) to orange (right).
func _draw_round_banner(vs: Vector2, u: float) -> void:
	var t := float(_round_banner.t)
	if t <= 0.0:
		return
	var age := ROUND_BANNER_TIME - t
	var a := clampf(age / 0.18, 0.0, 1.0) * clampf(t / 0.4, 0.0, 1.0)
	var slide := (1.0 - ease(clampf(age / 0.28, 0.0, 1.0), 0.35)) * vs.x * 0.12
	var h := 0.13 * u
	var y0 := vs.y * 0.3
	var w := minf(vs.x * 0.66, 1.3 * u)
	var x0 := (vs.x - w) * 0.5 - slide
	var xm := x0 + w * 0.5
	var sk := h * 0.18
	var blue := Color(HudDraw.BLUE, 0.88 * a)
	var orange := Color(HudDraw.ORANGE, 0.88 * a)
	var fade := w * 0.22
	draw_polygon(PackedVector2Array([Vector2(x0, y0), Vector2(x0 + fade, y0), Vector2(x0 + fade, y0 + h), Vector2(x0, y0 + h)]),
		PackedColorArray([Color(blue, 0.0), blue, blue, Color(blue, 0.0)]))
	draw_colored_polygon(PackedVector2Array([Vector2(x0 + fade, y0), Vector2(xm + sk, y0), Vector2(xm - sk, y0 + h), Vector2(x0 + fade, y0 + h)]), blue)
	draw_colored_polygon(PackedVector2Array([Vector2(xm + sk, y0), Vector2(x0 + w - fade, y0), Vector2(x0 + w - fade, y0 + h), Vector2(xm - sk, y0 + h)]), orange)
	draw_polygon(PackedVector2Array([Vector2(x0 + w - fade, y0), Vector2(x0 + w, y0), Vector2(x0 + w, y0 + h), Vector2(x0 + w - fade, y0 + h)]),
		PackedColorArray([orange, Color(orange, 0.0), Color(orange, 0.0), orange]))
	draw_line(Vector2(x0 + fade, y0), Vector2(x0 + w - fade, y0), Color(1, 1, 1, 0.25 * a), 1.5)
	draw_line(Vector2(x0 + fade, y0 + h), Vector2(x0 + w - fade, y0 + h), Color(1, 1, 1, 0.25 * a), 1.5)
	var tc := Vector2(xm, y0 + h * 0.4)
	HudDraw.text_parts(self, [["ROUND ", Color.WHITE], [str(int(_round_banner.round)), HudDraw.YELLOW]], tc, int(0.078 * u), 1, 3, "bold", a)
	HudDraw.text_parts(self, [["AREA: ", Color(1, 1, 1, 0.95)], [String(_round_banner.area), HudDraw.YELLOW]],
		Vector2(xm, y0 + h * 0.8), int(0.03 * u), 1, 2, "bold", a)


## Elimination badge (our own emblem) with HEADSHOT / ELIMINATED and the victim's name plate.
func _draw_kill_banner(vs: Vector2, u: float) -> void:
	var t := float(_kill_banner.t)
	if t <= 0.0:
		return
	var age := KILL_BANNER_TIME - t
	var a := clampf(age / 0.1, 0.0, 1.0) * clampf(t / 0.45, 0.0, 1.0)
	var pop := 1.0 + 0.45 * (1.0 - clampf(age / 0.2, 0.0, 1.0))
	var c := Vector2(vs.x * 0.5, vs.y * 0.19)
	var bs := 0.19 * u * pop
	HudDraw.disk(self, c, bs * 0.42, Color(0.9, 0.2, 0.15, 0.18 * a * (1.0 - clampf(age / 0.6, 0.0, 1.0))))
	HudDraw.icon(self, HudDraw.tex("badge_elim"), c, Vector2(bs, bs), Color(1, 1, 1, a))
	# One dark plate under the badge holds both lines (HEADSHOT / ELIMINATED, then the name),
	# so they stay readable over a bright hall or the character's raised arms.
	var head := bool(_kill_banner.head)
	var label := "HEADSHOT" if head else "ELIMINATED"
	var lfs := int(0.036 * u)
	var nm := String(_kill_banner.name).to_upper()
	var fs := int(0.03 * u)
	var ty := c.y + 0.19 * u * 0.5 + 0.024 * u
	var pw := maxf(HudDraw.text_width(label, lfs, "bold"), HudDraw.text_width(nm, fs, "bold")) + 0.2 * u
	var plate := Rect2(c.x - pw * 0.5, ty - 0.026 * u, pw, 0.1 * u)
	HudDraw.plate(self, plate, 0.72 * a)
	HudDraw.text(self, label, Vector2(c.x, ty), lfs, Color(HudDraw.FEED_HEAD if head else Color.WHITE, a), 1, 3, "bold")
	var line_y := ty + 0.026 * u
	draw_rect(Rect2(c.x - pw * 0.3, line_y, pw * 0.6, maxf(1.5, 0.003 * u)), Color(HudDraw.KILL_RED, a))
	HudDraw.text(self, nm, Vector2(c.x, line_y + 0.025 * u), fs, Color(1, 1, 1, a), 1, 2, "bold")


func _draw_center_text(vs: Vector2, u: float) -> void:
	var t := float(_center.t)
	if t <= 0.0 or String(_center.text) == "" or panels.pick_open:
		return
	var dur := float(_center.dur)
	var a := clampf(t / 0.3, 0.0, 1.0) * clampf((dur - t) / 0.12 + 0.2, 0.0, 1.0)
	var y := vs.y * (0.47 if float(_kill_banner.t) > 0.0 else 0.36)
	if float(_round_banner.t) > 0.0:
		y = vs.y * 0.55
	var fsize := int(float(_center.size) * u / 720.0)
	var col: Color = _center.col
	HudDraw.text(self, String(_center.text).to_upper(), Vector2(vs.x * 0.5, y), fsize, Color(col, col.a * a), 1, maxi(4, fsize / 12), "title")
	# Sub-lines in capitals like the rest of the HUD; a line that only repeats the name already
	# on the elimination badge ("<NAME> ELIMINATED") is left out.
	var sub := String(_center.sub).to_upper()
	var victim := String(_kill_banner.name).to_upper()
	if float(_kill_banner.t) > 0.0 and victim != "" and sub.contains(victim):
		sub = ""
	if sub != "":
		HudDraw.text(self, sub, Vector2(vs.x * 0.5, y + fsize * 0.62), int(0.04 * u), Color(1, 1, 1, a), 1, 4, "bold")


func _draw_tips(vs: Vector2, u: float) -> void:
	if tips_time <= 0.0 or panels.pick_open or match_over:
		return
	var a := clampf(tips_time, 0.0, 1.0)
	var fs := int(0.027 * u)
	var l1 := "LEFT SIDE: MOVE  ·  RIGHT SIDE: DRAG TO AIM"
	var l2 := "HOLD FIRE AND DRAG IT TO AIM WHILE SHOOTING"
	var w := maxf(HudDraw.text_width(l1, fs), HudDraw.text_width(l2, fs)) + 0.08 * u
	var r := Rect2(vs.x * 0.5 - w * 0.5, vs.y * 0.6, w, 0.1 * u)
	draw_rect(r, Color(0, 0, 0, 0.5 * a))
	HudDraw.text(self, l1, Vector2(vs.x * 0.5, r.position.y + r.size.y * 0.3), fs, Color(1, 1, 1, a), 1, 0, "bold")
	HudDraw.text(self, l2, Vector2(vs.x * 0.5, r.position.y + r.size.y * 0.72), fs, Color(HudDraw.YELLOW, a), 1, 0, "bold")


# ---------------------------------------------------------------- editor preview

func _draw_editor(vs: Vector2, u: float) -> void:
	var c := vs * 0.5
	HudDraw.ring(self, c, 0.026 * u, Color(0, 0, 0, 0.45), 3.4)
	HudDraw.ring(self, c, 0.026 * u, Color.WHITE, 1.6)
	HudDraw.disk(self, c, 2.0, Color.WHITE)
	_draw_score_bar(vs, u)
	_draw_hp_block(vs, u)
	_draw_zone_strip(vs)
	var fs := int(0.03 * u)
	var feed := [["PLAYER  ", Color.WHITE], ["ELIMINATED  ", HudDraw.FEED_ELIM], ["BOT", Color.WHITE], ["  (VIPER AR)", Color(1, 1, 1, 0.82)]]
	var feed_c := Vector2(vs.x * 0.5, vs.y * float(FEED_Y[0]))
	var feed_w := HudDraw.text_parts(self, feed, feed_c, fs, 1, 3, "bold", 0.8)
	_draw_controls(vs)
	_draw_weapon_panel(vs)
	# Labels under (or above) each widget, nudged so they never sit on top of each other or on
	# another widget (the small corner gear's label goes beside it, not onto the weapon panel).
	var taken: Array[Rect2] = [Rect2(feed_c - Vector2(feed_w * 0.5, fs * 0.6), Vector2(feed_w, fs * 1.2))]
	var widgets: Array[Rect2] = []
	for wid: String in HudLayout.ORDER:
		var wr := HudLayout.hit_rect(wid, layout[wid], vs)
		if wid == "minimap":
			wr.size.y += wr.size.x * HudLayout.STRIP_H
		elif wid == "fire_r":
			wr = wr.grow(HudLayout.radius(layout[wid], vs) * 0.17)
		widgets.append(wr)
	var lfs := int(0.022 * u)
	for id: String in HudLayout.ORDER:
		var w: Dictionary = layout[id]
		var r := HudLayout.hit_rect(id, w, vs)
		var sel := id == selected_id
		var label := String(SHORT_LABELS.get(id, HudLayout.LABELS.get(id, id)))
		# Labels keep clear of the selection ring (r + 5) and of the fire button's dotted halo.
		var lr0 := r
		if HudLayout.kind(id) in ["button", "joy"]:
			lr0 = r.grow((HudLayout.radius(w, vs) * 0.17 if id == "fire_r" else 0.0) + 6.0)
		var lw := HudDraw.text_width(label, lfs, "bold") + 8.0
		var lh := lfs * 1.2
		var below := Vector2(lr0.get_center().x, lr0.end.y + (r.size.y * HudLayout.STRIP_H if HudLayout.kind(id) == "square" else 0.0) + lh * 0.5 + 2.0)
		var above := Vector2(lr0.get_center().x, lr0.position.y - lh * 0.5 - 2.0)
		var left := Vector2(lr0.position.x - lw * 0.5 - 2.0, lr0.get_center().y)
		var right := Vector2(lr0.end.x + lw * 0.5 + 2.0, lr0.get_center().y)
		var spots := [below, above, left, right] if below.y < vs.y - lh * 0.5 else [above, left, right, below]
		spots.append(below + Vector2(0, lh))
		spots.append(above - Vector2(0, lh))
		# First free spot, slid back on screen at the edges; when none is free (a widget dragged
		# onto others) the one that covers the least: other labels count ten times more than
		# widgets, so a label never lands on another label while a free-ish spot exists.
		var lr := Rect2()
		var best := INF
		var area := lw * lh
		for sp: Vector2 in spots:
			var cand := Rect2(sp - Vector2(lw, lh) * 0.5, Vector2(lw, lh))
			cand.position = cand.position.clamp(Vector2.ZERO, (vs - cand.size).max(Vector2.ZERO))
			var inner := cand.grow(-1.0)
			var score := 0.0
			for t in taken:
				score += 10.0 * t.intersection(inner).get_area() / area
			for t in widgets:
				score += t.intersection(inner).get_area() / area
			if score < best - 0.0001:
				best = score
				lr = cand
			if score <= 0.0:
				break
		taken.append(lr)
		HudDraw.text(self, label, lr.get_center(), lfs, Color(HudDraw.YELLOW, 1.0) if sel else Color(1, 1, 1, 0.8), 1, 3, "bold")
		if sel:
			if HudLayout.kind(id) in ["button", "joy"]:
				HudDraw.ring(self, r.get_center(), r.size.x * 0.5 + 5.0, HudDraw.YELLOW, 2.5)
			else:
				draw_rect(r.grow(5.0), HudDraw.YELLOW, false, 2.5)
