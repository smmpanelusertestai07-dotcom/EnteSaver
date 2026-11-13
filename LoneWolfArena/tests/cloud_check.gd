extends Node
## Internet 1 vs 1 end to end (Cloud, end-to-end encrypted) through tests/mqtt_mock.gd
## (tools/qa/run_checks.sh starts both, LW_MQTT_URL points Cloud at it): LW_NET_ROLE=host sees
## the guest's announcement in the lobby, challenges it; the guest
## accepts; both load the arena, exchange their players' state, the host floods the guest with
## walls, frags and shots (the guest makes only one round's items), the guest opens its pause menu
## (back closes it, a switch of apps does not stack a second one) and runs (the host sees its
## footprints), the host lands a lethal hit on
## its copy of the guest, the guest's phone applies it and reports its death, and both show the
## result (host VICTORY, guest DEFEAT), which each one's profile keeps: a LONE WOLF entry in
## HISTORY with the other phone's id and name (its row opens their card), the deaths and rounds in
## CAREER, the other phone among the recent players. Prints "CLOUD CHECK DONE bad=N".
## The direct path (NetDirect; run_checks.sh sets LW_DIRECT=local: the loopback address is the only
## candidate, no STUN server is asked): it comes up on both copies, the state goes over it (not the
## relay) and the ping chip says DIRECT; then the guest blocks its UDP mid-match, the host falls
## back to the relay within TIMEOUT_MS (the chip says RELAY), the state flows on through the relay
## on both, and the match ends with the same result.
## After the match (its results on both): the host's ADD FRIEND reaches the guest; the guest taps
## REMATCH, the host's screen says so and its REMATCH agrees: a fresh challenge (the host's, the
## guest takes it at once) loads a new match against the same player on both.

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_NET_ROLE") == "host"
	var cloud := Game.cloud_service()
	cloud.start_lobby()
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void: started[0] = true)
	var auto_accept := func(_who: String) -> void: cloud.answer(true)
	if not host:
		cloud.invited.connect(auto_accept)
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
	await _check_direct(arena)
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
		# Online the tree is not paused: leaving the app opens no menu (a returning player sees the
		# match, which ran on), Android back still closes the pause menu, and switching apps with
		# it open does not stack a second one.
		arena.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
		await at.wait(0.1)
		if _pause_menus(arena) != 0:
			_fail("online, leaving the app opened the pause menu over the running match")
		arena.call("open_pause")
		await at.wait(0.1)
		arena.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
		await at.wait(0.1)
		var menus := _pause_menus(arena)
		get_tree().root.propagate_notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		await at.wait(0.2)
		at.log_line("pause menus: %d open, %d after back" % [menus, _pause_menus(arena)])
		if menus != 1 or _pause_menus(arena) != 0:
			_fail("online, back did not close the one pause menu")
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
	await _check_fallback(arena, host)
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
	if not host:
		cloud.invited.disconnect(auto_accept)      # (from here on the results screen answers)
	await _check_rematch(arena, host, cloud, opp_id, opp_name)
	await at.wait(1.0)
	return _done("")


## The online results: ADD FRIEND (the host's request reaches the guest), then REMATCH: the guest
## asks first, the host's screen says so and agrees, and a new match loads on both against the
## same player (the host's fresh challenge, taken by the guest's results screen).
func _check_rematch(arena: Node, host: bool, cloud: Cloud, opp_id: String, opp_name: String) -> void:
	var layer: Node = arena.get("pause_layer")
	if not await _until(func() -> bool: return layer.find_child("Rematch", true, false) != null, 10.0):
		_fail("the online results have no REMATCH")
		return
	var rematch := layer.find_child("Rematch", true, false) as Button
	var friend := layer.find_child("AddFriend", true, false) as Button
	var status := layer.find_child("RematchStatus", true, false) as Label
	if layer.find_child("PlayAgain", true, false) != null:
		_fail("an online match's results still offer PLAY AGAIN")
	if host:
		if friend == null or friend.disabled:
			_fail("the online results have no ADD FRIEND for a player who is not a friend")
		else:
			friend.pressed.emit()
			if friend.text != "REQUEST SENT" or not friend.disabled:
				_fail("ADD FRIEND did not send the friend request")
		if not await _until(func() -> bool: return status.text.contains("WANTS A REMATCH"), 25.0):
			_fail("the guest's REMATCH never showed on the host's results (\"%s\")" % status.text)
			return
		at.log_line("host's results: \"%s\"" % status.text)
		rematch.pressed.emit()
	else:
		if not await _until(func() -> bool: return cloud.friend_requests.has(opp_id), 20.0):
			_fail("the host's friend request never reached the guest")
		await at.wait(0.5)
		rematch.pressed.emit()
		at.log_line("guest's REMATCH: \"%s\" / \"%s\"" % [rematch.text, status.text])
		if rematch.text != "ASKED":
			_fail("the guest's REMATCH did not ask the host")
	var old := arena.get_instance_id()
	var fresh := func() -> bool:
		var s := get_tree().current_scene
		return s != null and s.get_instance_id() != old and s.name == "Arena" and bool(s.get("online"))
	if not await _until(fresh, 40.0):
		_fail("the rematch never loaded (\"%s\")" % (status.text if is_instance_valid(status) else "?"))
		return
	var again := get_tree().current_scene
	await at.wait_for_phase(again, 1, 40.0)
	var b2: Fighter = again.get("bot")
	at.log_line("rematch: a new arena, online %s, against %s, phase %d" % [again.get("online"), b2.display_name if b2 else "?", int(again.get("phase"))])
	if b2 == null or b2.display_name != opp_name or not Game.session.in_session or int(again.get("phase")) != 1:
		_fail("the rematch is not a running match against the same player")


## Waits (game time) until cond() is true or `seconds` pass; returns whether it came true.
func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while not cond.call() and t < seconds:
		await at.wait(0.25)
		t += 0.25
	return cond.call()


## The direct path is up on this copy, the state comes over it and goes out over it, the chip
## says DIRECT with the direct round trip.
func _check_direct(arena: Node) -> void:
	var cl: Cloud = Game.session
	var t := 0.0
	while not cl.direct_up() and t < 8.0:
		await at.wait(0.25)
		t += 0.25
	if not cl.direct_up():
		_fail("the direct path never came up")
		return
	var d_in := cl.direct.states_in
	var d_out := cl.direct.states_out
	var r_out := cl.relay_states_out
	await at.wait(1.0)
	var hud_net: HudNet = arena.find_child("HudNet", true, false)
	await at.wait(0.6)                 # (the ping's first answers)
	at.log_line("direct: %d states in and %d out over it in 1 s, %d out through the relay, rtt %d ms, chip %s %d ms" % [
		cl.direct.states_in - d_in, cl.direct.states_out - d_out, cl.relay_states_out - r_out, cl.direct.rtt,
		hud_net.link_tag() if hud_net else "?", hud_net.ping_ms() if hud_net else -2])
	if cl.direct.states_in - d_in < 3 or cl.direct.states_out - d_out < 3:
		_fail("the state does not go over the direct path")
	if cl.relay_states_out - r_out > 1:
		_fail("the state still goes through the relay while the direct path is up")
	if hud_net == null or hud_net.link_tag() != "DIRECT" or cl.direct.rtt < 0 or hud_net.ping_ms() != cl.direct.rtt:
		_fail("the ping chip does not show the direct round trip with DIRECT")


## Mid-match the guest's UDP is blocked: the host stops hearing it and falls back to the relay
## within TIMEOUT_MS (plus a frame or two), and on both the state goes on through the relay.
func _check_fallback(arena: Node, host: bool) -> void:
	var cl: Cloud = Game.session
	if cl.direct == null:
		_fail("no direct path to block")
		return
	var t := 0.0
	var seen_up := false               # the host saw the path up and then saw it drop
	if not host:
		cl.direct.blocked = true
		# The host keeps sending direct until it notices (TIMEOUT_MS): the gap the fall back costs.
		await at.wait(NetDirect.TIMEOUT_MS / 1000.0 + 0.2)
	else:
		while cl.direct_up() and t < 8.0:
			seen_up = true
			await at.wait(0.05)
			t += 0.05
	var down_ms := Time.get_ticks_msec() - cl.direct._rx_ms
	await at.wait(0.3)
	var r_in := cl.relay_states_in
	await at.wait(1.0)
	var hud_net: HudNet = arena.find_child("HudNet", true, false)
	at.log_line("UDP blocked on the guest: direct up %s (fell back %d ms after the last packet), %d states in through the relay in 1 s, chip %s" % [
		str(cl.direct_up()), down_ms, cl.relay_states_in - r_in, hud_net.link_tag() if hud_net else "?"])
	if cl.direct_up() or (hud_net != null and hud_net.link_tag() != "RELAY"):
		_fail("still direct with the guest's UDP blocked")
	if host and (down_ms < NetDirect.TIMEOUT_MS or (seen_up and down_ms > NetDirect.TIMEOUT_MS + 600)):
		_fail("the fall back to the relay did not come TIMEOUT_MS after the last direct packet")
	if cl.relay_states_in - r_in < 3:
		_fail("the state does not come through the relay after the fall back")


func _pause_menus(arena: Node) -> int:
	var n := 0
	for c in (arena.get("pause_layer") as Node).get_children():
		n += 1 if c is PauseMenu and not c.is_queued_for_deletion() else 0
	return n


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
