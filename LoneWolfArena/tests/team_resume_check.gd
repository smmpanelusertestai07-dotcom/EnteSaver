extends Node
## An all-human DUO (2 VS 2) over tests/mqtt_mock.gd with FOUR copies of the game (LW_NET_ROLE host,
## m1, m2, m3; tools/qa/run_checks.sh, step "team_resume", one round, LW_AWAY_GRACE_MS longer than
## the check needs). The host opens a CUSTOM ROOM (DUO) with a fixed code and password, the three
## others join it by code, the host starts the match.
## 1. In the fight the HOST goes away (its process stalls AWAY_MS long, nothing sent or heard): on
##    every member its fighter stands frozen ("<NAME> RECONNECTING...") and the stand-in (the present
##    member with the lowest id) decides it: the zone knocks it, then finishes it, and every member
##    sees it out. Back, the host adopts that word: its player is out too.
## 2. Then the member with the highest id (never the host, never the stand-in) is KILLED
##    (LW_RESUME_PART=1: the process exits, nothing says goodbye) and started again (LW_RESUME_PART=2,
##    same data folder): with no tap it is back in the same match (the session file, REJOINING
##    MATCH..., the arena, the host's "sync" and "all"): round 1, the fight, the host's fighter out,
##    nothing counted again. The others saw its fighter AWAY and back meanwhile.
## 3. The host's teammate then goes down in the zone: the host's team is wiped and every copy ends
##    with the same result (the host's team DEFEAT, the other VICTORY).
## Prints "TEAM RESUME CHECK DONE bad=N" ("TEAM RESUME PART 1 DONE bad=N" before the kill).

const CODE := "424242"
const PIN := "4711"
const HOST_AWAY_MS := 7000

var bad := 0
var at: Node
var role := ""
var host := false
var part := 1
var cloud: Cloud


func run(autotest: Node) -> int:
	at = autotest
	role = OS.get_environment("LW_NET_ROLE")
	host = role == "host"
	part = 2 if OS.get_environment("LW_RESUME_PART") == "2" else 1
	cloud = Game.cloud_service()
	at.log_line("team resume check: %s, part %d" % [role, part])
	if part == 2:
		return await _again()
	cloud.start_lobby()
	if not await _until(func() -> bool: return cloud.status == "online" and cloud.my_id != "", 30.0):
		return _done("never online")
	if host:
		await at.wait(1.0)
		cloud.open_room(PIN, {}, CODE, 2)
		if not await _until(func() -> bool: return (cloud.group.get("members", []) as Array).size() == 4, 60.0):
			return _done("the three others never joined the room (%d)" % (cloud.group.get("members", []) as Array).size())
		await at.wait(2.0)
		var why := cloud.room_start()
		if why != "":
			return _done("START refused: " + why)
	else:
		await at.wait(3.0)
		cloud.join_room(CODE, PIN)
	var arena := await _arena(60.0)
	if arena == null:
		return _done("the match did not load")
	await at.wait_for_phase(arena, 1, 60.0)
	if not is_instance_valid(arena) or int(arena.get("phase")) != 1:
		return _done("the fight never began")
	var ids := _ids(arena)
	var host_id := String(arena.get("host_id"))
	var others: Array = ids.keys().filter(func(id: String) -> bool: return id != host_id)
	others.sort()
	var stand_in := String(others[0])
	var killed := String(others[others.size() - 1])
	var hslot := int(ids[host_id])
	var hf := arena.call("slot_fighter", hslot) as Fighter
	var mate := _mate_of(arena, hslot)
	var me := String(cloud.my_id)
	at.log_line("%s: slot %d, host slot %d, stand-in %s, to be killed %s, host's teammate slot %d" % [role, int(ids[me]), hslot,
		"me" if me == stand_in else "other", "me" if me == killed else "other", mate])
	await at.wait(2.0)
	# 1. The host away.
	if host:
		at.log_line("host: away %d ms" % HOST_AWAY_MS)
		OS.delay_msec(HOST_AWAY_MS)
		await at.wait(0.3)
		var me_f := arena.get("player") as Fighter
		if not await _until(func() -> bool: return is_instance_valid(arena) and not me_f.alive, 12.0):
			return _done("back, the host did not adopt its stand-in's word (alive %s, knocked %s, HP %.1f)" % [me_f.alive, me_f.knocked, me_f.hp])
		at.log_line("host: back, its player is out as its stand-in decided")
	else:
		var r := hf as RemoteFighter
		if not await _until(func() -> bool: return is_instance_valid(arena) and r.away, 15.0):
			return _done("the host's fighter was never AWAY")
		at.log_line("%s: the host is AWAY (frozen %s, decided here %s)" % [role, r.away, r.decided_here])
		if me == stand_in:
			if not r.decided_here:
				_fail("the stand-in does not decide the away host's fighter")
			var n := 0
			while r.alive and n < 6:
				n += 1
				r.take_damage(120.0, "body", null, r.global_position, "zone")
				await at.wait(0.4)
			at.log_line("%s: the zone took the host's fighter: alive %s" % [role, r.alive])
		elif r.decided_here:
			_fail("a member that is not the stand-in decides the host's fighter")
		if not await _until(func() -> bool: return is_instance_valid(arena) and not r.alive, 10.0):
			return _done("the away host's fighter was not eliminated here (alive %s, knocked %s)" % [r.alive, r.knocked])
		if not await _until(func() -> bool: return is_instance_valid(arena) and not r.away, 20.0):
			return _done("the host never came back")
		at.log_line("%s: the host's fighter is out, the host is back" % role)
	await at.wait(3.0)
	# 2. One member killed and started again.
	if me == killed:
		at.log_line("%s: matches %d, session file %s" % [role, int(Game.profile.matches), FileAccess.file_exists(Cloud.resume_path())])
		if not FileAccess.file_exists(Cloud.resume_path()):
			_fail("no session file while the all-human match runs")
		if int(Game.profile.matches) != 1:
			_fail("the match was not counted once (%d)" % int(Game.profile.matches))
		at.log_line("TEAM RESUME PART 1 DONE bad=%d" % bad)
		OS.kill(OS.get_process_id())
		return bad
	var kf := arena.call("slot_fighter", int(ids[killed])) as RemoteFighter
	if not await _until(func() -> bool: return is_instance_valid(arena) and kf.away, 20.0):
		return _done("the killed member's fighter was never AWAY")
	if not await _until(func() -> bool: return is_instance_valid(arena) and not kf.away, 40.0):
		return _done("the killed member never came back")
	at.log_line("%s: the killed member is back" % role)
	# 3. The host's teammate goes down: the host's team is wiped.
	if int(ids[me]) == mate:
		await at.wait(3.0)
		await _go_down(arena)
	return await _end(arena, hslot)


## The killed member's new process: back in the same match with no tap.
func _again() -> int:
	var saw_rejoin := [false]
	var watch := func() -> bool:
		var s := get_tree().current_scene
		if s is Lobby and (s as Lobby).dialogs.modal != null and is_instance_valid((s as Lobby).dialogs.modal) \
				and (s as Lobby).dialogs.modal.name == "RejoinModal":
			saw_rejoin[0] = true
		return s is TeamArenaNet
	if not await _until(watch, 40.0):
		return _done("the restarted copy did not go back into its match")
	var arena := get_tree().current_scene
	at.log_line("%s: back in the team arena (REJOINING MATCH... seen %s, resumed %s)" % [role, saw_rejoin[0], cloud.resumed])
	if not cloud.resumed or not cloud.session_multi:
		_fail("the arena after the restart is not the saved all-human session")
	if not await _until(func() -> bool: return is_instance_valid(arena) and not cloud.rejoining() and int(arena.get("phase")) == 1, 30.0):
		return _done("the rejoined arena never took the host's word and entered the fight")
	await at.wait(1.5)
	var ids := _ids(arena)
	var host_id := String(arena.get("host_id"))
	var hslot := int(ids[host_id])
	var hf := arena.call("slot_fighter", hslot) as Fighter
	var me := arena.get("player") as Fighter
	at.log_line("%s: rejoined round %d, phase %d, host's fighter alive %s, own HP %.1f, matches %d" % [role, int(arena.get("round_index")),
		int(arena.get("phase")), hf.alive, me.hp, int(Game.profile.matches)])
	if int(arena.get("round_index")) != 1 or hf.alive or not me.alive:
		_fail("the rejoined arena is not in round 1 with the host's fighter out")
	if int(Game.profile.matches) != 0:
		_fail("the rejoined match was counted again (%d)" % int(Game.profile.matches))
	if int(ids[cloud.my_id]) == _mate_of(arena, hslot):
		await at.wait(3.0)
		await _go_down(arena)
	return await _end(arena, hslot)


## Every copy: the match ends with the host's team beaten.
func _end(arena: Node, hslot: int) -> int:
	if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_result_shown")), 60.0):
		return _done("the match did not end with its result")
	var hist: Array = Game.profile.history
	var h: Dictionary = hist[0] if not hist.is_empty() else {}
	var my_team := int(arena.get("my_team"))
	var host_team := int((arena.call("slot_fighter", hslot) as Fighter).team)
	var want := "lost" if my_team == host_team else "won"
	at.log_line("%s: result %s (want %s), score %s, history %d" % [role, str(h.get("result")), want, str(arena.get("team_score")), hist.size()])
	if h.get("result") != want or hist.size() != 1:
		_fail("the match did not end as one %s here" % want)
	await at.wait(4.0)
	return _done("")


## slot by id from the arena's roster.
func _ids(arena: Node) -> Dictionary:
	var out := {}
	for e: Dictionary in arena.get("roster"):
		out[String(e.id)] = int(e.slot)
	return out


## The slot of the host's teammate.
func _mate_of(arena: Node, hslot: int) -> int:
	var t := int((arena.call("slot_fighter", hslot) as Fighter).team)
	for e: Dictionary in arena.get("roster"):
		if int(e.team) == t and int(e.slot) != hslot:
			return int(e.slot)
	return -1


## This copy's player goes down in the zone (nobody's kill).
func _go_down(arena: Node) -> void:
	var me := arena.get("player") as Fighter
	var n := 0
	while me.alive and n < 20:
		n += 1
		me.take_damage(100.0, "body", null, me.global_position, "zone")
		await at.wait(0.2)
	at.log_line("%s: down in the zone (alive %s)" % [role, me.alive])


func _arena(seconds: float) -> Node:
	if not await _until(func() -> bool: return get_tree().current_scene is TeamArenaNet, seconds):
		return null
	return get_tree().current_scene


func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while not cond.call() and t < seconds:
		await at.wait(0.25)
		t += 0.25
	return cond.call()


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("TEAM RESUME CHECK DONE bad=%d" % bad)
	return bad
