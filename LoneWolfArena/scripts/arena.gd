extends Node3D
## Match controller of a 1 vs 1 on the warehouse arena CARGO CAGE, first to rounds_to_win rounds:
## TRAINING GROUND against the bot or the target dummy (practice), LONE WOLF against another
## phone online (`mode`, `mode_name`). Each round: PREP (spawn alcoves behind a red barrier,
## weapon pick for both players, red countdown) -> FIGHT (round banner, the two-stage clock of
## RoundRules: stage 1 with the zone over the whole hall, stage 2 with the zone closing) -> a break,
## or END (kill, time-out on HP, or an integrity flag) -> results screen. Also renders the top-down minimap image once, runs the pause menu and feeds the HUD and
## scoreboard.

enum Phase { PREP, FIGHT, END, BREAK }      # BREAK: the pause between two rounds

## Online, after the match: the other player wants a rematch (their REMATCH, event "rm"); the
## results screen offers to accept it.
signal rematch_asked

## The prep of a round that opens a pick pair (the pick panel closes a second before it ends).
const PREP_TIME := 15.0
const PREP_SHORT := 5.0          # the second round of a pick keeps the gun: no pick panel
const BREAK_TIME := 3.5
const SPECTATE_EXTRA := 1.5       # s more between rounds while the eliminated player watches the killer
## The 1 vs 1's fight: stage 1 (the zone holds over the whole hall) and stage 2 (it closes to
## ZONE_MIN); RoundRules has the clock, team_arena.gd a longer SQUAD stage 2 (stage2_time).
const ROUND_TIME := 110.0          # RoundRules.STAGE1_S + RoundRules.STAGE2_S
const ZONE_HOLD := 20.0            # RoundRules.STAGE1_S
const ZONE_SHRINK := 90.0          # RoundRules.STAGE2_S
const ZONE_MIN := 0.5              # RoundRules.ZONE_FINAL_R
## The final centre keeps this far (m, and a metre more) from the hall's walls (zone_final_for).
const ZONE_EDGE := 4.0
## The most rounds a match lasts (the best-of, 2 x rounds_to_win - 1, is never longer): rounds that
## keep ending in draws still end the match, which the most rounds won wins (level: a DRAW).
const MAX_ROUNDS := 9
## Online the results wait this long (real seconds) at most for the other phone's own numbers.
const FINAL_WAIT_S := 3.0
const BOT_NAMES := ["KAI", "REX", "VIPER", "NOVA", "BLAZE", "GHOST", "RAPTOR", "ONYX", "TITAN", "ZED"]
const DUMMY_NAME := "TARGET DUMMY"

var fighters: Array[Fighter] = []
var player: Player
var bot: Bot
var hud: HUD
var map: MapBuilder
var phase := Phase.PREP
var prep_left := PREP_TIME
var time_left := ROUND_TIME
var elapsed := 0.0
var match_time := 0.0
var round_index := 1
var rounds_to_win := Game.ROUNDS_TO_WIN       # Game.rounds_to_win(): a custom room's own number online
## The mode this match is played in (a key of Game.MODE_NAMES): "lonewolf" online, "training"
## against the bot or the target dummy; mode_name is what the HUD, pause menu and results show.
var mode := Game.DEFAULT_MODE
var mode_name := Game.mode_name(Game.DEFAULT_MODE)
var score := {"player": 0, "bot": 0}
var picked_weapon := ""
var pick_note := ""                # prep line under PREPARE: who picks the gun, or which it is
var zone_center := Vector3.ZERO
var zone_radius := 999.0
var zone_start_radius := 30.0
var zone_state := "stationary"      # "stationary" (stage 1), "shrinking" (stage 2), "closed"
var zone_warning := ""
var map_name := "CARGO CAGE"
var map_rect := Rect2(-22, -16, 44, 32)   # world XZ area shown by the minimap
var minimap_texture: Texture2D
var obstacles: Array[Rect2] = []
var cover_points: Array[Vector3] = []
var nav_map := RID()
var env: WorldEnvironment
var sun: DirectionalLight3D
var ui_layer: CanvasLayer
var pause_layer: CanvasLayer
var result := {}
var _zone_mesh: MeshInstance3D
var _outside := {}                  # fighter -> seconds outside the zone (never reset, like the reference)
var _last_count := 99
var _end_t := 0.0
var _result_shown := false
var _winner: Fighter
var _draw := false
var _invalid := false
var _rng := RandomNumberGenerator.new()
var practice := false      # Game.practice: the target dummy with endless HP, no zone, no clock, no record
var online := false        # Game.online: the "bot" is the other phone's player (RemoteFighter, see Cloud)
var _net_t := 0.0
var _net_begun := false
var _net_their_ready := false
var _net_timeup_t := -1.0
var _break_t := 0.0
var _bot_pick_t := -1.0
var _forfeit := false            # the other phone left: the match is ours
var _deaths := 0                 # times this phone's player went down (the result's "deaths")
var _enemy_id := ""              # the online opponent's player id (the result's "enemy_id")
var _counted := false            # Game.count_match counted this match (its first fight began)
var _called_off := false         # online: the session ended with no result to show (_on_net_ended)
var _left_scene := false
var _graphics_on := []           # [graphics, visual effects] apply_graphics last set up
## A custom room's unlimited walls or frags: at most this many per round and player (spawn_cap).
const ROOM_SPAWN_CAP := 30
var _net_buckets := {}           # kind of message from the other phone -> [tokens, ms] (_net_rate_ok)
var _net_spawns := {}            # "wall" / "grenade" -> how many the other phone's player used this round
var _my_spawns := {}             # the same for this phone's player (online, held to spawn_cap)
## Online the host decides each round (_net_decide): the deaths it learned of this round
## ("player" / "bot" as the host sees them -> [killer, headshot, when (s, the guest's one-way trip
## taken off its report)]), decided once the other phone's report of a death up to DEATH_SETTLE_S
## after the first could have come: two deaths that close are one draw on both phones, else the
## first one down loses. The guest reports its own death ("died", with its cause) and applies the
## host's word ("rend": winner, score, round).
const DEATH_SETTLE_S := 0.35
var _round_deaths := {}
var _settle_t := -1.0
var _down_cause := {}            # fighter -> what took them out this round (death_cause)
## Online, once the match is over each phone sends its own player's numbers ("fin": kills, damage,
## headshots, shots, hits; the host adds the match time and both players' HP as it decided with),
## so both results show the same table: the guest takes the time and the HP from the host.
var _their_final := {}
var _final_sent := false
var _net_host := false           # this phone hosts the online match (Game.session.is_host at its start)
var _net_left := false           # this arena is done with its session (leave_session / _exit_tree)
var _rematch_sent := false       # "rm" went out (ask_rematch)
var rematch_wanted := false      # the other player asked for a rematch ("rm", after the match)
var rematch_they_take := true    # ... and their phone takes this one's challenges (their "rm" says)
## A player AWAY (Cloud.peer_away_changed: no link, the app in the background, BACK pressed out of
## the app) is not out of the match: its fighter stands frozen and this phone decides its HP and
## death meanwhile (RemoteFighter.set_away); past Cloud.AWAY_GRACE_MS it has LEFT. Back, it asks
## ("back", once a second while Cloud.rejoining) and takes the other phone's word ("sync",
## _send_sync) before it sends its own states again.
var _back_t := 0.0
var _last_rend: Array = []       # the host's last "rend" (sent again after a "sync")
## The safe zone's centre when it has closed this round (zone_final_for): it moves there from the
## map's centre while it shrinks.
var zone_final := Vector3.ZERO
## This round's ELIMINATED BY card (the HUD draws it while the player spectates): {} until the
## player goes down, then {"cause": death_cause, "name", "gun", "gun_id", "damage" (what the
## killer dealt the player this round)}.
var eliminated_by := {}
## The 1 vs 1 weapon cooldown (RoundRules.cooldown_left): pick round -> the gun picked for that pair
## of rounds, whoever picked it. Both phones fill it alike from the same picks.
var picks := {}


func _ready() -> void:
	_rng.randomize()
	Effects.load_textures()
	map = MapBuilder.new()
	map.build(self)
	env = map.env
	sun = map.sun
	obstacles = map.obstacles
	cover_points = map.cover_points
	map_rect = map.map_rect
	map_name = map.map_name
	zone_center = map.zone_center
	zone_start_radius = map.zone_start_radius
	online = Game.online and Game.session != null and Game.session.in_session
	practice = Game.practice and not online
	mode = "lonewolf" if online else "training"
	mode_name = Game.mode_name(mode) + (" · LOCAL" if online and Game.local_match() else "")   # PLAY WITHOUT INTERNET
	rounds_to_win = Game.rounds_to_win(online)
	if Game.online and not online:
		# The session ended while this phone was loading: back to the lobby, which says why (never
		# a match against the bot instead).
		Game.online = false
		var lost := Game.session != null and Game.session.last_end_reason != "left"
		Game.match_notice = ["CONNECTION LOST" if lost else "OPPONENT LEFT", ("The connection was lost" if lost
			else "The other player left") + " before the match began. Nothing was counted."]
		Game.goto_lobby.call_deferred()
		return
	_build_zone()
	_spawn_fighters()
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 5
	add_child(ui_layer)
	hud = HUD.new()
	ui_layer.add_child(hud)
	hud.bind(player, self)
	hud.pause_pressed.connect(open_pause)
	pause_layer = CanvasLayer.new()
	pause_layer.layer = 10
	pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(pause_layer)
	map.nav.bake_finished.connect(_on_nav_baked)
	map.nav.bake_navigation_mesh(true)
	apply_graphics()
	Game.settings_changed.connect(apply_graphics)
	Guard.tampered.connect(_on_tampered)
	Audio.stop_music()
	Audio.play_ambience("match_ambience", -16.0)
	Effects.warm_up(self)
	_render_minimap.call_deferred()
	if online:
		_net_setup()
	else:
		_start_prep()
	# A detection from before this match (a speed hack switched on in the lobby, a re-signed
	# APK) voids it too: Guard reports each reason only once per session.
	for reason in ["signature", "speed", "memory"]:
		if reason in Guard.flags:
			_on_tampered.call_deferred(reason)
			break


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	Audio.stop_ambience()
	leave_session()


## This match's session is over for this arena: its handlers go and the other phone hears "bye".
## The results' REMATCH calls it before a fresh challenge (or before accepting one): the session
## that challenge starts is not this one, so leaving the tree later must not end it, and the next
## arena reads Game.online from that challenge (set again when it starts).
func leave_session() -> void:
	if not online or _net_left:
		return
	_net_left = true
	Game.online = false
	for sig: String in ["event_received", "state_received", "session_ended", "peer_away_changed"]:
		for c: Dictionary in Game.session.get_signal_connection_list(sig):
			if (c.callable as Callable).get_object() == self:
				Game.session.disconnect(sig, c.callable)
	Game.session.end_session("left")


# ---------------------------------------------------------------- match against another phone (Cloud)

## Both phones load the arena at their own pace: each says "ready", and the host starts the prep
## on both once it has heard the guest.
func _net_setup() -> void:
	_net_host = Game.session.is_host
	Game.session.event_received.connect(_on_net_event)
	Game.session.state_received.connect(_on_net_state)
	Game.session.session_ended.connect(_on_net_ended)
	Game.session.peer_away_changed.connect(_on_peer_away)
	var queued: Array = Game.session.queue.duplicate()
	Game.session.queue.clear()
	Game.session.send_event("ready")
	for q: Array in queued:
		_on_net_event(String(q[0]), q[1])
	Game.mark("online match: " + ("host" if Game.session.is_host else "guest"))


func _net_begin() -> void:
	if _net_begun:
		return
	_net_begun = true
	if Game.session.is_host:
		Game.session.send_event("begin")
	_start_prep()


func _on_net_state(s: PackedFloat32Array) -> void:
	# The last value is the sender's round: a packet from before a round's reset is dropped. The
	# other phone sends 20 a second; far more is a flood (each can switch the gun and the stance).
	if s.size() == RemoteFighter.STATE_SIZE and int(s[s.size() - 1]) == round_index and phase != Phase.BREAK \
			and _net_rate_ok("state", 30.0, 30.0):
		(bot as RemoteFighter).apply_state(s, Game.session.last_state_sent_ms)


func _on_net_event(kind: String, data: Array) -> void:
	var remote := bot as RemoteFighter
	match kind:
		"ready":
			_net_their_ready = true
			if Game.session.is_host:
				_net_begin()
		"begin":
			if not Game.session.is_host:
				_net_begin()
				_follow_host_clock()
		"pick":
			# Its pick for this round (late ones still count: both must hold the same gun).
			# A gun on cooldown is replaced by the first free one, as the picker's phone does.
			if data.size() == 2 and Weapons.PICKABLE.has(String(data[0])) and int(data[1]) == round_index \
					and not _i_pick() and (phase == Phase.PREP or phase == Phase.FIGHT):
				_apply_pick(legal_pick(String(data[0])))
		"shot":
			# Its shots: muzzle flash, tracer, impact and sound here, while the round is fought and
			# never faster than its gun (or fists) fire.
			if data.size() == 6 and phase == Phase.FIGHT:
				var origin := _net_vec(data, 0)
				var dir := _net_vec(data, 3)
				if _in_hall(origin) and dir.is_finite() and _remote_shot_allowed():
					remote.remote_shot(origin, dir)
		"hit":
			# Only while the round is fought, never faster than this round's gun can fire, and never
			# more than one bullet (pellet), punch or frag of it can do: a tampered phone cannot
			# send fake damage.
			if data.size() == 5 and String(data[1]) in ["head", "body", "limb"] and phase == Phase.FIGHT \
					and _remote_hit_allowed():
				var zone := String(data[1])
				var hit_from := _net_vec(data, 2)
				if not _in_hall(hit_from):
					hit_from = remote.global_position
				# A hit says where it came from: its shooter for a bullet or a punch, the blast for a
				# frag (which lands away from the thrower), so the kill feed can name the frag.
				var frag := zone == "body" and hit_from.distance_to(remote.global_position) > 2.5
				player.take_damage(clampf(float(data[0]), 0.0, _max_remote_hit(zone)), zone, remote, hit_from, "frag" if frag else "")
		"died":
			# Its player went down: [headshot, cause, round]. Only a hit of this phone's player
			# ("gun", "frag") is a kill; the zone, a fall or leaving credit nobody.
			if remote.alive and (data.size() == 1 or (data.size() == 3 and int(data[2]) == round_index)) \
					and (phase == Phase.FIGHT or phase == Phase.BREAK):
				var cause := String(data[1]) if data.size() == 3 else "gun"      # (1.1.0 sent only the headshot)
				var by_me := cause in ["gun", "frag"]
				remote.last_hit_cause = cause if cause in ["frag", "zone", "fall", "left", "self"] else ""
				if by_me:
					player.stats.kills += 1
				remote.hp = 0.0                  # (its last state may still carry the HP before the final blow)
				remote.die(player if by_me else null, bool(data[0]) and by_me)
				if by_me:
					hud.confirm_kill(remote.chest_position())     # the kill's sound and buzz, as against the bot
		"grenade":
			if data.size() == 6:
				var at := _net_vec(data, 0)
				var vel := _net_vec(data, 3)
				if vel.is_finite() and _remote_spawn_allowed("grenade", at):
					var g := Grenade.new()
					g.thrower = remote
					g.cosmetic = true          # the thrower's phone deals its damage
					add_child(g)
					g.global_position = at
					g.linear_velocity = vel.limit_length(30.0)
		"wall":
			if data.size() == 4:
				var pos := _net_vec(data, 0)
				var yaw := float(data[3]) if (data[3] is float or data[3] is int) else NAN
				if is_finite(yaw) and _remote_spawn_allowed("wall", pos):
					var wall := ShieldWall.new()
					add_child(wall)
					wall.global_position = pos
					wall.look_at(pos + Vector3(-sin(yaw), 0, -cos(yaw)), Vector3.UP)
		"rend":
			# The host's word on this round: [round, winner (1 the host, -1 this phone, 0 a draw),
			# host's score, this phone's score, timed out, headshot, killer (1 / -1 / 0)].
			if data.size() == 7 and not Game.session.is_host and int(data[0]) == round_index \
					and (phase == Phase.FIGHT or phase == Phase.PREP):
				var w := int(data[1])
				var k := int(data[6])
				score.player = maxi(int(data[3]), 0)
				score.bot = maxi(int(data[2]), 0)
				_end_round((bot as Fighter) if w == 1 else ((player as Fighter) if w == -1 else null), bool(data[5]), bool(data[4]),
					(bot as Fighter) if k == 1 else ((player as Fighter) if k == -1 else null), true)
				if phase == Phase.END:
					_send_final()
		"fin":
			# The match is over on the other phone: its own player's numbers (_send_final). The
			# host's also end this phone's match with its score if its last round left this one
			# waiting for a next round (the host decides when the match ends, the round cap too).
			var f := final_from(data, not _net_host)
			if not f.is_empty() and _their_final.is_empty() and int(data[0]) == round_index \
					and phase in [Phase.FIGHT, Phase.BREAK, Phase.END]:
				_their_final = f
				if not _net_host and phase != Phase.END:
					_conclude_from_host()
		"rm":
			# After the match: the other player tapped REMATCH (the results screen asks this one);
			# [whether their phone takes this one's challenges] (DUEL CHALLENGES FROM).
			if phase == Phase.END and not rematch_wanted and data.size() <= 1:
				rematch_wanted = true
				rematch_they_take = not (data.size() == 1 and data[0] is bool and not bool(data[0]))
				rematch_asked.emit()
		"round":
			# The host starts each next round and sends the score as it counts it.
			if data.size() == 3 and not Game.session.is_host and phase == Phase.BREAK and int(data[0]) == round_index + 1:
				score.player = int(data[2])
				score.bot = int(data[1])
				_next_round()
				_follow_host_clock()
		"back":
			# The other player is back after being away: this phone's word on its fighter.
			if data.is_empty() and _net_rate_ok("back", 2.0, 3.0):
				_send_sync()
		"sync":
			_on_sync(data)


## The other phone's player went AWAY (frozen here, its HP and death decided here) or came back
## (this phone's word on its fighter goes to it at once: "sync").
func _on_peer_away(_id: String, away: bool) -> void:
	if not online or _net_left:
		return
	(bot as RemoteFighter).set_away(away, true)
	if not away:
		_send_sync()


## This phone's word on the other phone's fighter and on the match, for that phone back from being
## away: [round, phase, prep left or fight time, this phone's score, the other's score, its HP,
## alive, x, y, z, the round's gun, what took it out, the match's picks (RoundRules.picks_text: the
## weapon cooldown)]. The fight time is the whole fight's, so both phones show the same stage of the
## two-stage clock. The host's last word on a round that is over
## here ("rend", and "fin" once the match is) goes again after it: the other phone missed it.
func _send_sync() -> void:
	if not session_up():
		return
	var r := bot as RemoteFighter
	var at := r.global_position
	Game.session.send_event("sync", [round_index, int(phase), prep_left if phase == Phase.PREP else elapsed, int(score.player),
		int(score.bot), snappedf(r.hp, 0.1), r.alive, snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01),
		picked_weapon, String(_down_cause.get(r, "")), RoundRules.picks_text(picks)])
	if _net_host and _last_rend.size() == 7 and int(_last_rend[0]) == round_index and (phase == Phase.BREAK or phase == Phase.END):
		Game.session.send_event("rend", _last_rend)
		if phase == Phase.END:
			_final_sent = false
			_send_final()


## The other phone's word ("sync", see _send_sync). The guest takes the host's picks (the weapon
## cooldown) and follows the host's round as it stands (_follow_round); then either takes its own player's HP (never more than it has: no healing back
## what it lost while away), its place and, gone down meanwhile, its death. The host answers with its
## own word, so the guest follows its round.
func _on_sync(data: Array) -> void:
	if data.size() < 12 or data.size() > 13 or not _net_rate_ok("sync", 2.0, 4.0) or not data[6] is bool \
			or typeof(data[10]) != TYPE_STRING or typeof(data[11]) != TYPE_STRING or (data.size() == 13 and typeof(data[12]) != TYPE_STRING):
		return
	for i: int in [0, 1, 2, 3, 4, 5, 7, 8, 9]:
		if not (data[i] is float or data[i] is int) or not is_finite(float(data[i])):
			return
	var r := int(data[0])
	var ph := int(data[1])
	if r < 1 or r > MAX_ROUNDS or ph < 0 or ph > 3:
		return
	Game.session.rejoined()
	if not _net_host:
		if data.size() == 13:
			picks = RoundRules.picks_from_text(String(data[12]), Weapons.PICKABLE)     # the host's cooldowns
		_follow_round(r, ph, float(data[2]), int(data[3]), int(data[4]), String(data[10]))
	if r == round_index and ph == int(phase) and (phase == Phase.FIGHT or phase == Phase.PREP) and player.alive:
		var pos := Vector3(float(data[7]), float(data[8]), float(data[9]))
		if _in_hall(pos) and player.global_position.distance_to(pos) > 1.5:
			player.global_position = pos           # where the others saw it stand meanwhile
			player.velocity = Vector3.ZERO
		var hp := clampf(float(data[5]), 0.0, Fighter.MAX_HP)
		if bool(data[6]) and hp > 0.0:
			player.hp = minf(player.hp, hp)
		elif phase == Phase.FIGHT:
			var cause := String(data[11])
			player.last_hit_cause = cause if cause in ["frag", "zone", "fall", "self"] else ""
			player.hp = 0.0
			player.die(bot if cause in ["gun", "frag"] else null, false)
	if _net_host:
		_send_sync()


## The guest back from being away: the host's round as it stands (it went on meanwhile, or this
## phone went on alone): that round in the host's phase, with the host's score and gun.
func _follow_round(r: int, ph: int, clock: float, host_score: int, my_score: int, gun: String) -> void:
	if phase == Phase.END:
		return
	score.bot = maxi(host_score, 0)
	score.player = maxi(my_score, 0)
	if r != round_index or (ph == int(Phase.FIGHT) and phase != Phase.FIGHT) or (ph == int(Phase.PREP) and phase != Phase.PREP):
		_net_begun = true
		round_index = r - 1
		_next_round()                    # both back at their spawns, in that round's prep
		if ph == int(Phase.FIGHT):
			_start_fight()
	if Weapons.PICKABLE.has(gun) and gun != picked_weapon:
		_apply_pick(gun)
	if phase == Phase.FIGHT and ph == int(Phase.FIGHT):
		elapsed = clampf(clock, 0.0, round_time())
		time_left = round_time() - elapsed
	elif phase == Phase.PREP and ph == int(Phase.PREP):
		prep_left = clampf(clock, 0.0, PREP_TIME)


## The session ended before the match did. "left": the other phone said bye, or went silent while
## this one still hears the relay: once the first fight began that is a forfeit, the match is
## ours. "connection lost": THIS phone lost the relay (no signal, airplane mode, away in the
## background about as long as the other phone waits), which is never a win: a counted match goes
## into the profile as QUIT MATCH puts it (LEFT, a defeat). A match whose first fight had not begun
## counts nowhere either way. Both of those end here and go back to the lobby, which says why.
func _on_net_ended(reason: String) -> void:
	if phase == Phase.END:
		return
	if reason == "left" and _counted:
		_forfeit = true
		var remote := bot as RemoteFighter
		if remote.alive and phase != Phase.BREAK:
			remote.last_hit_cause = "left"          # the kill feed says LEFT, nobody's kill
			remote.die(null, false)
		else:
			_end_round(null)
		hud.show_center("OPPONENT LEFT", 2.5, Color.WHITE, 80, "YOU WIN")
		return
	var lost := reason != "left"
	var counts := _counted and not _invalid
	close_pause()
	record_left()
	_called_off = true
	phase = Phase.END
	_end_t = 0.0
	Engine.time_scale = 1.0
	_freeze_all()
	var title := "CONNECTION LOST" if lost else "OPPONENT LEFT"
	var sub := "THE MATCH COUNTS AS LEFT" if counts else "THE MATCH DID NOT START"
	hud.show_center(title, 2.6, UI.BAD if lost else Color.WHITE, 80, sub)
	Game.match_notice = [title, ("The connection was lost: the match counts as LEFT (a defeat)." if counts
		else ("The connection was lost before the match began. Nothing was counted." if lost
		else "%s left before the match began. Nothing was counted." % bot.display_name))]


## The most one reported hit can do in this zone: a bullet (one pellet) of this round's gun at
## point-blank range, a punch, or (on the body) a frag at its centre, before the armour.
func _max_remote_hit(zone: String) -> float:
	var best := 0.0
	for id: String in [_round_gun(), "fists"]:
		var d: Dictionary = Weapons.DEFS[id]
		best = maxf(best, float(d.damage) * Weapons.zone_mult(d, zone, 0.0) * Weapons.pen_mult(d, zone))
	if zone == "body":
		best = maxf(best, Grenade.MAX_DAMAGE)
	return best * 1.02


func _round_gun() -> String:
	return picked_weapon if Weapons.DEFS.has(picked_weapon) else Weapons.DEFAULT_PICK


## Hit reports may not come faster than the round's gun fires (all its pellets), with headroom for
## network bunching: a token bucket refilled at 1.5 x that rate.
func _remote_hit_allowed() -> bool:
	var d: Dictionary = Weapons.DEFS[_round_gun()]
	var rate := maxf(float(d.pellets) / maxf(float(d.interval), 0.05), 1.0 / 0.45) * 1.5 + 3.0
	return _net_rate_ok("hit", rate, maxf(float(d.pellets) * 3.0, 12.0))


## Shot reports (one per trigger pull, pellets included): the round's gun or the fists, whichever
## fires faster, with the same headroom.
func _remote_shot_allowed() -> bool:
	var interval := minf(float(Weapons.DEFS[_round_gun()].interval), float(Weapons.DEFS.fists.interval))
	return _net_rate_ok("shot", 1.5 / maxf(interval, 0.05) + 2.0, 8.0)


## A wall or grenade of the other phone's player: while the round is fought (or about to be: the
## guest's prep ends a moment after the host's), at a real spot in the hall, within the items that
## player has this round (spawn_cap) and no faster than a hand can use them. Anything else is
## dropped: each one is a body, a mesh, effects and sounds on this phone, so a tampered phone could
## otherwise flood it until it stalls.
func _remote_spawn_allowed(kind: String, pos: Vector3) -> bool:
	if not (phase == Phase.FIGHT or (phase == Phase.PREP and prep_left < 2.0)) or not _in_hall(pos):
		return false
	if int(_net_spawns.get(kind, 0)) >= spawn_cap(kind) or not _net_rate_ok(kind, 2.5, 3.0):
		return false
	_net_spawns[kind] = int(_net_spawns.get(kind, 0)) + 1
	return true


## The walls ("wall") or frags ("grenade") one player may use in a round: the round's starting
## items, or a custom room's unlimited ones up to ROOM_SPAWN_CAP (this phone's player keeps to the
## same number, see _apply_room_rules, so both phones show the same walls).
func spawn_cap(kind: String) -> int:
	if online and bool(Game.room_rules.get("walls" if kind == "wall" else "frags", false)):
		return ROOM_SPAWN_CAP
	return Fighter.START_SHIELDS if kind == "wall" else Fighter.START_GRENADES


## Token bucket per kind of message from the other phone: `burst` at once, then `rate` a second;
## false (drop it) when they come faster.
func _net_rate_ok(kind: String, rate: float, burst: float) -> bool:
	var now := Time.get_ticks_msec()
	var b: Array = _net_buckets.get(kind, [burst, now])
	var tokens := minf(burst, float(b[0]) + float(now - int(b[1])) / 1000.0 * rate)
	var ok := tokens >= 1.0
	_net_buckets[kind] = [tokens - 1.0 if ok else tokens, now]
	return ok


## Three values of an event's data from index i on, as a point or a direction; NaN for what is not
## a number, which every check rejects.
static func _net_vec(data: Array, i: int) -> Vector3:
	var out := Vector3()
	for k in 3:
		var v: Variant = data[i + k]
		out[k] = float(v) if (v is float or v is int) else NAN
	return out


## A point the other phone may name: a real number inside the hall (with a margin), not far above
## or below its floor.
func _in_hall(p: Vector3) -> bool:
	return p.is_finite() and map_rect.grow(2.0).has_point(Vector2(p.x, p.z)) and p.y > -3.0 and p.y < 15.0


## Called by RemoteFighter for every hit this phone's player lands on it.
func net_hit(amount: float, zone: String, from_pos: Vector3) -> void:
	Game.session.send_event("hit", [amount, zone, from_pos.x, from_pos.y, from_pos.z])


func net_shot(origin: Vector3, dir: Vector3) -> void:
	if online:
		Game.session.send_event("shot", [origin.x, origin.y, origin.z, dir.x, dir.y, dir.z])


func net_grenade(pos: Vector3, vel: Vector3) -> void:
	if online:
		_my_spawns["grenade"] = int(_my_spawns.get("grenade", 0)) + 1
		Game.session.send_event("grenade", [pos.x, pos.y, pos.z, vel.x, vel.y, vel.z])


func net_wall(pos: Vector3, fwd: Vector3) -> void:
	if online:
		_my_spawns["wall"] = int(_my_spawns.get("wall", 0)) + 1
		Game.session.send_event("wall", [pos.x, pos.y, pos.z, atan2(-fwd.x, -fwd.z)])


# ---------------------------------------------------------------- world

func _build_zone() -> void:
	_zone_mesh = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 12.0
	cm.cap_top = false
	cm.cap_bottom = false
	cm.radial_segments = 64
	_zone_mesh.mesh = cm
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;
uniform vec4 tint : source_color = vec4(0.35, 0.62, 1.0, 0.42);
void fragment() {
	float stripes = 0.5 + 0.5 * sin((UV.x * 260.0 + UV.y * 30.0) + TIME * 3.0);
	float fade = smoothstep(1.0, 0.35, UV.y) * smoothstep(0.0, 0.08, UV.y);
	ALBEDO = mix(tint.rgb, vec3(1.0), 0.25 * stripes);
	ALPHA = tint.a * (0.4 + 0.6 * stripes) * fade;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	_zone_mesh.material_override = m
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_mesh.layers = CharacterModel.LAYER_ACTORS
	_zone_mesh.visible = false
	add_child(_zone_mesh)


func _spawn_fighters() -> void:
	var pick := String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK))
	if not Weapons.DEFS.has(pick):
		pick = Weapons.DEFAULT_PICK
	player = Player.new()
	player.name = "Player"
	player.display_name = String(Game.profile.name)
	player.arena = self
	add_child(player)
	var guest: bool = online and not Game.session.is_host       # the invited phone starts at the other end
	player.global_position = map.spawn_b if guest else map.spawn_a
	player.setup_fighter(String(Game.profile.bundle), pick)
	player.aim_yaw = map.spawn_b_yaw if guest else map.spawn_a_yaw
	player.hold_fire = true
	fighters.append(player)
	bot = RemoteFighter.new() if online else Bot.new()
	bot.name = "Bot"
	bot.display_name = "BOT " + String(BOT_NAMES[_rng.randi() % BOT_NAMES.size()])
	bot.arena = self
	add_child(bot)
	bot.global_position = map.spawn_a if guest else map.spawn_b
	var bot_bundles := ["desert", "neon", "shadow", "royal", "default"]
	var bot_bundle := String(bot_bundles[_rng.randi() % bot_bundles.size()])
	if online:
		bot.display_name = String(Game.session.opponent.get("name", "PLAYER"))
		bot_bundle = String(Game.session.opponent.get("bundle", "default"))
		_enemy_id = String(Game.session.opponent.get("id", ""))
	bot.setup_fighter(bot_bundle, pick)
	bot.aim_yaw = map.spawn_a_yaw if guest else map.spawn_b_yaw
	bot.configure(int(Game.settings.difficulty), player)
	bot.hold_fire = true
	bot.frozen = true
	if practice:
		bot.display_name = DUMMY_NAME
		bot.endless_hp = true
		player.endless_hp = true
	fighters.append(bot)
	for f in fighters:
		f.died.connect(_on_fighter_died)
		_outside[f] = 0.0


func _on_nav_baked() -> void:
	nav_map = map.nav.get_navigation_map()
	bot.nav_ready = true


func random_nav_point() -> Vector3:
	if nav_map.is_valid():
		for i in 6:
			var p := NavigationServer3D.map_get_random_point(nav_map, 1, false)
			if p != Vector3.ZERO and in_zone(p):
				return p
	return zone_center + Vector3(_rng.randf_range(-8, 8), 0, _rng.randf_range(-8, 8))


func closest_nav_point(p: Vector3) -> Vector3:
	if nav_map.is_valid():
		return NavigationServer3D.map_get_closest_point(nav_map, p)
	return p


## Renders the arena once from straight above (roof and ceiling live on visual layer 2 and
## are skipped) into the minimap texture.
func _render_minimap() -> void:
	await get_tree().process_frame
	var vp := SubViewport.new()
	var aspect := map_rect.size.x / maxf(map_rect.size.y, 0.01)
	vp.size = Vector2i(roundi(512 * aspect), 512)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.transparent_bg = false
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = map_rect.size.y
	cam.cull_mask = 1
	cam.near = 0.5
	cam.far = 60.0
	vp.add_child(cam)
	var c := map_rect.get_center()
	cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(c.x, 30.0, c.y))
	cam.current = true
	# Characters, weapons and the zone wall live on visual layer 3, so the minimap camera
	# (cull mask 1) sees only the floor plan.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if not is_inside_tree() or not is_instance_valid(vp):
		return
	var img := vp.get_texture().get_image()
	if img and not img.is_empty():
		minimap_texture = ImageTexture.create_from_image(img)
	vp.queue_free()


# ---------------------------------------------------------------- settings

## The graphics level and the visual effects on the match (at start and on Game.settings_changed).
## Only a change of those two sets them up again: any other save (the gun pick saves last_pick, the
## pause menu's sensitivity) leaves the frame-rate governor's lowered resolution and measurements
## alone.
func apply_graphics() -> void:
	var g := int(Game.settings.graphics)
	if hud:
		hud.reload_layout()
	var wanted := [g, bool(Game.settings.visual_effects)]
	if wanted == _graphics_on:
		return
	_graphics_on = wanted
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = [0.7, 0.85, 1.0, 1.0][clampi(g, 0, 3)]
	PerfGovernor.attach(self, vp.scaling_3d_scale)       # lowers it while frames run long (and AUTO measures)
	vp.msaa_3d = Viewport.MSAA_2X if g >= 2 else Viewport.MSAA_DISABLED
	if sun:
		sun.shadow_enabled = g >= 1
	RenderingServer.directional_shadow_atlas_set_size(4096 if g >= 3 else 2048, true)
	if env:
		env.environment.glow_enabled = g >= 1
	Effects.configure(g, bool(Game.settings.visual_effects))
	if map:
		map.apply_quality(g)


# ---------------------------------------------------------------- match flow

## The gun is picked every two rounds and the picker alternates (the reference mode's rule):
## rounds 1-2 you (online: the inviter), 3-4 the opponent, and so on. Both fighters get it.
## A custom room's rules: unlimited ammo, walls or frags top this phone's player up (each phone
## runs its own player; both got the same rules with the invite).
func _apply_room_rules() -> void:
	if not online or Game.room_rules.is_empty() or player == null:
		return
	var r: Dictionary = Game.room_rules
	var walls := mini(9, spawn_cap("wall") - int(_my_spawns.get("wall", 0)))
	if bool(r.get("walls", false)) and player.shields < walls:
		player.shields = walls
	var frags := mini(9, spawn_cap("grenade") - int(_my_spawns.get("grenade", 0)))
	if bool(r.get("frags", false)) and player.grenades < frags:
		player.grenades = frags
	if bool(r.get("ammo", false)):
		for w: WeaponState in player.weapons:
			if not w.infinite() and w.reserve < 300:
				w.reserve = 999


## The zone as a round starts: over the whole hall and still. The prep resets it too, so the strip
## and the map never show the round before's closing zone; the fight's start then draws the spot
## it closes on (zone_final).
func _reset_zone() -> void:
	elapsed = 0.0
	zone_radius = zone_start_radius
	zone_state = "stationary"
	zone_center = map.zone_center
	zone_warning = ""
	_update_zone_mesh()


func _start_prep() -> void:
	eliminated_by = {}
	_reset_zone()
	_round_deaths.clear()
	_down_cause.clear()
	_settle_t = -1.0
	_net_spawns.clear()
	_my_spawns.clear()
	_apply_room_rules()
	phase = Phase.PREP
	var pick_round := (round_index - 1) % 2 == 0
	prep_left = PREP_TIME if pick_round else PREP_SHORT
	map.set_barriers(true)
	for f in fighters:
		f.hold_fire = true
	player.frozen = false
	bot.frozen = true
	pick_note = ""
	_bot_pick_t = -1.0
	if pick_round:
		picked_weapon = ""
		if _i_pick():
			var strip := [] if practice else RoundRules.picker_rows(last_round(), not (online and not Game.session.is_host))
			hud.open_weapon_pick(Weapons.PICKABLE, preselected_pick(), prep_left - 1.0, _on_weapon_picked, pick_cooldowns(), strip)
		else:
			pick_note = "%s IS PICKING THE WEAPON" % bot.display_name
			if not online:
				_bot_pick_t = _rng.randf_range(1.5, 3.5)
	else:
		pick_note = "WEAPON: " + String(player.gun().def.name)
	if round_index == 1 and int(Game.profile.matches) < 3:
		hud.tips_time = 9.0
	Game.mark("prep started")


## The guns on cooldown at this round's pick (gun -> rounds left; none against the target dummy).
func pick_cooldowns() -> Dictionary:
	return {} if practice else RoundRules.cooldowns(Weapons.PICKABLE, round_index, picks)


## The gun the pick panel starts on and the one taken when nothing is chosen in time: the last one
## this player picked, or the first free gun when that one rests.
func preselected_pick() -> String:
	return legal_pick(String(Game.settings.get("last_pick", Weapons.DEFAULT_PICK)))


## `id` when it may be picked for this round, else the first free gun (both phones alike).
func legal_pick(id: String) -> String:
	if practice:
		return id if Weapons.DEFS.has(id) else Weapons.DEFAULT_PICK
	return RoundRules.legal_pick(id, Weapons.PICKABLE, round_index, picks)


func _i_pick() -> bool:
	var first := ((round_index - 1) / 2) % 2 == 0
	return not first if online and not Game.session.is_host else first


## This phone's player picked (or the pick timer ran out on its turn).
func _on_weapon_picked(id: String) -> void:
	if not Weapons.DEFS.has(id):
		id = Weapons.DEFAULT_PICK
	id = legal_pick(id)
	Game.settings.last_pick = id
	Game.save_settings()
	_apply_pick(id)
	if online:
		Game.session.send_event("pick", [id, round_index])


## The target dummy: the weapon pick opens again during the fight (the HUD's CHANGE GUN slot), so
## guns can be compared without leaving the match; both fighters get the new gun at once.
func repick() -> void:
	if practice and phase == Phase.FIGHT and not hud.panels.pick_open:
		hud.open_weapon_pick(Weapons.PICKABLE, _round_gun(), PREP_TIME, _on_weapon_picked)


func _apply_pick(id: String) -> void:
	picked_weapon = id
	if not practice:
		picks[RoundRules.pick_round_of(round_index)] = id      # (rests for the next rounds' picks)
	for f in fighters:
		f.set_loadout(id)
	pick_note = "" if _i_pick() else "%s PICKED: %s" % [bot.display_name, String(Weapons.DEFS[id].name)]
	Game.mark("weapon picked: " + id)


func _start_fight() -> void:
	phase = Phase.FIGHT
	_net_timeup_t = -1.0
	if not practice and round_index == 1 and not _counted:
		Game.count_match(mode)
		_counted = true
	if picked_weapon == "" and (round_index - 1) % 2 == 0 and _i_pick():
		hud.close_weapon_pick()
		_on_weapon_picked(preselected_pick())
	pick_note = ""
	map.set_barriers(false)
	for f in fighters:
		f.hold_fire = false
		f.frozen = false
	time_left = round_time()
	_zone_mesh.visible = not practice
	_reset_zone()
	zone_final = zone_final_for(round_index)
	Game.mark("match started")
	if practice:
		_place_dummy()
		zone_radius = 999.0
		hud.show_center(mode_name, 2.0, Color(1.0, 0.82, 0.22), 80, "TARGET DUMMY: IT NEVER GOES DOWN")
	else:
		var point := rounds_to_win > 1 and maxi(int(score.player), int(score.bot)) == rounds_to_win - 1
		var final := rounds_to_win > 1 and round_index >= last_round()
		hud.show_round_banner(round_index, map_name, "FINAL ROUND" if final else ("MATCH POINT!" if point else ""))
	Audio.play("countdown_go", 0.0)


func _physics_process(delta: float) -> void:
	_apply_room_rules()
	if online and phase != Phase.END:
		_net_t += delta
		if _net_t >= float(Game.session.state_interval) - 0.002:      # (3 ticks of 1/60 s add up to a hair under 0.05)
			_back_t -= _net_t
			_net_t = 0.0
			if not Game.session.rejoining():
				Game.session.send_state(RemoteFighter.pack(player, round_index))
			elif _back_t <= 0.0:
				_back_t = 1.0                # back from being away: the other phone's word first ("sync")
				Game.session.send_event("back")
	match phase:
		Phase.PREP when online and not _net_begun:
			pass        # online the first prep starts on both phones together (_net_begin), never alone
		Phase.PREP:
			if _bot_pick_t > 0.0:
				_bot_pick_t -= delta
				if _bot_pick_t <= 0.0:
					_apply_pick(_bot_choice())
			prep_left -= delta
			var n := ceili(prep_left)
			if prep_left <= 3.0 and n != _last_count and n > 0:
				_last_count = n      # the HUD draws the prep countdown; this only beeps
				Audio.play("countdown_beep", -2.0)
			if prep_left <= 0.0:
				_start_fight()
		Phase.FIGHT:
			elapsed += delta
			match_time += delta
			if practice:
				time_left = elapsed          # the clock counts the practice time up
				_refill_practice_ammo()
			else:
				time_left -= delta
				_update_zone(delta)
				if _settle_t >= 0.0:
					_settle_t -= delta
					if _settle_t <= 0.0:
						_net_decide()
				elif time_left <= 0.0:
					if online and not Game.session.is_host:
						# The host's clock decides a time-out ("rend"); decide alone only if its word
						# never comes (the session ends long before, normally).
						_net_timeup_t = maxf(_net_timeup_t, 0.0) + delta
						if _net_timeup_t > 10.0:
							_timeout()
					else:
						_timeout()
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
			# Online the host starts the next round; the guest goes on alone if that never comes.
			var brk := BREAK_TIME + (SPECTATE_EXTRA if player != null and not player.alive else 0.0)
			if (_break_t >= brk and (not online or Game.session.is_host)) or _break_t >= brk + 8.0:
				_next_round()


## The bot's pick: any gun not on cooldown.
func _bot_choice() -> String:
	var free: Array = []
	for g: String in Weapons.PICKABLE:
		if RoundRules.cooldown_left(g, round_index, picks) == 0:
			free.append(g)
	if free.is_empty():
		return legal_pick(Weapons.DEFAULT_PICK)
	return String(free[_rng.randi() % free.size()])


## Both back at their spawns with full HP, items and ammo for the next round (stats carry over).
func _next_round() -> void:
	round_index += 1
	if online and Game.session.is_host:
		Game.session.send_event("round", [round_index, int(score.player), int(score.bot)])
	Engine.time_scale = 1.0
	hud.match_over = false
	for c in get_children():
		if c is ShieldWall or c is Grenade:
			c.queue_free()
	var guest: bool = online and not Game.session.is_host
	player.reset_for_round(map.spawn_b if guest else map.spawn_a, map.spawn_b_yaw if guest else map.spawn_a_yaw)
	bot.reset_for_round(map.spawn_a if guest else map.spawn_b, map.spawn_a_yaw if guest else map.spawn_b_yaw)
	for f in fighters:
		_outside[f] = 0.0
	Game.mark("round %d" % round_index)
	_start_prep()


## The target dummy (TRAINING GROUND's DUMMY): the bot stands still in the open centre bay, facing
## the player's spawn, and takes every hit without going down.
func _place_dummy() -> void:
	bot.frozen = true
	bot.hold_fire = true
	bot.global_position = closest_nav_point(zone_center)
	var d := player.global_position - bot.global_position
	bot.aim_yaw = atan2(-d.x, -d.z)


## Against the target dummy the gun never runs dry (the magazine still needs reloading).
func _refill_practice_ammo() -> void:
	var w := player.weapon()
	if not w.infinite() and w.reserve < int(w.def.mag):
		w.reserve = int(w.def.get("reserve", 0))


## Stage 2's length (s): RoundRules.STAGE2_S; a SQUAD's is longer (team_arena.gd).
func stage2_time() -> float:
	return RoundRules.STAGE2_S


## The whole fight of a round (s): stage 1 and stage 2.
func round_time() -> float:
	return RoundRules.fight_time(stage2_time())


## The stage being fought (1 or 2; the HUD's clock and the checks read it).
func stage() -> int:
	return RoundRules.stage_at(elapsed)


## What the top clock shows in the fight: the seconds left of the current stage.
func stage_left() -> float:
	return RoundRules.stage_left(elapsed, stage2_time())


## Seconds until the zone changes state (for the HUD's "SAFE ZONE" strip): to the start of the
## closing in stage 1, to its end in stage 2.
func zone_next() -> float:
	if zone_state == "closed":
		return 0.0
	return RoundRules.zone_next(elapsed, stage2_time())


## Where the zone will be `t` s into this round's fight: [centre, radius] (the bot heads there).
func zone_at(t: float) -> Array:
	return [RoundRules.zone_center_at(t, map.zone_center, zone_final, stage2_time()),
		RoundRules.zone_radius_at(t, zone_start_radius, stage2_time())]


## Whether this arena applies the zone's damage to `f` (team_arena.gd: only fighters run here).
func zone_hurts(f: Fighter) -> bool:
	return f.alive


func _update_zone(delta: float) -> void:
	var to_start := RoundRules.STAGE1_S - elapsed
	zone_warning = "SAFE ZONE SHRINKS IN %ds" % ceili(to_start) if to_start > 0.0 and to_start < 10.0 else ""
	if elapsed >= RoundRules.STAGE1_S:
		if zone_state == "stationary":
			zone_state = "shrinking"
			hud.show_center("ZONE SHRINKING", 1.6, Color(0.5, 0.75, 1.0), 64)
			Audio.play("countdown_beep", -6.0, 0.7)
		var z := zone_at(elapsed)
		zone_center = z[0]
		zone_radius = z[1]
		if RoundRules.zone_t(elapsed, stage2_time()) >= 1.0:
			zone_state = "closed"
		_update_zone_mesh()
	for f in fighters:
		if zone_hurts(f) and not in_zone(f.global_position):
			_outside[f] = float(_outside[f]) + delta
			var o: float = _outside[f]
			var dps := 5.0 if o < 10.0 else (10.0 if o < 20.0 else 20.0)
			f.take_damage(dps * delta, "zone", null, f.global_position, "zone")


func _update_zone_mesh() -> void:
	_zone_mesh.scale = Vector3(zone_radius, 1.0, zone_radius)
	_zone_mesh.global_position = zone_center + Vector3.UP * 6.0


## Where the safe zone closes in round `r`: a random spot of the hall's floor, the last circle inside
## the walls (MapBuilder.HX / HZ less ZONE_EDGE and a margin) and its centre off the cover (the
## obstacles), a new one every round. Online every phone gets the same (Cloud.match_seed: the room's
## key and the round); TRAINING draws it at random. (The start circle, from the map's centre, always
## holds the final one, and the circles of stage 2 are nested: the centre moves at most 18.9 m in
## stage 2, less than the 27.1 m the radius shrinks.)
func zone_final_for(r: int) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = Game.session.match_seed("zone%d" % r) if online and Game.session != null else _rng.randi()
	var mx := MapBuilder.HX - ZONE_EDGE - 1.0
	var mz := MapBuilder.HZ - ZONE_EDGE - 1.0
	var best := Vector3(map.zone_center.x, 0.0, map.zone_center.z)
	for i in 16:
		var p := Vector3(rng.randf_range(-mx, mx), 0.0, rng.randf_range(-mz, mz))
		var free := true
		for o: Rect2 in obstacles:
			if o.grow(1.0).has_point(Vector2(p.x, p.z)):
				free = false
				break
		if free:
			return p
	return best


func in_zone(p: Vector3) -> bool:
	return Vector2(p.x - zone_center.x, p.z - zone_center.z).length() <= zone_radius


func _timeout(my_hp := -1.0, their_hp := -1.0) -> void:
	if phase != Phase.FIGHT:
		return
	if online and Game.session.is_host and not _forfeit:
		_net_decide(true)
		return
	if my_hp < 0.0:
		my_hp = player.hp
		their_hp = bot.hp
	var winner: Fighter = null
	if absf(my_hp - their_hp) >= 0.5:
		winner = (player as Fighter) if my_hp > their_hp else (bot as Fighter)
	Game.mark("time up")
	_end_round(winner, false, true)


func _freeze_all() -> void:
	hud.match_over = true
	hud.release_all()
	for f in fighters:
		f.frozen = true
		f.round_over = true


func _on_fighter_died(victim: Fighter, killer: Fighter, headshot: bool) -> void:
	Game.mark("%s eliminated" % ("player" if victim == player else "bot"))
	if victim == player:
		_deaths += 1
	var cause := death_cause(victim, killer)
	_down_cause[victim] = cause
	if victim == player:
		_note_eliminated_by(cause, killer)
	if online and victim == player:
		Game.session.send_event("died", [headshot and cause == "gun", cause, round_index])
	if cause == "left":
		hud.add_kill_feed(victim.display_name, "", "", "", false, false, "LEFT")
	elif cause == "zone" or cause == "fall":
		hud.add_kill_feed(cause.to_upper(), victim.display_name, "", "", false, false)      # (no gun to name)
	elif cause == "self":
		hud.add_kill_feed(victim.display_name, victim.display_name, "FRAG", "item_grenade", false, false)
	else:
		var frag := cause == "frag"
		hud.add_kill_feed(killer.display_name, victim.display_name, "FRAG" if frag else String(killer.weapon().def.name),
			"item_grenade" if frag else String(killer.weapon().def.icon), headshot, killer == player)
	if phase == Phase.END or phase == Phase.BREAK:
		return
	if not (killer and is_instance_valid(killer) and killer != victim):
		killer = null
	if online and not _forfeit:
		# The host decides the round (a moment later: a second death that close makes it a draw);
		# the guest waits for its word.
		if Game.session.is_host:
			var trip := _one_way()
			var late := 0.0 if victim == player else trip
			_round_deaths["player" if victim == player else "bot"] = [killer, headshot, Time.get_ticks_msec() / 1000.0 - late]
			if _settle_t < 0.0:
				_settle_t = DEATH_SETTLE_S + trip - late
		return
	var winner := killer if killer else ((player as Fighter) if victim == bot else (bot as Fighter))
	_end_round(winner, headshot, false, killer)


## The ELIMINATED BY card's numbers when the player went down (see eliminated_by).
func _note_eliminated_by(cause: String, killer: Fighter) -> void:
	var by: Fighter = killer if killer != null and is_instance_valid(killer) and killer != player else bot
	var gun_id := String(by.weapon().id) if cause == "gun" and by != null else ""
	eliminated_by = {"cause": cause, "name": by.display_name if by != null else "",
		"gun": "FRAG" if cause == "frag" else (String(by.weapon().def.name) if by != null else ""),
		"gun_id": gun_id, "damage": roundi(float(player.round_taken.get(by, 0.0)))}


## What took a fighter out: "gun" (or fists) and "frag" are the other fighter's kill; "zone",
## "fall", "self" (its own frag) and "left" (it left the match) are nobody's.
static func death_cause(victim: Fighter, killer: Fighter) -> String:
	var c := victim.last_hit_cause
	if c in ["left", "zone", "fall", "self"]:
		return c
	if killer == victim:
		return "self"
	if killer == null or not is_instance_valid(killer):
		return "zone"
	return "frag" if c == "frag" else "gun"


## Online, the host: the round as it stands now (the deaths it learned of; at the time-out the
## higher HP), decided here and sent to the guest ("rend"), which shows exactly this.
func _net_decide(timed_out := false) -> void:
	if phase != Phase.FIGHT:
		return
	_settle_t = -1.0
	var me_dead := _round_deaths.has("player")
	var they_dead := _round_deaths.has("bot")
	if me_dead and they_dead:
		# Both down: that close together a draw, else the first one down loses.
		var dt := float(_round_deaths.player[2]) - float(_round_deaths.bot[2])
		if absf(dt) > DEATH_SETTLE_S:
			_round_deaths.erase("bot" if dt < 0.0 else "player")
			me_dead = dt < 0.0
			they_dead = not me_dead
	var winner: Fighter = null
	var info: Array = [null, false]
	if me_dead != they_dead:
		winner = (bot as Fighter) if me_dead else (player as Fighter)
		info = _round_deaths["player" if me_dead else "bot"]
		timed_out = false
	elif me_dead:
		timed_out = false                # both went down that close: a draw
	elif absf(player.hp - bot.hp) >= 0.5:
		winner = (player as Fighter) if player.hp > bot.hp else (bot as Fighter)
	var killer: Fighter = info[0]
	var hs := bool(info[1])
	if timed_out:
		Game.mark("time up")
	_end_round(winner, hs, timed_out, killer)
	_last_rend = [round_index, 1 if winner == player else (-1 if winner == bot else 0),
		int(score.player), int(score.bot), timed_out, hs, 1 if killer == player else (-1 if killer == bot else 0)]
	Game.session.send_event("rend", _last_rend)
	if phase == Phase.END:
		_send_final()                    # (after its "rend": the guest ends the match with it, then takes these)


## The time a message takes from one phone to the other (s), at most 0.5 s: half the measured round
## trip to it; before that is measured, this phone's round trip to the relay (phone, relay, phone);
## else 0.15 s.
func _one_way() -> float:
	if int(Game.session.peer_rtt) > 0:
		return clampf(float(Game.session.peer_rtt) / 2000.0, 0.0, 0.5)
	if int(Game.session.relay_rtt) > 0:
		return clampf(float(Game.session.relay_rtt) / 1000.0, 0.0, 0.5)
	return 0.15


## The guest's prep starts when the host's "begin" / "round" arrives, the one-way trip late: it is
## shortened by that, so both fights (and their zones) start about together, on the host's clock.
func _follow_host_clock() -> void:
	if phase == Phase.PREP:
		prep_left = maxf(prep_left - _one_way(), 0.5)


## Whether the match is over after round `r` at `mine` : `theirs` rounds won, first to `goal`: a
## side reached it, or that was its last round (the best-of, 2 x goal - 1 rounds, at most
## MAX_ROUNDS; drawn rounds count, so rounds that keep ending in draws still end it).
static func match_over_after(r: int, mine: int, theirs: int, goal: int) -> bool:
	return mine >= goal or theirs >= goal or r >= mini(2 * goal - 1, MAX_ROUNDS)


## The round this match ends with at the latest (FINAL ROUND on its banner).
func last_round() -> int:
	return mini(2 * rounds_to_win - 1, MAX_ROUNDS)


## A round is decided (an elimination, or the time-out: winner null = a draw). The score goes up;
## the match is over once match_over_after says so or when the other phone left; otherwise the next
## round follows a break. Online the host decides (_net_decide) and the guest shows its word.
func _end_round(winner: Fighter, headshot := false, timed_out := false, killer: Fighter = null, synced := false) -> void:
	_settle_t = -1.0
	close_pause()                        # (online the menu is an overlay: the round's end closes it)
	if winner != null and not synced and not _forfeit:      # (a forfeit keeps the real score)
		score["player" if winner == player else "bot"] += 1
	var mine := int(score.player)
	var theirs := int(score.bot)
	var decided := practice or _forfeit or match_over_after(round_index, mine, theirs, rounds_to_win)
	var line := "%d  -  %d" % [mine, theirs]
	_freeze_all()
	if decided:
		_conclude()
	else:
		phase = Phase.BREAK
		_break_t = 0.0
		Game.mark("round over")
	if not decided:
		hud.show_round_result("DRAW" if winner == null else ("VICTORY" if winner == player else "DEFEAT"), mine, theirs)
	elif timed_out:
		hud.show_center("TIME UP", 2.0, Color.WHITE, 96, ("DRAW" if winner == null else "HIGHER HP WINS: " + winner.display_name) + "    " + line)
	elif winner != player and winner != null and not player.alive:
		hud.show_center("ELIMINATED", 2.5, UI.BAD, 100, "%s    %s" % [_how_down(player, killer), line])
	else:
		_show_match_end()
	if not timed_out:
		Engine.time_scale = 0.35
		if killer == player and winner == player:
			hud.kill_banner(bot.display_name, headshot)
		elif winner == player and not bot.alive:
			# Nobody's kill (the zone, a fall, their own frag): no elimination badge, a line that says
			# what took them out instead (a player who left: OPPONENT LEFT says it).
			var cause := String(_down_cause.get(bot, death_cause(bot, killer)))
			if cause in HUD.OUT_LINES:
				hud.out_banner(bot.display_name, cause)
	if winner == player:
		Audio.play("victory_sting", 0.0)
	elif winner != null:
		Audio.play("defeat_sting", 0.0)


## How the player went down, for the ELIMINATED line: by the killer, or in the zone, a fall or by
## their own frag.
func _how_down(victim: Fighter, killer: Fighter) -> String:
	match String(_down_cause.get(victim, death_cause(victim, killer))):
		"gun", "frag":
			return "by %s" % (killer.display_name if killer != null and is_instance_valid(killer) else bot.display_name)
		"fall":
			return "in a fall"
		"self":
			return "by your own frag"
	return "in the zone"


## The match is over (phase END): the most rounds won wins, level is a DRAW, a forfeit is a win.
func _conclude() -> void:
	phase = Phase.END
	_end_t = 0.0
	var mine := int(score.player)
	var theirs := int(score.bot)
	_draw = mine == theirs and not _forfeit
	_winner = null if _draw else ((player as Fighter) if mine > theirs or _forfeit else (bot as Fighter))
	Game.mark("match over: " + ("draw" if _draw else ("won" if _winner == player else "lost")))
	if _winner == player:
		player.model.play_victory()
		player.victory_cam = true


## The match's end in the middle of the screen: VICTORY!, DEFEAT or DRAW with the rounds.
func _show_match_end() -> void:
	var line := "%d  -  %d" % [int(score.player), int(score.bot)]
	if _draw:
		hud.show_center("DRAW", 2.5, Color.WHITE, 100, line)
	elif _winner == player:
		hud.show_center("VICTORY!", 2.5, UI.ACCENT, 110, line)
	else:
		hud.show_center("DEFEAT", 2.5, UI.BAD, 100, line)


## Online, the guest: the host's "fin" says the match is over while this phone still waits for a
## next round (or for the last round's word): it ends here too, with the host's score.
func _conclude_from_host() -> void:
	score.player = int(_their_final.guest_score)
	score.bot = int(_their_final.host_score)
	close_pause()
	_freeze_all()
	_conclude()
	_show_match_end()
	_send_final()


## Online, once the match is over: this phone's own player's numbers to the other phone ("fin":
## [round, match time, host's HP, guest's HP, host's rounds, guest's rounds, kills, damage,
## headshots, shots, hits]; time, HP and rounds only from the host, -1 from the guest), so both
## results show the same table.
func _send_final() -> void:
	if not online or _final_sent or _net_left or not Game.session.in_session:
		return
	_final_sent = true
	var st := player.stats
	var h := _net_host
	Game.session.send_event("fin", [round_index, snappedf(match_time, 0.01) if h else -1.0, _shown_hp(player) if h else -1,
		_shown_hp(bot) if h else -1, int(score.player) if h else -1, int(score.bot) if h else -1,
		int(st.kills), roundi(st.damage), int(st.headshots), int(st.shots), int(st.hits)])


## A "fin" from the other phone, checked: whole numbers in range ({} when anything is off). From the
## host (`from_host`) the time, both HP and both scores must be there too.
static func final_from(data: Array, from_host: bool) -> Dictionary:
	if data.size() != 11:
		return {}
	for v: Variant in data:
		if not (v is int or v is float) or not is_finite(float(v)):
			return {}
	var n := func(i: int) -> int: return roundi(float(data[i]))
	var f := {"time": float(data[1]), "host_hp": n.call(2), "guest_hp": n.call(3), "host_score": n.call(4), "guest_score": n.call(5),
		"kills": n.call(6), "damage": n.call(7), "headshots": n.call(8), "shots": n.call(9), "hits": n.call(10)}
	var ok := int(f.kills) >= 0 and int(f.kills) <= 2 * MAX_ROUNDS and int(f.damage) >= 0 and int(f.damage) <= 100000 \
		and int(f.headshots) >= 0 and int(f.shots) >= 0 and int(f.shots) <= 100000 and int(f.hits) >= 0 \
		and int(f.hits) <= int(f.shots) and int(f.headshots) <= int(f.hits)
	if from_host:
		ok = ok and float(f.time) >= 0.0 and float(f.time) <= 3600.0 and int(f.host_hp) >= 0 and int(f.host_hp) <= int(Fighter.MAX_HP) \
			and int(f.guest_hp) >= 0 and int(f.guest_hp) <= int(Fighter.MAX_HP) and int(f.host_score) >= 0 \
			and int(f.host_score) <= MAX_ROUNDS and int(f.guest_score) >= 0 and int(f.guest_score) <= MAX_ROUNDS
	return f if ok else {}


## A fighter's HP as the results show it: 0 once down; online the guest shows the host's numbers
## (those it decided the rounds with).
func _shown_hp(f: Fighter) -> int:
	if online and not _net_host and _their_final.has("host_hp") and int(_their_final.host_hp) >= 0:
		return int(_their_final.guest_hp if f == player else _their_final.host_hp)
	return roundi(f.hp) if f.alive else 0

## The results' REMATCH: tells the other phone ("rm", with whether this phone takes their
## challenges: `takes`) while the match's session is still up; false when it is not (the results
## then send a fresh challenge).
func ask_rematch(takes := true) -> bool:
	if not session_up() or phase != Phase.END:
		return false
	if not _rematch_sent:
		_rematch_sent = true
		Game.session.send_event("rm", [takes])
	return true


## Whether this phone hosted the online match (its results send the fresh challenge of a rematch).
func hosted() -> bool:
	return online and _net_host


## Whether the online match's session is still up (both phones on their results).
func session_up() -> bool:
	return online and not _net_left and Game.session != null and Game.session.in_session



func _on_tampered(reason: String) -> void:
	if _result_shown:
		return
	_invalid = true          # also when the fight is over but its result not yet recorded
	if phase == Phase.END:
		return
	phase = Phase.END
	_freeze_all()
	hud.show_center("INTEGRITY CHECK FAILED", 3.0, UI.BAD, 60, "this match will not count (%s)" % reason)


func on_gunshot(shooter: Fighter) -> void:
	for f in fighters:
		if f is Bot and f != shooter:
			(f as Bot).hear(shooter.global_position, 1.0)
	if shooter != player and hud:
		hud.reveal(shooter, 2.5)


func on_footstep(f: Fighter) -> void:
	for other in fighters:
		if other is Bot and other != f:
			(other as Bot).hear(f.global_position, 0.35)
	if f != player and hud:
		hud.reveal(f, 1.0)
		hud.footstep(f)


func shake_camera(pos: Vector3, amount: float) -> void:
	if player and player.alive:
		var d := player.global_position.distance_to(pos)
		player.add_shake(amount * clampf(1.0 - d / 25.0, 0.0, 1.0))


## Online the results wait (FINAL_WAIT_S at most) for the other phone's own numbers ("fin"), so
## both show the same table; not after a forfeit or once the other phone is gone.
func _awaits_final() -> bool:
	return online and not _forfeit and not _invalid and _their_final.is_empty() and not _net_left and Game.session.in_session


## Rows for the in-match scoreboard and the results: you first, then the opponent. Online, once the
## match is over, the opponent's row has the numbers its own phone sent ("fin"), and the guest shows
## the host's HP (_shown_hp).
func scoreboard_rows() -> Array:
	var rows := []
	for f in [player, bot]:
		var st: Dictionary = f.stats
		if f == bot and not _their_final.is_empty():
			st = _their_final
		var acc := 0.0 if int(st.shots) == 0 else float(st.hits) / float(st.shots) * 100.0
		rows.append({"name": f.display_name, "me": f == player, "alive": f.alive, "hp": _shown_hp(f),
			"kills": int(st.kills), "damage": roundi(st.damage), "headshots": int(st.headshots),
			"accuracy": roundi(acc), "rounds": int(score["player" if f == player else "bot"]),
			"weapon": String(f.gun().def.name)})
	return rows


# ---------------------------------------------------------------- results / pause

func _show_results() -> void:
	close_pause()
	Engine.time_scale = 1.0
	result = _final_result()
	if not _invalid and _counted:          # (a match is counted when its first fight begins)
		Game.record_match(result)
	var screen := ResultsScreen.new()
	pause_layer.add_child(screen)
	screen.setup(result)
	Game.mark("results shown")


## The decided match's result (phase END); from here on it counts as shown (_result_shown).
func _final_result() -> Dictionary:
	# Read the masked values first: a tamper flag raised by that read still voids the match.
	var hp_left := roundi(player.hp)
	hp_left = _shown_hp(player)          # (0 once down; the guest: the host's number)
	_result_shown = true
	var won := _winner == player and not _draw and not _invalid
	var st := player.stats
	var xp := 0
	if not _invalid and _counted:
		# capped: one opponent, at most one kill per round
		xp = 40 + (120 if won else 0) + mini(int(st.kills), 2 * Game.ROUNDS_TO_WIN - 1) * 30 + mini(int(float(st.damage) / 4.0), 250) + mini(int(st.headshots), 25) * 8
	return _match_result(won, xp, hp_left)


## The match as the results screen and Game.record_match read it (ResultsScreen.setup). "difficulty"
## is the bot's level, or ONLINE (LOCAL: PLAY WITHOUT INTERNET) when the opponent is another player;
## "local" marks a match on the local network (HISTORY shows it); "opponent_left": the other player
## left during the match (a forfeit win). Online the guest's time is the host's ("fin").
func _match_result(won: bool, xp: int, hp_left: int) -> Dictionary:
	var st := player.stats
	var acc := 0.0 if int(st.shots) == 0 else float(st.hits) / float(st.shots) * 100.0
	var t := match_time
	if online and not _net_host and float(_their_final.get("time", -1.0)) >= 0.0:
		t = float(_their_final.time)
	return {
		"won": won, "draw": _draw, "invalid": _invalid, "kills": int(st.kills), "damage": roundi(st.damage),
		"headshots": int(st.headshots), "accuracy": acc, "time": t, "xp": xp, "enemy": bot.display_name,
		"mode": mode_name, "mode_id": mode, "map": map_name, "weapon": String(player.gun().def.name),
		"score_player": int(score.player), "score_bot": int(score.bot), "hp_left": hp_left,
		"difficulty": ("LOCAL" if Game.local_match() else "ONLINE") if online else Game.DIFFICULTY_NAMES[int(Game.settings.difficulty)],
		"taken": int(st.taken), "shots": int(st.shots), "hits": int(st.hits), "deaths": _deaths, "enemy_id": _enemy_id,
		"local": online and Game.local_match(), "opponent_left": _forfeit,
	}


## QUIT MATCH (the pause menu) leaves a counted match before its results: Game.count_match counted
## it when its first fight began, so it goes into the profile now as LEFT, a defeat, with what was
## played so far (rounds, kills, damage, time; no XP): HISTORY then shows the match that CAREER
## counts. A match already decided (online the fight goes on under the pause menu) keeps its own
## result. Not the target dummy (never counted), a voided match or one whose result is in.
func record_left() -> void:
	if not _counted or _result_shown or _invalid:
		return
	if phase == Phase.END:
		result = _final_result()
		if not _invalid:
			Game.record_match(result)
		return
	_result_shown = true
	var r := _match_result(false, 0, roundi(player.hp))
	r.left = true
	Game.record_match(r)
	Game.mark("match left")


## The pause menu, once: online the tree is not paused, so an open menu is what says it is open (a
## back press reaches it, and it closes; switching apps with it open does not stack a second one).
func open_pause() -> void:
	if phase == Phase.END or get_tree().paused:
		return
	for c in pause_layer.get_children():
		if c is PauseMenu and not c.is_queued_for_deletion():
			return
	hud.release_all()
	if not online:                      # an online match keeps running on the other phone
		get_tree().paused = true
	var menu := PauseMenu.new()
	pause_layer.add_child(menu)
	Game.mark("pause opened")
	menu.closed.connect(func() -> void:
		if not online:
			get_tree().paused = false
		Game.mark("pause closed")
		hud.reload_layout())


## Closes an open pause menu (online it is an overlay: the end of a round or of the match closes it).
func close_pause() -> void:
	if pause_layer == null:
		return
	for c in pause_layer.get_children():
		if c is PauseMenu and not c.is_queued_for_deletion():
			c.call("_close")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if phase != Phase.END:
			open_pause()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		if phase == Phase.FIGHT and not get_tree().paused:
			if online:
				hud.release_all()       # the match runs on: a returning player sees it, not a menu
			else:
				open_pause()
