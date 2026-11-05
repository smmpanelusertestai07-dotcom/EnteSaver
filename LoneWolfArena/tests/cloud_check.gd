extends Node
## Internet 1 vs 1 end to end (Cloud, end-to-end encrypted) through tests/mqtt_mock.gd
## (tools/qa/run_checks.sh starts both, LW_MQTT_URL points Cloud at it): LW_NET_ROLE=host sees
## the guest's announcement in the lobby, challenges it; the guest
## accepts; both load the arena, exchange their players' state, the host floods the guest with
## walls, frags and shots (the guest makes only one round's items), the host lands a lethal hit on
## its copy of the guest, the guest's phone applies it and reports its death, and both show the
## result (host VICTORY, guest DEFEAT), which each one's profile keeps: a LONE WOLF entry in
## HISTORY with the other phone's id and name (its row opens their card), the deaths and rounds in
## CAREER, the other phone among the recent players. Prints "CLOUD CHECK DONE bad=N".

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_NET_ROLE") == "host"
	var cloud := Game.cloud_service()
	cloud.start_lobby()
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not host:
		cloud.invited.connect(func(_who: String) -> void: cloud.answer(true))
	var t := 0.0
	while host and (cloud.peers.is_empty() or cloud.status != "online") and t < 30.0:
		await at.wait(0.25)
		t += 0.25
	if host:
		if cloud.peers.is_empty():
			return _done("the guest was never discovered")
		if not cloud.invite(String(cloud.peers.keys()[0])):
			return _done("invite failed")
	t = 0.0
	while not started[0] and t < 40.0:
		await at.wait(0.25)
		t += 0.25
	if not started[0]:
		return _done("no session")
	at.log_line("session up as %s, opponent %s" % ["host" if host else "guest", cloud.opponent.get("name", "?")])
	var opp_id := String(cloud.opponent.get("id", ""))
	var opp_name := String(cloud.opponent.get("name", ""))
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
	# A tampered phone could send walls, frags and shots without end: the other phone makes only
	# what one player has in a round (Arena.spawn_cap) and its shots no faster than the gun.
	if host:
		var c: Vector3 = map.zone_center
		for i in 40:
			Game.session.send_event("wall", [c.x + 0.1 * i, 0.0, c.z, 0.0])
			Game.session.send_event("grenade", [c.x, 1.0, c.z, 0.0, 2.0, 0.0])
		for i in 60:
			Game.session.send_event("shot", [c.x, 1.5, c.z, 1.0, 0.0, 0.0])
		# Meanwhile the guest runs: its steps sound here and leave footprints on the minimap.
		var hud: HUD = arena.get("hud")
		var footprints := 0
		for i in 10:
			await at.wait(0.25)
			footprints = maxi(footprints, hud.steps.size())
		at.log_line("the running guest's footprints here: %d" % footprints)
		if footprints == 0:
			_fail("the other phone's player ran without a step heard or seen")
	else:
		var hud: HUD = arena.get("hud")
		hud.process_mode = Node.PROCESS_MODE_DISABLED     # (its joystick would stop the run)
		for i in 24:
			p.move_dir = Vector2(0, 1)
			await at.wait(0.05)
		p.move_dir = Vector2.ZERO
		hud.process_mode = Node.PROCESS_MODE_INHERIT
		await at.wait(0.8)
		var spawned: Dictionary = arena.get("_net_spawns")
		var walls := 0
		for n in arena.get_children():
			walls += 1 if n is ShieldWall else 0
		at.log_line("after a flood of walls and frags: %d walls here, used %s" % [walls, str(spawned)])
		if walls != Fighter.START_SHIELDS or int(spawned.get("wall", 0)) != Fighter.START_SHIELDS \
				or int(spawned.get("grenade", 0)) != Fighter.START_GRENADES:
			_fail("a flood of walls and frags from the other phone was not held to one round's items")
	# The host takes every round (LW_ROUNDS_TO_WIN sets how many): each next round must start on
	# both phones with both players back up at full HP, and the match end with the host's win.
	var round_now := 1
	while true:
		if host:
			if round_now > 1:
				await at.wait(1.5)     # the guest checks its reset 1 s into its round, which can start later
			await _shoot_down(at, arena, p, b)
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
	# The profile (an automated run starts from a new one).
	var sc: Dictionary = arena.get("score")
	var history: Array = Game.profile.history
	var h: Dictionary = history[0] if not history.is_empty() else {}
	var recent: Array = Game.profile.recent
	at.log_line("history: %s; deaths %d, rounds %d-%d, recent %s" % [str(h), int(Game.profile.deaths), int(Game.profile.rounds_won),
		int(Game.profile.rounds_lost), str(recent)])
	if (h.get("result") != ("won" if host else "lost") or h.get("mode") != "lonewolf" or h.get("id") != opp_id or opp_id == ""
			or h.get("enemy") != opp_name or h.get("score") != int(sc.player) or h.get("enemy_score") != int(sc.bot)):
		_fail("HISTORY does not keep the online match with the opponent's id")
	if int(Game.profile.deaths) != int(sc.bot) or int(Game.profile.rounds_won) != int(sc.player) or int(Game.profile.rounds_lost) != int(sc.bot):
		_fail("CAREER does not count the deaths and rounds of the online match")
	if recent.is_empty() or String(recent[0].id) != opp_id:
		_fail("the opponent is not among the recent players")
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
