extends RefCounted
## Unit tests of the direct path (NetDirect, run from tests/run_tests.gd, which counts the checks):
## the STUN Binding Request and the parser of its answer (crafted IPv4 and IPv6 answers, padding,
## the plain MAPPED-ADDRESS, and bad input of every kind), sealed packets (opened by the other
## side only, tampering, replays, late packets, the wrong key or direction), the candidate checks,
## two real sockets on this machine (punching, state, ping, the fall back to the relay exactly
## TIMEOUT_MS after the last packet, the path coming back by itself), and Cloud's part: the hello
## before any address, candidates only for a phone that said hello, nothing with the setting off,
## and a state that both paths bring taken once.

var t: Node


## A Cloud that keeps what it would say in the room instead of sending it.
class RoomRecorder extends Cloud:
	var said := []

	func _room_send(d: Dictionary) -> void:
		said.append(d.duplicate(true))


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._stun()
	me._sealing()
	me._candidates()
	me._loopback()
	me._cloud_part()


func _check(cond: bool, what: String) -> void:
	t._check(cond, what)


static func _tx() -> PackedByteArray:
	return PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])


## A Binding Success Response to _tx() carrying these attributes ([type, value] each, padded).
static func _response(attrs: Array, kind := 0x0101) -> PackedByteArray:
	var body := PackedByteArray()
	for a: Array in attrs:
		var v: PackedByteArray = a[1]
		body.append_array(PackedByteArray([int(a[0]) >> 8, int(a[0]) & 0xFF, v.size() >> 8, v.size() & 0xFF]))
		body.append_array(v)
		while body.size() % 4 != 0:
			body.append(0)
	var p := PackedByteArray([kind >> 8, kind & 0xFF, body.size() >> 8, body.size() & 0xFF, 0x21, 0x12, 0xA4, 0x42])
	p.append_array(_tx())
	p.append_array(body)
	return p


static func _xor_v4(ip: Array, port: int) -> PackedByteArray:
	var cookie := [0x21, 0x12, 0xA4, 0x42]
	var v := PackedByteArray([0, 1, (port ^ 0x2112) >> 8, (port ^ 0x2112) & 0xFF])
	for i in 4:
		v.append(int(ip[i]) ^ cookie[i])
	return v


func _stun() -> void:
	var req := NetDirect.stun_request(_tx())
	_check(req.size() == 20 and req.slice(0, 8) == PackedByteArray([0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42]) and req.slice(8) == _tx(),
		"STUN: a Binding Request is type 1, no attributes, the magic cookie and the transaction id")
	var v4 := _response([[0x0020, _xor_v4([203, 0, 113, 7], 54321)]])
	_check(NetDirect.stun_parse(v4, _tx()) == {"ip": "203.0.113.7", "port": 54321}, "STUN: XOR-MAPPED-ADDRESS, IPv4")
	# IPv6 2001:db8::1:2 port 40000, XORed with the cookie and the transaction id.
	var addr := PackedByteArray([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2])
	var x := PackedByteArray([0x21, 0x12, 0xA4, 0x42])
	x.append_array(_tx())
	var v := PackedByteArray([0, 2, (40000 ^ 0x2112) >> 8, (40000 ^ 0x2112) & 0xFF])
	for i in 16:
		v.append(addr[i] ^ x[i])
	var v6 := _response([[0x8022, "wolf!".to_utf8_buffer()], [0x0020, v]])
	var got := NetDirect.stun_parse(v6, _tx())
	_check(got == {"ip": "2001:db8:0:0:0:0:1:2", "port": 40000} and String(got.get("ip", "")).is_valid_ip_address(),
		"STUN: XOR-MAPPED-ADDRESS, IPv6, after a padded attribute (%s)" % str(got))
	var plain := _response([[0x0001, PackedByteArray([0, 1, 0x1F, 0x90, 198, 51, 100, 9])]])
	_check(NetDirect.stun_parse(plain, _tx()) == {"ip": "198.51.100.9", "port": 8080}, "STUN: the plain MAPPED-ADDRESS of an older server")
	var both := _response([[0x0001, PackedByteArray([0, 1, 0x1F, 0x90, 198, 51, 100, 9])], [0x0020, _xor_v4([203, 0, 113, 7], 54321)]])
	_check(NetDirect.stun_parse(both, _tx()).get("ip") == "203.0.113.7", "STUN: XOR-MAPPED-ADDRESS wins over MAPPED-ADDRESS")
	var bad := {
		"empty": PackedByteArray(),
		"short": v4.slice(0, 19),
		"an error response": _response([[0x0020, _xor_v4([203, 0, 113, 7], 54321)]], 0x0111),
		"a request": _response([[0x0020, _xor_v4([203, 0, 113, 7], 54321)]], 0x0001),
		"a length past the end": v4.slice(0, v4.size() - 4),
		"an attribute past the end": _response([[0x0020, PackedByteArray([0, 1, 0, 0])]]),
		"family 3": _response([[0x0020, PackedByteArray([0, 3, 1, 2, 3, 4, 5, 6])]]),
		"IPv4 with 20 bytes": _response([[0x0020, PackedByteArray([0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18])]]),
		"port 0": _response([[0x0020, _xor_v4([203, 0, 113, 7], 0)]]),
		"no address": _response([[0x8022, "wolf".to_utf8_buffer()]]),
		"garbage": Crypto.new().generate_random_bytes(64),
	}
	var other_tx := v4.duplicate()
	other_tx[19] = 99
	bad["another transaction"] = other_tx
	var cut: PackedByteArray = bad["an attribute past the end"]
	cut[23] = 40                     # the attribute claims 40 bytes
	bad["an attribute past the end"] = cut
	var cookie := v4.duplicate()
	cookie[5] = 0x13
	bad["a wrong cookie"] = cookie
	var wrong := []
	for k: String in bad:
		if not NetDirect.stun_parse(bad[k], _tx()).is_empty():
			wrong.append(k)
	_check(wrong.is_empty(), "STUN: bad answers give no address (%s)" % ", ".join(wrong))
	_check(NetDirect.stun_parse(v4, PackedByteArray([1, 2])).is_empty(), "STUN: a transaction id of the wrong size")


func _sealing() -> void:
	var key := Crypto.new().generate_random_bytes(32)
	var host := NetDirect.new(true, key)
	var guest := NetDirect.new(false, key)
	var msg := JSON.stringify({"k": "st", "s": [1, 2.5], "t": 7}).to_utf8_buffer()
	var p1 := host.seal(msg)
	var p2 := host.seal(msg)
	_check(p1 != p2 and p1[0] == NetDirect.MAGIC and p1[1] == 0 and p1.size() == 10 + 16 + 32 + 32,
		"a sealed packet: MAGIC, the host's direction, sequence, IV, encrypted payload, HMAC (a fresh IV each)")
	var tampered := p1.duplicate()
	tampered[30] = tampered[30] ^ 1
	_check(guest.open_packet(tampered).is_empty(), "a tampered packet is dropped")
	var turned := p1.duplicate()
	turned[1] = 1
	_check(guest.open_packet(turned).is_empty() and host.open_packet(turned).is_empty(), "a changed direction byte is dropped on both sides")
	_check(host.open_packet(host.seal(msg)).is_empty(), "this phone's own packet coming back is dropped")
	_check(NetDirect.new(false, Crypto.new().generate_random_bytes(32)).open_packet(p1).is_empty(), "a packet sealed with another match's key is dropped")
	_check(guest.open_packet(p1.slice(0, 57)).is_empty() and guest.open_packet(PackedByteArray()).is_empty(), "short packets are dropped")
	var d := guest.open_packet(p2)
	_check(d.get("k") == "st" and d.get("s") == [1.0, 2.5], "the other side opens it (%s)" % str(d))
	_check(guest.open_packet(p2).is_empty(), "a replayed packet is dropped")
	_check(guest.open_packet(p1).is_empty(), "an older packet that comes late is dropped")
	_check(not guest.open_packet(host.seal(msg)).is_empty(), "the next one is taken")
	# The app closed and opened again in the same match: a new path object with the same keys. Its
	# packets must pass the other phone's "newer than the last one" rule (the sequence starts at the
	# wall clock in ms and a path sends some 25 packets a second, so a later start is always ahead
	# of an earlier path's count; the check keeps to that rate: 20 packets, then 60 ms).
	for i in 20:
		guest.open_packet(host.seal(msg))
	OS.delay_msec(60)
	var host_again := NetDirect.new(true, key)
	_check(not guest.open_packet(host_again.seal(msg)).is_empty(), "after a restart the new path's first packet is taken by the other phone")
	_check(not host_again.open_packet(guest.seal(msg)).is_empty(), "and the restarted phone takes the other phone's next packet")
	_check(guest.open_packet(host.seal(msg)).is_empty(), "a packet of the path from before the restart is not newer than the new one's")
	_check(host.open_packet(guest.seal(msg)).get("t") == 7, "and the other way")


func _candidates() -> void:
	var good := [["203.0.113.7", 40000], ["10.1.2.3", 1024], ["2409:4040:1:2::5", 65535], ["fd00::1", 50000]]
	var bad := [["127.0.0.1", 40000], ["::1", 40000], ["fe80::1", 40000], ["169.254.3.4", 40000], ["224.0.0.1", 40000],
		["255.255.255.255", 40000], ["ff02::1", 40000], ["0.0.0.0", 40000], ["10.1.2.3", 53], ["10.1.2.3", 70000],
		["example.com", 40000], ["10.1.2.3", "40000"], [12, 40000], ["fe80::1%wlan0", 40000]]
	var wrong := []
	for c: Array in good:
		if not NetDirect.candidate_ok(c[0], c[1]):
			wrong.append(str(c))
	for c: Array in bad:
		if NetDirect.candidate_ok(c[0], c[1]):
			wrong.append(str(c))
	_check(wrong.is_empty(), "candidates: real unicast addresses and ports from 1024 only (%s)" % ", ".join(wrong))
	_check(NetDirect.candidate_ok("127.0.0.1", 40000, true) and not NetDirect.candidate_ok("10.1.2.3", 40000, true),
		"LW_DIRECT=local takes loopback only")
	var list := NetDirect.candidates_from([["203.0.113.7", 40000.0], ["127.0.0.1", 40000], "x", ["10.1.2.3"], ["10.1.2.3", 41000, 1]])
	_check(list == [["203.0.113.7", 40000]], "a candidate list from the room keeps the valid entries (%s)" % str(list))
	var many := []
	for i in 30:
		many.append(["10.0.0.%d" % (i + 1), 40000])
	_check(NetDirect.candidates_from(many).size() == NetDirect.MAX_CANDIDATES and NetDirect.candidates_from({}).is_empty(),
		"at most MAX_CANDIDATES are taken")
	_check(not NetDirect.local_usable("127.0.0.1") and not NetDirect.local_usable("fe80::2") and NetDirect.local_usable("192.168.1.20")
		and NetDirect.local_usable("2409:4040::9"), "own addresses: no loopback or link-local")
	if OS.get_environment("LW_DIRECT") == "":
		var saved := Game.autotest
		Game.autotest = "unit"
		_check(NetDirect.mode() == "off", "automated runs stay off the direct path (no STUN server asked)")
		Game.autotest = saved
	_check(Game.DEFAULT_SETTINGS.direct_connect == true and "direct_connect" in Game.BOOL_SETTINGS,
		"DIRECT CONNECTION is on by default, an on/off setting")


## Two sockets on this machine, driven with a made-up clock: the packets are real.
func _loopback() -> void:
	var key := Crypto.new().generate_random_bytes(32)
	var a := NetDirect.new(true, key, true)
	var b := NetDirect.new(false, key, true)
	var now := 100000
	_check(a.open(now) and b.open(now), "two direct sockets open on this machine")
	_check(a.gathered and a.candidates == [["127.0.0.1", a.port]], "LW_DIRECT=local: one loopback candidate, no STUN")
	_check(not a.can_send(now) and not a.heard(now), "nothing goes direct before the other side is heard")
	a.set_peer_candidates(b.candidates, now)
	b.set_peer_candidates(a.candidates, now)
	var steps := 0
	while steps < 60 and not (a.can_send(now) and b.can_send(now)):
		steps += 1
		now += 50
		_pump(a, b, now, 0.05)
	_check(a.can_send(now) and b.can_send(now), "punching opens the path both ways (%d steps)" % steps)
	b.send_state([1, 2, 3], 4321, now)
	var got := []
	for i in 10:
		OS.delay_msec(2)
		got.append_array(a.poll(now, 0.0))
		if not got.is_empty():
			break
	_check(got.size() == 1 and got[0].get("s") == [1.0, 2.0, 3.0] and int(got[0].get("t")) == 4321 and a.states_in == 1,
		"a state goes over the direct path (%s)" % str(got))
	for i in 30:
		now += 50
		_pump(a, b, now, 0.05)
	_check(a.rtt >= 0 and a.rtt < 1000 and b.rtt >= 0, "the ping over the direct path gives a round trip (%d ms)" % a.rtt)
	# Cut: nothing more reaches the host. It falls back exactly TIMEOUT_MS after the last packet.
	b.blocked = true
	for i in 5:
		now += 50
		_pump(a, b, now, 0.05)
	var last: int = a._rx_ms
	_check(last > 0 and a.can_send(last + NetDirect.TIMEOUT_MS - 1) and not a.can_send(last + NetDirect.TIMEOUT_MS),
		"the state goes back to the relay TIMEOUT_MS after the last direct packet")
	_check(not b.can_send(now), "the blocked side sends nothing direct")
	now = last + NetDirect.TIMEOUT_MS + 600
	_pump(a, b, now, 0.6)
	_check(not a.can_send(now) and not b.can_send(now), "both sides are back on the relay")
	b.blocked = false
	steps = 0
	while steps < 80 and not (a.can_send(now) and b.can_send(now)):
		steps += 1
		now += 100
		_pump(a, b, now, 0.1)
	_check(a.can_send(now) and b.can_send(now), "the path comes back by itself (background punching, %d steps)" % steps)
	a.close()
	b.close()


func _pump(a: NetDirect, b: NetDirect, now: int, delta: float) -> void:
	a.poll(now, delta)
	b.poll(now, delta)
	OS.delay_msec(2)
	a.poll(now, 0.0)
	b.poll(now, 0.0)


func _cloud_part() -> void:
	var c := RoomRecorder.new()
	c.in_session = true
	c._room = "test"
	c.is_host = true
	c._aes = Crypto.new().generate_random_bytes(32)
	c._mac = Crypto.new().generate_random_bytes(32)
	c.opponent = {"id": "peer"}
	c.direct = NetDirect.new(true, c._mac, true)
	c.direct.open(Time.get_ticks_msec())
	for i in 3:
		c._tick_direct(0.1)
	var kinds := c.said.map(func(d: Dictionary) -> String: return String(d.k))
	_check(kinds == ["dh"], "the direct path starts with a hello and no address (%s)" % str(kinds))
	# The other phone's own room messages, sealed with the same keys.
	var other := Cloud.new()
	other.my_id = "peer"
	other._aes = c._aes
	other._mac = c._mac
	c._on_room(other._room_packet({"k": "dc", "c": [["127.0.0.1", 40000], ["8.8.8.8", 53]]}))
	c._tick_direct(0.1)
	var dc: Array = c.said.filter(func(d: Dictionary) -> bool: return d.k == "dc")
	_check(c.direct.peer_candidates == [["127.0.0.1", 40000]] and dc.size() == 1 and dc[0].c == [["127.0.0.1", c.direct.port]],
		"its candidates (checked) start the punching, ours answer them")
	var s := [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
	var taken := [0]
	c.state_received.connect(func(_st: PackedFloat32Array) -> void: taken[0] += 1)
	c._on_room(other._room_packet({"k": "st", "s": s, "t": 500}))
	_check(not c._on_state_msg({"s": s, "t": 500}) and not c._on_state_msg({"s": s, "t": 499}) and c._on_state_msg({"s": s, "t": 501})
		and taken[0] == 2 and c.relay_states_in == 1, "a state both paths bring is taken once, an older one not at all")
	_check(not c._on_state_msg({"s": [1, "x", 3, 4, 5, 6, 7, 8, 9, 0], "t": 900}) and not c._on_state_msg({"s": [1], "t": 901}),
		"a direct state is checked like the relay's")
	c._direct_end()
	_check(c.direct == null and not c.direct_up(), "the session's end closes the direct path")
	# DIRECT CONNECTION off (no NetDirect): the other phone's hello and candidates change nothing,
	# and nothing about the direct path is said.
	c.said.clear()
	c._on_room(other._room_packet({"k": "dh"}))
	c._on_room(other._room_packet({"k": "dc", "c": [["127.0.0.1", 40000]]}))
	c._process(0.1)
	_check(c.said.is_empty() and c.direct == null, "with DIRECT CONNECTION off no address ever goes out")
	other.free()
	c.free()
