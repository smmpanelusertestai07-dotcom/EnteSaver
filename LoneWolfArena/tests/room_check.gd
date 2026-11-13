extends Node
## Friends and custom rooms end to end (Cloud through tests/mqtt_mock.gd, started by
## tools/qa/run_checks.sh). The guest (LW_NET_ROLE=guest) asks the host to be friends and the host
## accepts; each phone lists the other's signed player card (v2: picture, banner, level and
## signature, kept by the broker) and sees a new banner arrive once the other phone changes it;
## the host opens room 424242 with password 4821 and rules (first to 1, unlimited walls
## and ammo, and this build's RoomRules off their defaults: HP 100, speed 125%, jump 150%, one gun
## the whole match (the sniper), no aim assist, a room name); the guest tries a wrong password (refused), then the right one; the host sees it in
## the room and starts; both play the match with the room's rules (the host's walls never run out)
## (the room's rules reach the guest with the room before START; both phones' arenas play HP 100,
## the speed, the jump, the sniper without a pick panel, no aim assist) and the host wins. Prints "ROOM CHECK DONE bad=N".

const CODE := "424242"
const RULES := {"rounds": 1, "walls": true, "ammo": true, "frags": false, "hp": 100, "speed": 125, "jump": 150,
	"gun": "fixed", "gun_id": "sniper", "aim": false, "name": "CHECK ROOM"}
const PIN := "4821"
## Each phone's name card (its banner changes to "then" once it has seen the other's card).
const CARDS := {
	"host": {"avatar": "neon", "banner": "hive", "signature": "HOST SIDE", "xp": 5740, "then": "shards"},
	"guest": {"avatar": "royal", "banner": "scope", "signature": "GUEST SIDE", "xp": 0, "then": "contour"},
}

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	var host := OS.get_environment("LW_NET_ROLE") == "host"
	var me: Dictionary = CARDS["host" if host else "guest"]
	var them: Dictionary = CARDS["guest" if host else "host"]
	for k: String in ["avatar", "banner", "signature", "xp"]:
		Game.profile[k] = me[k]
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
	# ALL PLAYERS: the other phone's signed card (v3, with its career) is kept by the broker and listed whole; a
	# change of its banner publishes it again.
	cloud.start_directory()
	if not await _until(func() -> bool: return cloud.directory.has(other), 20.0):
		_fail("the other player's card never arrived")
	else:
		var card: Dictionary = cloud.directory[other]
		var level := clampi(1 + int(them.xp) / Game.XP_PER_LEVEL, 1, Cloud.CARD_LEVEL_MAX)
		if String(card.name) != String(cloud.peers[other].name):
			_fail("the card's name differs from the lobby's")
		if int(card.v) != 3 or (card.career as Dictionary).size() != 5 or card.avatar != them.avatar or card.banner != them.banner or int(card.level) != level \
				or card.signature != them.signature:
			_fail("the other player's v3 card did not come through whole: %s" % str(card))
		at.log_line("card v3: picture %s, banner %s, LV %d, \"%s\", career %s" % [card.avatar, card.banner, int(card.level), card.signature,
			str(card.career)])
		Game.profile.banner = me.then
		if not await _until(func() -> bool: return String((cloud.directory.get(other, {}) as Dictionary).get("banner", "")) == them.then, 20.0):
			_fail("the other player's new banner never arrived (a changed card is published again)")
	cloud.stop_directory()
	at.log_line("friends: %s (code %s)" % [Game.is_friend(other), Cloud.friend_code(other)])
	# Friends chat (NetChat): each phone sends the other a message, encrypted to the friend's key and
	# left on the relay; it arrives and is kept (unread), and its waiting copy is taken off the relay.
	var why := "?"
	for _i in 12:
		why = cloud.send_friend_chat(other, "hello from %s!" % ("host" if host else "guest"))
		if why == "":
			break
		await at.wait(0.5)
	if why != "":
		_fail("the friends chat message could not be sent (%s)" % why)
	var want := "HELLO FROM %s!" % ("GUEST" if host else "HOST")
	if not await _until(func() -> bool: return NetChat.messages(other).any(func(m: Array) -> bool:
			return not bool(m[1]) and String(m[2]) == want), 20.0):
		_fail("the friend's chat message never arrived")
	else:
		at.log_line("friends chat: \"%s\", unread %d" % [want, NetChat.unread(other)])
	# Custom room.
	if host:
		cloud.open_room(PIN, RULES, CODE)
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
		# The room's rules reach the joiner with the room (the host's roster), before START.
		if not await _until(func() -> bool: return int(cloud.room_rules_now().get("hp", 0)) == 100, 15.0):
			_fail("the room's rules never reached the joiner before the start (%s)" % str(cloud.room_rules_now()))
		elif String(cloud.room_rules_now().name) != "CHECK ROOM":
			_fail("the room's name did not come with its rules")
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
	# Both phones play by this build's room rules (RoomRules on the arena).
	var rr: RoomRules = arena.get("rules")
	at.log_line("room rules object: custom %s, HP %d, speed x%.2f, jump x%.2f, gun %s, assist %s, player HP %d" % [rr.custom, int(p.hp_max),
		p.rule_speed, p.rule_jump, p.gun().id, (p as Player).room_assist, int(p.hp)])
	if not rr.custom or p.hp_max != 100.0 or p.hp > 100.0 or b.hp_max != 100.0 or not is_equal_approx(p.rule_speed, 1.25) \
			or not is_equal_approx(p.rule_jump * p.rule_jump, 1.5) or (p as Player).room_assist:
		_fail("this phone's match does not play the room's HP / speed / jump / aim rules")
	if p.gun().id != "sniper" or b.gun().id != "sniper" or bool((arena.get("hud") as Node).get("panels").pick_open):
		_fail("ONE GUN: both fighters should hold the sniper without a pick panel (%s / %s)" % [p.gun().id, b.gun().id])
	# The online HUD layer: the round trip to the other phone is measured, and the host's chat line
	# (the room's encryption) shows in the guest's feed.
	var hud_net: HudNet = (arena.get("hud") as Node).get_node_or_null("HudNet")
	if hud_net == null:
		_fail("the online HUD layer (ping, chat) is missing")
	else:
		if not await _until(func() -> bool: return cloud.peer_rtt >= 0 and cloud.relay_rtt >= 0, 10.0):
			_fail("no round trip measured (opponent %d ms, relay %d ms)" % [cloud.peer_rtt, cloud.relay_rtt])
		at.log_line("ping: opponent %d ms, relay %d ms" % [cloud.peer_rtt, cloud.relay_rtt])
		if host:
			hud_net.send("nice shot")
		elif not await _until(func() -> bool: return hud_net.feed.any(func(e: Dictionary) -> bool: return String(e.text) == "NICE SHOT"), 10.0):
			_fail("the opponent's chat line never showed")
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
