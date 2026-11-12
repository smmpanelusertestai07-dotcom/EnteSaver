extends Node
## Rejoining an online 1 vs 1 after the app was closed, with two copies of the game (LW_NET_ROLE
## host / guest) through tests/mqtt_mock.gd (tools/qa/run_checks.sh, step "resume", plays first to
## 2 rounds and shortens the grace with LW_AWAY_GRACE_MS). The host challenges, the guest accepts.
## Round 1: the guest goes down in the zone (the host's round). Round 2: in the middle of the fight
## the guest's process EXITS (LW_RESUME_PART=1: killed, as the system kills an app; nothing says
## goodbye) and the step starts a new process of the guest (LW_RESUME_PART=2, same data folder).
## LW_RESUME_RUN=1: it starts at once. With no tap it is back in the same match (REJOINING
## MATCH..., the arena, the host's "sync"): round 2, the fight, the score 0 - 1, its HP no more than
## the host told it; the host saw it frozen (AWAY) meanwhile. The guest then goes down again and both
## end with the same result (the host 2 - 0 VICTORY, the guest 0 - 2 DEFEAT), counted once.
## LW_RESUME_RUN=2: the step starts it only after the grace: the host has its forfeit win (the guest
## LEFT), and the new guest opens in the normal lobby with the match in HISTORY as LEFT, counted
## once, and no session file left. (Automated runs keep the profile in memory only: part 1 checks
## the match was counted once, part 2 that it counts it nowhere again, its matches staying 0.)
## Prints "RESUME CHECK DONE bad=N" (part 1: "RESUME PART 1 DONE bad=N" before it exits).

var bad := 0
var at: Node
var host := false
var run_n := 1
var part := 1
var cloud: Cloud


func run(autotest: Node) -> int:
	at = autotest
	host = OS.get_environment("LW_NET_ROLE") == "host"
	run_n = 2 if OS.get_environment("LW_RESUME_RUN") == "2" else 1
	part = 2 if OS.get_environment("LW_RESUME_PART") == "2" else 1
	cloud = Game.cloud_service()
	at.log_line("resume check: %s, run %d, part %d" % ["host" if host else "guest", run_n, part])
	if not host and part == 2:
		return await _guest_again()
	cloud.invited.connect(func(_who: String) -> void: cloud.answer(true))
	cloud.start_lobby()
	if not await _until(func() -> bool: return cloud.status == "online" and not cloud.peers.is_empty(), 30.0):
		return _done("the other phone was never seen in the lobby")
	if host and not cloud.invite(String(cloud.peers.keys()[0])):
		return _done("invite failed")
	var arena := await _arena(50.0)
	if arena == null:
		return _done("the match did not load")
	await at.wait_for_phase(arena, 1, 40.0)
	if not is_instance_valid(arena) or int(arena.get("phase")) != 1:
		return _done("round 1 never reached its fight")
	if host:
		return await _host(arena)
	# The guest: down in round 1, then killed in round 2's fight.
	await at.wait(1.0)
	_go_down(arena)
	if not await _until(func() -> bool: return is_instance_valid(arena) and int(arena.get("round_index")) == 2 \
			and int(arena.get("phase")) == 1, 40.0):
		return _done("round 2 never reached its fight")
	await at.wait(2.0)
	var sc: Dictionary = arena.get("score")
	at.log_line("guest: round 2 fight, score %d - %d, matches %d, session file %s" % [int(sc.player), int(sc.bot),
		int(Game.profile.matches), FileAccess.file_exists(Cloud.resume_path())])
	if not FileAccess.file_exists(Cloud.resume_path()):
		_fail("no session file while the match runs")
	if int(Game.profile.matches) != 1:
		_fail("the match was not counted once (%d)" % int(Game.profile.matches))
	at.log_line("RESUME PART 1 DONE bad=%d" % bad)
	OS.kill(OS.get_process_id())     # (the system killing the app: no goodbye, nothing saved on the way out)
	return bad


## The host: round 1 is its; in round 2 the guest falls silent (its fighter frozen here), then (run 1)
## comes back and goes down, or (run 2) stays away past the grace: a forfeit.
func _host(arena: Node) -> int:
	var remote := arena.get("bot") as RemoteFighter
	var seen := []                       # [away, round, frozen] as Cloud said it, in order
	cloud.peer_away_changed.connect(func(_id: String, away: bool) -> void:
		if is_instance_valid(arena):
			seen.append([away, int(arena.get("round_index")), remote.away]))
	if not await _until(func() -> bool: return is_instance_valid(arena) and int(arena.get("round_index")) == 2 \
			and int(arena.get("phase")) == 1, 50.0):
		return _done("round 2 never reached its fight")
	if not await _until(func() -> bool: return not seen.is_empty(), 20.0):
		return _done("the guest's fighter was never taken for AWAY after its app was closed")
	at.log_line("host: the guest is AWAY (frozen %s, at %.1f HP)" % [remote.away, remote.hp])
	if run_n == 1:
		if not await _until(func() -> bool: return seen.size() >= 2, 30.0):
			return _done("the guest never came back after its restart")
		at.log_line("host: away and back as seen: %s" % str(seen))
		if not (bool(seen[0][0]) and bool(seen[0][2]) and int(seen[0][1]) == 2 and not bool(seen[1][0]) and int(seen[1][1]) == 2):
			_fail("the guest was not AWAY (frozen) and then back in round 2")
	if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_result_shown")), 60.0):
		return _done("the host's match did not end with its result")
	var hist: Array = Game.profile.history
	var h: Dictionary = hist[0] if not hist.is_empty() else {}
	var sc: Dictionary = arena.get("score")
	at.log_line("host: result %s, score %d - %d, forfeit %s, matches %d, history %d" % [str(h.get("result")), int(sc.player),
		int(sc.bot), arena.get("_forfeit"), int(Game.profile.matches), hist.size()])
	if h.get("result") != "won" or hist.size() != 1 or int(Game.profile.matches) != 1:
		_fail("the host's match did not end as one win")
	if run_n == 1 and (bool(arena.get("_forfeit")) or int(sc.player) != 2 or int(sc.bot) != 0):
		_fail("the rejoined match did not play on to 2 - 0")
	if run_n == 2 and not bool(arena.get("_forfeit")):
		_fail("a guest away past the grace was not taken for LEFT (a forfeit)")
	await at.wait(3.0)
	return _done("")


## The guest's new process: rejoins on its own (run 1), or (run 2, too late) stays in the lobby.
func _guest_again() -> int:
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby or get_tree().current_scene.name == "Arena", 30.0):
		return _done("neither the lobby nor the arena came up")
	if run_n == 2:
		await at.wait(8.0)
		var late_hist: Array = Game.profile.history
		var lh: Dictionary = late_hist[0] if not late_hist.is_empty() else {}
		at.log_line("guest (late): scene %s, in session %s, history %s (%d), matches %d, file %s" % [get_tree().current_scene.name,
			cloud.in_session, str(lh.get("result")), late_hist.size(), int(Game.profile.matches), FileAccess.file_exists(Cloud.resume_path())])
		if not get_tree().current_scene is Lobby or cloud.in_session or Game.online:
			_fail("a restart after the grace did not stay in the lobby")
		if lh.get("result") != "left" or late_hist.size() != 1 or int(Game.profile.matches) != 0:
			_fail("the match left past the grace is not one LEFT, counted once")
		if FileAccess.file_exists(Cloud.resume_path()):
			_fail("the session file outlived the grace")
		return _done("")
	var saw_rejoin := [false]
	var watch := func() -> bool:
		var s := get_tree().current_scene
		if s is Lobby and (s as Lobby).dialogs.modal != null and is_instance_valid((s as Lobby).dialogs.modal) \
				and (s as Lobby).dialogs.modal.name == "RejoinModal":
			saw_rejoin[0] = true
		return s != null and s.name == "Arena"
	if not await _until(watch, 30.0):
		return _done("the restarted copy did not go back into its match")
	var arena := get_tree().current_scene
	at.log_line("guest: back in the arena (REJOINING MATCH... seen %s, resumed %s)" % [saw_rejoin[0], cloud.resumed])
	if not cloud.resumed:
		_fail("the arena after the restart is not the saved session")
	if not await _until(func() -> bool: return is_instance_valid(arena) and not cloud.rejoining() and int(arena.get("phase")) == 1, 30.0):
		return _done("the rejoined arena never took the host's word and entered the fight")
	var me := arena.get("player") as Fighter
	var sc: Dictionary = arena.get("score")
	at.log_line("guest: rejoined round %d, phase %d, score %d - %d, HP %.1f, matches %d" % [int(arena.get("round_index")),
		int(arena.get("phase")), int(sc.player), int(sc.bot), me.hp, int(Game.profile.matches)])
	if int(arena.get("round_index")) != 2 or int(sc.player) != 0 or int(sc.bot) != 1:
		_fail("the rejoined arena is not in round 2 at 0 - 1")
	if int(Game.profile.matches) != 0:
		_fail("the rejoined match was counted again (%d)" % int(Game.profile.matches))
	# Back in a round already running: neither its ROUND / AREA band nor a ZONE SHRINKING line.
	var hud_n := arena.get("hud") as Node
	var band: Dictionary = hud_n.get("_round_banner") if hud_n else {}
	var centre: Dictionary = hud_n.get("_center") if hud_n else {}
	if float(band.get("t", 0.0)) > 0.0 or String(centre.get("text", "")) == "ZONE SHRINKING":
		_fail("the rejoin into a running round shows its round band or ZONE SHRINKING (band %.1f s, centre %s)"
			% [float(band.get("t", 0.0)), String(centre.get("text", ""))])
	await at.wait(2.0)
	_go_down(arena)
	if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_result_shown")), 30.0):
		return _done("the rejoined match did not end with its result")
	var hist: Array = Game.profile.history
	var h: Dictionary = hist[0] if not hist.is_empty() else {}
	sc = arena.get("score")
	at.log_line("guest: result %s, score %d - %d, matches %d, history %d" % [str(h.get("result")), int(sc.player), int(sc.bot),
		int(Game.profile.matches), hist.size()])
	if h.get("result") != "lost" or int(sc.player) != 0 or int(sc.bot) != 2 or hist.size() != 1 or int(Game.profile.matches) != 0:
		_fail("the rejoined match did not end as the host's did (0 - 2, one defeat)")
	await at.wait(3.0)
	return _done("")


## This copy's player goes down in the zone (nobody's kill): the host decides the round.
func _go_down(arena: Node) -> void:
	var me := arena.get("player") as Fighter
	var n := 0
	while me.alive and n < 20:
		n += 1
		me.take_damage(100.0, "body", null, me.global_position, "zone")
	at.log_line("%s: down in the zone in round %d" % ["host" if host else "guest", int(arena.get("round_index"))])


## The arena of the match that starts now.
func _arena(seconds: float) -> Node:
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.name == "Arena", seconds):
		return null
	return get_tree().current_scene


## Waits (game time) until cond() is true or `seconds` pass; returns whether it came true.
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
	at.log_line("RESUME CHECK DONE bad=%d" % bad)
	return bad
