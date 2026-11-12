class_name TeamArenaNet
extends TeamArena
## A DUO / SQUAD match between TWO phones over Cloud's 1 vs 1 session (scenes/team_arena_net.tscn;
## Game.online true, Game.session the Cloud whose session_team says the size and coop): the room,
## its keys, keep-alives, load stalls, the ping (Cloud.match_ping), chat, voice and the direct path
## are the 1 vs 1's, and so are "ready" / "begin" (Arena._net_setup) and the early way back to the
## lobby when the session ended during the load. `online` is true here, so the pause menu never
## pauses the tree. Overrides only TeamArena's SEAMS (is_referee, runs_here, _fighter_for, _net_tick,
## _report_down, _report_revive, _announce, net_*_by) and the 1 vs 1's _on_net_state /
## _on_net_event / _on_net_ended / _awaits_final / _send_final; the rules stay in TeamArena.
##
## Who runs what: the host (Game.session.is_host, slot 0) runs every bot (as real Bots, net_local)
## and is the referee; each phone runs its own player (the guest: slot 1 in coop, slot `size` in a
## match against the other player). Every fighter the other phone runs is a RemoteFighter here. HP is
## owned by the phone that runs the fighter (the 1 vs 1 rule): a hit on a RemoteFighter goes out
## ("hit") and that phone applies it. Only the host decides knocks, eliminations, revives and rounds:
## the guest reports its own player going down ("dn") and its own finished revives ("rvd"), checks
## nothing it cannot see, and applies the host's decisions.
##
## Messages (Cloud events, at most 16 values each; the fighter's slot first):
##   "tk" [round, sent ms, "<bot states>"]   host, with its state tick: every bot's state packed in one
##                                           string (pack_bots / unpack_bots), as RemoteFighter.pack
##   "pick" [slot, gun, round]  "shot" [slot, ox, oy, oz, dx, dy, dz]  "grenade" [slot, px, py, pz, vx,
##   vy, vz]  "wall" [slot, px, py, pz, yaw]  "hit" [target, attacker, amount, zone, fx, fy, fz]
##   "dn" [slot, round, by_slot, headshot, cause, finished]   guest: its player went down
##   "rvs" [reviver, target] / "rvx" [reviver]                a revive started / stopped (shown)
##   "rvd" [reviver, target, round]                           guest: its player finished a revive
##   "ko" / "el" / "rv" / "rend" / "round"                    host decisions (TeamArena's layouts)
##   "fin" [round, slot, kills, knocks, revives, damage, headshots, shots, hits, deaths]   once the
##                                           match is over, one per fighter the sender runs
##   "rm" [takes]                            after the match: the other player tapped PLAY AGAIN
##                                           TOGETHER / REMATCH on its results (Arena.ask_rematch)
##
## ALL-HUMAN MATCHES (a GROUP's own match, Game.team_match from TeamArena.link_roster, "multi" true;
## Game.session a Cloud with session_multi): every slot is a real player on its own phone, there are
## no bots, and the host (Game.team_match.host_id, the group's leader) referees as above. Each phone
## runs only its own slot; every other one is a RemoteFighter driven by that member's states
## (Cloud.state_from). Events come with their sender (Cloud.event_from): a member speaks only for the
## slot it runs (_theirs checks the sender owns the slot), decisions and "tk" are taken only from the
## host, and a "hit" goes to everyone but only the target's own phone applies it. The host starts
## the first prep once every member's arena said "ready" (READY_WAIT_S at most). A member that leaves
## (Cloud.member_left) is LEFT for the rest of the match (TeamReferee.leave on the host); the host
## leaving ends the match for everyone (ENDED, as the coop guest's). The results offer only LOBBY.
##
## Trust, as in the 1 vs 1: each phone can lie about its own fighter (a modified build can ignore
## hits), and the host about its bots and the rounds; nobody else can send anything (room keys, a
## counter per sender). What the other phone says is held to limits, so a modified build cannot
## crash this one, flood it or deal more than its gun: a hit only on a fighter that runs here, from
## a fighter the sender runs, on the other team and UP, while the round is fought, at most one
## bullet (pellet), punch or frag of the attacker's gun this round x 1.02, and per (kind, slot) no
## faster than that gun fires; a "dn" only for the guest's own slot in this round; a revive only of a
## KNOCKED teammate within reach after a revive start seen long enough before; decisions only from the
## host.

const TK_MAX := 3500                 # longest bot-state string a "tk" may carry
const BOT_VALUES := 9                # x, y, z, yaw, pitch, stance, flags, weapon, hp (RemoteFighter.pack without the round)
const CAUSES := ["gun", "frag", "zone", "fall", "self", "bleed", "left"]
const DECISION_SIZES := {"ko": 4, "el": 4, "rv": 2, "rend": 5, "round": 3}
const FIN_SIZE := 10
const READY_WAIT_S := 20.0           # all-human: the host starts the first prep after this even if a member never said "ready"

var am_host := false                 # this phone hosts: runs the bots, referees
var guest_slot := 1                  # the guest's player (1 in coop, `size` against the other player)
var coop := false
var _tk_last := ""
var _tk_same := 0
var _tk_ms := 0
var _rv_seen := {}                   # host: reviver slot -> [target slot, ms] from the guest's "rvs"
var _spawns := {}                    # "grenade<slot>" / "wall<slot>" -> how many the other phone used this round
var _spawn_round := -1
var _fin_sent := false
var multi := false                   # an all-human match (Cloud.session_multi): every human runs its own slot
var host_id := ""                    # who referees it (Game.team_match.host_id)
var _owner := {}                     # all-human: slot -> the id of the phone that runs it
var _slot_of := {}                   # all-human: id -> slot
var _from := ""                      # all-human: the sender of the event being handled
var _ready_from := {}                # all-human, host: members whose arena said "ready"
var _gone := {}                      # all-human: slot -> true once its member left
var _setup_t := 0.0                  # all-human, host: s since this arena began listening
## AWAY players (Cloud.peer_away_changed): their fighters stand frozen everywhere; the host decides
## the HP, knocks and eliminations of an away player's fighter (runs_here: hits and the zone take
## it on the host, its referee hears its downs) and, the player back ("back" [slot]), sends it its
## word ("sync" [slot, round, phase, prep left or fight time, team 0's and 1's rounds, HP, flags (1
## knocked, 2 out), x, y, z, by slot, cause]); a member sends its own downs of the round again when the
## host is back (they were lost meanwhile: _dn_log).
var _dn_log: Array = []              # guest / member: this round's "dn" sent ([round, data])


func _ready() -> void:
	var tm: Dictionary = Game.team_match
	coop = bool(tm.get("coop", false))
	guest_slot = 1 if coop else int(tm.get("size", 2))
	am_host = Game.session != null and Game.session.is_host
	multi = bool(tm.get("multi", false))
	host_id = String(tm.get("host_id", ""))
	if multi:
		for e: Variant in tm.get("roster", []):
			if e is Dictionary:
				var id := String((e as Dictionary).get("id", ""))
				var s := int((e as Dictionary).get("slot", -1))
				_owner[s] = host_id if bool((e as Dictionary).get("bot", false)) else id
				if id != "":
					_slot_of[id] = s
	super()


# ---------------------------------------------------------------- seams

func is_referee() -> bool:
	return am_host


func runs_here(f: Fighter) -> bool:
	return f != null and (runs_slot(f.slot) or (am_host and f is RemoteFighter and (f as RemoteFighter).decided_here))


## Whether the fighter in `slot` runs on this phone: the host runs every slot but the guest's; in an
## all-human match each phone runs only its own (and the host any bot's).
func runs_slot(slot: int) -> bool:
	if multi:
		return slot == int(Game.team_match.get("my_slot", -1)) or (am_host and String(_owner.get(slot, "")) == host_id \
			and bool(_entry(slot).get("bot", false)))
	return (slot != guest_slot) == am_host


func _fighter_for(entry: Dictionary) -> Fighter:
	if not runs_slot(int(entry.get("slot", -1))):
		return RemoteFighter.new()
	var f := super(entry)
	if f != null:
		f.net_local = true
	return f


## The player's state 20 times a second (Cloud.send_state: the direct path when it is up), and on
## the host one "tk" with every bot's state at the same tick. Revives the other phone runs go on
## here as it said ("rvs"), for the bars. Once the match is over: "fin".
func _net_tick(delta: float) -> void:
	for f in slots:
		if f != null and f.reviving != null and not runs_here(f):
			var tg := f.reviving
			if not f.alive or f.knocked or not is_instance_valid(tg) or not tg.alive or not tg.knocked \
					or f.global_position.distance_to(tg.global_position) > REVIVE_CANCEL_M + 1.5:
				_stop_shown_revive(f)        # (its "rvx" may still come; nothing goes on meanwhile)
			else:
				f.revive_t = minf(f.revive_t + delta, Fighter.REVIVE_S)
	if not _sending():
		return
	if multi and am_host and not _net_begun:
		_setup_t += delta
		if _setup_t > READY_WAIT_S:
			_net_begin()                 # (a member whose arena never got going: the match starts without waiting)
	if phase == Phase.END:
		if not _called_off:
			_send_final()
		return
	_net_t += delta
	if _net_t < float(Game.session.state_interval) - 0.002:
		return
	var dt := _net_t
	_net_t = 0.0
	if Game.session.rejoining():
		if not am_host:
			# Back from being away: the host's word first ("sync"), then this phone's states again.
			_back_t -= dt
			if _back_t <= 0.0:
				_back_t = 1.0
				Game.session.send_event("back", [my_slot])
			return
		Game.session.rejoined()          # (the host is the referee: nobody's word to wait for)
	Game.session.send_state(RemoteFighter.pack(player, round_index))
	if am_host:
		_send_tk()


func _send_tk() -> void:
	var bots: Array = []
	for f in slots:
		if f != player and f.alive and runs_here(f) and not (f is RemoteFighter):
			bots.append(f)
	if bots.is_empty():
		return
	var text := pack_bots(bots)
	var now := Time.get_ticks_msec()
	if text == _tk_last:
		_tk_same += 1
		if _tk_same > 1 and now - _tk_ms < Cloud.STATE_IDLE_MS:
			return                       # (standing still: twice, then every STATE_IDLE_MS, as a state)
	else:
		_tk_same = 0
		_tk_last = text
	_tk_ms = now
	Game.session.send_event("tk", [round_index, now, text])


func _report_down(f: Fighter, killer: Fighter, headshot: bool, cause: String, finished: bool) -> void:
	if am_host:
		super(f, killer, headshot, cause, finished)
	elif f == player and _sending():
		var data := [f.slot, round_index, killer.slot if killer != null and is_instance_valid(killer) else -1, headshot, cause, finished]
		if not _dn_log.is_empty() and int((_dn_log[0] as Array)[1]) != round_index:
			_dn_log.clear()
		_dn_log.append(data)
		Game.session.send_event("dn", data)


func _report_revive(reviver: Fighter, target: Fighter) -> void:
	if am_host:
		super(reviver, target)
	elif reviver == player and target != null and _sending():
		Game.session.send_event("rvd", [reviver.slot, target.slot, round_index])


## The host's decisions and picks go to the guest; from the guest only what its own player does
## ("pick", "rvs", "rvx").
func _announce(kind: String, data: Array) -> void:
	if not _sending():
		return
	if am_host or (kind in ["pick", "rvs", "rvx"] and not data.is_empty() and int(data[0]) == my_slot):
		Game.session.send_event(kind, data)
	if am_host and kind == "rend":
		_last_rend = data.duplicate()


func net_shot_by(f: Fighter, origin: Vector3, dir: Vector3) -> void:
	if _sending() and runs_here(f):
		Game.session.send_event("shot", [f.slot, origin.x, origin.y, origin.z, dir.x, dir.y, dir.z])


func net_grenade_by(f: Fighter, pos: Vector3, vel: Vector3) -> void:
	if _sending() and runs_here(f):
		Game.session.send_event("grenade", [f.slot, pos.x, pos.y, pos.z, vel.x, vel.y, vel.z])


func net_wall_by(f: Fighter, pos: Vector3, fwd: Vector3) -> void:
	if _sending() and runs_here(f):
		Game.session.send_event("wall", [f.slot, pos.x, pos.y, pos.z, atan2(-fwd.x, -fwd.z)])


func net_hit_by(target: Fighter, attacker: Fighter, amount: float, zone: String, from_pos: Vector3) -> void:
	if _sending() and runs_here(attacker) and not runs_here(target):
		Game.session.send_event("hit", [target.slot, attacker.slot, amount, zone, from_pos.x, from_pos.y, from_pos.z])


## Whether this arena still talks to the other phone.
func _sending() -> bool:
	return online and not _net_left and Game.session != null and Game.session.in_session


# ---------------------------------------------------------------- an all-human match's members

## All-human: the arena listens to every member (event_from, state_from, member_left) instead of the
## one opponent; events that came while it loaded are in Cloud.queue with their sender.
func _net_setup() -> void:
	if not multi:
		super()
		return
	_net_host = Game.session.is_host
	Game.session.event_from.connect(_on_event_from)
	Game.session.state_from.connect(_on_state_from)
	Game.session.member_left.connect(_on_member_left)
	Game.session.session_ended.connect(_on_net_ended)
	Game.session.peer_away_changed.connect(_on_peer_away)
	var queued: Array = Game.session.queue.duplicate()
	Game.session.queue.clear()
	Game.session.send_event("ready")
	for q: Array in queued:
		if q.size() == 3:
			_on_event_from(String(q[0]), q[1], String(q[2]))
	Game.mark("online match: " + ("host" if Game.session.is_host else "guest"))


func leave_session() -> void:
	if online and not _net_left and Game.session != null:
		for sig: String in ["event_from", "state_from", "member_left"]:
			for c: Dictionary in Game.session.get_signal_connection_list(sig):
				if (c.callable as Callable).get_object() == self:
					Game.session.disconnect(sig, c.callable)
	super()


## A member's event: the host's word only from the host; anything about a slot only from the member
## that runs it (_theirs, with _from set).
func _on_event_from(kind: String, data: Array, from: String) -> void:
	if not _slot_of.has(from) or _gone.has(int(_slot_of[from])):
		return
	_from = from
	match kind:
		"ready":
			if am_host:
				_ready_from[from] = true
				if _all_ready():
					_net_begin()
		"begin", "tk", "ko", "el", "rv", "rend", "round":
			if from == host_id:
				_on_net_event(kind, data)
		"rm":
			pass                         # (no PLAY AGAIN TOGETHER after an all-human match: the group stays together)
		_:
			_on_net_event(kind, data)
	_from = ""


## Whether every member still in the match has its arena up ("ready").
func _all_ready() -> bool:
	for id: String in _slot_of:
		if id != Game.session.my_id and not _gone.has(int(_slot_of[id])) and not _ready_from.has(id):
			return false
	return true


func _on_state_from(s: PackedFloat32Array, from: String) -> void:
	var slot := int(_slot_of.get(from, -1))
	var f := _slot(slot) as RemoteFighter
	if f != null and not runs_here(f) and s.size() == RemoteFighter.STATE_SIZE and int(s[s.size() - 1]) == round_index \
			and phase != Phase.BREAK and _net_rate_ok("state%d" % slot, 30.0, 30.0):
		f.apply_state(s, Game.session.last_state_sent_ms)


## A member left (said bye, or went silent): its slot is LEFT for the rest of the match.
func _on_member_left(id: String) -> void:
	var slot := int(_slot_of.get(id, -1))
	if slot < 0 or _gone.has(slot):
		return
	_gone[slot] = true
	_ready_from.erase(id)
	var f := _slot(slot)
	if phase != Phase.END:
		if am_host:
			referee_leave(slot)
		if hud != null and f != null:
			hud.show_center("%s LEFT" % f.display_name, 2.0, Color.WHITE, 64)
	if am_host and not _net_begun and _all_ready():
		_net_begin()


# ---------------------------------------------------------------- the other phone

func _on_net_state(s: PackedFloat32Array) -> void:
	var f := _slot(guest_slot if am_host else 0) as RemoteFighter
	if f != null and s.size() == RemoteFighter.STATE_SIZE and int(s[s.size() - 1]) == round_index and phase != Phase.BREAK \
			and _net_rate_ok("state", 30.0, 30.0):
		f.apply_state(s, Game.session.last_state_sent_ms)


func _on_net_event(kind: String, data: Array) -> void:
	match kind:
		"ready", "begin", "rm":
			super(kind, data)            # (Arena: the host starts the first prep on both; "rm": the results' PLAY AGAIN)
		"tk":
			if not am_host and data.size() == 3 and _num_ok(data[0]) and int(data[0]) == round_index and typeof(data[2]) == TYPE_STRING \
					and phase != Phase.BREAK and _net_rate_ok("tk", 30.0, 30.0):
				var sent := int(data[1]) if _num_ok(data[1]) else -1
				var states := unpack_bots(String(data[2]), bot_slots(), round_index)
				for s: int in states:
					var f := _slot(s) as RemoteFighter
					if f != null:
						f.apply_state(states[s], sent)
		"pick":
			var f := _theirs(data, 0)
			if data.size() == 3 and f != null and typeof(data[1]) == TYPE_STRING and Weapons.PICKABLE.has(String(data[1])) \
					and _num_ok(data[2]) and int(data[2]) == round_index and (phase == Phase.PREP or phase == Phase.FIGHT) \
					and _net_rate_ok("pick%d" % f.slot, 2.0, 4.0):
				_apply_decision("pick", [f.slot, String(data[1]), round_index])
		"shot":
			var f := _theirs(data, 0) as RemoteFighter
			if data.size() == 7 and f != null and phase == Phase.FIGHT:
				var origin := _net_vec(data, 1)
				var dir := _net_vec(data, 4)
				if _in_hall(origin) and dir.is_finite() and _shot_rate_ok(f):
					f.remote_shot(origin, dir)
		"grenade":
			var f := _theirs(data, 0)
			if data.size() == 7 and f != null:
				var at := _net_vec(data, 1)
				var vel := _net_vec(data, 4)
				if vel.is_finite() and _spawn_ok("grenade", f, at):
					var g := Grenade.new()
					g.thrower = f
					g.cosmetic = true          # the thrower's phone deals its damage
					add_child(g)
					g.global_position = at
					g.linear_velocity = vel.limit_length(30.0)
		"wall":
			var f := _theirs(data, 0)
			if data.size() == 5 and f != null:
				var pos := _net_vec(data, 1)
				var yaw := float(data[4]) if _num_ok(data[4]) else NAN
				if is_finite(yaw) and _spawn_ok("wall", f, pos):
					var wall := ShieldWall.new()
					add_child(wall)
					wall.global_position = pos
					wall.look_at(pos + Vector3(-sin(yaw), 0, -cos(yaw)), Vector3.UP)
		"hit":
			_on_hit(data)
		"dn":
			_on_down(data)
		"rvs":
			var r := _theirs(data, 0)
			var tg := _slot_at(data, 1)
			if data.size() == 2 and r != null and tg != null and r.alive and not r.knocked and tg.alive and tg.knocked \
					and r.team == tg.team and r != tg and r.global_position.distance_to(tg.global_position) <= Fighter.REVIVE_RANGE + 1.0 \
					and _net_rate_ok("rvs%d" % r.slot, 2.0, 4.0):
				r.reviving = tg
				r.revive_t = 0.0
				tg.revived_by = r
				_rv_seen[r.slot] = [tg.slot, Time.get_ticks_msec()]
		"rvx":
			var r := _theirs(data, 0)
			if data.size() == 1 and r != null:
				_stop_shown_revive(r)
		"rvd":
			_on_revived(data)
		"ko", "el", "rv", "rend", "round":
			# The host's word (never taken from the guest): applied as TeamArena applies its own.
			if not am_host and data.size() == int(DECISION_SIZES[kind]) and _decision_ok(kind, data):
				_apply_decision(kind, data)
				if kind == "round":
					_follow_host_clock()
		"fin":
			var f := _theirs(data, 1)
			var st := fin_from(data)
			if f != null and not st.is_empty() and int(data[0]) == round_index and not final_stats.has(f.slot):
				final_stats[f.slot] = st
		"back":
			# A player back from being away asks for the host's word on its fighter.
			var f := _theirs(data, 0)
			if am_host and data.size() == 1 and f != null and _net_rate_ok("back%d" % f.slot, 2.0, 3.0):
				_send_team_sync(f)
		"sync":
			if not am_host and (not multi or _from == host_id) and data.size() == 13 and _slot_at(data, 0) == player:
				_on_team_sync(data)


## A player went AWAY (`away`) or came back: every fighter its phone runs stands frozen meanwhile
## (decided by the host, see the notes above); back, the host's word goes to it ("sync") and a member
## sends the host its own downs of this round again when it is the host that is back.
func _on_peer_away(id: String, away: bool) -> void:
	if not online or _net_left:
		return
	var back: Array[Fighter] = []
	for f in slots:
		var r := f as RemoteFighter
		if r != null and ((multi and String(_owner.get(f.slot, "")) == id) or (not multi and not runs_slot(f.slot))):
			r.set_away(away, am_host)
			back.append(f)
	if away or not _sending():
		return
	if am_host:
		for f in back:
			_send_team_sync(f)
	elif not multi or id == host_id:
		for d: Array in _dn_log:
			if int(d[1]) == round_index and phase == Phase.FIGHT:
				Game.session.send_event("dn", d)


## The host's word on `f` (a fighter the other phone runs) for that phone back from being away;
## after it the last "rend" when this round is over here (the other phone missed it).
func _send_team_sync(f: Fighter) -> void:
	if not am_host or not _sending() or f == null:
		return
	var at := f.global_position
	var by: Fighter = f.knocked_by if f.knocked else f.last_attacker
	Game.session.send_event("sync", [f.slot, round_index, int(phase), prep_left if phase == Phase.PREP else elapsed,
		int(team_score[0]), int(team_score[1]), snappedf(f.hp, 0.1), (1 if f.knocked else 0) | (0 if f.alive else 2),
		snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01),
		by.slot if by != null and is_instance_valid(by) and by.team != f.team else -1, String(_down_cause.get(f, ""))])
	if _last_rend.size() == 5 and int(_last_rend[0]) == round_index and (phase == Phase.BREAK or phase == Phase.END):
		Game.session.send_event("rend", _last_rend)


## The host's word on this phone's player (see _send_team_sync): its round in its phase, the score,
## then the player's place, HP (never more than it has) and, gone down meanwhile, its knock or end.
func _on_team_sync(data: Array) -> void:
	for i: int in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]:
		if not _num_ok(data[i]) or not is_finite(float(data[i])):
			return
	if typeof(data[12]) != TYPE_STRING or not _net_rate_ok("sync", 2.0, 4.0):
		return
	var r := int(data[1])
	var ph := int(data[2])
	if r < 1 or r > MAX_ROUNDS * 2 or ph < 0 or ph > 3:
		return
	Game.session.rejoined()
	if phase == Phase.END:
		return
	if r != round_index:
		round_index = r - 1
		_apply_decision("round", [r, int(data[4]), int(data[5])])     # (TeamArena: the round reset, its prep)
	team_score = [maxi(int(data[4]), 0), maxi(int(data[5]), 0)]
	_sync_score()
	if ph == int(Phase.FIGHT) and phase == Phase.PREP:
		_net_begun = true
		_start_fight()
	if phase == Phase.FIGHT and ph == int(Phase.FIGHT):
		elapsed = clampf(float(data[3]), 0.0, round_time())
		time_left = round_time() - elapsed
	elif phase == Phase.PREP and ph == int(Phase.PREP):
		prep_left = clampf(float(data[3]), 0.0, TEAM_PREP_S)
	if ph != int(phase) or not player.alive or phase != Phase.FIGHT:
		return
	var pos := Vector3(float(data[8]), float(data[9]), float(data[10]))
	if _in_hall(pos) and player.global_position.distance_to(pos) > 1.5:
		player.global_position = pos           # where the others saw it stand meanwhile
		player.velocity = Vector3.ZERO
	var flags := int(data[7])
	var cause := String(data[12]) if String(data[12]) in CAUSES else "zone"
	var by := int(data[11])
	if flags & 2:
		_apply_decision("el", [my_slot, by, false, cause])
	elif flags & 1:
		if not player.knocked:
			_apply_decision("ko", [my_slot, by, false, cause])
	elif not player.knocked:
		player.hp = minf(player.hp, clampf(float(data[6]), 1.0, Fighter.MAX_HP))


## "hit" [target, attacker, amount, zone, fx, fy, fz]: see the trust notes at the top.
func _on_hit(data: Array) -> void:
	if data.size() != 7 or phase != Phase.FIGHT or typeof(data[3]) != TYPE_STRING or not String(data[3]) in ["head", "body", "limb"] \
			or not _num_ok(data[2]):
		return
	var target := _slot_at(data, 0)
	var attacker := _theirs(data, 1)
	if target == null or attacker == null or not runs_here(target) or attacker.team == target.team or not attacker.alive \
			or attacker.knocked or not target.alive or not _hit_rate_ok(attacker):
		return
	var zone := String(data[3])
	var from := _net_vec(data, 4)
	if not _in_hall(from):
		from = attacker.global_position
	# A hit says where it came from: its shooter for a bullet or a punch, the blast for a frag
	# (which lands away from the thrower), so the kill feed can name the frag.
	var frag := zone == "body" and from.distance_to(attacker.global_position) > 2.5
	target.take_damage(clampf(float(data[2]), 0.0, max_hit_by(attacker, zone)), zone, attacker, from, "frag" if frag else "")


## "dn" (host): the guest's player went down in this round; the referee decides as for its own.
func _on_down(data: Array) -> void:
	if not am_host or data.size() != 6 or not _num_ok(data[1]) or int(data[1]) != round_index or phase != Phase.FIGHT:
		return
	var f := _theirs(data, 0)
	var cause := String(data[4]) if typeof(data[4]) == TYPE_STRING else ""
	var finished := data[5] is bool and bool(data[5])
	if f == null or not f.alive or cause not in CAUSES or finished != f.knocked:
		return
	var killer := _slot_at(data, 2)
	if killer != null and killer.team == f.team and cause != "self":
		killer = null                    # (never a teammate's kill)
	var settling := _settle_t >= 0.0
	_report_down(f, killer, data[3] is bool and bool(data[3]), cause, finished)
	if not settling and phase == Phase.FIGHT and referee.winner() != -1:
		# Its team went down when the guest saw it, a one-way trip ago (as the 1 vs 1's
		# _round_deaths): the other team's moment for a draw is that much shorter.
		_settle_t = maxf(DEATH_SETTLE_S - _one_way(), 0.02)


## "rvd" (host): the guest's player finished a revive; checked against what the host sees.
func _on_revived(data: Array) -> void:
	if not am_host or data.size() != 3 or not _num_ok(data[2]) or int(data[2]) != round_index or phase != Phase.FIGHT:
		return
	var r := _theirs(data, 0)
	var tg := _slot_at(data, 1)
	if r == null or tg == null or r == tg or r.team != tg.team or not r.alive or r.knocked or not tg.alive or not tg.knocked:
		return
	var seen: Array = _rv_seen.get(r.slot, [])
	if seen.size() != 2 or int(seen[0]) != tg.slot or Time.get_ticks_msec() - int(seen[1]) < int((Fighter.REVIVE_S - 0.6) * 1000.0) \
			or r.global_position.distance_to(tg.global_position) > Fighter.REVIVE_RANGE + 1.0:
		return
	_rv_seen.erase(r.slot)
	_stop_shown_revive(r)
	_report_revive(r, tg)


func _stop_shown_revive(r: Fighter) -> void:
	if r.reviving != null and is_instance_valid(r.reviving) and r.reviving.revived_by == r:
		r.reviving.revived_by = null
	r.reviving = null
	r.revive_t = 0.0
	_rv_seen.erase(r.slot)


## A host decision's slots name real fighters (by_slot -1: nobody) and its numbers are numbers.
func _decision_ok(kind: String, data: Array) -> bool:
	for v: Variant in data:
		if typeof(v) not in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL, TYPE_STRING]:
			return false
	match kind:
		"ko", "el":
			return _slot_at(data, 0) != null and _num_ok(data[1]) and int(data[1]) >= -1 and int(data[1]) < slots.size() \
				and typeof(data[3]) == TYPE_STRING and String(data[3]) in CAUSES
		"rv":
			return _slot_at(data, 0) != null and _num_ok(data[1]) and int(data[1]) >= -1 and int(data[1]) < slots.size()
		"rend":
			return _num_ok(data[0]) and int(data[0]) == round_index and _num_ok(data[1]) and int(data[1]) in [-1, 0, 1] \
				and _num_ok(data[2]) and _num_ok(data[3]) and int(data[2]) >= 0 and int(data[3]) >= 0 \
				and int(data[2]) <= MAX_ROUNDS and int(data[3]) <= MAX_ROUNDS
		"round":
			return _num_ok(data[0]) and int(data[0]) == round_index + 1 and _num_ok(data[1]) and _num_ok(data[2]) \
				and int(data[1]) >= 0 and int(data[2]) >= 0 and int(data[1]) <= MAX_ROUNDS and int(data[2]) <= MAX_ROUNDS
	return false


## The most one reported hit by `attacker` can do in this zone: a bullet (one pellet) of its gun this
## round at point-blank range, a punch, or (on the body) a frag at its centre, before the armour,
## x 1.02.
func max_hit_by(attacker: Fighter, zone: String) -> float:
	var best := 0.0
	for d: Dictionary in [attacker.gun().def, Weapons.DEFS.fists]:
		best = maxf(best, float(d.damage) * Weapons.zone_mult(d, zone, 0.0) * Weapons.pen_mult(d, zone))
	if zone == "body":
		best = maxf(best, Grenade.MAX_DAMAGE)
	return best * 1.02


## Hit reports from one attacker: no faster than its gun fires (all its pellets), with headroom for
## network bunching (Arena._remote_hit_allowed per fighter).
func _hit_rate_ok(attacker: Fighter) -> bool:
	var d: Dictionary = attacker.gun().def
	var rate := maxf(float(d.pellets) / maxf(float(d.interval), 0.05), 1.0 / 0.45) * 1.5 + 3.0
	return _net_rate_ok("hit%d" % attacker.slot, rate, maxf(float(d.pellets) * 3.0, 12.0))


func _shot_rate_ok(f: Fighter) -> bool:
	var interval := minf(float(f.gun().def.interval), float(Weapons.DEFS.fists.interval))
	return _net_rate_ok("shot%d" % f.slot, 1.5 / maxf(interval, 0.05) + 2.0, 8.0)


## A wall or frag of a fighter the other phone runs: while the round is fought (or about to be), at
## a real spot in the hall, within that fighter's items this round, no faster than a hand can use them.
func _spawn_ok(kind: String, f: Fighter, pos: Vector3) -> bool:
	if _spawn_round != round_index:
		_spawn_round = round_index
		_spawns.clear()
	if not (phase == Phase.FIGHT or (phase == Phase.PREP and prep_left < 2.0)) or not _in_hall(pos) or not f.alive:
		return false
	var key := "%s%d" % [kind, f.slot]
	if int(_spawns.get(key, 0)) >= spawn_cap(kind) or not _net_rate_ok(key, 2.5, 3.0):
		return false
	_spawns[key] = int(_spawns.get(key, 0)) + 1
	return true


## The fighter in slot data[i] when the other phone runs it (null for anything else); in an
## all-human match only when the member who sent this event runs it.
func _theirs(data: Array, i: int) -> Fighter:
	var f := _slot_at(data, i)
	if f != null and multi and String(_owner.get(f.slot, "")) != _from:
		return null
	return f if f != null and not runs_here(f) else null


## The fighter in slot data[i] (a whole number naming a roster slot), else null.
func _slot_at(data: Array, i: int) -> Fighter:
	if i >= data.size() or not _num_ok(data[i]) or float(data[i]) != floorf(float(data[i])):
		return null
	return _slot(int(data[i]))


func _slot(s: int) -> Fighter:
	return slots[s] if s >= 0 and s < slots.size() else null


static func _num_ok(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))


## The bot slots of the roster (the host runs them).
func bot_slots() -> Array:
	var out := []
	for e: Dictionary in roster:
		if bool(e.get("bot", false)):
			out.append(int(e.get("slot", -1)))
	return out


# ---------------------------------------------------------------- the bots' states ("tk")

## Every bot's state in one string, "slot:x,y,z,yaw,pitch,stance,flags,weapon,hp;..." with short
## numbers (the position to the centimetre, angles to a thousandth, the rest to a tenth).
static func pack_bots(bots: Array) -> String:
	var parts := PackedStringArray()
	for f: Fighter in bots:
		var s := RemoteFighter.pack(f)
		var nums := PackedStringArray()
		for i in BOT_VALUES:
			nums.append(_short(s[i], i))
		parts.append("%d:%s" % [f.slot, ",".join(nums)])
	return ";".join(parts)


static func _short(v: float, i: int) -> String:
	var x := snappedf(v, 0.01 if i < 3 else (0.001 if i < 5 else 0.1))
	if x == floorf(x) and absf(x) < 1.0e9:
		return str(int(x))
	return String.num(x, 2 if i < 3 else (3 if i < 5 else 1))


## A "tk" string read back: slot -> RemoteFighter state (with `round_index` last), only for
## `bot_slots`, each slot once, BOT_VALUES finite numbers each; {} for anything else (too long too).
static func unpack_bots(text: String, bot_slots_list: Array, round_index_now: int) -> Dictionary:
	if text.length() > TK_MAX:
		return {}
	var out := {}
	for part: String in text.split(";", false):
		var kv := part.split(":")
		if kv.size() != 2 or not kv[0].is_valid_int():
			return {}
		var slot := kv[0].to_int()
		if not slot in bot_slots_list or out.has(slot):
			return {}
		var nums := kv[1].split(",")
		if nums.size() != BOT_VALUES:
			return {}
		var s := PackedFloat32Array()
		for n: String in nums:
			if not n.is_valid_float():
				return {}
			var v := n.to_float()
			if not is_finite(v) or absf(v) > 100000.0:
				return {}
			s.append(v)
		s.append(float(round_index_now))
		out[slot] = s
	return out


# ---------------------------------------------------------------- the end

## A "fin" checked: whole numbers in range ({} when anything is off).
static func fin_from(data: Array) -> Dictionary:
	if data.size() != FIN_SIZE:
		return {}
	for v: Variant in data:
		if not _num_ok(v) or float(v) < 0.0 or float(v) > 100000.0:
			return {}
	var n := func(i: int) -> int: return roundi(float(data[i]))
	var st := {"kills": n.call(2), "knocks": n.call(3), "revives": n.call(4), "damage": n.call(5), "headshots": n.call(6),
		"shots": n.call(7), "hits": n.call(8), "deaths": n.call(9), "taken": 0, "healed": 0}
	if int(st.kills) > 8 * MAX_ROUNDS or int(st.knocks) > 8 * MAX_ROUNDS or int(st.revives) > 8 * MAX_ROUNDS \
			or int(st.hits) > int(st.shots) or int(st.headshots) > int(st.hits) or int(st.deaths) > MAX_ROUNDS:
		return {}
	return st


## Once the match is over: the numbers of every fighter this phone runs ("fin"), so both results
## show the same tables.
func _send_final() -> void:
	if _fin_sent or not _sending():
		return
	_fin_sent = true
	_final_sent = true
	for f in slots:
		if runs_here(f):
			var st: Dictionary = f.stats
			Game.session.send_event("fin", [round_index, f.slot, int(st.kills), int(st.get("knocks", 0)), int(st.get("revives", 0)),
				roundi(float(st.damage)), int(st.headshots), int(st.shots), int(st.hits), int(st.get("deaths", 0))])


## The results wait (FINAL_WAIT_S at most) until every fighter the other phone runs has its "fin".
func _awaits_final() -> bool:
	if not _sending() or _forfeit or _invalid:
		return false
	for f in slots:
		if not runs_here(f) and not final_stats.has(f.slot) and not _gone.has(f.slot):
			return true
	return false


## The session ended before the match did. This phone dropped out ("connection lost"): LEFT, as the
## 1 vs 1. The other player left: against them (vs) a forfeit win once the first fight began; in
## coop on the host, the guest's slot is OUT for the rest of the match and the bots play on; in
## coop on the guest the match cannot go on (the bots ran on the host): back to the lobby, the
## match counted as ENDED (no win, no loss) if its first fight began.
func _on_net_ended(reason: String) -> void:
	if phase == Phase.END:
		return
	var other := _slot(guest_slot if am_host else 0)
	var who := other.display_name if other != null else "PLAYER"
	if multi:
		var host_f := _slot(int(_slot_of.get(host_id, -1)))
		who = host_f.display_name if host_f != null and not am_host else "EVERYONE ELSE"
	if reason != "left" or not _counted:
		super(reason)
		if reason == "left":             # (the 1 vs 1's words name an opponent: here the other player)
			var title := ("THE HOST LEFT" if not am_host else "TEAMMATE LEFT") if coop or multi else "OPPONENT LEFT"
			hud.show_center(title, 2.6, Color.WHITE, 80, "THE MATCH DID NOT START")
			Game.match_notice = [title, "%s left before the match began. Nothing was counted." % who]
		return
	if multi:
		# The host refereed (or, on the host, everyone else is gone): the match cannot go on. Counted,
		# it goes into the profile as ENDED: no win, no loss.
		_end_as_ended("THE HOST LEFT" if not am_host else "EVERYONE LEFT")
		return
	if coop and am_host:
		# The guest left: its slot is OUT for the rest of the match ("<NAME> LEFT"); the bots play on.
		referee_leave(guest_slot)
		hud.show_center("%s LEFT" % who, 2.5, Color.WHITE, 72, "YOUR BOTS PLAY ON")
		return
	if coop:
		# The host left: the bots ran there, so the match cannot go on. Counted, it goes into the
		# profile as ENDED: no win, no loss.
		_end_as_ended("THE HOST LEFT")
		return
	# Against the other player: a forfeit, the match is ours (as the 1 vs 1).
	_forfeit = true
	close_pause()
	for f in fighters:
		if not runs_here(f) and f.alive and f.team != my_team:
			f.last_hit_cause = "left"
	_freeze_all()
	_conclude()
	hud.show_center("OPPONENT LEFT", 2.5, Color.WHITE, 80, "YOU WIN")


## The match cannot go on (the referee's phone is gone): back to the lobby, counted as ENDED.
func _end_as_ended(title: String) -> void:
	close_pause()
	if not _result_shown and not _invalid:
		_result_shown = true
		var r := _match_result(false, 0, roundi(player.hp))
		r["ended"] = true
		Game.record_match(r)
	_called_off = true
	phase = Phase.END
	_end_t = 0.0
	Engine.time_scale = 1.0
	_freeze_all()
	hud.show_center(title, 2.6, Color.WHITE, 80, "THE MATCH ENDED")
	Game.match_notice = [title, "%s - THE MATCH ENDED. It counts as ENDED: no win, no loss." % title]
