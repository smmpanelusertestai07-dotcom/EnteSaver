extends Node
## PLAY WITHOUT INTERNET end to end with two copies of the game on this machine (tools/qa/run_checks.sh
## starts both, LW_NET_ROLE host / guest), through the lobby's tab as a player uses it: the host
## taps HOST and shows its code (passed to the guest in a file, as a player reads it off the
## screen); the guest taps JOIN, finds the host, picks it, types a wrong code (refused: WRONG CODE)
## and then the right one; both load the arena, exchange their players' state (end-to-end
## encrypted over the local network), the ping shows the local round trip, the host lands lethal
## hits over two rounds, and both show the result (host VICTORY, guest DEFEAT) as LONE WOLF ·
## LOCAL, which HISTORY keeps with the other phone's id, marked local. Prints "LAN CHECK DONE bad=N".

const HOST_PORT := 47820
const GUEST_PORT := 47821
const GAME_PORT := 47822
const CODE_FILE := "user://lan_code_for_test.txt"

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_NET_ROLE") == "host"
	var lan := Game.lan_service()
	lan.listen_port = HOST_PORT if host else GUEST_PORT
	lan.dest_ports = [HOST_PORT, GUEST_PORT]
	lan.game_port = GAME_PORT
	var started := [false]
	lan.session_started.connect(func(_h: bool) -> void: started[0] = true)
	var lobby: Node = get_tree().current_scene
	if host and FileAccess.file_exists(CODE_FILE):
		DirAccess.remove_absolute(CODE_FILE)
	(lobby.get("friends") as LobbyFriends).open("local")
	await at.wait(0.3)
	if not await _press(lobby, "LanHost" if host else "LanJoin"):
		return _done("no HOST / JOIN button in the tab PLAY WITHOUT INTERNET")
	if host:
		if not await _until(func() -> bool: return lan.role == "host" and lan.code.length() == Lan.CODE_DIGITS, 20.0):
			return _done("HOST never showed a code")
		var shown := _find(lobby, "LanCode") as Label
		at.log_line("hosting, code %s on screen: %s" % [lan.code, shown.text if shown else "-"])
		if shown == null or not shown.text.contains(lan.code):
			_fail("the host's code is not on the screen")
		var f := FileAccess.open(CODE_FILE, FileAccess.WRITE)
		f.store_string(lan.code)
		f.close()
	else:
		if not await _until(func() -> bool: return not lan.hosts.is_empty() and FileAccess.file_exists(CODE_FILE), 30.0):
			return _done("the host was never found")
		var code := FileAccess.get_file_as_string(CODE_FILE).strip_edges()
		at.log_line("found %s, code %s" % [str(lan.hosts.values().map(func(x: Dictionary) -> String: return x.name)), code])
		await _press(lobby, "LanHost_0")
		var wrong := str((int(code) + 1) % 10000).pad_zeros(Lan.CODE_DIGITS)
		if not await _type_code(lobby, wrong):
			return _done("no code field after picking the host")
		var friends: LobbyFriends = lobby.get("friends")
		if not await _until(func() -> bool: return friends.lan.note.begins_with("WRONG CODE"), 15.0):
			_fail("a wrong code was not refused (%s)" % friends.lan.note)
		if started[0]:
			_fail("a wrong code started a match")
		await _press(lobby, "LanHost_0")
		if not await _type_code(lobby, code):
			return _done("no code field for the second try")
	if not await _until(func() -> bool: return started[0], 40.0):
		return _done("no session")
	at.log_line("session up as %s, opponent %s" % ["host" if host else "guest", lan.opponent.get("name", "?")])
	var opp_id := String(lan.opponent.get("id", ""))
	var opp_name := String(lan.opponent.get("name", ""))
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.name == "Arena", 30.0):
		return _done("the lobby never started the match")
	var arena: Node = get_tree().current_scene
	if Game.session != lan or not String(arena.get("mode_name")).ends_with("LOCAL"):
		_fail("the match is not the local one (%s)" % arena.get("mode_name"))
	await at.wait_for_phase(arena, 1, 60.0)
	if arena.get("phase") != 1:
		return _done("never reached FIGHT")
	await at.wait(2.5)
	var p: Fighter = arena.get("player")
	var b: Fighter = arena.get("bot")
	var map: MapBuilder = arena.get("map")
	var their_spawn: Vector3 = map.spawn_b if host else map.spawn_a
	var hud_net := (arena.get("hud") as Node).get_node_or_null("HudNet")
	var ping: int = hud_net.call("ping_ms") if hud_net else -1
	at.log_line("remote at %s, its spawn %s, remote hp %.0f, ping %d ms" % [str(b.global_position), str(their_spawn), b.hp, ping])
	if not (b is RemoteFighter) or b.global_position.distance_to(their_spawn) > 3.0:
		_fail("the remote player does not follow the other phone's state")
	if ping < 0 or ping > 500:
		_fail("the ping does not show the local round trip (%d)" % ping)
	var round_now := 1
	while true:
		if host:
			if round_now > 1:
				await at.wait(1.5)
			await _shoot_down(arena, p, b)
		var t := 0.0
		while t < 30.0 and not arena.get("_result_shown") and not (int(arena.get("round_index")) > round_now and arena.get("phase") == 1):
			await at.wait(0.25)
			t += 0.25
		if arena.get("_result_shown"):
			break
		if int(arena.get("round_index")) <= round_now:
			return _done("round %d never ended" % round_now)
		round_now = int(arena.get("round_index"))
		await at.wait(1.0)
		at.log_line("round %d: me %.0f HP, remote %.0f HP, score %s" % [round_now, p.hp, b.hp, str(arena.get("score"))])
		if not p.alive or not b.alive or p.hp < Fighter.MAX_HP or b.hp < Fighter.MAX_HP - 1.0:
			_fail("round %d did not reset both players" % round_now)
	if round_now < 2:
		_fail("the match ended after one round")
	var winner: Variant = arena.get("_winner")
	at.log_line("result: winner=%s" % ("me" if winner == p else ("them" if winner == b else "none")))
	if host and winner != p:
		_fail("host should win")
	if not host and (winner != b or p.alive):
		_fail("guest should lose")
	var history: Array = Game.profile.history
	var h: Dictionary = history[0] if not history.is_empty() else {}
	at.log_line("history: %s" % str(h))
	if h.get("result") != ("won" if host else "lost") or h.get("mode") != "lonewolf" or h.get("local") != true \
			or h.get("id") != opp_id or opp_id == "" or h.get("enemy") != opp_name:
		_fail("HISTORY does not keep the local match (LONE WOLF, marked local, the opponent's id)")
	await at.wait(1.0)
	return _done("")


func _find(lobby: Node, node_name: String) -> Node:
	var m: Node = (lobby.get("dialogs") as LobbyDialogs).modal
	return m.find_child(node_name, true, false) if m and is_instance_valid(m) else null


func _press(lobby: Node, node_name: String) -> bool:
	var b := _find(lobby, node_name) as BaseButton
	if b == null:
		return false
	b.pressed.emit()
	await at.wait(0.3)
	return true


func _type_code(lobby: Node, code: String) -> bool:
	var le := _find(lobby, "LanCodeField") as LineEdit
	if le == null:
		return false
	le.text = code
	le.text_changed.emit(code)
	return await _press(lobby, "LanConnect")


func _until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while not cond.call() and t < timeout:
		await at.wait(0.25)
		t += 0.25
	return cond.call()


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("LAN CHECK DONE bad=%d" % bad)
	return bad


## The other phone takes only real hits (one bullet of the round's gun at most, at most as fast
## as it fires), so the host lands real headshots until the remote player goes down.
func _shoot_down(match_arena: Node, shooter: Fighter, target: Fighter) -> void:
	var d: Dictionary = Weapons.DEFS[String(match_arena.call("_round_gun"))]
	var hit := float(d.damage) * float(d.head_mult) * Weapons.pen_mult(d, "head")
	for _i in 20:
		if not target.alive:
			return
		target.take_damage(hit, "head", shooter, shooter.global_position)
		await at.wait(maxf(float(d.interval), 0.12))
