extends Node
## Friends and custom rooms end to end (Cloud through tests/mqtt_mock.gd, started by
## tools/qa/run_checks.sh). The guest (LW_LAN_ROLE=guest) asks the host to be friends and the host
## accepts; the host opens room 424242 with password 4821 and rules (first to 1, unlimited walls
## and ammo); the guest tries a wrong password (refused), then the right one; the host sees it in
## the room and starts; both play the match with the room's rules (the host's walls never run out)
## and the host wins. Prints "ROOM CHECK DONE bad=N".

const CODE := "424242"
const PIN := "4821"

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_LAN_ROLE") == "host"
	var cloud := Game.cloud_service()
	cloud.start_lobby()
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not await _until(func() -> bool: return cloud.status == "online" and not cloud.peers.is_empty(), 30.0):
		return _done("the other phone was never seen in the lobby")
	var other := String(cloud.peers.keys()[0])
	# Friends: the guest asks, the host accepts, both list each other.
	if host:
		if not await _until(func() -> bool: return cloud.friend_requests.has(other), 20.0):
			return _done("no friend request arrived")
		cloud.answer_friend(other, true)
	else:
		if not cloud.request_friend(other):
			return _done("friend request not sent")
	if not await _until(func() -> bool: return Game.is_friend(other), 20.0):
		_fail("not friends after the request was accepted")
	if not cloud.friend_requests.is_empty() or not (Game.profile.friend_out as Dictionary).is_empty():
		_fail("friend requests left over after the answer")
	# ALL PLAYERS: the other phone's signed card is kept by the broker and listed.
	cloud.start_directory()
	if not await _until(func() -> bool: return cloud.directory.has(other), 20.0):
		_fail("the other player's card never arrived")
	elif String(cloud.directory[other].name) != String(cloud.peers[other].name):
		_fail("the card's name differs from the lobby's")
	cloud.stop_directory()
	at.log_line("friends: %s (code %s)" % [Game.is_friend(other), Cloud.friend_code(other)])
	# Custom room.
	if host:
		cloud.open_room(PIN, {"rounds": 1, "walls": true, "ammo": true, "frags": false}, CODE)
		if not await _until(func() -> bool: return not cloud.room_guest.is_empty(), 40.0):
			return _done("nobody joined the room")
		if String(cloud.room_guest.id) != other:
			_fail("the wrong player joined the room")
		await at.wait(1.0)
		if not cloud.start_room_match():
			return _done("the room's match did not start")
	else:
		await at.wait(1.0)          # the host opens the room
		cloud.join_room(CODE, "0000")
		if not await _until(func() -> bool: return cloud.join_state == "wrong", 20.0):
			_fail("a wrong password was not refused (state %s)" % cloud.join_state)
		cloud.join_room(CODE, PIN)
		if not await _until(func() -> bool: return cloud.join_state == "in", 20.0):
			return _done("the right password did not get in (state %s)" % cloud.join_state)
	if not await _until(func() -> bool: return started[0], 30.0):
		return _done("no session")
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.name == "Arena", 30.0):
		return _done("the lobby never started the match")
	var arena: Node = get_tree().current_scene
	at.log_line("room rules here: %s, rounds to win %d" % [str(Game.room_rules), int(arena.get("rounds_to_win"))])
	if not bool(Game.room_rules.get("walls", false)) or not bool(Game.room_rules.get("ammo", false)) \
			or int(arena.get("rounds_to_win")) != 1:
		_fail("the room's rules did not reach this phone's match")
	await at.wait_for_phase(arena, 1, 60.0)
	if arena.get("phase") != 1:
		return _done("never reached FIGHT")
	await at.wait(1.5)
	var p: Fighter = arena.get("player")
	var b: Fighter = arena.get("bot")
	if host:
		p.deploy_shield()
		await at.wait(0.3)
		if p.shields < 9 or p.weapon().reserve < 300:
			_fail("unlimited walls / ammo did not top up (walls %d, reserve %d)" % [p.shields, p.weapon().reserve])
		await at.wait(1.0)
		await _shoot_down(at, arena, p, b)
	if not await _until(func() -> bool: return bool(arena.get("_result_shown")), 30.0):
		return _done("the match did not end")
	var winner: Variant = arena.get("_winner")
	if host and winner != p:
		_fail("host should win")
	if not host and winner != b:
		_fail("guest should lose")
	await at.wait(1.0)
	return _done("")


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
	at.log_line("ROOM CHECK DONE bad=%d" % bad)
	return bad

## The other phone takes only real hits (one bullet of the round's gun at most, at most as fast
## as it fires), so the host lands real headshots until the remote player goes down.
func _shoot_down(runner: Node, match_arena: Node, shooter: Fighter, target: Fighter) -> void:
	var d: Dictionary = Weapons.DEFS[String(match_arena.call("_round_gun"))]
	var hit := float(d.damage) * float(d.head_mult) * Weapons.pen_mult(d, "head")
	for _i in 20:
		if not target.alive:
			return
		target.take_damage(hit, "head", shooter, shooter.global_position)
		await runner.wait(maxf(float(d.interval), 0.12))
