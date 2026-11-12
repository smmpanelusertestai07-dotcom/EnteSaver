extends Node
## QUICK MATCH end to end (NetMatch and Cloud through tests/mqtt_mock.gd, started by
## tools/qa/run_checks.sh). The host copy (LW_NET_ROLE=host) presses START in LONE WOLF alone
## first: it searches (SEARCHING..., the timer runs, its own seeks come back from the relay but it
## never pairs with itself) and CANCEL stops it. Then both press START: they see each other, the
## lower id sends the quick challenge, the other takes it at once (no popup), and both load and
## play the match; the challenger is the match's host and wins. Prints "QUICK CHECK DONE bad=N".

const ALONE_S := 5.0           # the host searches alone this long, then cancels
const GUEST_DELAY_S := 9.0     # the guest presses START after the host's lone search

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_NET_ROLE") == "host"
	Game.mode = "lonewolf"
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 30.0):
		return _done("the lobby never came up")
	var lobby := get_tree().current_scene as Lobby
	var cloud := Game.cloud_service()
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not await _until(func() -> bool: return cloud.status == "online" and not cloud.peers.is_empty(), 30.0):
		return _done("the other phone was never seen in the lobby")
	var other := String(cloud.peers.keys()[0])
	if host:
		# Alone: the search runs and shows its time; nobody to pair with (not even this phone). It
		# opens no popup of its own (the first start's name prompt may stay open behind it).
		var before := lobby.dialogs.modal
		lobby.call("_start")
		await at.wait(ALONE_S)
		var nm := lobby.get_node_or_null("NetMatch") as NetMatch
		var tab := lobby.search_tab
		if nm == null or not nm.searching or not cloud.seeking or lobby.dialogs.modal != before or not tab.is_visible_in_tree() \
				or not (tab.find_child("SearchCancel", true, false) as Control).is_visible_in_tree():
			_fail("START in LONE WOLF did not show the QUICK MATCH search tab (no popup) (search %s, seeking %s, popup %s, tab %s)" % [
				nm != null and nm.searching, cloud.seeking, _modal_text(lobby), tab.is_visible_in_tree()])
		elif not cloud.quick_seen.is_empty() or cloud.waiting_for() != "" or started[0]:
			_fail("a lone search paired with something (seen %s)" % str(cloud.quick_seen.keys()))
		else:
			var timer := tab.find_child("SearchTimer", true, false) as Label
			at.log_line("searching alone: timer %s, line %s" % [timer.text if timer else "?", (tab.find_child("SearchLine", true, false) as Label).text])
			if timer == null or timer.text == "0:00":
				_fail("the search's timer does not run")
			(tab.find_child("SearchCancel", true, false) as Button).pressed.emit()
			await at.wait(0.5)
			if nm.searching or cloud.seeking or tab.is_visible_in_tree():
				_fail("the search tab's X did not stop the search")
		await at.wait(GUEST_DELAY_S - ALONE_S - 0.5)
	else:
		await at.wait(GUEST_DELAY_S)
		if started[0] or cloud.has_invite():
			_fail("a cancelled search still challenged")
	# Both search now: they find each other and the match loads.
	lobby.call("_start")
	if not await _until(func() -> bool: return started[0], 30.0):
		return _done("the two searches never paired")
	var challenger := cloud.my_id < other
	at.log_line("paired with %s: host %s (lower id %s)" % [String(cloud.opponent.get("name", "?")), cloud.is_host, challenger])
	if String(cloud.opponent.get("id", "")) != other or cloud.is_host != challenger:
		_fail("wrong pairing: opponent %s, host %s" % [str(cloud.opponent), cloud.is_host])
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.name == "Arena", 30.0):
		return _done("the lobby never started the match")
	if not Game.online:
		_fail("the quick match is not an online match")
	var arena: Node = get_tree().current_scene
	await at.wait_for_phase(arena, 1, 60.0)
	if arena.get("phase") != 1:
		return _done("never reached FIGHT")
	await at.wait(1.5)
	var p: Fighter = arena.get("player")
	var b: Fighter = arena.get("bot")
	if challenger:
		await _shoot_down(arena, p, b)
	if not await _until(func() -> bool: return bool(arena.get("_result_shown")), 30.0):
		return _done("the match did not end")
	var winner: Variant = arena.get("_winner")
	if winner != (p if challenger else b):
		_fail("the challenger should win")
	await at.wait(1.0)
	return _done("")


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
	at.log_line("QUICK CHECK DONE bad=%d" % bad)
	return bad


## Real headshots (one bullet of the round's gun at most, at most as fast as it fires).
func _shoot_down(match_arena: Node, shooter: Fighter, target: Fighter) -> void:
	var d: Dictionary = Weapons.DEFS[String(match_arena.call("_round_gun"))]
	var hit := float(d.damage) * float(d.head_mult) * Weapons.pen_mult(d, "head")
	for _i in 20:
		if not target.alive:
			return
		target.take_damage(hit, "head", shooter, shooter.global_position)
		await at.wait(maxf(float(d.interval), 0.12))


## What an open popup says (for a failure's message).
func _modal_text(lobby: Lobby) -> String:
	var m := lobby.dialogs.modal
	if m == null:
		return "none"
	var out := PackedStringArray()
	for l in m.find_children("*", "Label", true, false):
		out.append((l as Label).text)
	return " / ".join(out)
