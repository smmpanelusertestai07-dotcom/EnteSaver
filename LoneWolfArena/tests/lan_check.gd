extends Node
## Wi-Fi 1 vs 1 end to end with two copies of the game on one machine (tools/qa/run_checks.sh
## starts both): LW_LAN_ROLE=host finds the guest by its broadcast, challenges it; the guest
## accepts; both load the arena, exchange their players' state, the host lands a lethal hit on
## its copy of the guest, the guest's phone applies it and reports its death, and both show the
## result (host VICTORY, guest DEFEAT). Prints "LAN CHECK DONE bad=N".

const HOST_PORT := 47800
const GUEST_PORT := 47801

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_LAN_ROLE") == "host"
	var lan := Game.lan_service()
	lan.listen_port = HOST_PORT if host else GUEST_PORT
	lan.dest_ports = [HOST_PORT, GUEST_PORT]
	lan.start_discovery()
	var started := [false]
	lan.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not host:
		lan.invited.connect(func(_who: String) -> void: lan.answer(true))
	var t := 0.0
	while host and lan.peers.is_empty() and t < 30.0:
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
	Game.online = true
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
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
	if host:
		b.take_damage(9999.0, "head", p, p.global_position)
	t = 0.0
	while not arena.get("_result_shown") and t < 20.0:
		await at.wait(0.25)
		t += 0.25
	if not arena.get("_result_shown"):
		return _done("results never shown")
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
	at.log_line("LAN CHECK DONE bad=%d" % bad)
	return bad
