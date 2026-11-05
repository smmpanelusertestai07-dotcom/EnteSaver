extends RefCounted
## Unit tests of PLAY WITHOUT INTERNET (scripts/lan.gd; run from tests/run_tests.gd, which counts the
## checks): the pairing code, the discovery packets (a host's beacon checked field by field, a
## guest's question), pairing (the right code gives both phones the same room keys; a wrong code,
## a changed field, someone else's key or signature, an old nonce, a blocked player and a second
## guest are refused; too many wrong codes change the code), the room on top of it (Cloud's
## encrypted messages: tampered and replayed ones dropped) and the drop rules a match keeps
## (silence = "left", away = "connection lost").

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	var saved_at := Game.autotest
	var saved_profile := Game.profile.duplicate(true)
	Game.autotest = "unit"                  # nothing is saved
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	me._code()
	var c := Crypto.new()
	var host_key := c.generate_rsa(2048)
	var guest_key := c.generate_rsa(2048)
	me._discovery(host_key)
	me._pairing(host_key, guest_key)
	Game.profile = saved_profile
	Game.autotest = saved_at


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _code() -> void:
	var seen := {}
	var ok := true
	for i in 30:
		var code := Lan.new_code()
		ok = ok and code.length() == Lan.CODE_DIGITS and code.is_valid_int()
		seen[code] = true
	_check(ok and seen.size() > 20, "the pairing code is %d random digits (%d different in 30)" % [Lan.CODE_DIGITS, seen.size()])


func _host(key: CryptoKey) -> Lan:
	var h := Lan.new()
	h._use_key(key)
	h.role = "host"
	h._server_port = Lan.GAME_PORT
	h._new_code()
	return h


func _discovery(key: CryptoKey) -> void:
	var h := _host(key)
	Game.profile.name = "WIFI WOLF"
	var raw := JSON.stringify(h.beacon()).to_utf8_buffer()
	var b := Lan.read_beacon(raw)
	_check(b.get("id") == h.my_id and b.get("name") == "WIFI WOLF" and b.get("port") == Lan.GAME_PORT and b.get("nonce") == h._nonce
		and b.get("bundle") == "default", "a host's beacon reads back (%s)" % str(b.keys()))
	var bad := {
		"another id than its key's": ["id", "0123456789abcdef0123456789abcdef"],
		"another protocol": ["lw", Lan.PROTOCOL + 1],
		"a port that is no game port": ["port", 80],
		"a port that is text": ["port", "47791"],
		"a short nonce": ["nonce", "abc"],
		"a key too long": ["pk", "X".repeat(1300)],
		"not a beacon": ["t", "seek"],
	}
	for what: String in bad:
		var d := h.beacon()
		d[bad[what][0]] = bad[what][1]
		_check(Lan.read_beacon(JSON.stringify(d).to_utf8_buffer()).is_empty(), "a beacon with %s is dropped" % what)
	var odd := h.beacon()
	odd.name = "<b>W|O\nLF</b>"
	odd.bundle = "no such outfit"
	var ob := Lan.read_beacon(JSON.stringify(odd).to_utf8_buffer())
	_check(not ob.is_empty() and not String(ob.name).contains("<") and not String(ob.name).contains("|") and ob.bundle == "default",
		"a beacon's name is cleaned and an unknown outfit is the default (%s, %s)" % [ob.get("name"), ob.get("bundle")])
	var big := h.beacon()
	big["pad"] = "X".repeat(Lan.MAX_DATAGRAM)
	_check(Lan.read_beacon(JSON.stringify(big).to_utf8_buffer()).is_empty() and Lan.read_beacon(PackedByteArray([1, 2, 3])).is_empty()
		and Lan.read_beacon("[1, 2]".to_utf8_buffer()).is_empty(), "oversized and junk datagrams are dropped")
	var seek := JSON.stringify({"lw": Lan.PROTOCOL, "t": "seek", "id": "someone"}).to_utf8_buffer()
	_check(h.is_seek(seek) and not h.is_seek(JSON.stringify({"lw": Lan.PROTOCOL, "t": "seek", "id": h.my_id}).to_utf8_buffer())
		and not h.is_seek(JSON.stringify({"lw": 1, "t": "seek", "id": "someone"}).to_utf8_buffer()) and not h.is_seek(PackedByteArray([0x7B])),
		"a guest's question is answered, not this phone's own or another protocol's")
	h.free()


func _pairing(host_key: CryptoKey, guest_key: CryptoKey) -> void:
	var h := _host(host_key)
	var g := Lan.new()
	g._use_key(guest_key)
	Game.profile.name = "GUEST"
	var listed := Lan.read_beacon(JSON.stringify(h.beacon()).to_utf8_buffer())
	var made := g.pair_message(listed, h.code)
	var msg: Dictionary = made[0]
	var r := h.check_pair(msg.duplicate())
	_check(r.get("ok") == true and r.who.id == g.my_id and r.who.name == "GUEST" and r.keys[0] == made[1][0] and r.keys[1] == made[1][1]
		and (r.keys[0] as PackedByteArray).size() == 32 and r.keys[0] != r.keys[1],
		"the right code gives both phones the same room keys (%s)" % str(r.get("why", "")))
	var wrong := str((int(h.code) + 1) % 10000).pad_zeros(Lan.CODE_DIGITS)
	var w := h.check_pair(g.pair_message(listed, wrong)[0])
	_check(w.get("ok") == false and w.get("why") == "code" and h._tries == 1, "a wrong code is refused")
	var secret := Crypto.new().generate_random_bytes(32)
	_check(Lan.room_keys(secret, Lan.pairing_key("1234", h._nonce, h.my_id)) != Lan.room_keys(secret, Lan.pairing_key("1235", h._nonce, h.my_id)),
		"the room keys depend on the code")
	var changed := {"name": "BOSS", "bundle": "neon", "box": String(g.pair_message(listed, h.code)[0].box), "nonce": "0".repeat(32)}
	for k: String in changed:
		var d := msg.duplicate()
		d[k] = changed[k]
		var cr := h.check_pair(d)
		_check(cr.get("ok") == false, "a pairing message with a changed %s is refused" % k)
	var other := msg.duplicate()
	other.id = "0123456789abcdef0123456789abcdef"
	_check(h.check_pair(other).get("why") == "bad", "a pairing message whose id is not its key's is refused")
	var resigned := msg.duplicate()
	resigned.sig = g._sign("something else")
	_check(h.check_pair(resigned).get("why") == "bad", "a pairing message with a signature that does not match is refused")
	var junk := msg.duplicate()
	junk.tag = "zz"
	_check(h.check_pair(junk).get("why") == "code" and h.check_pair({"t": "pair"}).get("why") == "bad", "a junk tag or message is refused")
	Game.block(g.my_id, "GUEST")
	_check(h.check_pair(msg.duplicate()).get("ok") == false, "a blocked player cannot pair")
	Game.unblock(g.my_id)
	# Too many wrong codes: a new code (and nonce), so the old message is refused too.
	listed = Lan.read_beacon(JSON.stringify(h.beacon()).to_utf8_buffer())
	var first := h.code
	wrong = str((int(first) + 1) % 10000).pad_zeros(Lan.CODE_DIGITS)
	var old: Dictionary = g.pair_message(listed, first)[0]
	var changes := [0]
	h.code_changed.connect(func() -> void: changes[0] += 1)
	h._tries = 0
	for i in Lan.MAX_TRIES:
		h.check_pair(g.pair_message(listed, wrong)[0])
	_check(changes[0] == 1 and h._tries == 0 and h._nonce != listed.nonce and h.check_pair(old).get("why") == "code",
		"%d wrong codes change the code (%s -> %s) and the right old one no longer pairs" % [Lan.MAX_TRIES, first, h.code])
	# Paired: the room is Cloud's own (encrypted, counted), the rules a match keeps are Cloud's too.
	listed = Lan.read_beacon(JSON.stringify(h.beacon()).to_utf8_buffer())
	made = g.pair_message(listed, h.code)
	r = h.check_pair(made[0])
	_check(r.get("ok") == true, "a new pairing with the new code works")
	h._enter_room({"id": r.who.id, "name": r.who.name, "bundle": r.who.bundle, "room": "lan", "aes": r.keys[0], "mac": r.keys[1]})
	g._enter_room({"id": h.my_id, "name": "WIFI WOLF", "bundle": "default", "room": "lan", "aes": made[1][0], "mac": made[1][1]})
	_check(h.check_pair(g.pair_message(listed, h.code)[0]).get("why") == "busy", "a second guest is refused while the host is paired")
	var heard := {"ended": [], "states": 0, "events": []}
	h.session_ended.connect(func(reason: String) -> void: heard.ended.append(reason))
	h.state_received.connect(func(_s: PackedFloat32Array) -> void: heard.states += 1)
	var tampered := g._room_packet({"k": "join"})
	tampered[20] ^= 0x01
	h._on_room(tampered)
	_check(not h.in_session, "a tampered room message is dropped")
	var join := g._room_packet({"k": "join"})
	h._on_room(join)
	_check(h.in_session and h.opponent.get("id") == g.my_id, "the room handshake starts the session")
	h.event_received.connect(func(k: String, d: Array) -> void: heard.events.append([k, d]))
	var state := []
	state.resize(RemoteFighter.STATE_SIZE)
	state.fill(1)
	var st := g._room_packet({"k": "st", "s": state, "t": 5})
	h._on_room(st)
	h._on_room(st)
	h._on_room(g._room_packet({"k": "ev", "e": "hit", "d": [10, "head", {"x": 1}]}))
	h._on_room(g._room_packet({"k": "ev", "e": "pick", "d": ["rifle", 1]}))
	_check(heard.states == 1 and heard.events.size() == 1 and heard.events[0][0] == "pick",
		"a replayed state and an event with a nested value are dropped (%d states, %s)" % [heard.states, str(heard.events)])
	h._process(0.016)
	_check(h.in_session, "a normal frame keeps the local match")
	h._last_heard = Time.get_ticks_msec() - Cloud.SILENCE_MS - 100
	h._process(0.016)
	_check(not h.in_session and heard.ended == ["left"], "a silent other phone has left the local match (%s)" % str(heard.ended))
	h._enter_room({"id": r.who.id, "name": r.who.name, "bundle": r.who.bundle, "room": "lan", "aes": r.keys[0], "mac": r.keys[1]})
	h._ok = true
	h._on_room(g._room_packet({"k": "join"}))
	h._process(0.016)
	h._check_away(h._frame_ms + Cloud.AWAY_MS + 500)
	_check(not h.in_session and heard.ended.size() == 2 and heard.ended[1] == "connection lost",
		"a phone away about as long as the other waits ends the local match as connection lost (%s)" % str(heard.ended))
	h.free()
	g.free()
