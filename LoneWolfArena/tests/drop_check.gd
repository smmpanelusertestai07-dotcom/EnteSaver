extends Node
## Online matches that end before their result, with two copies of the game (LW_NET_ROLE host /
## guest) through tests/mqtt_mock.gd (tools/qa/run_checks.sh starts them, step "drop"):
## 0. The host's session ends while the guest's match is still loading: the guest comes back to
##    the lobby, which says the other player left, and never plays a match against the bot instead.
## 1. The guest's match takes 11 s to load (longer than a silent phone is waited for): its
##    keep-alives hold the session, so the host's arena waits instead of calling it off. The guest
##    then quits in the first prep (QUIT MATCH): the match never began, so the host counts no win,
##    no XP and no match, and its lobby says the other player left.
## 2. A second challenge; as its arena appears the guest freezes 8 s (a phone's first load compiles
##    its shaders): neither phone takes that for leaving, the match begins. 1 s into the first
##    fight the guest freezes for 9 s (an app in the background, a phone out of signal). The host
##    takes the silence for leaving: a forfeit, its VICTORY, with the real score (no round added).
##    The guest, back, knows it was the one away: CONNECTION LOST, the match counts as LEFT (a
##    defeat), never a second win.
## Prints "DROP CHECK DONE bad=N".

var bad := 0
var at: Node
var host := false
var cloud: Cloud


func run(autotest: Node) -> int:
	at = autotest
	host = OS.get_environment("LW_NET_ROLE") == "host"
	cloud = Game.cloud_service()
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void:
		started[0] = true
		at.log_line("session started"))
	cloud.session_ended.connect(func(reason: String) -> void: at.log_line("session ended: " + reason))
	cloud.invited.connect(func(_who: String) -> void: cloud.answer(true))
	var first_lobby := get_tree().current_scene.get_instance_id()
	if not host:
		Loading.delay_for_test = 4.0         # (match 0: the challenge may come before this phone sees the host)
	cloud.start_lobby()
	if not await _until(func() -> bool: return cloud.status == "online" and not cloud.peers.is_empty(), 30.0):
		return _done("the other phone was never seen in the lobby")
	# 0. The session ends while the guest loads.
	if host and not cloud.invite(String(cloud.peers.keys()[0])):
		return _done("invite failed")
	if not await _until(func() -> bool: return started[0], 30.0):
		return _done("no session for match 0")
	if host:
		await at.wait(0.5)
		cloud.end_session("left")
	var back := func() -> bool: return _in_lobby() and get_tree().current_scene.get_instance_id() != first_lobby
	if not await _until(back, 25.0):
		return _done("not back in the lobby after the session ended during the load")
	Loading.delay_for_test = 0.0
	var notice0: String = await _notice_text()
	var bot_matches := int((Game.profile.modes as Dictionary).training.matches)
	at.log_line("after match 0: \"%s\", bot matches %d" % [notice0, bot_matches])
	if bot_matches != 0 or Game.online:
		_fail("a session that ended while loading started a match against the bot")
	if not host and not notice0.contains("left before the match began"):
		_fail("the lobby did not say that the other player left during the load")
	get_tree().current_scene.get("dialogs").call("close_modal")
	await at.wait(6.0 if host else 1.0)       # the guest's slow load is over before the next challenge
	# 1. A slow load, then the guest quits in the first prep.
	if not host:
		Loading.delay_for_test = 11.0
	var arena := await _match()
	if arena == null:
		return _done("match 1 did not load")
	Loading.delay_for_test = 0.0
	if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_net_begun")), 30.0):
		return _done("match 1 never began: the slow load was taken for leaving")
	at.log_line("match 1 began after the guest's slow load")
	if host:
		if not await _until(func() -> bool: return _in_lobby(), 30.0):
			return _done("the host stayed in match 1 after the guest quit")
		var notice: String = await _notice_text()
		at.log_line("host back in the lobby: \"%s\"; matches %d, wins %d, xp %d, history %d" % [notice, int(Game.profile.matches),
			int(Game.profile.wins), int(Game.profile.xp), (Game.profile.history as Array).size()])
		if int(Game.profile.matches) != 0 or int(Game.profile.wins) != 0 or int(Game.profile.xp) != 0 \
				or not (Game.profile.history as Array).is_empty():
			_fail("a match the opponent left before it began was counted as a win")
		if not notice.contains("left before the match began"):
			_fail("the lobby did not say that the other player left")
		get_tree().current_scene.get("dialogs").call("close_modal")
	else:
		await at.wait(1.0)
		arena.call("record_left")            # QUIT MATCH, as the pause menu does it
		Game.goto_lobby()
		if not await _until(func() -> bool: return _in_lobby(), 10.0):
			return _done("the guest did not get back to the lobby")
		if int(Game.profile.matches) != 0 or not (Game.profile.history as Array).is_empty():
			_fail("quitting before the first fight counted a match")
	# 2. The guest goes away 9 s in the first fight.
	await at.wait(2.0)
	arena = await _match()
	if arena == null:
		return _done("match 2 did not load")
	if not host:
		at.log_line("guest: the arena's first frames freeze 8 s")
		OS.delay_msec(8000)
	await at.wait_for_phase(arena, 1, 40.0)
	if not is_instance_valid(arena) or not cloud.in_session:
		return _done("a load that froze 8 s was taken for a disconnect")
	if not is_instance_valid(arena) or arena.get("phase") != 1:
		return _done("match 2 never reached its fight")
	await at.wait(1.0)
	if host:
		if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_result_shown")), 30.0) \
				or not is_instance_valid(arena):
			return _done("the host's match did not end with its result while the guest was away")
		var h: Dictionary = (Game.profile.history as Array)[0] if not (Game.profile.history as Array).is_empty() else {}
		at.log_line("host: forfeit %s, winner me %s, history %s, wins %d" % [arena.get("_forfeit"), arena.get("_winner") == arena.get("player"),
			str(h.get("result")), int(Game.profile.wins)])
		if not bool(arena.get("_forfeit")) or h.get("result") != "won" or int(Game.profile.wins) != 1:
			_fail("the host did not win when the guest dropped out")
		var sc: Dictionary = arena.get("score")
		if int(sc.player) != 0 or int(sc.bot) != 0 or int(h.get("score", -1)) != 0:
			_fail("the forfeit added a round to the score (%s)" % str(sc))
		await at.wait(2.0)
	else:
		at.log_line("guest: frozen for 9 s")
		OS.delay_msec(9000)
		if not await _until(func() -> bool: return _in_lobby(), 15.0):
			return _done("the guest stayed in the match after it was away")
		var h: Dictionary = (Game.profile.history as Array)[0] if not (Game.profile.history as Array).is_empty() else {}
		var notice: String = await _notice_text()
		at.log_line("guest back in the lobby: \"%s\"; history %s, matches %d, wins %d, xp %d" % [notice, str(h.get("result")),
			int(Game.profile.matches), int(Game.profile.wins), int(Game.profile.xp)])
		if h.get("result") != "left" or int(Game.profile.wins) != 0 or int(Game.profile.matches) != 1 or int(Game.profile.xp) != 0:
			_fail("the phone that dropped out was not given a LEFT (a defeat)")
		if not notice.contains("connection was lost"):
			_fail("the lobby did not say that the connection was lost")
	return _done("")


## Challenges (host) or waits to be challenged (guest), then waits for the arena.
func _match() -> Node:
	var before := get_tree().current_scene.get_instance_id()     # (an id: the lobby is freed meanwhile)
	if host:
		if not await _until(func() -> bool: return not cloud.peers.is_empty() and not cloud.in_session, 30.0):
			return null
		if not cloud.invite(String(cloud.peers.keys()[0])):
			_fail("invite failed")
			return null
	var in_arena := func() -> bool:
		var s := get_tree().current_scene
		return s != null and s.get_instance_id() != before and s.name == "Arena"
	if not await _until(in_arena, 50.0):
		return null
	return get_tree().current_scene


func _in_lobby() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene is Lobby


## The lobby's open notice (LobbyDialogs.notice: it opens a frame after the lobby), or "".
func _notice_text() -> String:
	await at.wait(0.5)
	var lobby := get_tree().current_scene
	var m: Variant = lobby.get("_modal") if lobby else null
	var t := (m as Node).find_child("NoticeText", true, false) as Label if m is Node else null
	return t.text if t else ""


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
	at.log_line("DROP CHECK DONE bad=%d" % bad)
	return bad
