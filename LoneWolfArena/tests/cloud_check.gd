extends Node
## Internet 1 vs 1 end to end (Cloud, end-to-end encrypted) through tests/mqtt_mock.gd
## (tools/qa/run_checks.sh starts both, LW_MQTT_URL points Cloud at it): LW_LAN_ROLE=host sees
## the guest's announcement in the lobby, challenges it; the guest
## accepts; both load the arena, exchange their players' state, the host lands a lethal hit on
## its copy of the guest, the guest's phone applies it and reports its death, and both show the
## result (host VICTORY, guest DEFEAT). Prints "CLOUD CHECK DONE bad=N".

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_LAN_ROLE") == "host"
	var lan := Game.cloud_service()
	lan.start_lobby()
	var started := [false]
	lan.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not host:
		lan.invited.connect(func(_who: String) -> void: lan.answer(true))
	var t := 0.0
	while host and (lan.peers.is_empty() or lan.status != "online") and t < 30.0:
		await at.wait(0.25)
		t += 0.25
	if host:
		if lan.peers.is_empty():
			return _done("the guest was never discovered")
		if not lan.invite(String(lan.peers.keys()[0])):
			return _done("invite failed")
	t = 0.0
	while not started[0] and t < 40.0:
		await at.wait(0.25)
		t += 0.25
	if not started[0]:
		return _done("no session")
	at.log_line("session up as %s, opponent %s" % ["host" if host else "guest", lan.opponent.get("name", "?")])
	# The lobby takes it from here, as for a player: match loading, then the arena.
	t = 0.0
	while (get_tree().current_scene == null or get_tree().current_scene.name != "Arena") and t < 30.0:
		await at.wait(0.25)
		t += 0.25
	var arena: Node = get_tree().current_scene
	if arena == null or arena.name != "Arena":
		return _done("the lobby never started the match")
	await at.wait_for_phase(arena, 1, 60.0)
	if arena.get("phase") != 1:
		return _done("never reached FIGHT")
	await at.wait(1.5)
	var p: Fighter = arena.get("player")
	var b: Fighter = arena.get("bot")
	var map: MapBuilder = arena.get("map")
	var their_spawn: Vector3 = map.spawn_b if host else map.spawn_a
	at.log_line("remote at %s, its spawn %s, remote hp %.0f" % [str(b.global_position), str(their_spawn), b.hp])
	if not (b is RemoteFighter) or b.global_position.distance_to(their_spawn) > 3.0:
		_fail("the remote player does not follow the other phone's state")
	# The host takes every round (LW_ROUNDS_TO_WIN sets how many): each next round must start on
	# both phones with both players back up at full HP, and the match end with the host's win.
	var round_now := 1
	while true:
		if host:
			if round_now > 1:
				await at.wait(1.5)     # the guest checks its reset 1 s into its round, which can start later
			b.take_damage(9999.0, "head", p, p.global_position)
		t = 0.0
		while t < 30.0 and not arena.get("_result_shown") and not (int(arena.get("round_index")) > round_now and arena.get("phase") == 1):
			await at.wait(0.25)
			t += 0.25
		if arena.get("_result_shown"):
			break
		if int(arena.get("round_index")) <= round_now:
			return _done("round %d never ended" % round_now)
		round_now = int(arena.get("round_index"))
		await at.wait(1.0)
		at.log_line("round %d: me %.0f HP alive=%s, remote %.0f HP alive=%s, score %s" % [round_now, p.hp, p.alive, b.hp, b.alive, str(arena.get("score"))])
		if not p.alive or not b.alive or p.hp < Fighter.MAX_HP or b.hp < Fighter.MAX_HP - 1.0:
			_fail("round %d did not reset both players" % round_now)
	if round_now < 2:
		_fail("the match ended after one round")
	var winner: Variant = arena.get("_winner")
	at.log_line("result: winner=%s me alive=%s remote alive=%s" % [
		"me" if winner == p else ("them" if winner == b else "none"), p.alive, b.alive])
	if host and winner != p:
		_fail("host should win")
	if not host and (winner != b or p.alive):
		_fail("guest should lose")
	await at.wait(1.0)
	return _done("")


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("CLOUD CHECK DONE bad=%d" % bad)
	return bad
