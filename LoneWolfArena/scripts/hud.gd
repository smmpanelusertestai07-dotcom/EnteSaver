class_name HUD
extends Control
## In-match HUD of the Lone Wolf duel, laid out like the reference mobile shooters (positions
## from HudLayout, editable in the HUD editor). Everything is drawn in _draw (cheap on phones,
## icon textures loaded once):
##  - multi-touch controls: floating joystick (sprint by pushing past the ring) + sprint button,
##    look area, right / left FIRE (drag to aim while firing), scope, jump, crouch, prone,
##    RELOAD, SWITCH (gun <-> fists), medkit, wall, grenade, settings (pause) and scoreboard
##    buttons, the weapon panel;
##  - crosshair: spread ring / wide ring / dot by gun, red on target, red dot when aiming, full
##    sniper scope, reload and heal progress rings;
##  - feedback: damage numbers, hit marker, headshot icon, the elimination X and badge, damage
##    direction arcs, low-HP pulse;
##  - match info: duel score bar with timer, prep countdown, round banner, minimap (hud_minimap.gd)
##    with the safe-zone strip, HP block, kill feed; weapon pick + scoreboard (hud_panels.gd).

signal pause_pressed

const BUTTONS := ["fire_r", "fire_l", "scope", "jump", "crouch", "prone", "sprint", "medkit", "wall", "grenade", "freelook",
	"reload", "swap", "settings"]
const GLYPHS := {
	"fire_r": "v_fire", "fire_l": "v_fire", "scope": "v_scope", "jump": "stance_jump", "crouch": "stance_crouch",
	"prone": "stance_prone", "sprint": "stance_sprint", "medkit": "v_medkit", "wall": "v_wall",
	"grenade": "item_grenade", "settings": "v_settings", "freelook": "v_eye", "reload": "v_mag", "swap": "v_fist",
}
const GLYPH_FALLBACK := {"prone": "v_prone", "sprint": "v_sprint", "jump": "v_chevron"}
const GLYPH_SCALE := {
	"fire_r": 0.54, "fire_l": 0.54, "scope": 0.58, "jump": 0.72, "crouch": 0.72, "prone": 0.84, "sprint": 0.72,
	"medkit": 0.52, "wall": 0.54, "grenade": 0.62, "settings": 0.56, "freelook": 0.56, "reload": 0.4, "swap": 0.5,
}
const EXTRA_ICONS := ["v_fist", "v_mag", "v_headshot", "v_helmet", "v_vest", "v_zone", "badge_elim", "v_tick",
	"weapon_ar", "weapon_smg", "weapon_sg", "weapon_sg_lever", "weapon_pistol", "weapon_sidearm", "weapon_sniper", "v_skull", "v_splat"]
const SHORT_LABELS := {"settings": "MENU", "fire_l": "L FIRE"}
const LEFT_FIRE_OFF := 2           # setting left_fire: 0 always, 1 while aiming, 2 off
const DMG_LIFE := 0.7
const HIT_T := 0.22                # the hit marker's life
const HIT_BLOOM := 0.18            # the hit ring's growth
const FEED_LIFE := 6.0
const ROUND_BANNER_TIME := 1.9
## The elimination badge stays through the break's beat only (the result band follows at
## RoundRules.BREAK_RESULT_AT), small and without a pop, like the reference's streak icon.
const KILL_BANNER_TIME := 2.3
const KILL_X_TIME := 0.9
## The first match's tips (our words): small yellow labels under the buttons they name.
const TIPS := [["joystick", "MOVE"], ["fire_r", "HOLD TO FIRE · DRAG TO AIM"], ["wall", "TAP: SHIELD WALL"]]
const SPRINT_PUSH := 1.0           # joystick deflection (in ring radii) that counts as past the ring
const SPRINT_HOLD := 0.12          # seconds past the ring before the sprint locks (pushing further = run)
const JOY_ZONE_X := 0.4            # floating joystick: the left 40 % of the screen
const FIRE_TRAVEL := 1.25          # how far a held FIRE button follows the finger (x its radius)
const FEED_Y := [0.853, 0.81, 0.767]
const FEED_Y_SOLO := 0.767         # the 1 vs 1's line: the reference's place, over the bottom row
const FEED_Y_SOLO2 := 0.80         # ... and a second line at the same time stacks under it
const FEED_LIFE_SOLO := 3.5        # the 1 vs 1's lines stay a short while (team lines FEED_LIFE)
## An opponent who went down by itself (nobody's kill): what out_banner says took them out.
const OUT_LINES := {"zone": "CAUGHT IN THE ZONE", "fall": "DOWN FROM A FALL", "self": "HIT BY THEIR OWN FRAG"}
const OUT_ICONS := {"zone": "v_zone", "fall": "v_skull", "self": "item_grenade"}
## The team kill feed's verbs in their colours (add_team_feed).
const FEED_VERB_COLORS := {"KNOCKED": Color(1.0, 0.5, 0.3), "REVIVED": Color(0.45, 0.9, 0.5), "LEFT": Color(0.7, 0.72, 0.76)}

var player: Player
var arena: Node
var layout := {}
var editor_mode := false
var selected_id := ""
var match_over := false
var tips_time := 0.0
var minimap: HudMinimap
var panels: HudPanels
var team: HudTeam                  # DUO / SQUAD: the team layer (HudTeam.attach in bind), null in a 1 vs 1
var seen := {}                     # fighter -> in sight (refreshed 10x per second)

var _touches := {}                 # touch index -> {"kind": joy|look|fire|ui, "id": String}
var _spec_friend_rect := Rect2()     # ADD FRIEND on the SPECTATING card (empty while not drawn)
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
var _hit_tick := -1                # physics frame of the last hit report (a shot reports its head and body parts)
var _head_icon_t := 0.0
var _kill_x_t := 0.0
var _kill_x_pos := Vector3.ZERO
var _dmg_numbers: Array = []
var _dmg_dirs: Array = []
var _gun_alerts: Array = []           # gun_alert: {who, pos, dist, t}
var _kill_feed: Array = []
## Lines the kill feed keeps: three in DUO / SQUAD (and a HUD never bound), ONE in the 1 vs 1 (bind:
## a new line replaces the old, centred, with the gun's silhouette on a soft highlight before it).
var feed_lines := 3
var _flash := 0.0
var _zone_hurt := 0.0
var _hurt_sound_t := 0.0
var _center := {"text": "", "sub": "", "t": 0.0, "dur": 1.0, "col": Color.WHITE, "size": 96}
var _round_banner := {"t": 0.0, "round": 1, "area": ""}
var _break := {}                   # the break between rounds on screen (show_break), "age" in s
var _streak := {"round": -1, "n": 0}  # the player's kills this round (kill_banner's DOUBLE / TRIPLE)
var _result := {}                  # the match's end on the result band (show_result), "age" in s
var _kill_banner := {"t": 0.0, "name": "", "head": false}
var _reveal := {}
var steps: Array[Dictionary] = []     # enemy footprints for the minimap: {p (x, z), dir, side, t}
const STEP_SHOW := 2.2                # s a footprint stays on the minimap
var shots_heard: Array[Dictionary] = []   # an enemy's shots fired out of sight, for the minimap: {p (x, z), t}
const SHOT_SHOW := 2.0                # s a shot's mark fades over on the minimap
const STEP_BUZZ_M := 20.0             # an enemy's step this close buzzes (Game.vibrate "footsteps")
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
	_update_safe_area()
	_place_minimap(size)


## Keeps HudLayout.inset at the screen's camera cutout (checked again every second: turning the
## phone over moves the cutout to the other side without a size change).
func _update_safe_area() -> void:
	var m := UI.safe_margins(get_viewport())
	if m != HudLayout.inset:
		HudLayout.inset = m
		if minimap != null:
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
	# The ping chip in every match; chat and voice in an online one (scripts/hud_net.gd).
	HudNet.attach(self, bool(a.get("online")))
	# DUO / SQUAD: teammates, ally tags, knocked markers, REVIVE, spectating (scripts/hud_team.gd).
	if HudTeam.wanted(a):
		team = HudTeam.attach(self, a)
	feed_lines = 3 if team != null else 2


# ---------------------------------------------------------------- arena -> HUD API

func show_center(text: String, seconds: float, color := Color.WHITE, fsize := 96, sub := "") -> void:
	# During the prep the HUD draws its own block (weapon pick, then PREPARE + red countdown +
	# the match-up), so the arena's intro and countdown digits are not repeated on top of it.
	if arena != null and int(arena.get("phase")) == 0:
		return
	_center = {"text": text, "sub": sub, "t": seconds, "dur": maxf(seconds, 0.01), "col": color, "size": fsize}


## sub replaces the AREA line (the reference shows "Match Point!" there).
func show_round_banner(round_index: int, area: String, sub := "") -> void:
	_round_banner = {"t": ROUND_BANNER_TIME, "round": round_index, "area": area, "sub": sub}


## The match is decided (or a round of it decided by the time-out): `title` (VICTORY / DEFEAT /
## DRAW / TIME UP) and `sub` on the break's result band near the top, from `delay` s on (the beat:
## the kill feed and the badge first, as in a break) until the results, instead of big words over
## the middle of the screen.
func show_result(title: String, sub := "", delay := RoundRules.BREAK_RESULT_AT) -> void:
	_result = {"age": -maxf(delay, 0.0), "title": title, "sub": sub}


## The title on the result band now ("" while none shows; the checks read it).
func result_title() -> String:
	return String(_result.title) if not _result.is_empty() and float(_result.age) >= 0.0 else ""


## A rejoin into a round already running: its ROUND / AREA band is not shown (the next round's is).
func skip_round_banner() -> void:
	_round_banner.t = 0.0


## End of a round that does not end the match: the break's timed sequence (RoundRules.break_step,
## on the HUD's own clock from this call, which the arena makes as its break timer starts):
## a beat, then `title` (VICTORY / DEFEAT / DRAW) on a band near the top; then the screen dims
## under the two score plates (yours blue, theirs orange) where the winner's number (`won`: 1
## yours, -1 theirs, 0 a draw) counts up from the old score, while the top clock counts the break
## down in red; then round `next_round`'s band (`area`, or `sub`: MATCH POINT! / FINAL ROUND)
## until the prep. `mine` / `theirs` are the scores after the round. The ELIMINATED BY and
## SPECTATING cards stay on top.
func show_break(title: String, mine: int, theirs: int, won: int, next_round: int, area: String, sub := "") -> void:
	_break = {"age": 0.0, "title": title, "mine": mine, "theirs": theirs, "won": won, "round": next_round,
		"area": area, "sub": sub}
	_round_banner.t = 0.0


## The step of the break on screen ("" outside one): "beat", "result", "score", "band". The band
## stays for as long as the arena is in its break: online the guest's break ends with the host's
## word, which can come a moment after the sequence's own length.
## Whether the controls and the weapon panel are drawn: through the fight; in the break between
## rounds (round 8, like the reference) for a player still standing, and for everyone from the next
## round's band (RoundRules.BREAK_BAND_AT); never at the match's end. Taps stay ignored while the
## match is frozen (match_over).
func controls_shown() -> bool:
	if not match_over:
		return true
	if player == null or result_title() != "":
		return false
	var step := break_step()
	if step == "":
		return false
	return player.alive or step == "band"


func break_step() -> String:
	if _break.is_empty() or arena == null or int(arena.get("phase")) != 3:
		return ""
	var step := RoundRules.break_step(float(_break.age))
	return "band" if step == "done" else step


## A score plate's number now: the old score until the break's tick, then the new one
## (`mine`: this side's plate).
func break_score(mine: bool) -> int:
	var after := int(_break.mine if mine else _break.theirs)
	var gained := int(_break.won) == (1 if mine else -1)
	return RoundRules.break_score(float(_break.age), after - 1 if gained else after, after)


## The weapon pick panel (HudPanels.open_pick); a 1 vs 1 passes the guns on cooldown and the ROUNDS
## strip (who picks for each round).
func open_weapon_pick(options: Array, preselect: String, seconds: float, on_pick: Callable, cooldown := {}, strip := []) -> void:
	panels.open_pick(options, preselect, seconds, on_pick, _round(), cooldown, strip, "", _last_round())


## The side that does not pick: the same panel read-only (HudPanels.open_pick's `watch`) with
## `picker`'s name in the header; _process closes it once arena.picked_weapon is set or the prep
## is over.
func watch_weapon_pick(options: Array, seconds: float, picker: String, cooldown := {}, strip := []) -> void:
	panels.open_pick(options, "", seconds, Callable(), _round(), cooldown, strip, picker if picker != "" else "THE OTHER PLAYER", _last_round())


func _round() -> int:
	return int(arena.get("round_index")) if arena != null else 1


## The match's last round for the pick header's pair of rounds (0 against the target dummy).
func _last_round() -> int:
	if arena == null or bool(arena.get("practice")) or not arena.has_method("last_round"):
		return 0
	return int(arena.call("last_round"))


func close_weapon_pick() -> void:
	panels.close_pick()


## verb: what the line says instead of ELIMINATED / HEADSHOT ("LEFT": killer is then the one who left).
func add_kill_feed(killer: String, victim: String, weapon_name: String, weapon_icon: String, headshot: bool, mine: bool, verb := "") -> void:
	var life := FEED_LIFE if feed_lines > 2 else FEED_LIFE_SOLO
	_kill_feed.push_front({"killer": killer, "victim": victim, "weapon": weapon_name, "icon": weapon_icon,
		"head": headshot, "mine": mine, "t": life, "life": life, "verb": verb})
	while _kill_feed.size() > feed_lines:
		_kill_feed.pop_back()


## DUO / SQUAD (TeamArena): a kill feed line with each side in its colour (the player's team blue,
## the other orange); verb "KNOCKED", "REVIVED", "LEFT" or "" (ELIMINATED / HEADSHOT). REVIVED reads
## "<reviver> REVIVED <teammate>"; LEFT "<who> LEFT" (victim "").
func add_team_feed(killer: String, killer_ally: bool, victim: String, victim_ally: bool, weapon_name: String,
		weapon_icon: String, headshot: bool, mine: bool, verb := "") -> void:
	if verb == "REVIVED" or verb == "LEFT":
		weapon_name = ""              # (no gun to name)
	add_kill_feed(killer, victim, weapon_name, weapon_icon, headshot, mine, verb)
	var k: Dictionary = _kill_feed[0]
	k["kc"] = side_color(killer_ally)
	k["vc"] = side_color(victim_ally)
	k["verb_col"] = FEED_VERB_COLORS.get(verb, HudDraw.FEED_HEAD if headshot else HudDraw.FEED_ELIM)


## A name's colour in the team kill feed: the player's team blue, the other orange.
static func side_color(ally: bool) -> Color:
	return HudTeam.BLUE_TEXT if ally else HudTeam.ORANGE_TEXT


## DUO / SQUAD: the player knocked an enemy down: a KNOCKED plate (a red cross, KNOCKED and the name)
## in the elimination badge's place, calmer than a kill's.
func knock_banner(victim_name: String) -> void:
	_kill_banner = {"t": KILL_BANNER_TIME * 0.8, "name": victim_name, "head": false, "cause": "", "knock": true}


## Big elimination feedback when the player takes someone out: a red X on them and the badge.
## The badge's plate names the player (the one who made the kill, as the reference); in DUO / SQUAD
## a 2nd and 3rd kill inside one round read DOUBLE and TRIPLE (streak_word). Setting kill_badges
## off: no badge (the red X stays).
func kill_banner(victim_name: String, headshot: bool) -> void:
	var r := int(arena.get("round_index")) if arena != null and arena.get("round_index") != null else 0
	_streak = {"round": r, "n": int(_streak.n) + 1 if int(_streak.round) == r else 1}
	if bool(Game.settings.get("kill_badges", true)):
		_kill_banner = {"t": KILL_BANNER_TIME, "name": victim_name, "head": headshot, "cause": "",
			"by": player.display_name if player != null else "", "word": streak_word(int(_streak.n), team != null, headshot)}
	if arena != null:
		for f: Fighter in arena.get("fighters"):
			if f.display_name == victim_name:
				_kill_x_pos = f.chest_position()
				_kill_x_t = KILL_X_TIME


## The badge's word for the player's `n`th kill this round: DOUBLE / TRIPLE (our words) for a 2nd /
## 3rd in DUO / SQUAD, else HEADSHOT or ELIMINATED.
static func streak_word(n: int, teams: bool, headshot: bool) -> String:
	if teams and n >= 3:
		return "TRIPLE"
	if teams and n == 2:
		return "DOUBLE"
	return "HEADSHOT" if headshot else "ELIMINATED"


## The opponent went down by itself (the zone, a fall, their own frag: a cause in OUT_LINES). It is
## nobody's kill: no elimination badge and no red X, a plate in the badge's place says what took
## them out.
func out_banner(victim_name: String, cause: String) -> void:
	if OUT_LINES.has(cause):
		_kill_banner = {"t": KILL_BANNER_TIME, "name": victim_name, "head": false, "cause": cause}


## What the banner in the elimination badge's place shows now: "" none, "kill" (ELIMINATED /
## HEADSHOT) or the cause of an out_banner (the checks read it).
func banner_kind() -> String:
	if float(_kill_banner.t) <= 0.0:
		return ""
	if bool(_kill_banner.get("knock", false)):
		return "knock"
	var cause := String(_kill_banner.get("cause", ""))
	return cause if cause != "" else "kill"


func reveal(f: Fighter, seconds := 2.5) -> void:
	_reveal[f] = maxf(float(_reveal.get(f, 0.0)), seconds)


## An enemy fired (the arena's on_gunshot): out of sight, a red mark stays on the minimap where the
## shot was fired and fades over SHOT_SHOW s (never its live position); in sight its arrowhead
## shows anyway.
func shot_heard(f: Fighter) -> void:
	gun_alert(f)
	if seen.get(f, false):
		return
	shots_heard.append({"p": Vector2(f.global_position.x, f.global_position.z), "t": SHOT_SHOW})
	if shots_heard.size() > 12:
		shots_heard.pop_front()


## GUNSHOT ALERTS (round 8, setting gunshot_alerts): an enemy fired off screen within GUN_ALERT_M:
## a pale mark round the crosshair toward it for GUN_ALERT_S, fainter the further it is (none for
## a shooter on screen; the arenas call this only for the other side).
const GUN_ALERT_M := 60.0
const GUN_ALERT_S := 1.2
func gun_alert(f: Fighter) -> void:
	if player == null or f == null or f == player or not bool(Game.settings.get("gunshot_alerts", true)):
		return
	var dist := f.global_position.distance_to(player.global_position)
	if dist > GUN_ALERT_M or on_screen(f.chest_position()):
		return
	for g: Dictionary in _gun_alerts:
		if g.who == f:
			g.pos = f.global_position
			g.dist = dist
			g.t = GUN_ALERT_S
			return
	_gun_alerts.append({"who": f, "pos": f.global_position, "dist": dist, "t": GUN_ALERT_S})
	if _gun_alerts.size() > 4:
		_gun_alerts.pop_front()


## Whether a world point is in the player's view now (in front of the camera, inside the screen).
func on_screen(p: Vector3) -> bool:
	if player == null or player.camera == null or not player.camera.is_inside_tree() or player.camera.is_position_behind(p):
		return false
	return Rect2(Vector2.ZERO, size).has_point(player.camera.unproject_position(p))


## A gunshot alert's opacity: 1 close by, 0 at GUN_ALERT_M.
static func gun_alert_alpha(dist: float) -> float:
	return clampf(1.0 - dist / GUN_ALERT_M, 0.0, 1.0)


## Someone ran: a footprint where the step landed (left and right in turn), shown on the
## minimap for a moment like the reference mode's footstep marks; close by, a light buzz (the
## vibration row ENEMY FOOTSTEPS).
func footstep(f: Fighter) -> void:
	if player and f.global_position.distance_to(player.global_position) < STEP_BUZZ_M:
		Game.vibrate(15, "footsteps")
	var v := Vector2(f.velocity.x, f.velocity.z)
	var side := -1 if steps.is_empty() or int(steps[-1].side) > 0 else 1
	steps.append({"p": Vector2(f.global_position.x, f.global_position.z), "dir": v.normalized() if v.length() > 0.1 else Vector2.UP,
		"side": side, "t": STEP_SHOW})
	if steps.size() > 14:
		steps.pop_front()


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

## A shot reports its head part and its body part separately (Fighter._after_shot, head first), each
## the HP it really took: two numbers, one marker and one sound per shot.
func _on_hit_landed(target: Fighter, amount: float, headshot: bool, pos: Vector3, killed: bool) -> void:
	var tick := Engine.get_physics_frames()
	var same_shot := tick == _hit_tick
	_hit_tick = tick
	_hit_t = HIT_T
	_hit_head = headshot or (same_shot and _hit_head)
	if headshot:
		_head_icon_t = 0.7
	if Game.settings.damage_numbers:
		_add_damage_number(target, amount, headshot, pos)
	if not same_shot:
		Audio.play("hit_head" if headshot else "hit_body", -2.0 if headshot else -6.0)
	if killed:
		confirm_kill(pos if target == null else target.chest_position())


## The player's own kill (a shot or a frag; online the other phone reports it as its death): the
## red X there, the kill sound and a short buzz.
func confirm_kill(pos: Vector3) -> void:
	_kill_x_pos = pos
	_kill_x_t = KILL_X_TIME
	Audio.play("kill_confirm", 0.0)
	Game.vibrate(60, "shooting")


## Damage numbers like the reference's: small bold yellow digits up and left of the target's
## head, one number per burst: a hit on the same target within DMG_MERGE s of the newest number's
## last hit adds to it (it pops again with the sum) while that number is younger than
## DMG_MERGE_MAX; else a new number with a small random spread (at most +-DMG_SPREAD u), overlap
## allowed. A number rises DMG_RISE m/s and goes DMG_LIFE s after its last hit.
const DMG_MERGE := 0.3
const DMG_MERGE_MAX := 1.0
const DMG_RISE := 0.25
const DMG_SPREAD := 0.04
const DMG_HEAD_WARM := Color(1.0, 0.6, 0.16)
func _add_damage_number(target: Fighter, amount: float, headshot: bool, pos: Vector3) -> void:
	if target != null:
		for i in range(_dmg_numbers.size() - 1, -1, -1):
			var o: Dictionary = _dmg_numbers[i]
			if o.target != target:
				continue
			if float(o.last) < DMG_MERGE and float(o.t) < DMG_MERGE_MAX:
				o.amount = float(o.amount) + amount
				o.head = bool(o.head) or headshot
				o.last = 0.0
				return
			break
	var jit := Vector2.ZERO
	for o: Dictionary in _dmg_numbers:
		if o.target == target:
			jit = Vector2(randf_range(-DMG_SPREAD, DMG_SPREAD), randf_range(-DMG_SPREAD, DMG_SPREAD) * 0.5)
			break
	_dmg_numbers.append({"pos": pos, "amount": amount, "head": headshot, "t": 0.0, "last": 0.0, "target": target, "off": jit})
	if _dmg_numbers.size() > 8:
		_dmg_numbers.pop_front()


## Font size of a damage number: 0.032u .. 0.05u growing a little with the damage, heads x1.15.
func _dmg_size(amount: float, head: bool, u: float) -> int:
	return int(clampf((0.032 + amount * 0.00015) * u, 0.032 * u, 0.05 * u) * (1.15 if head else 1.0))


## The 3D point a damage number hangs from: over the target's head (rising), else the hit point.
func _dmg_anchor3(n: Dictionary) -> Vector3:
	var tg: Variant = n.target
	var p3: Vector3 = n.pos
	if tg is Fighter and is_instance_valid(tg) and (tg as Fighter).is_inside_tree():
		p3 = (tg as Fighter).head_position() + Vector3.UP * 0.22
	return p3 + Vector3.UP * minf(float(n.t), DMG_MERGE_MAX) * DMG_RISE


## A number's place on screen relative to its head point, in px: up-left plus its spread.
static func dmg_offset(n: Dictionary, u: float) -> Vector2:
	return Vector2(-0.03 * u, 0.0) + (n.off as Vector2) * u


## Screen centre of a damage number now.
func _dmg_point(n: Dictionary, u: float) -> Vector2:
	return player.camera.unproject_position(_dmg_anchor3(n)) + dmg_offset(n, u)


## Screen rect of a damage number now; min_digits keeps room for a number that may still grow.
func _dmg_rect(n: Dictionary, u: float, min_digits := 1) -> Rect2:
	var fs := _dmg_size(float(n.amount), bool(n.head), u)
	var txt := str(maxi(roundi(float(n.amount)), 1)).lpad(min_digits, "8")
	var w := UI.font("number").get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var c := _dmg_point(n, u)
	return Rect2(c - Vector2(w * 0.5 + 0.004 * u, fs * 0.42), Vector2(w + 0.008 * u, fs * 0.84))


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
		if randf() < 0.3:             # (a grunt now and then, never on every hit)
			Audio.play("grunt_%d" % (randi() % 3 + 1), -8.0, randf_range(0.94, 1.06))
	Game.vibrate(35, "damage")


# ---------------------------------------------------------------- touch input

func _input(event: InputEvent) -> void:
	if editor_mode or player == null or not is_visible_in_tree():
		return              # (hidden under the in-match menu or the results: online the tree runs on)
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
	if _spec_friend_rect.has_area() and _spec_friend_rect.grow(6).has_point(pos):
		spectate_add_friend()
		_touches[index] = {"kind": "ui", "id": "friend"}
		return
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
	if team != null and not player.alive and id != "settings":
		id = ""                 # out of a team round: the controls are hidden
	if id != "":
		_press(id, index)
		if _touches.has(index) and String(_touches[index].kind) == "fire":     # (settings releases all)
			_touches[index]["start"] = pos
			_touches[index]["pos"] = pos
		return
	if _joy_touch == -1 and _in_joy_zone(pos, vs):
		_start_joystick(index, pos, vs)
		return
	_touches[index] = {"kind": "look", "id": ""}


## Topmost control under the finger ("" = none): as drawn, the round buttons over the weapon panel
## (the gear first, it sits on the panel's corner); overlapping buttons: the closest centre wins.
func _widget_at(pos: Vector2, vs: Vector2) -> String:
	var gear: Dictionary = layout.settings
	if pos.distance_to(HudLayout.center(gear, vs)) <= HudLayout.touch_radius(gear, vs) * 1.15:
		return "settings"
	var best := ""
	var best_d := INF
	for id: String in HudLayout.ORDER:
		if HudLayout.kind(id) != "button" or not _button_visible(id):
			continue
		var w: Dictionary = layout[id]
		var r := HudLayout.touch_radius(w, vs)
		var d := pos.distance_to(HudLayout.center(w, vs)) / maxf(r, 1.0)
		if d <= 1.15 and d < best_d:
			best = id
			best_d = d
	if best != "":
		return best
	var panel: Dictionary = layout.weapons
	if HudLayout.weapon_main(panel, vs).grow(4).has_point(pos):
		return "weapons:main"
	var slots := HudLayout.weapon_slots(panel, vs)
	for i in 3:
		if slots[i].grow(4).has_point(pos):
			return "weapons:%d" % i
	if _can_repick() and HudLayout.weapon_repick(panel, vs).grow(4).has_point(pos):
		return "weapons:repick"
	return ""


func _button_visible(id: String) -> bool:
	if editor_mode:
		return true
	if not button_enabled(id):
		return false
	match id:
		"sprint":
			return int(Game.settings.get("run_mode", 2)) != 1
		"fire_l":
			# setting Left fire button: always, or only while aiming down a sight
			return int(Game.settings.get("left_fire", 0)) == 0 or (player != null and player.ads)
	return true


## Whether the settings show a button at all (CONTROLS: the left fire button, RELOAD, SWITCH and free
## look can be turned off; the editor still shows and places them, marked OFF).
static func button_enabled(id: String) -> bool:
	match id:
		"fire_l":
			return int(Game.settings.get("left_fire", 0)) != LEFT_FIRE_OFF
		"reload":
			return bool(Game.settings.get("reload_button", true))
		"swap":
			return bool(Game.settings.get("switch_button", true))
		"freelook":
			return bool(Game.settings.get("freelook_button", true))
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
		"medkit":
			_cancel_auto_sprint()
			player.use_medkit()
		"wall":
			player.use_shield()
		"grenade":
			player.use_grenade()
		"freelook":
			_touches[index] = {"kind": "free", "id": id}
			player.start_free_look()
		"reload":
			if not Weapons.is_melee(player.weapon().def):         # grey with the fists out: nothing to reload
				player.do_reload()
		"swap":
			player.select_weapon(player.next_weapon())      # gun -> sidearm -> fists -> gun
		"settings":
			release_all()
			pause_pressed.emit()
		"weapons:main":
			if not Weapons.is_melee(player.weapon().def):
				player.do_reload()
			else:
				player.select_weapon(Weapons.GUN)
		"weapons:0", "weapons:1", "weapons:2":
			# The small slots in SWITCH's order: the gun, the sidearm, the fists.
			player.select_weapon(Weapons.CYCLE[int(id.substr(8))])
		"weapons:repick":
			release_all()
			arena.call("repick")


func _on_drag(index: int, pos: Vector2, rel: Vector2) -> void:
	if not _touches.has(index):
		return
	match String(_touches[index].kind):
		"joy":
			var jr := _joy_radius(size)
			_joy_vec = (pos - _joy_center) / jr
			# Floating stick: the base follows a finger that runs far past the ring.
			if bool(Game.settings.get("dynamic_joystick", false)) and _joy_vec.length() > 1.6:
				_joy_center = pos - _joy_vec.normalized() * jr * 1.6
				_joy_vec = (pos - _joy_center) / jr
		"look":
			player.add_look(rel, false)
		"free":
			player.add_free_look(rel)
		"fire":
			_touches[index]["pos"] = pos
			if String(_touches[index].id) == "fire_r":
				player.add_look(rel, true)


## A held FIRE button moves with the finger like a joystick knob, as in the reference mode:
## in the drag's direction, at most FIRE_TRAVEL x its radius from home (the camera keeps
## following the whole drag), and it springs back when it is let go.
func _fire_center(id: String, home: Vector2, r: float, vs: Vector2) -> Vector2:
	for k in _touches:
		var t: Dictionary = _touches[k]
		if String(t.kind) == "fire" and String(t.id) == id and t.has("pos"):
			var c: Vector2 = home + ((t.pos as Vector2) - (t.start as Vector2)).limit_length(r * FIRE_TRAVEL)
			return Vector2(clampf(c.x, r, vs.x - r), clampf(c.y, r, vs.y - r))
	return home


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
		"free":
			player.end_free_look()
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
	if bool(Game.settings.get("dynamic_joystick", false)):
		return pos.x < vs.x * JOY_ZONE_X and pos.y > vs.y * 0.34
	return pos.distance_to(HudLayout.center(w, vs)) < HudLayout.radius(w, vs) * 1.4


func _joy_radius(vs: Vector2) -> float:
	return HudLayout.radius(layout.joystick, vs)


func _start_joystick(index: int, pos: Vector2, vs: Vector2) -> void:
	var r := _joy_radius(vs)
	_joy_touch = index
	if bool(Game.settings.get("dynamic_joystick", false)):
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
	if floorf(_time + real) != floorf(_time):
		_update_safe_area()
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
		_hp_lag = minf(_hp_lag, player.hp_max)
		if _hp_lag <= player.hp:
			_hp_lag = player.hp
		elif _lag_hold <= 0.0:
			_hp_lag = maxf(player.hp, _hp_lag - player.hp_max * 0.6 * real)
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
	if not _break.is_empty():
		_break.age = float(_break.age) + real
		if arena == null or int(arena.get("phase")) != 3:
			_break = {}                  # (the prep began: the host's "round" may end it early)
	if not _result.is_empty():
		_result.age = float(_result.age) + real
	_kill_banner.t = maxf(float(_kill_banner.t) - real, 0.0)
	tips_time = maxf(tips_time - real, 0.0)
	for n in _dmg_numbers:
		n.t += real
		n.last += real
	_dmg_numbers = _dmg_numbers.filter(func(n: Dictionary) -> bool: return float(n.last) < DMG_LIFE)
	for d in _dmg_dirs:
		d.t -= real
	_dmg_dirs = _dmg_dirs.filter(func(d: Dictionary) -> bool: return float(d.t) > 0.0)
	for g in _gun_alerts:
		g.t -= real
	_gun_alerts = _gun_alerts.filter(func(g: Dictionary) -> bool: return float(g.t) > 0.0)
	for k in _kill_feed:
		k.t -= real
	_kill_feed = _kill_feed.filter(func(k: Dictionary) -> bool: return float(k.t) > 0.0)
	for f in _reveal.keys():
		_reveal[f] -= delta
		if _reveal[f] <= 0.0:
			_reveal.erase(f)
	for st in steps:
		st.t = float(st.t) - delta
	steps = steps.filter(func(st: Dictionary) -> bool: return float(st.t) > 0.0)
	for sh in shots_heard:
		sh.t = float(sh.t) - delta
	shots_heard = shots_heard.filter(func(sh: Dictionary) -> bool: return float(sh.t) > 0.0)
	_vis_t -= real
	if _vis_t <= 0.0:
		_vis_t = 0.1
		_update_seen()
	if real > 0.0:
		_fps_smooth = lerpf(_fps_smooth, 1.0 / real, 0.05)
	panels.tick(delta, real)
	if panels.watching() and arena != null and (String(arena.get("picked_weapon")) != "" or int(arena.get("phase")) != 0):
		panels.close_pick()              # the pick watched arrived (or the prep is over)
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


## Online: "<NAME> RECONNECTING..." over every fighter whose player is AWAY (RemoteFighter.away:
## frozen until it is back), at the top of the screen while it is behind the camera; this phone's
## own "RECONNECTING..." while it rejoins its match (Cloud.rejoining).
func _draw_away(vs: Vector2, u: float) -> void:
	if arena == null or not ("fighters" in arena) or player == null or player.camera == null:
		return
	var f := UI.font("bold")
	var fs := int(0.034 * u)
	var top := vs.y * 0.2
	var lines: Array[String] = []
	if bool(arena.get("online")) and Game.session != null and Game.session.rejoining():
		lines.append("RECONNECTING...")
	for x: Variant in arena.fighters:
		var r := x as RemoteFighter
		if r == null or not r.away or not r.alive:
			continue
		var txt := "%s RECONNECTING..." % r.display_name
		var head := r.global_position + Vector3.UP * 2.3
		if player.camera.is_position_behind(head):
			lines.append(txt)
			continue
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var at := player.camera.unproject_position(head) - Vector2(w * 0.5, 0.0)
		draw_string_outline(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, fs / 6), Color(0, 0, 0, 0.8))
		draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.85, 0.3))
	for txt in lines:
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var at := Vector2((vs.x - w) * 0.5, top)
		draw_string_outline(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, fs / 6), Color(0, 0, 0, 0.8))
		draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.85, 0.3))
		top += fs * 1.3


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
	_draw_away(vs, u)
	if alive:
		if player.ready_item != "":
			_draw_item_aim(c, u)
		elif not scoped and not player.is_free_looking():
			_draw_crosshair(c, u)
		_draw_heal(c, u)
	_draw_kill_x(u)
	_draw_damage_numbers(u)
	if controls_shown():
		# The panel first: a button the player put over it stays in sight (and takes the taps there,
		# see _widget_at); the gear sits on the panel's corner. DUO / SQUAD: out of the round (the
		# camera on a teammate) only the gear stays.
		if team == null or player.alive or match_over:
			_draw_weapon_panel(vs)
			_draw_controls(vs)
		_draw_button("settings", vs)
	if hp_subject() != null:
		_draw_hp_block(vs, u)          # (out of the round: no HP 0/200; spectating: the watched fighter's)
	_draw_kill_feed(vs, u)
	_draw_score_bar(vs, u)
	if team != null:
		_draw_zone_strip(vs)       # (DUO / SQUAD only: the 1 vs 1's minimap has no zone strip)
	_draw_zone_banner(vs, u)
	_draw_prep(vs, u)
	_draw_break(vs, u)
	_draw_match_result(vs, u)
	_draw_round_banner(vs, u)
	_draw_kill_banner(vs, u)
	_draw_spectating(vs, u)
	_draw_eliminated_by(vs, u)
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
		if _button_visible(id) and id != "settings":
			_draw_button(id, vs)


## The scope button's small zoom label for a gun's sight: red dot 1X, 2x scope 2X, sniper 8X; none
## without a sight (iron sights, fists).
static func zoom_label(def: Dictionary) -> String:
	return String({"reddot": "1X", "2x": "2X", "sniper": "8X"}.get(Player.sight_of(def), ""))


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
			"medkit":
				count = player.medkits
				act = player.healing
				en = player.medkits > 0
			"wall":
				count = player.shields
				en = player.shields > 0
				act = player.ready_item == "wall"
			"grenade":
				count = player.grenades
				en = player.grenades > 0
				act = player.ready_item == "grenade"
			"reload":
				var g := _panel_weapon()
				act = g.reloading
				en = g == player.weapon() and (g.reloading or g.can_reload())    # grey: full, no reserve, fists out
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
	if (id == "fire_r" or id == "fire_l") and not editor_mode:
		if id == "fire_r":
			c = _fire_center(id, c, r, vs)
		if player != null and player.ready_item != "":
			glyph = _glyph(player.ready_item)   # a wall or grenade in hand: FIRE uses it
		elif player != null and Weapons.is_melee(player.weapon().def):
			glyph = HudDraw.tex("v_fist")       # fists out: the fire buttons punch
	var gscale := float(GLYPH_SCALE.get(id, 0.6))
	if id == "swap" and player != null and not editor_mode and player.next_weapon() != Weapons.FISTS:
		glyph = HudDraw.weapon_tex(player.weapons[player.next_weapon()].def)      # what it draws next (a fist: the fists)
		gscale = 0.62
	if id == "fire_r":
		_draw_fire_halo(c, r, o, pressed)
	HudDraw.button(self, c, r, glyph, o, pressed, act, en, gscale)
	if count >= 0:
		HudDraw.count_badge(self, c, r, count, o)
	if id == "scope" and player != null and not editor_mode:
		var zl := zoom_label(player.weapon().def)
		if zl != "":
			HudDraw.text(self, zl, c + Vector2(0, r * 0.98), maxi(int(r * 0.42), 10), Color(1, 1, 1, 0.92 * o), 1, 3, "number")
	if id == "medkit" and act and player != null:
		HudDraw.ring(self, c, r + 2.0, Color(HudDraw.GOLD, 0.95 * o), 3.0, player.heal_progress())
	if id == "reload" and act and player != null:
		HudDraw.ring(self, c, r + 2.0, Color(HudDraw.YELLOW, 0.95 * o), 3.0, _panel_weapon().reload_progress())
	if id == "swap" or (id == "reload" and not act):
		# SWITCH: two arrows chasing each other (it trades the hand's slot); RELOAD: one round the
		# magazine (while it reloads, the gold progress ring takes its place)
		var mark := Color(1, 1, 1, (0.85 if en else 0.38) * o)
		if id == "swap":
			_draw_cycle_arrows(c, r, mark, 2, 80.0)
		else:
			_draw_cycle_arrows(c, r, mark, 1, 285.0)


## `n` arrows evenly spread round a button's rim, each an arc of `span` degrees, clockwise.
func _draw_cycle_arrows(c: Vector2, r: float, col: Color, n: int, span: float) -> void:
	var rr := r * 0.78
	var lw := maxf(1.5, r * 0.07)
	var hs := r * 0.17
	for k in n:
		var a0 := deg_to_rad(-150.0) + TAU * k / n
		var a1 := a0 + deg_to_rad(span)
		draw_arc(c, rr, a0, a1, maxi(8, int(span / 8.0)), col, lw, true)
		var tip := c + Vector2.from_angle(a1) * rr
		var along := Vector2.from_angle(a1 + PI * 0.5)
		var out := Vector2.from_angle(a1)
		draw_colored_polygon(PackedVector2Array([tip + along * hs, tip - along * hs * 0.3 + out * hs * 0.65,
			tip - along * hs * 0.3 - out * hs * 0.65]), col)


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
	var gun_sel := true                 # a gun (the round's or the sidearm) in hand: the main slot lit
	var held := Weapons.GUN
	if player != null and not editor_mode:
		var g := _panel_weapon()
		def = g.def
		ammo = g.ammo
		reserve = g.reserve
		reloading = g.reloading
		progress = g.reload_progress()
		held = player.current
		gun_sel = g == player.weapon()
	var dim := 1.0 if gun_sel else 0.55
	var pressed := _pressed.has("weapons:main")
	# Near-black slots at ~70 % (the reference), the main one with its top-right corner cut.
	HudDraw.slot_rect(self, main, s * 0.2, Color(HudDraw.SLOT_BG, (0.86 if pressed else 0.76) * o))
	HudDraw.vband(self, Rect2(main.position, Vector2(main.size.x - s * 0.2, main.size.y * 0.4)), Color(1, 1, 1, 0.05 * o), Color(1, 1, 1, 0.0))
	var picking := weapon_picking()
	if picking != "":
		_draw_picking_slots(main, slots, s, o, picking)
		return
	# Ammo: big magazine number + small "/reserve".
	var ax := main.position.x + s * 0.16
	var ay := main.position.y + s * 0.38
	var mag_col := Color(1, 1, 1, 0.98 * dim * o) if ammo > 0 else Color(1.0, 0.36, 0.3, o)
	var aw := HudDraw.text(self, str(ammo), Vector2(ax, ay), int(s * 0.56), mag_col, 0, 2, "number")
	HudDraw.text(self, "/%d" % reserve, Vector2(ax + aw + s * 0.02, ay + s * 0.08), int(s * 0.3), Color(1, 1, 1, 0.85 * dim * o), 0, 2, "number")
	var status := "RELOAD" if gun_sel else "TAP TO SWITCH"
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
	# Small slots in SWITCH's order (Weapons.CYCLE): the gun, the sidearm (each with its rounds
	# left, magazine and reserve), the fists; the one in hand lit gold.
	for i in 3:
		var r := slots[i]
		var wi: int = Weapons.CYCLE[i]
		var sel := wi == held
		var sp := _pressed.has("weapons:%d" % i)
		draw_rect(r, Color(HudDraw.SLOT_BG, (0.86 if sp else 0.76) * o))
		if sel:
			HudDraw.vband(self, r, Color(HudDraw.GOLD, 0.7 * o), Color(HudDraw.GOLD.darkened(0.3), 0.62 * o))
			draw_rect(Rect2(r.position.x, r.end.y - 2.0, r.size.x, 2.0), Color(1, 0.93, 0.6, o))
		if wi == Weapons.FISTS:
			HudDraw.icon(self, HudDraw.tex("v_fist"), r.get_center() + Vector2(0, -s * 0.1), Vector2(r.size.y, r.size.y) * 0.5,
				Color(1, 1, 1, (1.0 if sel else 0.8) * o))
			_infinity(r.get_center() + Vector2(0, r.size.y * 0.3), s * 0.13, Color(1, 1, 1, 0.9 * o))
			continue
		var sd: Dictionary = Weapons.DEFS[Weapons.SIDEARM] if wi == Weapons.SIDE else Weapons.DEFS[Weapons.DEFAULT_PICK]
		var left := int(sd.mag) + int(sd.reserve)
		if player != null and not editor_mode and player.weapons.size() > wi:
			var ws: WeaponState = player.weapons[wi]
			sd = ws.def
			left = ws.ammo + ws.reserve
		HudDraw.icon(self, HudDraw.weapon_tex(sd), r.get_center() + Vector2(0, -s * 0.08), Vector2(r.size.x * (0.8 if wi == Weapons.GUN else 0.62), r.size.y * 0.5),
			Color(1, 1, 1, (1.0 if sel else 0.75) * o))
		HudDraw.text(self, str(left), Vector2(r.position.x + s * 0.08, r.end.y - s * 0.17), int(s * 0.25),
			Color(1, 1, 1, 0.92 * o) if left > 0 else Color(1.0, 0.36, 0.3, o), 0, 2, "number")
	if _can_repick():
		# The target dummy: CHANGE GUN beside the small slots opens the weapon pick again.
		var rp := HudLayout.weapon_repick(w, vs)
		draw_rect(rp, Color(HudDraw.SLOT_BG, (0.86 if _pressed.has("weapons:repick") else 0.76) * o))
		draw_rect(Rect2(rp.position.x, rp.end.y - 2.0, rp.size.x, 2.0), Color(HudDraw.YELLOW, 0.9 * o))
		HudDraw.text(self, "CHANGE GUN", rp.get_center(), int(s * 0.19), Color(1, 1, 1, 0.92 * o), 1, 2, "bold")


## The weapon the panel's main slot (and RELOAD) is about: the gun or the sidearm in hand, else
## (the fists out) the round's gun.
func _panel_weapon() -> WeaponState:
	var w := player.weapon()
	return player.gun() if Weapons.is_melee(w.def) else w


## The weapon panel while the round's gun is being picked (Fighter.awaiting_pick): "" when it is
## not, "picking" while the other side picks (or nothing is chosen yet), else the gun id this
## player's open pick panel has chosen (drawn dimmed until it is applied).
func weapon_picking() -> String:
	if player == null or editor_mode or not player.awaiting_pick:
		return ""
	if panels.pick_open and not panels.watching() and Weapons.DEFS.has(panels.pick_choice):
		return panels.pick_choice
	return "picking"


## The main slot in its picking state: no ammo, "PICKING..." (the chosen gun's silhouette dimmed
## for the picker), the gun's and the sidearm's small slots empty (the sidearm comes with the
## gun), the fists held.
func _draw_picking_slots(main: Rect2, slots: Array[Rect2], s: float, o: float, picking: String) -> void:
	var ax := main.position.x + s * 0.16
	HudDraw.text(self, "--", Vector2(ax, main.position.y + s * 0.38), int(s * 0.5), Color(1, 1, 1, 0.4 * o), 0, 2, "number")
	var dots := ".".repeat(1 + int(_time * 2.0) % 3)
	HudDraw.text(self, "PICKING" + dots, Vector2(ax, main.position.y + s * 0.76), int(s * 0.23), Color(HudDraw.YELLOW, 0.9 * o), 0, 2, "bold")
	if picking != "picking":
		HudDraw.icon(self, HudDraw.weapon_tex(Weapons.DEFS[picking]), Vector2(main.end.x - main.size.x * 0.3, main.position.y + s * 0.44),
			Vector2(main.size.x * 0.5, s * 0.66), Color(1, 1, 1, 0.32 * o))
	var ul := Rect2(main.position.x + s * 0.12, main.end.y - s * 0.09, main.size.x - s * 0.24, maxf(2.0, s * 0.035))
	draw_rect(ul, Color(1, 1, 1, 0.22 * o))
	for i in 3:
		var r := slots[i]
		draw_rect(r, Color(HudDraw.SLOT_BG, 0.76 * o))
		if Weapons.CYCLE[i] == Weapons.FISTS:
			HudDraw.vband(self, r, Color(HudDraw.GOLD, 0.7 * o), Color(HudDraw.GOLD.darkened(0.3), 0.62 * o))
			draw_rect(Rect2(r.position.x, r.end.y - 2.0, r.size.x, 2.0), Color(1, 0.93, 0.6, o))
			HudDraw.icon(self, HudDraw.tex("v_fist"), r.get_center() + Vector2(0, -s * 0.1), Vector2(r.size.y, r.size.y) * 0.5, Color(1, 1, 1, o))
			_infinity(r.get_center() + Vector2(0, r.size.y * 0.3), s * 0.13, Color(1, 1, 1, 0.9 * o))


## TRAINING GROUND's target dummy lets the gun be changed during the fight (Arena.repick).
func _can_repick() -> bool:
	return not editor_mode and arena != null and bool(arena.get("practice")) and arena.has_method("repick")


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


## A wall or grenade in hand: a small centre dot instead of the crosshair; for the grenade a
## dotted arc to where it would land and a ring there (the wall's preview stands in the world).
func _draw_item_aim(c: Vector2, u: float) -> void:
	draw_circle(c, maxf(0.0045 * u, 1.5), Color(1, 1, 1, 0.9))
	if player.ready_item != "grenade":
		return
	var cam := player.camera
	var arc := player.grenade_arc()
	var dot := maxf(0.0055 * u, 1.8)
	for i in range(2, arc.size() - 1, 2):
		if not cam.is_position_behind(arc[i]):
			draw_circle(cam.unproject_position(arc[i]), dot, Color(1, 1, 1, 0.45 + 0.5 * float(i) / arc.size()))
	var land := arc[arc.size() - 1]
	var nrm := player.arc_normal
	var t1 := nrm.cross(Vector3.RIGHT if absf(nrm.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := nrm.cross(t1)
	var ring := PackedVector2Array()
	for k in 33:
		var q := land + nrm * 0.04 + (t1 * cos(TAU * k / 32.0) + t2 * sin(TAU * k / 32.0)) * 0.9
		if cam.is_position_behind(q):
			return
		ring.append(cam.unproject_position(q))
	draw_polyline(ring, Color(1.0, 0.4, 0.3, 0.95), maxf(0.0045 * u, 1.5), true)
	draw_circle(cam.unproject_position(land), dot * 1.3, Color(1.0, 0.4, 0.3, 0.95))


func _draw_crosshair(c: Vector2, u: float) -> void:
	var w := player.weapon()
	var on := player.crosshair_on_target
	var hit := _hit_t > 0.0
	var col := Color(1.0, 0.16, 0.13) if (on or hit) else Game.crosshair_color()
	var sc := Game.crosshair_scale()
	var dyn := bool(Game.settings.dynamic_crosshair)
	var outline := Color(0, 0, 0, 0.45)
	var shade := Color(0, 0, 0, 0.3)          # soft shadow under the thin lines
	var ring_col := Color(col, col.a * 0.92)
	var ring_r := 0.0
	var reload_ring := w.reloading and bool(Game.settings.get("reload_on_crosshair", true))
	if player.ads and player.scope_type() == "reddot":
		ring_r = _draw_red_dot(c, u, sc, on or hit)
	else:
		# The reference's crosshairs: a thin circle about 7 % of the screen high with a small dot
		# (the shotgun's is fixed with four short ticks outside it, the rifles' widen with the
		# spray), a small circle for the fists.
		match String(w.def.get("crosshair", "ring")):
			"dot":
				HudDraw.disk(self, c, 2.8 * sc, outline)
				HudDraw.disk(self, c, 1.9 * sc, col)
				ring_r = 0.0175 * u * sc
				if Weapons.is_melee(w.def):
					HudDraw.ring(self, c, ring_r, shade, 2.8)
					HudDraw.ring(self, c, ring_r, ring_col, 1.3)
			"wide":
				ring_r = 0.035 * u * sc
				if not reload_ring:
					HudDraw.ring(self, c, ring_r, shade, 3.0)
					HudDraw.ring(self, c, ring_r, ring_col, 1.4)
					for k in 4:
						var d := Vector2.UP.rotated(k * PI * 0.5)
						draw_line(c + d * (ring_r + 2.0), c + d * (ring_r + 2.0 + 0.009 * u * sc), shade, 3.0, true)
						draw_line(c + d * (ring_r + 2.0), c + d * (ring_r + 2.0 + 0.009 * u * sc), ring_col, 1.4, true)
				HudDraw.disk(self, c, 2.6 * sc, outline)
				HudDraw.disk(self, c, 1.7 * sc, col)
			_:
				# widens with the real spread (moving, jumping, a long spray)
				ring_r = clampf(maxf(0.028 * u, _spread_px() if dyn else 0.0), 0.026 * u, 0.06 * u) * sc
				if not reload_ring:
					HudDraw.ring(self, c, ring_r, shade, 3.0)
					HudDraw.ring(self, c, ring_r, ring_col, 1.4)
				HudDraw.disk(self, c, 2.6 * sc, outline)
				HudDraw.disk(self, c, 1.7 * sc, col)
	# Reload progress on the crosshair (setting), with a small magazine mark at the upper right.
	if reload_ring:
		var rr := maxf(ring_r, 0.03 * u)
		HudDraw.ring(self, c, rr, Color(0, 0, 0, 0.4), 4.4)
		HudDraw.ring(self, c, rr, Color(1, 1, 1, 0.25), 2.4)
		HudDraw.ring(self, c, rr, Color(1, 1, 1, 0.95), 2.4, w.reload_progress())
		var mp := c + Vector2(1, -1).normalized() * (rr + 0.022 * u)
		HudDraw.icon(self, HudDraw.tex("v_mag"), mp, Vector2(0.026, 0.026) * u, Color(1, 1, 1, 0.95))
	# Hit marker (round 8): the crosshair blooms into a large orange ring (about 1/16 of the
	# screen width across) with an orange centre dot, out in HIT_BLOOM s and fading (a headshot
	# redder and a little larger), faint white ticks inside it; setting hit_ring off: the
	# short diagonal ticks alone.
	if hit:
		var age := HIT_T - _hit_t
		var ha := clampf(_hit_t / HIT_T, 0.0, 1.0)
		var r0 := maxf(ring_r, 10.0) + 4.0
		if bool(Game.settings.get("hit_ring", true)):
			var big := hit_bloom_radius(size, _hit_head)
			var grow := 1.0 - pow(1.0 - clampf(age / HIT_BLOOM, 0.0, 1.0), 2.0)
			var rr := lerpf(r0, big, grow)
			var oc := Color(1.0, 0.22, 0.12) if _hit_head else Color(1.0, 0.52, 0.12)
			HudDraw.ring(self, c, rr, Color(0, 0, 0, 0.35 * ha), 5.0)
			HudDraw.ring(self, c, rr, Color(oc, 0.95 * ha), 2.6)
			HudDraw.disk(self, c, 3.6 * sc, Color(0, 0, 0, 0.4 * ha))
			HudDraw.disk(self, c, 2.6 * sc, Color(oc, ha))
			for k in 4:
				var d := Vector2(1, 1).normalized().rotated(k * PI * 0.5)
				draw_line(c + d * rr * 0.55, c + d * rr * 0.8, Color(1, 1, 1, 0.35 * ha), 1.6, true)
		else:
			var hc := Color(1.0, 0.36, 0.2, ha) if _hit_head else Color(1, 1, 1, ha)
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


## The hit ring's full radius on `vs`: 1/16 of the width across (a headshot 15 % larger).
static func hit_bloom_radius(vs: Vector2, head: bool) -> float:
	return vs.x * 0.0625 * 0.5 * (1.15 if head else 1.0)


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
		low = clampf(1.0 - player.hp / (player.hp_max * 0.35), 0.0, 1.0)
	var pulse := low * (0.26 + 0.12 * sin(_time * 6.5))
	var vig := maxf(_flash, pulse)
	if vig > 0.01:
		_edge_glow(vs, Color(0.85, 0.04, 0.04, vig), vs.y * 0.24)
	if _zone_hurt > 0.0:
		_draw_zone_splats(vs, clampf(_zone_hurt / 0.6, 0.0, 1.0))


## Zone damage (round 8, like the reference): red splats round the four screen edges (our own splat
## sprite, v_splat) over a faint red edge glow; they fade in the 0.6 s after the last zone hit.
const ZONE_SPLATS := [
	[0.06, 0.1, 0.2, 0.3], [0.32, 0.02, 0.14, 1.9], [0.7, 0.03, 0.16, 4.0], [0.95, 0.12, 0.19, 2.6],
	[0.02, 0.5, 0.17, 5.1], [0.98, 0.55, 0.16, 0.9], [0.08, 0.93, 0.19, 3.3], [0.4, 0.99, 0.13, 5.8],
	[0.63, 0.98, 0.15, 1.2], [0.93, 0.92, 0.2, 2.2],
]
func _draw_zone_splats(vs: Vector2, a: float) -> void:
	_edge_glow(vs, Color(0.8, 0.05, 0.04, 0.16 * a), vs.y * 0.12)
	var t := HudDraw.tex("v_splat")
	if t == null:
		return
	var u := HudLayout.unit(vs)
	for sp: Array in ZONE_SPLATS:
		var c := Vector2(float(sp[0]) * vs.x, float(sp[1]) * vs.y)
		var sz := float(sp[2]) * u * (1.0 + 0.06 * sin(_time * 3.0 + float(sp[3])))
		draw_set_transform(c, float(sp[3]))
		HudDraw.icon(self, t, Vector2.ZERO, Vector2(sz, sz), Color(0.78, 0.04, 0.03, 0.62 * a))
	draw_set_transform(Vector2.ZERO)


func _edge_glow(vs: Vector2, col: Color, t: float) -> void:
	var clear := Color(col, 0.0)
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(vs.x, 0), Vector2(vs.x, t), Vector2(0, t)]), PackedColorArray([col, col, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, vs.y - t), Vector2(vs.x, vs.y - t), Vector2(vs.x, vs.y), Vector2(0, vs.y)]), PackedColorArray([clear, clear, col, col]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(t, 0), Vector2(t, vs.y), Vector2(0, vs.y)]), PackedColorArray([col, clear, clear, col]))
	draw_polygon(PackedVector2Array([Vector2(vs.x - t, 0), Vector2(vs.x, 0), Vector2(vs.x, vs.y), Vector2(vs.x - t, vs.y)]), PackedColorArray([clear, col, col, clear]))


func _draw_damage_dirs(c: Vector2, u: float) -> void:
	if player.camera == null or (_dmg_dirs.is_empty() and _gun_alerts.is_empty()):
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
	# Gunshot alerts: a paler orange arc further out with a small muzzle-flash glyph on it.
	for g in _gun_alerts:
		var to: Vector3 = (g.pos as Vector3) - player.global_position
		to.y = 0.0
		if to.length() < 0.1:
			continue
		to = to.normalized()
		var ang := atan2(to.dot(right), to.dot(fwd)) - PI * 0.5
		var a := clampf(float(g.t) / 0.3, 0.0, 1.0) * gun_alert_alpha(float(g.dist))
		var r := 0.26 * u
		var col := Color(1.0, 0.62, 0.35)
		draw_arc(c, r, ang - 0.22, ang + 0.22, 16, Color(col, 0.75 * a), 0.008 * u, true)
		var m := c + Vector2.from_angle(ang) * (r + 0.03 * u)
		var d := Vector2.from_angle(ang)
		var sd := d.orthogonal()
		var k := 0.016 * u
		draw_colored_polygon(PackedVector2Array([m + d * k * 1.3, m + sd * k * 0.55, m - d * k * 0.5, m - sd * k * 0.55]), Color(col, 0.9 * a))
		draw_circle(m - d * k * 0.2, k * 0.3, Color(1, 0.95, 0.8, a), true, -1.0, true)


func _draw_damage_numbers(u: float) -> void:
	if player.camera == null:
		return
	var f := UI.font("number")
	for n in _dmg_numbers:
		var last := float(n.last)
		if player.camera.is_position_behind(_dmg_anchor3(n)):
			continue
		var sp := _dmg_point(n, u)
		var head := bool(n.head)
		var amount := float(n.amount)
		var a := clampf(1.0 - (last - (DMG_LIFE - 0.25)) / 0.25, 0.0, 1.0)
		var pop := 1.0 + clampf(0.1 - last, 0.0, 0.1) * 3.0          # pops when it appears or grows
		var fs := int(_dmg_size(amount, head, u) * pop)
		var col := DMG_HEAD_WARM if head else HudDraw.DMG_BODY
		var txt := str(maxi(roundi(amount), 1))
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		# Bold italic: skew the glyphs to the right around their centre.
		draw_set_transform_matrix(Transform2D(0.0, Vector2.ONE, -0.22, sp))
		var base := Vector2(-w * 0.5, (f.get_ascent(fs) - f.get_descent(fs)) * 0.5)
		draw_string_outline(f, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, fs / 7), Color(0.05, 0.02, 0.0, 0.85 * a))
		draw_string(f, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, a))
	draw_set_transform_matrix(Transform2D.IDENTITY)


## The red X on an eliminated enemy (a kill marker, short and small).
func _draw_kill_x(u: float) -> void:
	if _kill_x_t <= 0.0 or player.camera == null or player.camera.is_position_behind(_kill_x_pos):
		return
	var p := player.camera.unproject_position(_kill_x_pos)
	var age := KILL_X_TIME - _kill_x_t
	var a := clampf(_kill_x_t / 0.25, 0.0, 1.0)
	var k := (0.055 * u) * (1.0 + 0.2 * clampf(1.0 - age / 0.1, 0.0, 1.0))
	var wd := 0.012 * u
	for d in [Vector2(1, 1), Vector2(1, -1)]:
		var v: Vector2 = d.normalized() * k
		draw_line(p - v, p + v, Color(0, 0, 0, 0.55 * a), wd + 4.0, true)
		draw_line(p - v, p + v, Color(HudDraw.KILL_RED, a), wd, true)


# ---------------------------------------------------------------- HP, kill feed

func _bottom_limits(vs: Vector2, u: float) -> Vector2:
	var lo := 0.0
	var hi := vs.x
	for id in ["medkit", "grenade", "crouch", "prone", "wall"]:
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


## Whose health the HP block shows: the player while alive; out of the 1 vs 1 round, the fighter
## the camera follows (its HP, like the reference); else nobody (no HP 0/200 over the ELIMINATED
## BY card, also not in the round break).
func hp_subject() -> Fighter:
	if player == null or editor_mode:
		return player
	if player.alive:
		return player
	if team == null:
		return player.spectating_now()
	return null


## The player's full health: a room's HP rule (Fighter.hp_max), else Fighter.MAX_HP.
func _hp_full() -> float:
	var f := hp_subject()
	if f != null:
		return f.hp_max
	return player.hp_max if player != null else Fighter.MAX_HP


## The HP block's label, "HP 200/200" (a room's HP 100: "HP 100/100").
func hp_label() -> String:
	var f := hp_subject()
	var hp := f.hp if f != null and not editor_mode else _hp_full()
	return "HP %d/%d" % [ceili(hp), int(_hp_full())]


## The HP block's geometry on `vs`: font size fs, icon size isz, x0 (left edge of the first
## armour icon), fixed (icons + label width), bar_w, stacked. Inline like the reference:
## [helmet][vest] HP 200/200 [bar], measured on the widest label so the bar does not shift while
## the number changes. Short of room (16:9 between the medkit and grenade buttons) the block
## shifts between the bottom buttons; only a very narrow gap puts the label above the bar.
func hp_geometry(vs: Vector2, u: float) -> Dictionary:
	var mx := _hp_full()
	var lim := _bottom_limits(vs, u)
	var avail := lim.y - lim.x
	var fs := int(0.019 * u)
	var isz := 0.04 * u
	var lw := HudDraw.text_width("HP %d/%d" % [int(mx), int(mx)], fs, "semi")
	var icons_w := isz * 2.0 + 0.008 * u
	var fixed := icons_w + 0.014 * u + lw + 0.012 * u
	var bar_w := minf(0.38 * u, avail - fixed)
	var stacked := bar_w < 0.13 * u
	if stacked:
		fixed = icons_w + 0.014 * u
		bar_w = clampf(avail - fixed, 0.14 * u, 0.38 * u)
	# The bar sits on the screen centre when there is room, else the block shifts between limits.
	var x0 := clampf(vs.x * 0.5 - bar_w * 0.5 - fixed, lim.x, maxf(lim.y - fixed - bar_w, lim.x))
	return {"fs": fs, "isz": isz, "x0": x0, "fixed": fixed, "bar_w": bar_w, "stacked": stacked}


func _draw_hp_block(vs: Vector2, u: float) -> void:
	var f := hp_subject()
	var mx := _hp_full()
	var hp := mx
	var healing_rem := 0.0
	var lag_hp := _hp_lag
	if f != null and not editor_mode:
		hp = f.hp
		if f != player:
			lag_hp = hp
		if f.healing:
			healing_rem = minf(Fighter.HEAL_RATE * minf(f.heal_left, Fighter.HEAL_AMOUNT / Fighter.HEAL_RATE), mx - hp)
	var g := hp_geometry(vs, u)
	var by := vs.y * 0.948              # (the reference's height, a little over the bottom edge)
	var bh := maxf(4.0, 0.0105 * u)
	var label := hp_label()
	var fs := int(g.fs)
	var isz := float(g.isz)
	var x0 := float(g.x0)
	var bar_w := float(g.bar_w)
	var bar := Rect2(x0 + float(g.fixed), by - bh * 0.5, bar_w, bh)
	draw_rect(bar.grow(1.0), Color(0, 0, 0, 0.5))
	var frac := clampf(hp / mx, 0.0, 1.0)
	var lag := clampf(lag_hp / mx, 0.0, 1.0)
	if lag > frac:
		draw_rect(Rect2(bar.position + Vector2(bar_w * frac, 0), Vector2(bar_w * (lag - frac), bh)), Color(0.95, 0.25, 0.2, 0.85))
	var fill := HudDraw.HP_WHITE if frac > 0.3 else Color(1.0, 0.45, 0.4)
	draw_rect(Rect2(bar.position, Vector2(bar_w * frac, bh)), fill)
	if healing_rem > 0.0:
		draw_rect(Rect2(bar.position + Vector2(bar_w * frac, 0), Vector2(bar_w * healing_rem / mx, bh)), Color(HudDraw.HEAL_GREEN, 0.85 + 0.15 * sin(_time * 8.0)))
	if bool(g.stacked):
		HudDraw.text(self, label, Vector2(bar.position.x, by - bh - 0.02 * u), int(fs * 0.9), Color(1, 1, 1, 0.95), 0, 3, "semi")
	else:
		HudDraw.text(self, label, Vector2(bar.position.x - 0.012 * u, by), fs, Color(1, 1, 1, 0.95), 2, 3, "semi")
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
		var a := clampf(t / 0.5, 0.0, 1.0) * clampf((float(k.get("life", FEED_LIFE)) - t) / 0.15, 0.0, 1.0)
		var head := bool(k.head)
		var parts := [[String(k.killer) + "  ", k.get("kc", Color(1, 1, 1) if not bool(k.mine) else Color(0.75, 0.9, 1.0))],
			[(String(k.get("verb", "")) if String(k.get("verb", "")) != "" else ("HEADSHOT" if head else "ELIMINATED")) + "  ",
				k.get("verb_col", HudDraw.FEED_HEAD if head else HudDraw.FEED_ELIM)],
			[String(k.victim), k.get("vc", Color(1, 1, 1))]]
		if String(k.weapon) != "":
			parts.append(["  (%s)" % String(k.weapon), Color(1, 1, 1, 0.82)])
		var tw := HudDraw.parts_width(parts, fs)
		var solo := feed_lines <= 2
		var y := vs.y * (solo_feed_y(i, mini(_kill_feed.size(), feed_lines)) if solo else float(FEED_Y[i]))
		if solo:
			_draw_feed_line(parts, tw, String(k.get("icon", "")), y, fs, a)
			continue
		# A dark plate keeps the line readable over the white shirt, the yellow pads and the floor.
		draw_rect(Rect2(vs.x * 0.5 - tw * 0.5 - fs * 0.6, y - fs * 0.72, tw + fs * 1.2, fs * 1.44), Color(0.03, 0.03, 0.04, 0.5 * a))
		HudDraw.text_parts(self, parts, Vector2(vs.x * 0.5, y), fs, 1, 3, "bold", a)


## The 1 vs 1's feed line `i` (0 = newest) of `n` on screen, as a fraction of the height: one line
## at FEED_Y_SOLO; with two, the older stays there and the newer stacks under it (FEED_Y_SOLO2).
static func solo_feed_y(i: int, n: int) -> float:
	if n <= 1:
		return FEED_Y_SOLO
	return FEED_Y_SOLO2 if i == 0 else FEED_Y_SOLO


## The 1 vs 1's kill feed line, centred: the gun's (or the frag's) silhouette, then the text,
## on a soft highlight that fades out to both sides (darkest under the line, none at its ends).
func _draw_feed_line(parts: Array, tw: float, icon_name: String, y: float, fs: int, a: float) -> void:
	var t := HudDraw.tex(icon_name) if icon_name != "" else null
	var isz := Vector2(fs * 2.4, fs * 1.05)
	var iw := isz.x + fs * 0.55 if t != null else 0.0
	var cx := size.x * 0.5
	var x0 := cx - (tw + iw) * 0.5
	var half := (tw + iw) * 0.5 + fs * 3.0
	var top := y - fs * 0.85
	var bot := y + fs * 0.85
	var mid := Color(0.02, 0.02, 0.03, 0.58 * a)
	var edge := Color(mid, 0.0)
	for side: float in [-1.0, 1.0]:
		var outer := cx + side * half
		var inner := cx + side * (half - fs * 3.0)
		draw_polygon(PackedVector2Array([Vector2(inner, top), Vector2(outer, top), Vector2(outer, bot), Vector2(inner, bot)]),
			PackedColorArray([mid, edge, edge, mid]))
	draw_rect(Rect2(cx - (half - fs * 3.0), top, (half - fs * 3.0) * 2.0, bot - top), mid)
	draw_line(Vector2(cx - half * 0.8, top), Vector2(cx + half * 0.8, top), Color(1, 1, 1, 0.12 * a), 1.0)
	if t != null:     # (a dark shadow under the white silhouette: readable over the white shirt too)
		HudDraw.icon(self, t, Vector2(x0 + isz.x * 0.5 + 1.5, y + 1.5), isz, Color(0, 0, 0, 0.7 * a))
		HudDraw.icon(self, t, Vector2(x0 + isz.x * 0.5, y), isz, Color(1, 1, 1, 0.92 * a))
	HudDraw.text_parts(self, parts, Vector2(x0 + iw + tw * 0.5, y), fs, 1, 3, "bold", a)


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
		if break_step() != "":
			mine = break_score(true)           # (the plates' tick moves these too)
			theirs = break_score(false)
		# The fight's clock counts each stage down on its own (RoundRules): 00:20 to 00:00, then
		# stage 2 from its full length; red in the prep and the last 10 s of a stage.
		if phase == 0:
			t = float(arena.get("prep_left"))
		elif break_step() != "":
			t = maxf(RoundRules.BREAK_S - float(_break.age), 0.0)      # the break counts down, red
			phase = 0
		elif bool(arena.get("practice")):
			t = float(arena.get("time_left"))
		else:
			t = float(arena.call("stage_left"))
		red = phase == 0 or (t <= 10.0 and not bool(arena.get("practice")))
		if player != null:
			hp_me = clampf(player.hp / player.hp_max, 0.0, 1.0)
		var b: Variant = arena.get("bot")
		if b is Fighter:
			hp_bot = clampf((b as Fighter).hp / (b as Fighter).hp_max, 0.0, 1.0)
		if team != null:
			# DUO / SQUAD: each bar is the team's HP still standing (knocked and out count 0)
			hp_me = team.team_hp(team.my_team())
			hp_bot = team.team_hp(1 - team.my_team())
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


## The zone strip under the minimap (SAFE ZONE STATIONARY / SHRINKING m:ss / CLOSED): drawn in a
## DUO / SQUAD and in the HUD editor's preview; the 1 vs 1 shows none (its space stays reserved,
## the FPS line sits under it).
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
	if arena != null and not editor_mode and bool(arena.get("practice")):
		parts = [["TRAINING", HudDraw.YELLOW], ["  NO ZONE", Color.WHITE]]
		closed = true
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
	if team != null:
		_draw_team_matchup(vs, u)
	elif player != null and b is Fighter:
		# The match-up on a dark plate: readable over the bright, red-tinted alcove.
		var parts := [[player.display_name, Color(0.62, 0.86, 1.0)], ["   VS   ", Color(1, 1, 1, 0.85)],
			[(b as Fighter).display_name, Color(1.0, 0.72, 0.52)]]
		var mfs := int(0.032 * u)
		var mw := HudDraw.parts_width(parts, mfs)
		var my := vs.y * 0.415
		HudDraw.plate(self, Rect2(cx - mw * 0.5 - 0.09 * u, my - 0.032 * u, mw + 0.18 * u, 0.064 * u), 0.62)
		HudDraw.text_parts(self, parts, Vector2(cx, my), mfs, 1, 3, "bold")
	var note := String(arena.get("pick_note"))
	if note != "":
		HudDraw.text(self, note, Vector2(cx, vs.y * 0.49), int(0.03 * u), Color(1.0, 0.86, 0.35), 1, 3, "bold")


## DUO / SQUAD prep: "BLUE: A, B  VS  ORANGE: C, D" on a dark plate (two lines when one would not
## fit the screen).
func _draw_team_matchup(vs: Vector2, u: float) -> void:
	var lines := team_matchup_lines()
	var blue: Array = lines[0]
	var orange: Array = lines[1]
	var mfs := int(0.03 * u)
	var one := blue + [["   VS   ", Color(1, 1, 1, 0.85)]] + orange
	var room := vs.x * 0.92
	var cx := vs.x * 0.5
	var my := vs.y * 0.415
	if HudDraw.parts_width(one, mfs) <= room:
		var mw := HudDraw.parts_width(one, mfs)
		HudDraw.plate(self, Rect2(cx - mw * 0.5 - 0.06 * u, my - 0.03 * u, mw + 0.12 * u, 0.06 * u), 0.62)
		HudDraw.text_parts(self, one, Vector2(cx, my), mfs, 1, 3, "bold")
		return
	var two := [blue, [["VS   ", Color(1, 1, 1, 0.85)]] + orange]
	var w := maxf(HudDraw.parts_width(two[0], mfs), HudDraw.parts_width(two[1], mfs))
	if w > room:
		mfs = maxi(10, int(mfs * room / w))
		w = room
	HudDraw.plate(self, Rect2(cx - w * 0.5 - 0.05 * u, my - 0.035 * u, w + 0.1 * u, 0.1 * u), 0.62)
	HudDraw.text_parts(self, two[0], Vector2(cx, my - 0.005 * u), mfs, 1, 3, "bold")
	HudDraw.text_parts(self, two[1], Vector2(cx, my + 0.04 * u), mfs, 1, 3, "bold")


## The prep line's two halves as text parts: [["BLUE: ", col], ["A, B", col]] and the same for ORANGE.
func team_matchup_lines() -> Array:
	var out := []
	for side in 2:
		var t: int = team.my_team() if side == 0 else 1 - team.my_team()
		var names := PackedStringArray()
		for f: Fighter in team.members(t):
			names.append(f.display_name.to_upper())
		out.append([["BLUE: " if side == 0 else "ORANGE: ", HudDraw.BLUE if side == 0 else HudDraw.ORANGE],
			[", ".join(names), HudTeam.BLUE_TEXT if side == 0 else HudTeam.ORANGE_TEXT]])
	return out


## "ROUND n / AREA: name" on a band fading from blue (left) to orange (right).
## Eliminated and following the killer's view: SPECTATING and their name at the bottom right
## (the controls are hidden then; the kill feed keeps the bottom centre), with a small row of what
## this player still carried when eliminated (walls, frags, medkits: Player.kit_at_death) and,
## in an internet match against the player watched (Arena.watched_player_id), ADD FRIEND: the same
## friend request as the results', greyed as REQUEST SENT once sent and FRIENDS when they already
## are (spectate_friend_state). DUO / SQUAD: HudTeam draws it, with NEXT.
func _draw_spectating(vs: Vector2, u: float) -> void:
	_spec_friend_rect = Rect2()
	if team != null:
		return
	var who := player.spectating_now() if player != null else null
	if who == null:
		return
	var nm := who.display_name.to_upper()
	var fs := int(0.03 * u)
	var lfs := int(0.022 * u)
	var kit: Dictionary = player.kit_at_death
	var friend := spectate_friend_state(who)
	var w := maxf(maxf(HudDraw.text_width(nm, fs, "bold"), HudDraw.text_width("SPECTATING", lfs, "bold")) + 0.12 * u,
		0.36 * u if not kit.is_empty() or friend != "" else 0.0)
	var h := 0.085 * u + (0.05 * u if not kit.is_empty() else 0.0) + (0.075 * u if friend != "" else 0.0)
	var c := Vector2(vs.x - w * 0.5 - 0.06 * u, vs.y * 0.8)
	var top := minf(c.y - 0.04 * u, vs.y - 0.02 * u - h)
	HudDraw.plate(self, Rect2(c.x - w * 0.5, top, w, h), 0.7)
	HudDraw.text(self, "SPECTATING", Vector2(c.x, top + 0.025 * u), lfs, HudDraw.YELLOW, 1, 2, "bold")
	HudDraw.text(self, nm, Vector2(c.x, top + 0.062 * u), fs, Color.WHITE, 1, 2, "bold")
	var y := top + 0.085 * u
	if not kit.is_empty():
		# [wall] n   [frag] n   [medkit] n, centred under the name
		var items := [["v_wall", int(kit.get("walls", 0))], ["item_grenade", int(kit.get("frags", 0))], ["v_medkit", int(kit.get("medkits", 0))]]
		var step := 0.1 * u
		var x0 := c.x - step * (items.size() - 1) * 0.5
		var iy := y + 0.024 * u
		for i in items.size():
			var ix := x0 + step * i
			var n := int(items[i][1])
			var col := Color(1, 1, 1, 0.92) if n > 0 else Color(1, 1, 1, 0.35)
			HudDraw.icon(self, HudDraw.tex(String(items[i][0])), Vector2(ix - 0.018 * u, iy), Vector2(0.034, 0.034) * u, col)
			HudDraw.text(self, "x%d" % n, Vector2(ix + 0.004 * u, iy), int(0.02 * u), col, 0, 2, "bold")
		y += 0.05 * u
	if friend != "":
		var br := Rect2(c.x - w * 0.5 + 0.03 * u, y + 0.008 * u, w - 0.06 * u, 0.06 * u)
		var on := friend == "add"
		draw_rect(br, Color(UI.ACCENT, 0.95) if on else Color(0.3, 0.3, 0.32, 0.75))
		var caption := String({"add": "ADD FRIEND", "sent": "REQUEST SENT", "friends": "FRIENDS"}.get(friend, ""))
		HudDraw.text(self, caption, br.get_center(), int(0.024 * u), UI.INK if on else Color(1, 1, 1, 0.6), 1, 0, "bold")
		if on:
			_spec_friend_rect = br


## ADD FRIEND on the SPECTATING card for the player watched (`who`): "add" (can be sent), "sent"
## (a request is waiting), "friends" (they already are), or "" (no button: a bot, a match without
## internet, a blocked player).
func spectate_friend_state(who: Fighter) -> String:
	if arena == null or not arena.has_method("watched_player_id") or who == null:
		return ""
	var id := String(arena.call("watched_player_id", who))
	if id == "" or Game.is_blocked(id):
		return ""
	if Game.is_friend(id):
		return "friends"
	return "sent" if Game.cloud_service().friend_asked(id) else "add"


## A tap on the SPECTATING card's ADD FRIEND: the friend request goes to the player watched.
func spectate_add_friend() -> bool:
	var who := player.spectating_now() if player != null else null
	if spectate_friend_state(who) != "add":
		return false
	var ok := Game.cloud_service().request_friend(String(arena.call("watched_player_id", who)))
	queue_redraw()
	return ok


## The 1 vs 1 player is out of the round: a small card at the bottom left while it spectates (the
## controls are hidden then): "ELIMINATED BY <NAME>" over a row with the killer's name, the gun
## (its silhouette and name) and the damage that player dealt this one this round; the zone, a fall
## or the player's own frag read "ELIMINATED BY THE ZONE" / "... A FALL" / "... YOUR OWN FRAG".
func _draw_eliminated_by(vs: Vector2, u: float) -> void:
	if team != null or arena == null or player == null or player.alive or int(arena.get("phase")) < 2:
		return
	var e: Dictionary = arena.get("eliminated_by")
	if e.is_empty():
		return
	var cause := String(e.get("cause", ""))
	var by_name := String(e.get("name", "")).to_upper()
	var what := String({"zone": "THE ZONE", "fall": "A FALL", "self": "YOUR OWN FRAG", "left": "LEAVING"}.get(cause, by_name))
	var line := String({"zone": "OUTSIDE THE SAFE ZONE TOO LONG", "fall": "A DROP FROM THE HIGH GROUND",
		"self": "STAY CLEAR OF YOUR OWN FRAG", "left": ""}.get(cause, ""))
	# The card ends 0.01u before the HP block's first armour icon on every screen shape (16:9: the
	# block sits right of the medkit), its contents scaled down to that width.
	var r := death_card_rect(vs, u)
	var k := clampf(r.size.x / (0.56 * u), 0.6, 1.0)
	var fs := int(0.026 * u * k)
	var h := r.size.y
	HudDraw.plate(self, r, 0.78)
	draw_rect(Rect2(r.position, Vector2(0.008 * u, r.size.y)), HudDraw.RED)
	var tx := r.position.x + 0.03 * u * k
	var ty := r.position.y + 0.035 * u
	HudDraw.text_parts(self, [["ELIMINATED BY ", Color(0.78, 0.8, 0.84)], [what, Color(1.0, 0.5, 0.45)]],
		Vector2(tx, ty), fs, 0, 2, "bold")
	draw_line(Vector2(tx, ty + 0.025 * u), Vector2(r.end.x - 0.03 * u * k, ty + 0.025 * u), Color(1, 1, 1, 0.14), 1.0)
	var ry := r.position.y + h * 0.68
	if cause in ["gun", "frag"]:
		var nfs := int(0.028 * u * k)
		var nm := by_name
		var nw := minf(HudDraw.text_width(nm, nfs, "bold"), 0.17 * u * k)
		HudDraw.text(self, nm, Vector2(tx, ry), _fit_fs(nm, nfs, 0.17 * u * k), Color.WHITE, 0, 2, "bold")
		var gx := tx + nw + 0.03 * u * k
		var gid := String(e.get("gun_id", ""))
		var t: Texture2D = HudDraw.tex("item_grenade") if cause == "frag" else HudDraw.weapon_tex(Weapons.DEFS.get(gid, Weapons.DEFS[Weapons.DEFAULT_PICK]))
		HudDraw.icon(self, t, Vector2(gx + 0.04 * u * k, ry), Vector2(0.08, 0.04) * u * k, Color(1, 1, 1, 0.92))
		HudDraw.text(self, String(e.get("gun", "")), Vector2(gx + 0.09 * u * k, ry), int(0.022 * u * k), Color(0.78, 0.8, 0.84), 0, 2, "semi")
		HudDraw.text_parts(self, [["DMG ", Color(0.78, 0.8, 0.84)], [str(int(e.get("damage", 0))), HudDraw.YELLOW]],
			Vector2(r.end.x - 0.03 * u * k, ry), nfs, 2, 2, "bold")
	elif line != "":
		HudDraw.text(self, line, Vector2(tx, ry), _fit_fs(line, int(0.022 * u * k), r.size.x - 0.05 * u * k), Color(0.78, 0.8, 0.84), 0, 2, "semi")


## The ELIMINATED BY card's rectangle: bottom left, at most 0.56u wide and ending at least 0.01u
## before the HP block's first armour icon (the block may show the watched fighter's HP).
func death_card_rect(vs: Vector2, u: float) -> Rect2:
	var x := 0.03 * u
	var right := minf(x + 0.56 * u, float(hp_geometry(vs, u).x0) - 0.01 * u)
	var h := 0.13 * u
	return Rect2(x, vs.y - h - 0.035 * u, maxf(right - x, 0.2 * u), h)


## Font size for `t`: `px`, smaller when the text would be wider than `room`.
func _fit_fs(t: String, px: int, room: float) -> int:
	var w := HudDraw.text_width(t, px, "bold")
	return maxi(9, int(px * minf(1.0, room / maxf(w, 1.0))))


func _draw_round_banner(vs: Vector2, u: float) -> void:
	var t := float(_round_banner.t)
	if t <= 0.0:
		return
	var age := float(_round_banner.get("dur", ROUND_BANNER_TIME)) - t
	_draw_round_band(vs, u, int(_round_banner.round), String(_round_banner.area), String(_round_banner.get("sub", "")), age, t)


## "ROUND n / AREA: name" (or the sub-line: MATCH POINT! / FINAL ROUND) on a band fading from blue
## (left) to orange (right), `age` s after it came and `left` s before it goes (it slides in and
## fades out).
func _draw_round_band(vs: Vector2, u: float, round_n: int, area: String, sub: String, age: float, left: float) -> void:
	var a := clampf(age / 0.18, 0.0, 1.0) * clampf(left / 0.4, 0.0, 1.0)
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
	HudDraw.text_parts(self, [["ROUND ", Color.WHITE], [str(round_n), HudDraw.YELLOW]], tc, int(0.078 * u), 1, 3, "bold", a)
	if sub != "":
		HudDraw.text(self, sub, Vector2(xm, y0 + h * 0.8), int(0.032 * u), Color(HudDraw.YELLOW, a), 1, 2, "bold")
	else:
		HudDraw.text_parts(self, [["AREA: ", Color(1, 1, 1, 0.95)], [area, HudDraw.YELLOW]],
			Vector2(xm, y0 + h * 0.8), int(0.03 * u), 1, 2, "bold", a)


## The break between rounds, step by step (show_break): the result band near the top, the dimmed
## screen with the score plates, the next round's band.
func _draw_break(vs: Vector2, u: float) -> void:
	var step := break_step()
	var age := float(_break.age) if step != "" else 0.0
	match step:
		"result":
			_draw_result_band(vs, u, String(_break.title), "ROUND %d" % (int(_break.round) - 1), age - RoundRules.BREAK_RESULT_AT,
				RoundRules.BREAK_SCORE_AT - age)
		"score":
			_draw_break_score(vs, u, age - RoundRules.BREAK_SCORE_AT, RoundRules.BREAK_BAND_AT - age)
		"band":
			_draw_round_band(vs, u, int(_break.round), String(_break.area), String(_break.sub),
				age - RoundRules.BREAK_BAND_AT, RoundRules.BREAK_S - age + 0.3)


## Whether the match's end shows a win (VICTORY!: its longer sequence, RoundRules.match_end_step).
func result_won() -> bool:
	return not _result.is_empty() and String(_result.title).begins_with("VICTORY")


## The match's end (round 8): the result band (show_result); a win then turns into a big glowing
## gold VICTORY! across the middle with sparks, and the band moves to the top with the split score
## band under it until the results cover it (RoundRules.match_end_step).
func _draw_match_result(vs: Vector2, u: float) -> void:
	if result_title() == "":
		return
	var age := float(_result.age)
	var title := String(_result.title)
	var sub := String(_result.sub).to_upper()
	var t := age + RoundRules.MATCH_BAND_AT
	match RoundRules.match_end_step(t, result_won()):
		"band", "results":
			if not result_won():
				_draw_result_band(vs, u, title, sub, age, 99.0)
			else:
				_draw_result_band(vs, u, title, sub, age, RoundRules.VICTORY_WORD_AT - t)
		"word":
			_draw_victory_word(vs, u, t - RoundRules.VICTORY_WORD_AT)
		"top":
			_draw_victory_top(vs, u, t - RoundRules.VICTORY_TOP_AT)


## The big gold VICTORY! across the middle, `t` s into its RoundRules.VICTORY_WORD_S: it pops in,
## glows and throws sparks, then fades as the band takes the top.
func _draw_victory_word(vs: Vector2, u: float, t: float) -> void:
	var a := clampf(t / 0.15, 0.0, 1.0) * clampf((RoundRules.VICTORY_WORD_S - t) / 0.25, 0.0, 1.0)
	var c := Vector2(vs.x * 0.5, vs.y * 0.5)
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0, 0, 0, 0.35 * a))
	var pop := 1.0 + 0.25 * (1.0 - clampf(t / 0.25, 0.0, 1.0))
	var fs := int(0.2 * u * pop)
	var gold := Color(1.0, 0.8, 0.22)
	for i in 3:
		var g := 1.0 - i * 0.3
		HudDraw.text(self, "VICTORY!", c, fs, Color(1.0, 0.65, 0.1, 0.12 * a * g), 1, int(0.03 * u * (i + 1)), "heavy", Color(1.0, 0.6, 0.1, 1.0))
	HudDraw.text(self, "VICTORY!", c, fs, Color(gold, a), 1, 5, "heavy", Color(0.35, 0.18, 0.0, 0.9 * a))
	var shine := clampf((t - 0.2) / 0.6, 0.0, 1.0)
	if shine > 0.0 and shine < 1.0:
		var w := HudDraw.text_width("VICTORY!", fs, "heavy")
		var x := c.x - w * 0.5 + w * shine
		draw_line(Vector2(x - fs * 0.25, c.y + fs * 0.4), Vector2(x + fs * 0.25, c.y - fs * 0.4), Color(1, 1, 0.9, 0.55 * a), fs * 0.08, true)
	_draw_sparks(c + Vector2(-0.3 * u, 0), t, 0.3 * u, gold, a)
	_draw_sparks(c + Vector2(0.3 * u, 0), t - 0.15, 0.3 * u, gold, a)
	_draw_sparks(c, t - 0.4, 0.45 * u, Color(1, 0.95, 0.7), a)


## After the big word: the VICTORY! band slid up to the top with the split score band under it.
func _draw_victory_top(vs: Vector2, u: float, t: float) -> void:
	var k := clampf(t / 0.35, 0.0, 1.0)
	var a := clampf(t / 0.2, 0.0, 1.0)
	var cy := lerpf(vs.y * 0.5, vs.y * 0.12, 1.0 - pow(1.0 - k, 3.0))
	HudDraw.text(self, "VICTORY!", Vector2(vs.x * 0.5, cy), int(0.09 * u), Color(1.0, 0.8, 0.22, a), 1, 4, "heavy", Color(0.35, 0.18, 0.0, 0.9 * a))
	var sc: Dictionary = arena.get("score") if arena != null else {}
	_draw_split_score(vs, u, cy + 0.14 * u, a, int(sc.get("player", 0)), int(sc.get("bot", 0)), 0, -1.0)


## VICTORY (yellow) / DEFEAT (grey) / DRAW, TIME UP (white) on a dark band at y 0.15 that fades at
## both ends, `sub` ("ROUND n", or the match's end line) under the word; it fades in, no pop.
func _draw_result_band(vs: Vector2, u: float, title: String, sub: String, age: float, left: float) -> void:
	var a := clampf(age / 0.25, 0.0, 1.0) * clampf(left / 0.35, 0.0, 1.0)
	var col: Color = HudDraw.YELLOW if title.begins_with("VICTORY") else (Color(0.8, 0.82, 0.85) if title == "DEFEAT" else Color.WHITE)
	var cy := vs.y * 0.15
	var h := 0.12 * u
	var w := minf(vs.x * 0.7, 1.4 * u)
	var x0 := (vs.x - w) * 0.5
	var fade := w * 0.3
	var bg := Color(0.03, 0.04, 0.06, 0.72 * a)
	var y0 := cy - h * 0.5
	draw_polygon(PackedVector2Array([Vector2(x0, y0), Vector2(x0 + fade, y0), Vector2(x0 + fade, y0 + h), Vector2(x0, y0 + h)]),
		PackedColorArray([Color(bg, 0.0), bg, bg, Color(bg, 0.0)]))
	draw_rect(Rect2(x0 + fade, y0, w - fade * 2.0, h), bg)
	draw_polygon(PackedVector2Array([Vector2(x0 + w - fade, y0), Vector2(x0 + w, y0), Vector2(x0 + w, y0 + h), Vector2(x0 + w - fade, y0 + h)]),
		PackedColorArray([bg, Color(bg, 0.0), Color(bg, 0.0), bg]))
	var line := Color(col, 0.55 * a)
	draw_line(Vector2(x0 + fade * 0.5, y0), Vector2(x0 + w - fade * 0.5, y0), line, 1.5)
	draw_line(Vector2(x0 + fade * 0.5, y0 + h), Vector2(x0 + w - fade * 0.5, y0 + h), line, 1.5)
	HudDraw.text(self, title, Vector2(vs.x * 0.5, cy - h * 0.1), int(0.075 * u), Color(col, a), 1, 4, "title")
	if sub != "":
		HudDraw.text(self, sub, Vector2(vs.x * 0.5, cy + h * 0.34), _fit_fs(sub, int(0.024 * u), w * 0.6),
			Color(1, 1, 1, 0.8 * a), 1, 2, "bold")


## The break's score step (round 8, like the reference): the screen dimmed near black, one wide
## split band (x 0.12-0.93 of the width: yours blue on the left, theirs orange on the right) with
## both numbers by our centre glyph, the names at its ends and the round's result over it; the
## number that changed flashes with a burst of sparks at the tick (RoundRules.BREAK_TICK_AT).
func _draw_break_score(vs: Vector2, u: float, age: float, left: float) -> void:
	var a := clampf(age / 0.3, 0.0, 1.0) * clampf(left / 0.3, 0.0, 1.0)
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0, 0, 0, 0.92 * a))
	var tick := float(_break.age) - RoundRules.BREAK_TICK_AT
	var flash := 0 if tick < 0.0 else int(_break.won)
	_draw_split_score(vs, u, vs.y * 0.5, a, break_score(true), break_score(false), flash, tick)
	var title := String(_break.title)
	HudDraw.text(self, title, Vector2(vs.x * 0.5, vs.y * 0.5 - 0.15 * u), int(0.05 * u),
		Color(HudDraw.YELLOW if title.begins_with("VICTORY") else Color(0.86, 0.88, 0.9), a), 1, 3, "heavy")


## The split score band centred at height `cy`: blue (yours) | orange (theirs), the numbers by the
## centre glyph, the names at the ends. `flash` 1: your number flashes and sparks (-1 theirs, 0
## none), `tick` s after the change.
func split_band_rect(vs: Vector2, u: float, cy: float) -> Rect2:
	var h := 0.14 * u
	return Rect2(vs.x * 0.12, cy - h * 0.5, vs.x * 0.81, h)


func _draw_split_score(vs: Vector2, u: float, cy: float, a: float, mine: int, theirs: int, flash: int, tick: float) -> void:
	var r := split_band_rect(vs, u, cy)
	var cx := vs.x * 0.5
	var fade := r.size.x * 0.12
	var blue := Color(HudDraw.BLUE, 0.92 * a)
	var orange := Color(HudDraw.ORANGE, 0.92 * a)
	draw_polygon(PackedVector2Array([r.position, Vector2(r.position.x + fade, r.position.y), Vector2(r.position.x + fade, r.end.y), Vector2(r.position.x, r.end.y)]),
		PackedColorArray([Color(blue, 0.0), blue, blue, Color(blue, 0.0)]))
	draw_rect(Rect2(r.position.x + fade, r.position.y, cx - r.position.x - fade, r.size.y), blue)
	draw_rect(Rect2(cx, r.position.y, r.end.x - fade - cx, r.size.y), orange)
	draw_polygon(PackedVector2Array([Vector2(r.end.x - fade, r.position.y), Vector2(r.end.x, r.position.y), Vector2(r.end.x, r.end.y), Vector2(r.end.x - fade, r.end.y)]),
		PackedColorArray([orange, Color(orange, 0.0), Color(orange, 0.0), orange]))
	draw_rect(Rect2(r.position.x + fade, r.position.y, r.size.x - fade * 2.0, r.size.y * 0.4), Color(1, 1, 1, 0.1 * a))
	# Our centre glyph: a dark diamond with a white rim and three claw marks.
	var g := r.size.y * 0.62
	var dia := PackedVector2Array([Vector2(cx, cy - g), Vector2(cx + g * 0.8, cy), Vector2(cx, cy + g), Vector2(cx - g * 0.8, cy)])
	draw_colored_polygon(dia, Color(0.06, 0.07, 0.09, 0.95 * a))
	dia.append(dia[0])
	draw_polyline(dia, Color(1, 1, 1, 0.85 * a), maxf(2.0, 0.004 * u), true)
	for k in 3:
		var dx := (k - 1) * g * 0.22
		draw_line(Vector2(cx + dx + g * 0.1, cy - g * 0.38), Vector2(cx + dx - g * 0.1, cy + g * 0.38), Color(1, 1, 1, 0.9 * a), maxf(2.0, 0.005 * u), true)
	var names := ["YOUR TEAM", "THE OTHER TEAM"] if team != null else [player.display_name if player != null else "YOU", _their_name()]
	for side in 2:
		var mine_side := side == 0
		var sgn := -1.0 if mine_side else 1.0
		var nc := Vector2(cx + sgn * (g * 0.8 + 0.07 * u), cy)
		var lit := flash == (1 if mine_side else -1) and tick >= 0.0
		var pop := 1.0 + (0.35 * (1.0 - clampf(tick / 0.35, 0.0, 1.0)) if lit else 0.0)
		var col := Color.WHITE
		if lit and tick < 0.6:
			col = Color.WHITE.lerp(HudDraw.YELLOW, 0.5 + 0.5 * sin(tick * 30.0))
		HudDraw.text(self, str(mine if mine_side else theirs), nc, int(0.11 * u * pop), Color(col, a), 1, 4, "number")
		if lit:
			_draw_sparks(nc, tick, 0.12 * u, HudDraw.YELLOW, a)
		var nm := String(names[side]).to_upper()
		var nx := r.position.x + fade + 0.02 * u if mine_side else r.end.x - fade - 0.02 * u
		HudDraw.text(self, nm, Vector2(nx, cy), _fit_fs(nm, int(0.028 * u), r.size.x * 0.22), Color(1, 1, 1, 0.95 * a),
			0 if mine_side else 2, 3, "bold")


## A burst of sparks from `c`, `t` s after it began (0.7 s): streaks flying out and fading.
func _draw_sparks(c: Vector2, t: float, reach: float, col: Color, a: float) -> void:
	if t < 0.0 or t > 0.7:
		return
	var k := t / 0.7
	for i in 16:
		var ang := TAU * i / 16.0 + 0.37 * float(i % 3)
		var d := Vector2.from_angle(ang)
		var far := reach * (0.4 + 0.6 * (float((i * 7) % 5) / 4.0))
		var p0 := c + d * far * pow(k, 0.6)
		var p1 := p0 + d * reach * 0.18 * (1.0 - k)
		draw_line(p0, p1, Color(col, (1.0 - k) * a), maxf(2.0, reach * 0.03), true)


## The 1 vs 1 opponent's name (the score plates).
func _their_name() -> String:
	var b: Variant = arena.get("bot") if arena != null else null
	return (b as Fighter).display_name if b is Fighter else "OPPONENT"


## Elimination badge (our own emblem) with HEADSHOT / ELIMINATED and the victim's name plate.
func _draw_kill_banner(vs: Vector2, u: float) -> void:
	var t := float(_kill_banner.t)
	if t <= 0.0 or break_step() not in ["", "beat"] or result_title() != "":
		return                           # (the result band takes over from the badge)
	var age := KILL_BANNER_TIME - t
	var a := clampf(age / 0.12, 0.0, 1.0) * clampf(t / 0.35, 0.0, 1.0)
	var pop := 1.0
	var c := Vector2(vs.x * 0.5, vs.y * 0.17)
	var cause := String(_kill_banner.get("cause", ""))
	if bool(_kill_banner.get("knock", false)):
		_draw_knock_banner(c, u, a, pop)
		return
	if cause != "":
		_draw_out_banner(c, u, a, cause)
		return
	# Small and still (no glow, no pulse, no pop): a headshot kill only tints the badge red and puts
	# the head target on it.
	var bs := 0.12 * u
	var head := bool(_kill_banner.head)
	HudDraw.icon(self, HudDraw.tex("badge_elim"), c, Vector2(bs, bs), Color(1.0, 0.62, 0.55, a) if head else Color(1, 1, 1, a))
	if head:
		HudDraw.disk(self, c, bs * 0.17, Color(0.55, 0.05, 0.03, 0.9 * a))
		HudDraw.icon(self, HudDraw.tex("v_headshot"), c, Vector2(bs, bs) * 0.27, Color(1.0, 0.86, 0.8, a))
	# One dark plate under the badge holds both lines (HEADSHOT / ELIMINATED, then the name),
	# so they stay readable over a bright hall or the character's raised arms.
	var label := String(_kill_banner.get("word", "HEADSHOT" if head else "ELIMINATED"))
	var lfs := int(0.03 * u)
	var nm := String(_kill_banner.get("by", _kill_banner.name)).to_upper()
	var fs := int(0.026 * u)
	var ty := c.y + bs * 0.5 + 0.022 * u
	var pw := maxf(HudDraw.text_width(label, lfs, "bold"), HudDraw.text_width(nm, fs, "bold")) + 0.2 * u
	var plate := Rect2(c.x - pw * 0.5, ty - 0.024 * u, pw, 0.09 * u)
	HudDraw.plate(self, plate, 0.72 * a)
	HudDraw.text(self, label, Vector2(c.x, ty), lfs, Color(HudDraw.FEED_HEAD if head else Color.WHITE, a), 1, 3, "bold")
	var line_y := ty + 0.026 * u
	draw_rect(Rect2(c.x - pw * 0.3, line_y, pw * 0.6, maxf(1.5, 0.003 * u)), Color(HudDraw.KILL_RED, a))
	HudDraw.text(self, nm, Vector2(c.x, line_y + 0.025 * u), fs, Color(1, 1, 1, a), 1, 2, "bold")


## knock_banner's plate: a red cross in a ring over KNOCKED and the name (calmer than a kill's badge).
func _draw_knock_banner(c: Vector2, u: float, a: float, pop: float) -> void:
	var r := 0.04 * u * lerpf(1.0, pop, 0.5)
	var red := Color(1.0, 0.5, 0.3)
	HudDraw.disk(self, c, r, Color(0.1, 0.03, 0.02, 0.75 * a))
	HudDraw.ring(self, c, r, Color(red, 0.95 * a), maxf(2.0, 0.005 * u))
	var s := r * 1.1
	var t := s * 0.32
	draw_rect(Rect2(c - Vector2(t * 0.5, s * 0.5), Vector2(t, s)), Color(red, a))
	draw_rect(Rect2(c - Vector2(s * 0.5, t * 0.5), Vector2(s, t)), Color(red, a))
	var nm := String(_kill_banner.name).to_upper()
	var fs := int(0.03 * u)
	var lfs := int(0.032 * u)
	var ty := c.y + r + 0.03 * u
	var pw := maxf(HudDraw.text_width(nm, fs, "bold"), HudDraw.text_width("KNOCKED", lfs, "bold")) + 0.14 * u
	HudDraw.plate(self, Rect2(c.x - pw * 0.5, ty - 0.026 * u, pw, 0.088 * u), 0.66 * a)
	HudDraw.text(self, "KNOCKED", Vector2(c.x, ty), lfs, Color(red, a), 1, 3, "bold")
	HudDraw.text(self, nm, Vector2(c.x, ty + 0.037 * u), fs, Color(1, 1, 1, a), 1, 2, "bold")


## out_banner's plate: a small disk with what took them out (the zone's blue for the zone) and one
## line, "<NAME>" over "CAUGHT IN THE ZONE" (OUT_LINES), smaller and calmer than a kill's badge.
func _draw_out_banner(c: Vector2, u: float, a: float, cause: String) -> void:
	var tint := Color(0.45, 0.72, 1.0) if cause == "zone" else Color(0.86, 0.86, 0.88)
	var r := 0.042 * u
	HudDraw.disk(self, c, r, Color(0.04, 0.06, 0.1, 0.72 * a))
	HudDraw.ring(self, c, r, Color(tint, 0.9 * a), maxf(2.0, 0.005 * u))
	HudDraw.icon(self, HudDraw.tex(String(OUT_ICONS.get(cause, "v_zone"))), c, Vector2(r, r) * 1.15, Color(tint, a))
	var line := String(OUT_LINES.get(cause, ""))
	var nm := String(_kill_banner.name).to_upper()
	var fs := int(0.03 * u)
	var lfs := int(0.026 * u)
	var ty := c.y + r + 0.03 * u
	var pw := maxf(HudDraw.text_width(nm, fs, "bold"), HudDraw.text_width(line, lfs, "bold")) + 0.14 * u
	HudDraw.plate(self, Rect2(c.x - pw * 0.5, ty - 0.024 * u, pw, 0.082 * u), 0.66 * a)
	HudDraw.text(self, nm, Vector2(c.x, ty), fs, Color(1, 1, 1, a), 1, 2, "bold")
	HudDraw.text(self, line, Vector2(c.x, ty + 0.035 * u), lfs, Color(tint, a), 1, 2, "bold")


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
	for tip: Array in TIPS:
		var id := String(tip[0])
		if not layout.has(id):
			continue
		var w: Dictionary = layout[id]
		var c := HudLayout.center(w, vs)
		var r := HudLayout.radius(w, vs)
		var at := c + Vector2(0, r + 0.022 * u)
		if at.y > vs.y - 0.02 * u:
			at = c - Vector2(0, r + 0.022 * u)
		HudDraw.text(self, String(tip[1]), at, int(0.02 * u), Color(HudDraw.YELLOW, a), 1, 3, "bold")


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
	var feed_c := Vector2(vs.x * 0.5, vs.y * FEED_Y_SOLO)
	var feed_w := HudDraw.text_parts(self, feed, feed_c, fs, 1, 3, "bold", 0.8)
	_draw_weapon_panel(vs)                    # as in a match: the panel, the buttons, the gear
	_draw_controls(vs)
	_draw_button("settings", vs)
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
		if not button_enabled(id):
			label += " (OFF)"              # turned off in SETTINGS > CONTROLS: placed, not shown in a match
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
