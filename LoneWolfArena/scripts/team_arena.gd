class_name TeamArena
extends "res://scripts/arena.gd"
## DUO (2 vs 2) and SQUAD (4 vs 4) on CARGO CAGE, first to TEAM_ROUNDS_TO_WIN rounds, set up from
## Game.team_match (autoload/game.gd). Offline (TRAINING GROUND, or a team search that found nobody:
## scenes/team_arena.tscn) everything runs on this phone. Online (scenes/team_arena_net.tscn,
## TeamArenaNet, WP-N) the match runs between TWO phones over Cloud's 1 vs 1 session (Game.session):
## the host runs every bot and referees, each phone runs its own player; TeamArenaNet overrides only
## the SEAMS at the end of this file. Team 0 spawns in alcove A, team 1 in alcove B; on every phone
## the player's team is BLUE, the other ORANGE.
## The rules (TeamReferee decides them, this arena applies them):
##  - a fighter whose HP runs out is KNOCKED at once (Fighter.knock: prone, crawling, no gun or
##    items) and the referee says what it is: "ko" while a teammate is still UP, else "el" (out)
##    together with its KNOCKED teammates; knock HP bleeds out over Fighter.BLEED_S, hits and the
##    zone take it too, and at 0 the fighter is out;
##  - an UP teammate within Fighter.REVIVE_RANGE revives it in Fighter.REVIVE_S standing still
##    (start_revive: the HUD's REVIVE, or a bot); moving, firing, being knocked, the target dying,
##    more than REVIVE_CANCEL_M apart or the round's end cancel it; done, the referee stands it up
##    with Fighter.REVIVE_HP;
##  - friendly fire is off (Fighter.take_damage; a fighter's own frag still hurts it) and bullets
##    and sight lines pass through teammates (Fighter.ignore_fighters); the aim assist, the red
##    crosshair and the shot magnet skip teammates (Player);
##  - a round is won when nobody on the other team is UP (decided DEATH_SETTLE_S after the first
##    team went down, so two teams wiped that close together make a draw); at the time-out the team
##    whose UP fighters have more HP in all wins (TeamReferee.timeout_winner);
##  - every fighter picks its own gun in every prep (bots after 1.5-3.5 s; a player who does not
##    pick gets the last one picked);
##  - once out, the camera follows the nearest teammate still UP (spectate_next cycles them);
##  - kills are the referee's eliminations (Fighter stats "kills", "knocks", "revives").

const TEAM_ROUNDS_TO_WIN := 4             # LW_ROUNDS_TO_WIN overrides it in test runs
## The prep of every team round (every fighter picks its own gun in it).
const TEAM_PREP_S := 10.0
const REVIVE_CANCEL_M := 2.5              # a revive stops when the two are farther apart than this
const SPAWN_SIDE := 1.2                   # m beside the alcove's middle line (members 0 / 1 of a team)
const SPAWN_BACK := 2.0                   # m deeper into the alcove (members 2 / 3)
const ENEMY_TEAM_NAME := "ORANGE TEAM"
## SQUAD costs about twice the 1 vs 1's draw calls (8 fighters; measured with tools/qa's Xvfb
## renderer: LOW 189 / 99, MEDIUM 349 / 159), so at LOW and MEDIUM the other fighters farther than
## SHADOW_CUT_M from the camera cast no shadow (checked SHADOW_CUT_S apart), and the bots' looks
## around fall on different frames (Bot.perceive_timer, Bot._retarget_t).
const SHADOW_CUT_M := 15.0
const SHADOW_CUT_S := 0.25
const BOT_OUTFITS := ["desert", "neon", "shadow", "royal", "default"]

var team_size := 0                        # players a team: 2 DUO, 4 SQUAD (the HUD: > 1 means a team match)
var my_team := 0                          # the player's team (0 / 1)
var my_slot := 0                          # the player's roster slot (Game.team_match.my_slot)
var slots: Array[Fighter] = []            # every fighter by its slot (Game.team_match.roster order)
var roster: Array = []                    # Game.team_match.roster
var team_score := [0, 0]                  # rounds won by team 0 / 1 (`score` mirrors it: player = mine, bot = theirs)
var referee := TeamReferee.new()
## slot -> the numbers the other phone sent for a fighter it runs ("fin", WP-N fills it): the results
## and the scoreboard show those (slot_stats).
var final_stats := {}
var _picked := {}                         # slot -> the gun it holds this round
var _pick_at := {}                        # bot slot -> s until it picks (prep)
var _applying := 0                        # inside _apply_decision: downs it causes are not reported
var _spectate_killer: Fighter             # who took the player out (followed when no teammate is UP)
var _shadow_t := 0.0
var _shadow_cut := {}                     # fighter -> true while its shadow is cut (SHADOW_CUT_M)


func _ready() -> void:
	team_size = int(Game.team_match.get("size", 2))
	super()


## A team match on this phone only, as Game.team_match: TRAINING GROUND DUO / SQUAD, or a player
## whose DUO / SQUAD search found nobody (TeamMatch). The player in slot 0, bots in every other
## slot (team 0 = slots 0..n-1), each bot at level `diff`; a bot's empty name and outfit are picked
## by the arena ("BOT <NAME>", a random outfit).
static func offline_match(players_a_team: int, mode_id: String, diff: int) -> Dictionary:
	var out_roster := []
	for i in players_a_team * 2:
		var me := i == 0
		out_roster.append({"slot": i, "id": "", "name": String(Game.profile.name) if me else "",
			"bundle": String(Game.profile.bundle) if me else "", "team": 0 if i < players_a_team else 1,
			"bot": not me, "diff": clampi(diff, 0, 2)})
	return {"size": players_a_team, "online": false, "coop": false, "mode_id": mode_id, "my_slot": 0, "host": true,
		"roster": out_roster}


## A team match between two phones (a TEAM INVITE: coop, both players on team 0 against bots; or a
## team QUICK MATCH: each player with bot teammates against the other), as Game.team_match. Both
## phones build the same roster from the same inputs (host / guest: {"id", "name", "bundle"}), so
## slots, teams, bot names and outfits
## agree without being sent (`seed_value`: the same number on both, e.g. from the two ids). The host
## is slot 0; the guest slot 1 (coop) or `size` (vs).
static func link_match(size: int, coop: bool, host: Dictionary, guest: Dictionary, am_host: bool, seed_value: int, diff := 1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var guest_slot := 1 if coop else size
	var outfits := ["desert", "neon", "shadow", "royal", "default"]
	var out_roster := []
	for i in size * 2:
		var human: Dictionary = host if i == 0 else (guest if i == guest_slot else {})
		var bot_name := "BOT " + String(BOT_NAMES[rng.randi() % BOT_NAMES.size()])
		var bot_outfit := String(outfits[rng.randi() % outfits.size()])
		out_roster.append({"slot": i, "id": String(human.get("id", "")), "team": 0 if i < size else 1, "bot": human.is_empty(),
			"name": String(human.get("name", "PLAYER")) if not human.is_empty() else bot_name,
			"bundle": String(human.get("bundle", "default")) if not human.is_empty() else bot_outfit,
			"diff": clampi(diff, 0, 2)})
	return {"size": size, "online": true, "coop": coop, "mode_id": "duo" if size == 2 else "squad",
		"my_slot": 0 if am_host else guest_slot, "host": am_host, "roster": out_roster}


## An all-human match (a GROUP's own match, Cloud.session_multi) as Game.team_match: every slot a
## real player, NO bot slots. `in_roster` is Cloud.session_roster ([{"slot", "id", "name", "bundle",
## "team"}]); teams may be uneven (1..size players each) and a slot nobody holds is simply absent.
## The slots are numbered again 0..n-1 in roster order (BLUE first), the same on every phone, so
## the arena's slot list has no gaps. `host_id` referees. {} for anything that cannot be played
## (a size other than 2 / 4, a team empty or over size, an id twice, this phone not in it).
## `seed_value` is kept for the bots' names of rosters that have some (none here).
static func link_roster(size: int, in_roster: Array, my_id: String, host_id: String, seed_value: int) -> Dictionary:
	if size not in [2, 4]:
		return {}
	var entries := []
	for e: Variant in in_roster:
		if not e is Dictionary:
			return {}
		entries.append(e)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return [int(a.get("team", 0)), int(a.get("slot", 0))] < [int(b.get("team", 0)), int(b.get("slot", 0))])
	var out_roster := []
	var counts := [0, 0]
	var ids := {}
	var mine := -1
	for e: Dictionary in entries:
		var t := int(e.get("team", -1))
		var id := String(e.get("id", ""))
		if t not in [0, 1] or id == "" or ids.has(id):
			return {}
		ids[id] = true
		counts[t] += 1
		if id == my_id:
			mine = out_roster.size()
		out_roster.append({"slot": out_roster.size(), "id": id, "team": t, "bot": false, "name": String(e.get("name", "PLAYER")),
			"bundle": String(e.get("bundle", "default")), "diff": 1})
	if mine < 0 or not ids.has(host_id) or counts[0] < 1 or counts[1] < 1 or counts[0] > size or counts[1] > size:
		return {}
	return {"size": size, "online": true, "coop": false, "multi": true, "mode_id": "duo" if size == 2 else "squad", "my_slot": mine,
		"host": my_id == host_id, "host_id": host_id, "seed": seed_value, "roster": out_roster}


# ---------------------------------------------------------------- read API (HUD, results: WP-B2)

func team_of(f: Fighter) -> int:
	return f.team if f != null else -1


## On the player's team (the player too).
func ally(f: Fighter) -> bool:
	return f != null and player != null and f.team == player.team


func members(t: int) -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in slots:
		if f != null and f.team == t:
			out.append(f)
	return out


## "up" | "knocked" | "out" | "left" this round.
func status_of(f: Fighter) -> String:
	if f != null and referee.left.has(f.slot):
		return "left"
	if f == null or not f.alive:
		return "out"
	return "knocked" if f.knocked else "up"


## A KNOCKED teammate within Fighter.REVIVE_RANGE of `f` (who is UP), nearest first; null when none.
func revive_candidate(f: Fighter) -> Fighter:
	if f == null or not f.alive or f.knocked or phase != Phase.FIGHT:
		return null
	var best: Fighter = null
	var best_d := Fighter.REVIVE_RANGE
	for o in fighters:
		if o != f and o.alive and o.knocked and f.ally_of(o) and (o.revived_by == null or o.revived_by == f):
			var d := f.global_position.distance_to(o.global_position)
			if d <= best_d:
				best = o
				best_d = d
	return best


## The HUD's REVIVE: `f` starts reviving `target` (Fighter.REVIVE_S standing still next to it).
func start_revive(f: Fighter, target: Fighter) -> bool:
	if f == null or target == null or phase != Phase.FIGHT or not runs_here(f):
		return false
	if not f.alive or f.knocked or not target.alive or not target.knocked or not f.ally_of(target):
		return false
	if f.reviving == target:
		return true
	if f.reviving != null or (target.revived_by != null and target.revived_by != f):
		return false
	if f.global_position.distance_to(target.global_position) > Fighter.REVIVE_RANGE:
		return false
	f.cancel_heal()
	f.ads = false
	f.sprinting = false
	f.move_dir = Vector2.ZERO
	if f is Player:
		(f as Player).put_away_item()
		(f as Player).firing = false
	f.reviving = target
	f.revive_t = 0.0
	target.revived_by = f
	if f.model:
		f.model.play_heal(true)          # the revive animation
	Game.mark("revive started")
	_announce("rvs", [f.slot, target.slot])
	return true


func cancel_revive(f: Fighter) -> void:
	if f == null or f.reviving == null:
		return
	_end_revive(f)
	if runs_here(f):
		_announce("rvx", [f.slot])


## How far a revive of `target` has come: 0..1 while a teammate revives it, -1 when nobody does
## (the knocked player's own BEING REVIVED bar, the teammates panel).
func revive_progress(target: Fighter) -> float:
	if target == null or target.revived_by == null or not is_instance_valid(target.revived_by):
		return -1.0
	var r := target.revived_by
	if r.reviving != target:
		return -1.0
	return clampf(r.revive_t / Fighter.REVIVE_S, 0.0, 1.0)


## Out of the round: the camera goes to the next teammate still UP (the HUD's NEXT).
func spectate_next() -> void:
	if player == null or player.alive:
		return
	var ups := _up_mates()
	if ups.is_empty():
		return
	var i := ups.find(player.spectating)
	player.spectating = ups[(i + 1) % ups.size()]


## Whom the camera follows while the player is out (null: the player's own view).
func spectated() -> Fighter:
	return player.spectating_now() if player != null else null


## The fighter in a roster slot (null when there is none).
func slot_fighter(s: int) -> Fighter:
	return slots[s] if s >= 0 and s < slots.size() else null


## A fighter's numbers for the results and the scoreboard: its own stats ("kills", "knocks",
## "revives", "damage", "headshots", "shots", "hits", "deaths", ...), or what the other phone sent
## for it once the match is over (final_stats).
func slot_stats(s: int) -> Dictionary:
	if final_stats.has(s):
		return final_stats[s]
	var f := slot_fighter(s)
	if f == null:
		return {}
	var st: Dictionary = f.stats.duplicate()
	st["deaths"] = int(st.get("deaths", 0))
	return st


## First to this many rounds (TEAM_ROUNDS_TO_WIN; test runs of the editor binary: LW_ROUNDS_TO_WIN).
static func team_rounds_to_win() -> int:
	if not OS.has_feature("template") and OS.get_environment("LW_ROUNDS_TO_WIN") != "":
		return maxi(int(OS.get_environment("LW_ROUNDS_TO_WIN")), 1)
	return TEAM_ROUNDS_TO_WIN


## Where team member `index` (0..3, by slot) stands in its alcove: `base` is the map's spawn point
## and `yaw` its facing (into the hall); two beside the middle line, two more deeper in.
static func spawn_spot(base: Vector3, yaw: float, index: int) -> Vector3:
	var b := Basis(Vector3.UP, yaw)
	var side := SPAWN_SIDE * (-1.0 if index % 2 == 0 else 1.0)
	var back := SPAWN_BACK * float(index / 2)
	return base + b * Vector3(side, 0.0, back)


## The round's clock by team size (RoundRules, as the 1 vs 1): stage 1 the same, stage 2 of a DUO
## as the 1 vs 1's, a SQUAD's longer.
func stage2_time() -> float:
	return RoundRules.SQUAD_STAGE2_S if team_size >= 4 else RoundRules.STAGE2_S


# ---------------------------------------------------------------- the match (offline semantics)

func _spawn_fighters() -> void:
	practice = false
	mode = String(Game.team_match.get("mode_id", "training"))
	mode_name = ("TRAINING GROUND" if mode == "training" else "LONE WOLF") + " · " + ("SQUAD" if team_size >= 4 else "DUO")
	rounds_to_win = team_rounds_to_win()
	roster = Game.team_match.get("roster", [])
	my_slot = int(Game.team_match.get("my_slot", 0))
	var pick := String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK))
	if not Weapons.DEFS.has(pick):
		pick = Weapons.DEFAULT_PICK
	var names: Array = BOT_NAMES.duplicate()
	names.shuffle()
	slots.clear()
	slots.resize(roster.size())
	var teams := {}
	for entry: Dictionary in roster:
		var s := int(entry.get("slot", -1))
		if s < 0 or s >= slots.size():
			continue
		var f := _fighter_for(entry)
		f.team = clampi(int(entry.get("team", 0)), 0, 1)
		f.slot = s
		f.name = "Player" if s == my_slot else "Fighter%d" % s
		var nm := String(entry.get("name", ""))
		f.display_name = nm if nm != "" else "BOT " + String(names[s % names.size()])
		f.arena = self
		add_child(f)
		var outfit := String(entry.get("bundle", ""))
		if outfit == "":
			outfit = String(BOT_OUTFITS[_rng.randi() % BOT_OUTFITS.size()])
		f.global_position = _spawn_for(f)
		f.setup_fighter(outfit, pick)
		f.aim_yaw = _yaw_for(f.team)
		f.hold_fire = true
		slots[s] = f
		fighters.append(f)
		teams[s] = f.team
	player = slot_fighter(my_slot) as Player
	my_team = player.team
	for f in fighters:
		if f.team != my_team:
			bot = f as Bot             # the first enemy: the 1 vs 1's helpers never meet null
			break
	for f in fighters:
		var mates := members(f.team)
		mates.erase(f)
		f.ignore_fighters(mates)
		if f is Bot:
			var b := f as Bot
			var foes := members(1 - f.team)
			b.configure(int(_entry(f.slot).get("diff", Game.settings.difficulty)), foes[0] if not foes.is_empty() else null)
			b.enemies = foes
			b.allies = mates
			b.perceive_timer = _rng.randf() * 0.1      # their looks around fall on different frames
			b._retarget_t = _rng.randf() * Bot.RETARGET_S
			b.frozen = true
		f.died.connect(_on_team_died)
		f.knocked_down.connect(_on_knocked)
		f.knock_finished.connect(_on_knock_finished)
		_outside[f] = 0.0
		if not bool(Game.team_match.get("coop", false)) and not bool(_entry(f.slot).get("bot", true)) and f != player and f.team != my_team:
			_enemy_id = String(_entry(f.slot).get("id", ""))
	referee.setup(teams)


func _on_nav_baked() -> void:
	super()
	for f in fighters:
		if f is Bot:
			(f as Bot).nav_ready = true


func _entry(s: int) -> Dictionary:
	for e: Dictionary in roster:
		if int(e.get("slot", -1)) == s:
			return e
	return {}


func _spawn_for(f: Fighter) -> Vector3:
	var index := 0
	for o: Dictionary in roster:
		if int(o.get("team", 0)) == f.team and int(o.get("slot", -1)) < f.slot:
			index += 1
	return spawn_spot(map.spawn_a if f.team == 0 else map.spawn_b, _yaw_for(f.team), index)


func _yaw_for(t: int) -> float:
	return map.spawn_a_yaw if t == 0 else map.spawn_b_yaw


func _start_prep() -> void:
	_reset_zone()
	_round_deaths.clear()
	_down_cause.clear()
	_settle_t = -1.0
	_net_spawns.clear()
	_my_spawns.clear()
	phase = Phase.PREP
	prep_left = TEAM_PREP_S
	map.set_barriers(true)
	referee.reset_round()
	_picked.clear()
	_pick_at.clear()
	picked_weapon = ""
	pick_note = "EVERY FIGHTER PICKS A GUN"
	for f in fighters:
		f.hold_fire = true
		f.frozen = f != player
		if f is Bot and runs_here(f) and not (f is RemoteFighter):
			_pick_at[f.slot] = _rng.randf_range(1.5, 3.5)
	hud.open_weapon_pick(Weapons.PICKABLE, String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK)), prep_left - 1.0, _on_weapon_picked)
	if round_index == 1 and int(Game.profile.matches) < 3:
		hud.tips_time = 9.0
	Game.mark("prep started")


## This phone's player picked (or the pick timer ran out).
func _on_weapon_picked(id: String) -> void:
	if not id in Weapons.PICKABLE:
		id = Weapons.DEFAULT_PICK
	Game.settings.last_pick = id
	Game.save_settings()
	_set_pick(player, id)
	_announce("pick", [my_slot, id, round_index])


func _set_pick(f: Fighter, id: String) -> void:
	if f == null or not id in Weapons.PICKABLE:
		return
	_picked[f.slot] = id
	f.set_loadout(id)
	if f == player:
		picked_weapon = id


func _bot_pick(s: int) -> void:
	_pick_at.erase(s)
	var id := String(Weapons.PICKABLE[_rng.randi() % Weapons.PICKABLE.size()])
	_set_pick(slot_fighter(s), id)
	_announce("pick", [s, id, round_index])


func _start_fight() -> void:
	phase = Phase.FIGHT
	_net_timeup_t = -1.0
	if round_index == 1 and not _counted:
		Game.count_match(mode)
		_counted = true
	if not _picked.has(my_slot):
		hud.close_weapon_pick()
		_on_weapon_picked(String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK)))
	for s: int in _pick_at.keys():
		_bot_pick(s)
	pick_note = ""
	map.set_barriers(false)
	for f in fighters:
		f.hold_fire = false
		f.frozen = false
	time_left = round_time()
	_zone_mesh.visible = true
	_reset_zone()
	zone_final = zone_final_for(round_index)
	Game.mark("match started")
	if round_index == 1 and _quiet_round != round_index:     # (a rejoin into its prep: none)
		hud.show_round_banner(round_index, map_name, round_sub(round_index))      # (later: at the break's end)
	Audio.play("countdown_go", 0.0)


func _physics_process(delta: float) -> void:
	_net_tick(delta)
	match phase:
		Phase.PREP when online and not _net_begun:
			pass        # online the first prep starts on both phones together (_net_begin)
		Phase.PREP:
			for s: int in _pick_at.keys():
				_pick_at[s] = float(_pick_at[s]) - delta
				if float(_pick_at[s]) <= 0.0:
					_bot_pick(s)
			prep_left -= delta
			var n := ceili(prep_left)
			if prep_left <= 3.0 and n != _last_count and n > 0:
				_last_count = n
				Audio.play("countdown_beep", -2.0)
			if prep_left <= 0.0:
				_start_fight()
		Phase.FIGHT:
			elapsed += delta
			match_time += delta
			time_left -= delta
			_update_zone(delta)
			_update_revives(delta)
			if is_referee() and not _referee_waits():
				if _settle_t >= 0.0:
					_settle_t -= delta
					if _settle_t <= 0.0:
						_decide_round(false)
				elif referee.winner() != -1:
					_settle_t = DEATH_SETTLE_S        # a team is down: a moment for the other's last one
				elif time_left <= 0.0:
					_decide_round(true)
		Phase.END:
			_end_t += delta / maxf(Engine.time_scale, 0.01)
			if _end_t > 1.0 and Engine.time_scale < 1.0:
				Engine.time_scale = 1.0
			if _called_off:
				if _end_t > 2.6 and not _left_scene:
					_left_scene = true
					Game.goto_lobby()
			elif _end_t > 2.6 and not _result_shown and (not _awaits_final() or _end_t > 2.6 + FINAL_WAIT_S):
				_show_results()
		Phase.BREAK:
			_break_t += delta / maxf(Engine.time_scale, 0.01)
			if _break_t > 1.0 and Engine.time_scale < 1.0:
				Engine.time_scale = 1.0
			if (_break_t >= BREAK_TIME and is_referee()) or _break_t >= BREAK_TIME + 8.0:
				_next_round()
	_update_spectate()
	_update_shadow_cut(delta)


## LOW / MEDIUM: fighters far from the camera cast no shadow (see SHADOW_CUT_M). A gun picked later
## brings new meshes: the next check cuts those too.
func _update_shadow_cut(delta: float) -> void:
	_shadow_t -= delta
	if _shadow_t > 0.0 or player == null:
		return
	_shadow_t = SHADOW_CUT_S
	var cut_on := int(Game.settings.graphics) <= 1
	var eye := player.camera.global_position if player.camera != null else player.global_position
	for f in fighters:
		if f == player or f.model == null:
			continue
		var cut := cut_on and f.global_position.distance_to(eye) > SHADOW_CUT_M
		if not cut and not bool(_shadow_cut.get(f, false)):
			continue
		_shadow_cut[f] = cut
		for mi: GeometryInstance3D in f.model.find_children("*", "GeometryInstance3D", true, false):
			if cut and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.set_meta("lw_shadow_cut", true)
			elif not cut and mi.has_meta("lw_shadow_cut"):
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				mi.remove_meta("lw_shadow_cut")


func zone_hurts(f: Fighter) -> bool:
	return f.alive and runs_here(f)


## DUO / SQUAD announce the stage change (the band in stage 1's last 10 s, ZONE SHRINKING, the
## beep), unlike the 1 vs 1 (arena.gd).
func quiet_stage_change() -> bool:
	return false


## Revives in progress by fighters that run here: cancelled, or done after Fighter.REVIVE_S.
func _update_revives(delta: float) -> void:
	for f in fighters:
		if f.reviving == null or not runs_here(f):
			continue
		var t := f.reviving
		# (a reviver cannot shoot: Fighter.perform_shot; the player's FIRE cancels it)
		var stop := not f.alive or f.knocked or not is_instance_valid(t) or not t.alive or not t.knocked \
			or f.move_dir.length() > 0.2 or f.global_position.distance_to(t.global_position) > REVIVE_CANCEL_M
		if f is Player and (f as Player).firing:
			stop = true
		if stop:
			cancel_revive(f)
			continue
		f.revive_t += delta
		if f.revive_t >= Fighter.REVIVE_S:
			_end_revive(f)
			_report_revive(f, t)


func _end_revive(f: Fighter) -> void:
	var t := f.reviving
	f.reviving = null
	f.revive_t = 0.0
	if t != null and is_instance_valid(t) and t.revived_by == f:
		t.revived_by = null
	if f.model and not f.healing:
		f.model.play_heal(false)


func _up_mates() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in members(my_team):
		if f != player and f.alive and not f.knocked:
			out.append(f)
	return out


## Out: the camera follows the nearest teammate still UP, else (nobody UP) the one who did it.
func _update_spectate() -> void:
	if player == null or player.alive:
		return
	var cur := player.spectating
	if cur != null and is_instance_valid(cur) and cur.alive and not cur.knocked and player.ally_of(cur):
		return
	var best: Fighter = null
	var best_d := INF
	for f in _up_mates():
		var d := f.global_position.distance_to(player.global_position)
		if d < best_d:
			best = f
			best_d = d
	if best != null:
		player.spectating = best
	elif cur == null or not is_instance_valid(cur) or not cur.alive:
		player.spectating = _spectate_killer if _spectate_killer != null and is_instance_valid(_spectate_killer) and _spectate_killer.alive else null


## The referee's word on the round (an elimination settled, or the time-out).
func _decide_round(timed_out: bool) -> void:
	if phase != Phase.FIGHT:
		return
	_settle_t = -1.0
	var w := referee.winner()
	if w == -1:
		if not timed_out:
			return
		var hp := {}
		for f in fighters:
			hp[f.slot] = f.hp if f.alive and not f.knocked else 0.0
		w = referee.timeout_winner(hp)
	else:
		timed_out = false
	var win_team := w if w == 0 or w == 1 else -1
	var sc := [int(team_score[0]), int(team_score[1])]
	if win_team >= 0:
		sc[win_team] += 1
	if timed_out:
		Game.mark("time up")
	var data := [round_index, win_team, sc[0], sc[1], timed_out]
	_announce("rend", data)
	_apply_decision("rend", data)


func _next_round() -> void:
	var data := [round_index + 1, int(team_score[0]), int(team_score[1])]
	if is_referee():
		_announce("round", data)
	_apply_decision("round", data)


func _sync_score() -> void:
	score.player = int(team_score[my_team])
	score.bot = int(team_score[1 - my_team])


## A round is decided: the score, the round's end on screen, then a break or the match's end.
func _end_team_round(win_team: int, timed_out: bool) -> void:
	_settle_t = -1.0
	close_pause()
	for f in fighters:
		if f.reviving != null:
			_end_revive(f)
	var mine := int(team_score[my_team])
	var theirs := int(team_score[1 - my_team])
	var decided := _forfeit or match_over_after(round_index, mine, theirs, rounds_to_win)
	_freeze_all()
	if decided:
		_conclude()
	else:
		phase = Phase.BREAK
		_break_t = 0.0
		Game.mark("round over")
	if not decided:
		hud.show_break("DRAW" if win_team < 0 else ("VICTORY" if win_team == my_team else "DEFEAT"), mine, theirs,
			0 if win_team < 0 else (1 if win_team == my_team else -1), round_index + 1, map_name, round_sub(round_index + 1))
	elif timed_out:
		hud.show_center("TIME UP", 2.0, Color.WHITE, 96, ("DRAW" if win_team < 0 else ("YOUR TEAM HAS MORE HP" if win_team == my_team
			else "THE OTHER TEAM HAS MORE HP")) + "    %d  -  %d" % [mine, theirs])
	else:
		_show_match_end()
	if not timed_out:
		Engine.time_scale = 0.35
	if win_team == my_team:
		Audio.play("victory_sting", 0.0)
	elif win_team >= 0:
		Audio.play("defeat_sting", 0.0)


func _conclude() -> void:
	phase = Phase.END
	_end_t = 0.0
	var mine := int(score.player)
	var theirs := int(score.bot)
	_draw = mine == theirs and not _forfeit
	_winner = null if _draw else ((player as Fighter) if mine > theirs or _forfeit else (bot as Fighter))
	Game.mark("match over: " + ("draw" if _draw else ("won" if _winner == player else "lost")))
	if _winner == player and player.alive and not player.knocked:
		player.model.play_victory()
		player.victory_cam = true


## A new round: everyone back in their alcove with full HP and items (a slot that left stays out).
func _reset_round() -> void:
	Engine.time_scale = 1.0
	hud.match_over = false
	for c in get_children():
		if c is ShieldWall or c is Grenade:
			c.queue_free()
	for f in fighters:
		_outside[f] = 0.0
		if referee.left.has(f.slot):
			continue
		f.reset_for_round(_spawn_for(f), _yaw_for(f.team))
	Game.mark("round %d" % round_index)
	_start_prep()


func _on_team_died(victim: Fighter, _killer: Fighter, _headshot: bool) -> void:
	victim.stats["deaths"] = int(victim.stats.get("deaths", 0)) + 1
	if victim == player:
		_deaths += 1
	for f in fighters:
		if f.reviving == victim:
			cancel_revive(f)


## Fighter.knocked_down: HP gone. A fighter that runs here went down by itself: the referee hears it.
func _on_knocked(victim: Fighter, killer: Fighter, headshot: bool) -> void:
	if _applying > 0 or not runs_here(victim) or phase != Phase.FIGHT:
		return
	_report_down(victim, killer, headshot, death_cause(victim, killer), false)


## Fighter.knock_finished: knock HP gone (finished off, the zone, bled out).
func _on_knock_finished(victim: Fighter, killer: Fighter, headshot: bool) -> void:
	if _applying > 0 or not runs_here(victim) or phase != Phase.FIGHT:
		return
	var cause := "bleed" if victim.last_hit_cause == "bleed" else death_cause(victim, killer)
	_report_down(victim, killer, headshot, cause, true)


## The referee's decisions on a down (offline, or the host for any slot; TeamArenaNet's "dn").
func referee_down(s: int, by: int, headshot: bool, cause: String, finished: bool) -> void:
	for d: Array in referee.down(s, by, headshot, cause, finished):
		var data := [int(d[1]), int(d[2]), bool(d[3]), String(d[4])]
		_announce(String(d[0]), data)
		_apply_decision(String(d[0]), data)


## The referee's word on a finished revive (offline, or the host; TeamArenaNet's "rvd").
func referee_revive(by: int, s: int) -> void:
	if referee.revive(by, s):
		var data := [s, by]
		_announce("rv", data)
		_apply_decision("rv", data)


## A slot left the match (online: the other phone's player): out now and every round after.
func referee_leave(s: int) -> void:
	for d: Array in referee.leave(s):
		var data := [int(d[1]), int(d[2]), bool(d[3]), String(d[4])]
		_announce(String(d[0]), data)
		_apply_decision(String(d[0]), data)


func _feed(by: Fighter, victim: Fighter, cause: String, headshot: bool, verb: String) -> void:
	if hud == null or victim == null:
		return
	if cause == "left":
		hud.add_team_feed(victim.display_name, ally(victim), "", false, "", "", false, false, "LEFT")
	elif by == null and cause == "bleed":       # (no knocker to credit: "<name> BLED OUT")
		hud.add_team_feed(victim.display_name, ally(victim), "", false, "", "", false, false, "BLED OUT")
	elif by == null:
		hud.add_team_feed(cause.to_upper(), false, victim.display_name, ally(victim), "", "", false, false, verb)
	elif cause == "self" or by == victim:
		hud.add_team_feed(victim.display_name, ally(victim), victim.display_name, ally(victim), "FRAG", "item_grenade", false, false, verb)
	else:
		var frag := cause == "frag"
		hud.add_team_feed(by.display_name, ally(by), victim.display_name, ally(victim), "FRAG" if frag else String(by.weapon().def.name),
			"item_grenade" if frag else String(by.weapon().def.icon), headshot, by == player, verb)


## Results (ResultsScreen, Game.record_match): the 1 vs 1's keys plus the team's.
func _match_result(won: bool, xp: int, hp_left: int) -> Dictionary:
	var r := super(won, xp, hp_left)
	var bots := 0
	for e: Dictionary in roster:
		if bool(e.get("bot", false)):
			bots += 1
	r["team"] = true
	r["team_size"] = team_size
	r["rows"] = scoreboard_rows()
	r["knocks"] = int(player.stats.get("knocks", 0))
	r["revives"] = int(player.stats.get("revives", 0))
	r["bots"] = bots
	r["mode_id"] = mode
	var vs := online and not bool(Game.team_match.get("coop", false)) and _enemy_id != ""
	r["enemy"] = ENEMY_TEAM_NAME
	r["enemy_id"] = _enemy_id if vs else ""
	if vs:
		for f in fighters:
			if f.team != my_team and not bool(_entry(f.slot).get("bot", true)):
				r["enemy"] = f.display_name
	return r


## XP = 40 + 120 for a win + 30 a kill (at most 4 a round played) + 15 a knock + 20 a revive +
## damage / 4 (at most 250) + 8 a headshot (at most 25).
func _final_result() -> Dictionary:
	var hp_left := roundi(player.hp)
	hp_left = _shown_hp(player)
	_result_shown = true
	var won := _winner == player and not _draw and not _invalid
	var st := player.stats
	var xp := 0
	if not _invalid and _counted:
		xp = 40 + (120 if won else 0) + mini(int(st.kills), 4 * round_index) * 30 + int(st.get("knocks", 0)) * 15 \
			+ int(st.get("revives", 0)) * 20 + mini(int(float(st.damage) / 4.0), 250) + mini(int(st.headshots), 25) * 8
	return _match_result(won, xp, hp_left)


## Rows for the scoreboard and the results: my team first (me first), then the other; the 1 vs 1's
## keys plus "team", "ally", "slot", "status", "knocks", "revives" and "bot".
func scoreboard_rows() -> Array:
	var rows := []
	var order: Array[Fighter] = [player]
	for f in members(my_team):
		if f != player:
			order.append(f)
	order.append_array(members(1 - my_team))
	for f in order:
		var st := slot_stats(f.slot)
		var shots := int(st.get("shots", 0))
		var acc := 0.0 if shots == 0 else float(st.get("hits", 0)) / float(shots) * 100.0
		rows.append({"name": f.display_name, "me": f == player, "alive": f.alive, "hp": _shown_hp(f),
			"kills": int(st.get("kills", 0)), "damage": roundi(float(st.get("damage", 0.0))), "headshots": int(st.get("headshots", 0)),
			"accuracy": roundi(acc), "rounds": int(team_score[f.team]), "weapon": String(f.gun().def.name),
			"team": f.team, "ally": f.team == my_team, "slot": f.slot, "status": status_of(f),
			"knocks": int(st.get("knocks", 0)), "revives": int(st.get("revives", 0)), "bot": bool(_entry(f.slot).get("bot", false))})
	return rows


## Hearing: bots hear everyone; the HUD shows and buzzes only for the other team.
func on_gunshot(shooter: Fighter) -> void:
	for f in fighters:
		if f is Bot and f != shooter and runs_here(f):
			(f as Bot).hear(shooter.global_position, 1.0)
	if not ally(shooter) and hud:
		hud.reveal(shooter, 2.5)
		hud.shot_heard(shooter)          # (the minimap: a fading mark where it fired, out of sight)


func on_footstep(f: Fighter) -> void:
	for other in fighters:
		if other is Bot and other != f and runs_here(other):
			(other as Bot).hear(f.global_position, 0.35)
	if not ally(f) and hud:
		hud.reveal(f, 1.0)
		hud.footstep(f)


# ---------------------------------------------------------------- SEAMS (TeamArenaNet overrides these)
# Offline (this class) every fighter runs here and this phone referees. Slots and teams are the
# roster's on every phone. Decisions, as _apply_decision takes them and _announce sends them:
#   "ko" [slot, by_slot (-1: nobody), headshot, cause]     knocked down
#   "el" [slot, by_slot, headshot, cause]                  out of the round
#   "rv" [slot, by_slot]                                   revived (by_slot did it)
#   "rend" [round, winner_team (0 / 1, -1 a draw), score0, score1, timed_out]
#   "round" [round, score0, score1]                        the next round starts
#   "pick" [slot, gun_id, round]                           a fighter's gun for this round
# Causes: "gun", "frag", "zone", "fall", "self", "bleed", "left".

#   "rvs" [reviver, target] / "rvx" [reviver]            a revive started / stopped (shown only;
#                                                       _announce'd for fighters that run here)

## Whether this phone decides knocks, eliminations, revives and rounds (offline: yes; online: the host).
func is_referee() -> bool:
	return true


## Whether the referee holds its word on the round for now (no wipe, settle or time-out checks):
## offline never; online a host back after a restart until the members said where they stand.
func _referee_waits() -> bool:
	return false


## Whether `f` is simulated on this phone (offline: every fighter; online: the player, and on the host
## also the bots). Only these take hits, report going down and run revives here.
func runs_here(_f: Fighter) -> bool:
	return true


## The fighter for one roster entry (offline: the Player for my_slot, a Bot for the others; online
## also a RemoteFighter for a fighter the other phone runs). The arena adds it to the tree.
func _fighter_for(entry: Dictionary) -> Fighter:
	if int(entry.get("slot", -1)) == my_slot:
		return Player.new()
	return Bot.new()


## Once per physics frame before the round logic: the online subclass sends the states here.
func _net_tick(_delta: float) -> void:
	pass


## A fighter that runs here went down by itself (HP gone: finished false; knock HP gone: finished
## true). Offline / host: the referee decides now; online guest: told to the host.
func _report_down(f: Fighter, killer: Fighter, headshot: bool, cause: String, finished: bool) -> void:
	if is_referee():
		referee_down(f.slot, killer.slot if killer != null and is_instance_valid(killer) else -1, headshot, cause, finished)


## A revive done by a fighter that runs here. Offline / host: the referee decides now; guest: told.
func _report_revive(reviver: Fighter, target: Fighter) -> void:
	if is_referee():
		referee_revive(reviver.slot, target.slot)


## A decision this phone made as referee (or the player's own "pick"): online it goes to the other phone.
func _announce(_kind: String, _data: Array) -> void:
	pass


## Applies a decision (the referee's own, or online the host's): fighters, kill feed, HUD, score.
func _apply_decision(kind: String, data: Array) -> void:
	_applying += 1
	match kind:
		"ko":
			_apply_knock(data)
		"el":
			_apply_out(data)
		"rv":
			_apply_revive(data)
		"rend":
			if data.size() >= 5 and int(data[0]) == round_index and phase == Phase.FIGHT:
				team_score = [int(data[2]), int(data[3])]
				_sync_score()
				_end_team_round(int(data[1]), bool(data[4]))
		"round":
			if data.size() >= 3 and int(data[0]) > round_index:
				round_index = int(data[0])
				team_score = [int(data[1]), int(data[2])]
				_sync_score()
				_reset_round()
		"pick":
			if data.size() >= 3 and int(data[2]) == round_index:
				_set_pick(slot_fighter(int(data[0])), String(data[1]))
	_applying -= 1


func _apply_knock(data: Array) -> void:
	if data.size() < 4:
		return
	var f := slot_fighter(int(data[0]))
	var by := slot_fighter(int(data[1]))
	if f == null or not f.alive:
		return
	var hs := bool(data[2])
	if not f.knocked:
		f.knock(by, hs)
	f.knocked_by = by
	_down_cause[f] = String(data[3])
	if by != null and by.team != f.team:
		by.stats.knocks = int(by.stats.get("knocks", 0)) + 1
		if by == player:
			hud.knock_banner(f.display_name)
	_feed(by, f, String(data[3]), hs, "KNOCKED")
	Game.mark("knocked: slot %d" % f.slot)


func _apply_out(data: Array) -> void:
	if data.size() < 4:
		return
	var f := slot_fighter(int(data[0]))
	var by := slot_fighter(int(data[1]))
	if f == null or not f.alive:
		return
	if by == f:
		by = null
	var hs := bool(data[2])
	var cause := String(data[3])
	_down_cause[f] = cause
	f.last_hit_cause = cause
	if f == player:
		_spectate_killer = by
	f.die(by, hs)
	if by != null and by.team != f.team:
		by.stats.kills = int(by.stats.kills) + 1
		if by == player:
			hud.kill_banner(f.display_name, hs)
	_feed(by, f, cause, hs, "")
	Game.mark("out: slot %d" % f.slot)


func _apply_revive(data: Array) -> void:
	if data.size() < 2:
		return
	var f := slot_fighter(int(data[0]))
	var by := slot_fighter(int(data[1]))
	if f == null or not f.alive or not f.knocked:
		return
	if by != null and by.reviving == f:
		_end_revive(by)
	f.stand_up(Fighter.REVIVE_HP, by)
	if by != null:
		by.stats.revives = int(by.stats.get("revives", 0)) + 1
	_feed(by, f, "", false, "REVIVED")
	Game.mark("revived: slot %d" % f.slot)


## What fighters running here do that the other phone must show (online only; Fighter calls these
## for fighters with net_local set when the arena has them, else the 1 vs 1's net_shot / ...).
func net_shot_by(_f: Fighter, _origin: Vector3, _dir: Vector3) -> void:
	pass


func net_grenade_by(_f: Fighter, _pos: Vector3, _vel: Vector3) -> void:
	pass


func net_wall_by(_f: Fighter, _pos: Vector3, _fwd: Vector3) -> void:
	pass


## RemoteFighter calls this (instead of the 1 vs 1's net_hit) for every hit a fighter running here
## lands on a fighter the other phone runs: the other phone applies it.
func net_hit_by(_target: Fighter, _attacker: Fighter, _amount: float, _zone: String, _from_pos: Vector3) -> void:
	pass
