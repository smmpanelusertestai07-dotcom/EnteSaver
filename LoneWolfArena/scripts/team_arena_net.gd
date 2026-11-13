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
##
## AN AWAY HOST (all-human): the host referees, so while it is away nobody would decide for its own
## frozen fighter. The STAND-IN does instead: the present member of the host's own team whose fighter
## is UP, the lowest id of those (stand_in_id, the same on every phone that hears the same members;
## none, nobody decides it meanwhile). For the away host's fighter only, and only
## while the host is away, the stand-in decides its HP (hits from every member reach it, held to the
## guns' rates and bullets as the host holds them, and the zone takes it there), knocks it ("ko") when
## a teammate of it is still UP, else eliminates it ("el"), and bleeds it out; the others take those
## two words from the stand-in for that fighter alone. The host back (its "back" [slot], once a second
## while it rejoins, or heard again), the stand-in sends it "sync" for its fighter as the host would
## (with no stand-in, the present teammate, else member, with the lowest id: _sync_giver_id), with
## flag 4 when it stood in. The host takes it from a teammate (from another member only the round,
## phase, clock and score after a restart): never more HP than it has, and a knock or an elimination
## through its referee only with flag 4; with flag 4 also when it never noticed it was away itself.
## Rounds and every other fighter still wait for the host.
##
## BACK AFTER A RESTART (Cloud.resumed, the sealed session file): a member's fresh arena holds still
## until the host's "sync" for its slot, then enters that round in that phase with the score and the
## clock, and the host's "all" [round, "<slot>:<flags>:<gun>;..."] (flags 1 knocked, 2 out, 4 left)
## puts every fighter as it stands. A host's fresh arena asks with "back" too: its stand-in's "sync"
## brings the round, phase, clock, score and its own fighter, and every member's "rep" [slot, round,
## HP, flags, gun] its own fighter (RESUME_REP_S long); its referee is rebuilt from what they said,
## and until then it decides nothing on the round (_referee_waits). Members who had left before the
## restart stay LEFT (Cloud.left_members, from the session file).
var _dn_log: Array = []              # guest / member: this round's "dn" sent ([round, data])
const RESUME_REP_S := 4.0            # a resumed host takes the members' "rep" this long after its stand-in's "sync"
var _rep_t := -1.0                   # resumed host: s left to take "rep" (and to keep asking with "back")
var _all_wait := false               # resumed member: the host's "all" not taken yet
var _ko_by_stand_in := {}            # slot -> the round the stand-in knocked it in (the host's word on it later is not applied again)
var _stand_in_ko_t := 0              # (inside _apply_stand_in)
var _host_back_ms := -100000         # member: when the host was last heard again after being AWAY
const STOOD_IN_MS := 8000            # a stand-in's "sync" says it stood in (flag 4) this long after the host is back


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
	return f != null and (runs_slot(f.slot) or (f is RemoteFighter and (f as RemoteFighter).decided_here and (am_host or _decides_for(f))))


## All-human: the stand-in referee for an away host (see the notes above): the present member of
## the host's own team whose fighter is UP, the lowest id of those as this phone hears them; "" when
## there is none (nobody decides the host's fighter then) and outside an all-human match. Never a
## member of the other team: its word could end the host's fighter with no hit at all.
func stand_in_id() -> String:
	if not multi or Game.session == null:
		return ""
	var hf := _slot(int(_slot_of.get(host_id, -1)))
	if hf == null:
		return ""
	var best := ""
	for id: String in _slot_of:
		var f := _slot(int(_slot_of[id]))
		if id == host_id or f == null or f.team != hf.team or not f.alive or f.knocked or _gone.has(f.slot) \
				or (id != Game.session.my_id and Game.session.peer_is_away(id)):
			continue
		if best == "" or id < best:
			best = id
	return best


## All-human: the member that answers a host back with "sync" for its fighter: its stand-in; with
## none, the present teammate of the host with the lowest id; with none of those, the present member
## with the lowest id (then only the round, its phase, the clock and the score count on the host).
func _sync_giver_id() -> String:
	var s := stand_in_id()
	if s != "" or not multi or Game.session == null:
		return s
	var hf := _slot(int(_slot_of.get(host_id, -1)))
	var mate := ""
	var any := ""
	for id: String in _slot_of:
		var f := _slot(int(_slot_of[id]))
		if id == host_id or f == null or _gone.has(f.slot) or (id != Game.session.my_id and Game.session.peer_is_away(id)):
			continue
		if any == "" or id < any:
			any = id
		if hf != null and f.team == hf.team and (mate == "" or id < mate):
			mate = id
	return mate if mate != "" else any


## The host: whether a "sync" on its fighter from `from` is taken at all: from a teammate still in the
## match, or, with no teammate here, from the one member _sync_giver_id names.
func _stand_in_sync_from_ok(from: String) -> bool:
	if from == host_id or not _slot_of.has(from):
		return false
	var f := _slot(int(_slot_of[from]))
	if f == null or _gone.has(f.slot):
		return false
	return f.team == player.team or _sync_giver_id() == from


## This phone stands in for the away host and decides `f` meanwhile: `f` is the host's fighter.
func _decides_for(f: Fighter) -> bool:
	return multi and not am_host and f != null and f.slot == int(_slot_of.get(host_id, -1)) and f is RemoteFighter \
		and (f as RemoteFighter).away and stand_in_id() == Game.session.my_id


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
	if multi and am_host and not _net_begun and not _resuming:
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
	if _rep_t > 0.0:
		_rep_t -= dt
		if _rep_t <= 0.0:
			_referee_from_fighters()         # (every "rep" in: the round may be decided from here)
	if Game.session.rejoining() or _rep_t > 0.0:
		if not am_host or (multi and (_resuming or _rep_t > 0.0)):
			# Back from being away: the host's word first ("sync"; a resumed host's: its stand-in's,
			# then the members' "rep"), then this phone's states again.
			_back_t -= dt
			if _back_t <= 0.0:
				_back_t = 1.0
				Game.session.send_event("back", [my_slot])
			if not am_host or _resuming:
				return
		elif multi:
			# The host back from a short absence: its stand-in's word on its fighter ("sync") is taken
			# while Cloud.rejoining; "back" asks for it.
			_back_t -= dt
			if _back_t <= 0.0:
				_back_t = 1.0
				Game.session.send_event("back", [my_slot])
		else:
			Game.session.rejoined()      # (the host is the referee: nobody's word to wait for)
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
	elif _decides_for(f) and _sending():
		# The stand-in's word on the away host's fighter: knocked while a teammate is UP, else out.
		var up := false
		for m in members(f.team):
			if m != f and m.alive and not m.knocked and not _gone.has(m.slot):
				up = true
		var by := killer.slot if killer != null and is_instance_valid(killer) and killer.team != f.team else -1
		var data := [f.slot, by, headshot, cause]
		var kind := "ko" if up and not finished else "el"
		Game.session.send_event(kind, data)
		_apply_stand_in(kind, data)
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


## A knock the stand-in decided is applied once: the host's own word on it later (it adopted the
## stand-in's) changes nothing and credits nobody twice; a revive in between forgets it.
func _apply_decision(kind: String, data: Array) -> void:
	if kind in ["ko", "rv"] and not data.is_empty() and _num_ok(data[0]) and _ko_by_stand_in.has(int(data[0])) and _stand_in_ko_t <= 0:
		var known := int(_ko_by_stand_in[int(data[0])]) == round_index
		_ko_by_stand_in.erase(int(data[0]))
		if kind == "ko" and known:
			return
	super(kind, data)


## The stand-in's knock or elimination of the away host's fighter, here (sender or receiver).
func _apply_stand_in(kind: String, data: Array) -> void:
	if kind == "ko":
		_stand_in_ko_t = 1
		_apply_decision(kind, data)
		_stand_in_ko_t = 0
		_ko_by_stand_in[int(data[0])] = round_index
	else:
		_apply_decision(kind, data)


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
	if Game.session.resumed:
		# Back after a restart (the session file): the match was counted when it began; this arena
		# holds still until the word on where it stands ("sync").
		_resuming = true
		_all_wait = not am_host
		_counted = bool(Game.session.resume_note.get("counted", false))
		var mine := maxi(int(Game.session.resume_note.get("mine", 0)), 0)
		var theirs := maxi(int(Game.session.resume_note.get("theirs", 0)), 0)
		team_score = [mine, theirs] if my_team == 0 else [theirs, mine]
		_sync_score()
		for id: String in Game.session.left_members():
			if _slot_of.has(id):              # (left before the restart: LEFT still, quietly)
				_gone[int(_slot_of[id])] = true
				referee.left[int(_slot_of[id])] = true
		Game.mark("online match rejoined after a restart")
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
		"begin", "tk", "ko", "el", "rv", "rend", "round", "all":
			if from == host_id:
				_on_net_event(kind, data)
			elif kind in ["ko", "el"] and _stand_in_word(data, from):
				_apply_stand_in(kind, data)
		"rm":
			pass                         # (no PLAY AGAIN TOGETHER after an all-human match: the group stays together)
		_:
			_on_net_event(kind, data)
	_from = ""


## A "ko" / "el" from the stand-in (see the notes above): for the host's fighter only, while the host is
## away here, from the member that stands in as this phone hears them, well formed.
func _stand_in_word(data: Array, from: String) -> bool:
	var hf := _slot(int(_slot_of.get(host_id, -1))) as RemoteFighter
	return not am_host and hf != null and hf.away and data.size() == 4 and _slot_at(data, 0) == hf and from == stand_in_id() \
		and from != Game.session.my_id and _decision_ok("ko", data) and phase == Phase.FIGHT


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
					and not rules.gun_forced() and _net_rate_ok("pick%d" % f.slot, 2.0, 4.0):
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
			# A player back from being away asks for the host's word on its fighter; the host back
			# asks its stand-in for the word on its own and every member for its "rep".
			var f := _theirs(data, 0)
			if am_host and data.size() == 1 and f != null and _net_rate_ok("back%d" % f.slot, 2.0, 3.0):
				_send_team_sync(f)
				if multi:
					_send_all()
			elif multi and not am_host and _from == host_id and data.size() == 1 and f != null and _net_rate_ok("back", 2.0, 3.0):
				if _sync_giver_id() == Game.session.my_id:
					_send_team_sync(f)
				_send_rep()
				for d: Array in _dn_log:        # (a host back after a restart never heard them)
					if int(d[1]) == round_index and phase == Phase.FIGHT:
						Game.session.send_event("dn", d)
		"sync":
			if not am_host and (not multi or _from == host_id) and data.size() == 13 and _slot_at(data, 0) == player:
				_on_team_sync(data)
			elif am_host and multi and data.size() == 13 and _slot_at(data, 0) == player and _stand_in_sync_from_ok(_from) and _num_ok(data[7]) \
					and (Game.session.rejoining() or _resuming or (int(data[7]) & 4 and _slot(int(_slot_of[_from])).team == player.team)):
				_on_stand_in_sync(data)
		"all":
			if not am_host and multi and _all_wait and data.size() == 2 and _num_ok(data[0]) and int(data[0]) == round_index \
					and typeof(data[1]) == TYPE_STRING and String(data[1]).length() <= 400:
				_all_wait = false
				_apply_all(String(data[1]))
		"rep":
			var f := _theirs(data, 0)
			if am_host and multi and _rep_t > 0.0 and f != null and data.size() == 5 and _num_ok(data[1]) and int(data[1]) == round_index \
					and _num_ok(data[2]) and _num_ok(data[3]) and typeof(data[4]) == TYPE_STRING and _net_rate_ok("rep%d" % f.slot, 2.0, 3.0):
				_apply_rep(f, int(data[3]), String(data[4]))


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
	var hf := _slot(int(_slot_of.get(host_id, -1))) as RemoteFighter
	if multi and not am_host and hf != null and hf.away:
		hf.set_away(true, _decides_for(hf))        # (the stand-in may have changed: anyone away or back)
	if away or not _sending():
		return
	if multi and not am_host and id == host_id and hf != null:
		_host_back_ms = Time.get_ticks_msec()
		if _sync_giver_id() == Game.session.my_id:
			_send_team_sync(hf)                   # the host is back: the stand-in's word on its fighter
	if am_host:
		for f in back:
			_send_team_sync(f)
		if multi and not back.is_empty():
			_send_all()                  # (a member back after a restart takes every fighter from it)
	elif not multi or id == host_id:
		for d: Array in _dn_log:
			if int(d[1]) == round_index and phase == Phase.FIGHT:
				Game.session.send_event("dn", d)


## The host's word on `f` (a fighter the other phone runs) for that phone back from being away;
## after it the last "rend" when this round is over here (the other phone missed it).
func _send_team_sync(f: Fighter) -> void:
	if not _sending() or f == null or not (am_host or (multi and f.slot == int(_slot_of.get(host_id, -1)))):
		return
	var at := f.global_position
	var by: Fighter = f.knocked_by if f.knocked else f.last_attacker
	# (flag 4, a member's word on the host's fighter: it saw the host away and stood in for it)
	var stood := not am_host and f is RemoteFighter and stand_in_id() == Game.session.my_id \
		and ((f as RemoteFighter).away or Time.get_ticks_msec() - _host_back_ms < STOOD_IN_MS)
	Game.session.send_event("sync", [f.slot, round_index, int(phase), prep_left if phase == Phase.PREP else elapsed,
		int(team_score[0]), int(team_score[1]), snappedf(f.hp, 0.1), (1 if f.knocked else 0) | (0 if f.alive else 2) | (4 if stood else 0),
		snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01),
		by.slot if by != null and is_instance_valid(by) and by.team != f.team else -1, String(_down_cause.get(f, ""))])
	if am_host and _last_rend.size() == 5 and int(_last_rend[0]) == round_index and (phase == Phase.BREAK or phase == Phase.END):
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
	var fresh := _resuming
	if _resuming:
		_resuming = false                # a fresh arena after a restart: into the match from here
		if not _net_begun:
			_net_begun = true
			_start_prep()
		_put_gone_down()
		Game.mark("rejoined: round %d, phase %d" % [r, ph])
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
	elif ph == int(Phase.BREAK) and phase != Phase.BREAK:
		_freeze_all()                    # (the round is over there: the next one comes with the host's "round")
		phase = Phase.BREAK
		_break_t = 0.0
	if fresh and phase != Phase.BREAK:
		_rejoined_quietly()              # (a round already running: no band, no ZONE SHRINKING)
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


## The host: the stand-in's word on its own fighter (see the notes above). After a restart
## (_resuming) it also brings the round, its phase, the clock and the score (as a member takes the
## host's "sync"), and the members' "rep" are taken for RESUME_REP_S. Then its player: where the
## others saw it, never more HP than it has, and a knock or an elimination through the referee.
func _on_stand_in_sync(data: Array) -> void:
	for i: int in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]:
		if not _num_ok(data[i]) or not is_finite(float(data[i])):
			return
	if typeof(data[12]) != TYPE_STRING or not _net_rate_ok("sync", 2.0, 4.0):
		return
	var r := int(data[1])
	var ph := int(data[2])
	if r < 1 or r > MAX_ROUNDS * 2 or ph < 0 or ph > 3 or phase == Phase.END:
		return
	if not _resuming:
		Game.session.rejoined()          # (back from a short absence: the stand-in's word is in)
	else:
		_resuming = false
		_rep_t = RESUME_REP_S
		Game.session.rejoined()
		if not _net_begun:
			_net_begun = true
			_start_prep()
		_put_gone_down()
		Game.mark("rejoined: round %d, phase %d" % [r, ph])
		if r != round_index:
			round_index = r - 1
			_apply_decision("round", [r, int(data[4]), int(data[5])])
		team_score = [maxi(int(data[4]), 0), maxi(int(data[5]), 0)]
		_sync_score()
		if ph == int(Phase.FIGHT) and phase == Phase.PREP:
			_start_fight()
		if phase == Phase.FIGHT and ph == int(Phase.FIGHT):
			elapsed = clampf(float(data[3]), 0.0, round_time())
			time_left = round_time() - elapsed
		elif phase == Phase.PREP and ph == int(Phase.PREP):
			prep_left = clampf(float(data[3]), 0.0, TEAM_PREP_S)
		elif ph == int(Phase.BREAK):
			_freeze_all()
			phase = Phase.BREAK
			_break_t = 0.0
		if phase != Phase.BREAK:
			_rejoined_quietly()          # (a round already running: no band, no ZONE SHRINKING)
	if r != round_index or phase != Phase.FIGHT or ph != int(Phase.FIGHT) or not player.alive:
		return
	var pos := Vector3(float(data[8]), float(data[9]), float(data[10]))
	if _in_hall(pos) and player.global_position.distance_to(pos) > 1.5:
		player.global_position = pos
		player.velocity = Vector3.ZERO
	var flags := int(data[7])
	var mate := _slot(int(_slot_of.get(_from, -1)))
	if mate == null or mate.team != player.team:
		return                           # (no teammate here: the round and the clock only, never this fighter)
	var cause := String(data[12]) if String(data[12]) in CAUSES else "zone"
	var by := int(data[11]) if _slot(int(data[11])) != null and _slot(int(data[11])).team != player.team else -1
	if not flags & 4:
		flags &= ~3                      # (nobody stood in for it: no knock or end of it to take)
	if flags & 3:
		_rebuild_referee()
		if not player.knocked:
			referee_down(my_slot, by, false, cause, false)
		if flags & 2 and player.alive:
			referee_down(my_slot, by, false, cause, true)
	elif not player.knocked:
		player.hp = minf(player.hp, clampf(float(data[6]), 1.0, Fighter.MAX_HP))


## The host's "all" for a member back after a restart: every fighter's knock, out (or left) and gun.
func _send_all() -> void:
	var parts := PackedStringArray()
	for f in slots:
		if f == null:
			continue
		var flags := (1 if f.knocked else 0) | (0 if f.alive else 2) | (4 if _gone.has(f.slot) or referee.left.has(f.slot) else 0)
		parts.append("%d:%d:%s" % [f.slot, flags, String(_picked.get(f.slot, ""))])
	Game.session.send_event("all", [round_index, ";".join(parts)])


## A member back after a restart: the host's "all" read (see _send_all); anything off is skipped.
func _apply_all(text: String) -> void:
	for part: String in text.split(";", false):
		var a := part.split(":")
		if a.size() != 3 or not a[0].is_valid_int() or not a[1].is_valid_int():
			continue
		var f := _slot(a[0].to_int())
		if f == null:
			continue
		var flags := a[1].to_int()
		if Weapons.PICKABLE.has(a[2]) and (phase == Phase.PREP or phase == Phase.FIGHT):
			if f == player:
				if not _picked.has(my_slot) or String(_picked[my_slot]) != a[2]:
					hud.close_weapon_pick()
					_on_weapon_picked(a[2])
			else:
				_set_pick(f, a[2])
		if f == player:
			continue
		if flags & 4:
			_gone[f.slot] = true
		_set_down_quietly(f, flags)


## A fighter put as another phone says it stands (knocked, out), with no kill feed or credit: the
## match is entered again, those words were heard before.
func _set_down_quietly(f: Fighter, flags: int) -> void:
	if not f.alive or phase != Phase.FIGHT:
		return
	_applying += 1
	if flags & 6:
		f.last_hit_cause = "left" if flags & 4 else "gun"
		f.quiet_death = true
		f.die(null, false)
		f.quiet_death = false
	elif flags & 1 and not f.knocked:
		f.knock(null, false)
	_applying -= 1


## After a restart: the fighters of members who had left (the session file's, _net_setup) out,
## with no kill feed, in any phase; the rounds after keep them out (TeamReferee.left).
func _put_gone_down() -> void:
	for s: int in _gone:
		var f := _slot(s)
		if f != null and f.alive:
			_applying += 1
			f.last_hit_cause = "left"
			f.die(null, false)
			_applying -= 1


## A member's word on its own fighter for its host back after a restart (_rep_t).
func _send_rep() -> void:
	if _sending() and phase != Phase.END:
		Game.session.send_event("rep", [my_slot, round_index, snappedf(player.hp, 0.1),
			(1 if player.knocked else 0) | (0 if player.alive else 2), String(_picked.get(my_slot, ""))])


## The resumed host takes a member's "rep": its gun, its knock or end (quietly), then the referee.
func _apply_rep(f: Fighter, flags: int, gun: String) -> void:
	if Weapons.PICKABLE.has(gun) and (phase == Phase.PREP or phase == Phase.FIGHT):
		_set_pick(f, gun)
	_set_down_quietly(f, flags)
	_referee_from_fighters()


## The resumed host's referee rebuilt from its fighters, and a team left with nobody UP wiped ("el").
func _referee_from_fighters() -> void:
	if phase != Phase.FIGHT:
		return
	_rebuild_referee()
	for t: int in [0, 1]:
		if referee.up_count(t) == 0:
			for d: Array in referee._wipe(t):
				var w := [int(d[1]), int(d[2]), bool(d[3]), String(d[4])]
				_announce("el", w)
				_apply_decision("el", w)


## A resumed host decides nothing on the round (no wipe, settle or time-out) until its stand-in's
## "sync" is in and the members' "rep" had RESUME_REP_S to come: its fresh referee knows nothing of
## their knocks and ends yet.
func _referee_waits() -> bool:
	return _resuming or _rep_t > 0.0


## A resumed host's referee from its fighters as they stand (UP, KNOCKED, OUT; those who left).
func _rebuild_referee() -> void:
	for f in slots:
		if f == null:
			continue
		if _gone.has(f.slot):
			referee.left[f.slot] = true
		referee.status[f.slot] = TeamReferee.OUT if not f.alive or _gone.has(f.slot) else (TeamReferee.KNOCKED if f.knocked else TeamReferee.UP)
		if f.knocked and int(referee.knocker.get(f.slot, -1)) == -1 and f.knocked_by != null and is_instance_valid(f.knocked_by):
			referee.knocker[f.slot] = f.knocked_by.slot


## The session file's note on this match (all-human: Cloud keeps it for a restart): counted, the
## score as this phone's team sees it, the round.
func _note() -> void:
	if multi and _sending():
		Game.session.note_match(_counted, int(team_score[my_team]), int(team_score[1 - my_team]), mode_name, round_index, "",
			String(Game.team_match.get("mode_id", "duo")))


func _start_fight() -> void:
	super()
	_note()


func _end_team_round(win_team: int, timed_out: bool) -> void:
	super(win_team, timed_out)
	_note()


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
## round (or of the sidearm while its states have it in hand: Fighter.net_arms) at point-blank
## range, a punch, or (on the body) a frag at its centre, before the armour, x 1.02.
func max_hit_by(attacker: Fighter, zone: String) -> float:
	var best := Weapons.hit_cap(attacker.net_arms(), zone)
	if zone == "body":
		best = maxf(best, Grenade.MAX_DAMAGE)
	return best * 1.02


## Hit reports from one attacker: no faster than the weapons it may hold fire (all their pellets),
## with headroom for network bunching (Arena._remote_hit_allowed per fighter).
func _hit_rate_ok(attacker: Fighter) -> bool:
	var r := Weapons.hit_rate(attacker.net_arms())
	return _net_rate_ok("hit%d" % attacker.slot, r.x, r.y)


func _shot_rate_ok(f: Fighter) -> bool:
	var interval := Weapons.min_interval(f.net_arms())
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
