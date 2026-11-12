class_name Lan
extends Cloud
## PLAY WITHOUT INTERNET: LONE WOLF 1 vs 1 between two phones on the same Wi-Fi, or on one phone's
## hotspot that the other joins (mobile data can stay off). Nothing leaves the local network and
## there is no server: the HOST phone listens, the JOIN phone connects to it. Lives under Game
## (Game.lan_service()), so the session outlives the scene change into the arena.
##
## It is a Cloud whose room runs over the local network instead of the relay: the arena reaches it
## as Game.session, and everything a match does (state 20 a second, events, the room ping, chat,
## voice, the limits on what the other phone may send, the keep-alive while a match loads, silence
## = "left", away = "connection lost") is Cloud's own code. Only finding the other phone, pairing
## and the transport are here.
##
## Finding: HOST opens a TCP port and says so on UDP port DISCOVERY_PORT once a second (broadcast:
## {lw, t "host", id, name, outfit, public key, port, nonce}); JOIN listens there, asks too ("seek",
## which a host answers straight back) and lists the hosts it hears (read_beacon checks each).
## Pairing: the host shows a PAIRING CODE (CODE_DIGITS digits). The guest picks the host, types the
## code and connects: its "pair" message carries a fresh 32-byte secret encrypted with the host's
## public key (RSA), its own public key and a signature with it (its id is the hash of that key, as
## online), and an HMAC tag with a key stretched from the code (pairing_key). The host refuses a
## wrong code (after MAX_TRIES wrong ones it shows a new code), a bad signature or id, an old
## nonce and a blocked player, then decrypts the secret. Both make the room's AES-256 and HMAC keys
## from the secret and the code (room_keys): from then on every message is a Cloud room message
## (AES-256-CBC + HMAC-SHA256, a counter against replays), one frame on the TCP connection (2-byte
## length, then the bytes; TCP keeps them in order, as the relay does). Others on the same Wi-Fi
## see the hosts' names and outfits, never a match.
## A phone whose Wi-Fi address went away in a match ends it as "connection lost" (it is the one that
## dropped out); a closed connection is the other phone leaving.

signal hosts_changed                   # the JOIN list changed
signal pair_failed(why: String)        # this phone's JOIN was refused: "code" (wrong), "busy", "gone"
signal code_changed                    # the host shows a new pairing code

const DISCOVERY_PORT := 47790
const GAME_PORT := 47791
const PROTOCOL := 2
const CODE_DIGITS := 4
const MAX_TRIES := 5                   # wrong codes before the host shows a new one
const HOST_TIMEOUT_MS := 4500          # a host not heard this long leaves the JOIN list
const PAIR_WAIT_MS := 5000             # a connection that has not paired by then is closed
const MAX_DATAGRAM := 1400
const MAX_HOSTS := 16
const MAX_PENDING := 4
const STRETCH := 2000                  # HMAC rounds from the code to the pairing key

var role := ""                         # "", "host" (HOST: shows the code) or "join" (JOIN: lists the hosts)
var code := ""                         # the pairing code this phone shows as the host
var hosts := {}                        # JOIN: id -> {"name", "bundle", "pk", "ip", "port", "nonce", "seen"}
## Ports hellos go to and the one this phone listens on (tests run two copies on one machine).
var dest_ports: Array[int] = [DISCOVERY_PORT]
var listen_port := DISCOVERY_PORT
var game_port := GAME_PORT
var _udp: PacketPeerUDP
var _server: TCPServer
var _server_port := 0
var _tcp: StreamPeerTCP                # the connection to the other phone (pairing, then the match)
var _rxb := PackedByteArray()
var _outq: Array[PackedByteArray] = [] # frames waiting for the connection to open
var _pending: Array = []               # HOST: [{"tcp", "rx", "t"}] connections that have not paired yet
var _nonce := ""
var _tries := 0
var _beacon_t := 0.0
var _mlock: Object = null
var _my_ip := ""                       # this phone's local address in the match
var _peer_ip := ""                     # the other phone's
var _ip_t := 0.0
var _want := ""                        # HOST or JOIN tapped before this phone's key was ready
var _ok := false                       # the host took this phone's pairing (it says "ok")


func _ready() -> void:
	name = "Lan"
	process_mode = Node.PROCESS_MODE_ALWAYS
	status = "offline"


## The player id and key are the ones the online mode uses (made once, kept on the phone).
func _identity() -> bool:
	if _key == null:
		var cloud := Game.cloud_service()
		cloud.prepare_identity()
		if cloud._key != null:
			_use_key(cloud._key)
	return _key != null


# ---------------------------------------------------------------- HOST / JOIN

## HOST: a new pairing code, the game port open, the beacon on.
func host() -> bool:
	if in_session or _room != "":
		return false
	stop()
	if not _identity():
		_want = "host"           # (the key is being made: a first run that never went online)
		return true
	if not _open_udp(true):
		return false
	_server = TCPServer.new()
	_server_port = 0
	for p in range(game_port, game_port + 6):
		if _server.listen(p) == OK:
			_server_port = p
			break
	if _server_port == 0:
		_server = null
		stop()
		return false
	role = "host"
	_new_code()
	_beacon_t = 0.0
	return true


## JOIN: listens for hosts (and asks for them once a second).
func seek() -> bool:
	if in_session or _room != "":
		return false
	stop()
	if not _identity():
		_want = "join"
		return true
	if not _open_udp(false):
		return false
	role = "join"
	hosts.clear()
	_beacon_t = 0.0
	return true


## Back to neither: discovery and the game port close. A match (or the pairing in progress) is
## not touched: end_session / _leave_room end those.
func stop() -> void:
	role = ""
	_want = ""
	code = ""
	hosts.clear()
	for c: Dictionary in _pending:
		(c.tcp as StreamPeerTCP).disconnect_from_host()
	_pending.clear()
	if _server:
		_server.stop()
		_server = null
	if _udp:
		_udp.close()
		_udp = null
	_multicast_lock(false)


func _new_code() -> void:
	code = new_code()
	_nonce = _crypto.generate_random_bytes(16).hex_encode()
	_tries = 0
	code_changed.emit()


static func new_code() -> String:
	var b := Crypto.new().generate_random_bytes(4)
	var n := (b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) % int(pow(10, CODE_DIGITS))
	return str(n).pad_zeros(CODE_DIGITS)


## The discovery socket: the host must have DISCOVERY_PORT (guests ask there); a guest that cannot
## get it (another app holds it) still finds hosts by asking from any port.
func _open_udp(must_listen: bool) -> bool:
	_udp = PacketPeerUDP.new()
	if _udp.bind(listen_port) != OK:
		_udp = PacketPeerUDP.new()
		if must_listen or _udp.bind(0) != OK:
			_udp = null
			return false
	_udp.set_broadcast_enabled(true)
	_multicast_lock(true)
	return true


## This phone's address on the local network ("" when it is on none: no Wi-Fi, no hotspot).
static func local_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or _private_172(a):
			return a
	return ""


static func _private_172(a: String) -> bool:
	var parts := a.split(".")
	return parts.size() == 4 and parts[0] == "172" and int(parts[1]) >= 16 and int(parts[1]) <= 31


## The limited broadcast plus each private network's /24 broadcast (a phone's hotspot does not
## route 255.255.255.255 on every Android version).
static func broadcast_addresses() -> PackedStringArray:
	var out := PackedStringArray(["255.255.255.255"])
	for a in IP.get_local_addresses():
		var parts := a.split(".")
		if parts.size() == 4 and (a.begins_with("192.168.") or a.begins_with("10.") or _private_172(a)):
			var b := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
			if not b in out:
				out.append(b)
	if Game.autotest != "":
		out.append("127.0.0.1")
	return out


# ---------------------------------------------------------------- discovery packets

func beacon() -> Dictionary:
	return {"lw": PROTOCOL, "t": "host", "id": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "pk": _pk_pem, "port": _server_port, "nonce": _nonce}


## A host's beacon from the network, checked: {} unless every field is right (the id is the hash
## of the key it carries, the name is cleaned, the outfit known, the port a real one).
static func read_beacon(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() > MAX_DATAGRAM or pkt.is_empty() or pkt[0] != 0x7B:
		return {}
	var v: Variant = JSON.parse_string(pkt.get_string_from_utf8())
	if not v is Dictionary:
		return {}
	var d := v as Dictionary
	if not _number(d.get("lw")) or int(d.lw) != PROTOCOL or d.get("t") != "host":
		return {}
	for k in ["id", "name", "bundle", "pk", "nonce"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return {}
	var pk := String(d.pk)
	if pk.length() > 1200 or String(d.id) != pk.sha256_text().left(32) or String(d.nonce).length() != 32:
		return {}
	if not _number(d.get("port")) or int(d.port) < 1024 or int(d.port) > 65535:
		return {}
	var who := Game.clean_name(String(d.name).left(64))
	return {"id": String(d.id), "name": who if who != "" else "PLAYER", "pk": pk, "port": int(d.port),
		"nonce": String(d.nonce), "bundle": String(CharacterModel.bundle_info(String(d.bundle).left(32)).id)}


## A guest's question "who hosts here?" (answered with the beacon, straight to the asker).
func is_seek(pkt: PackedByteArray) -> bool:
	if pkt.size() > 256 or pkt.is_empty() or pkt[0] != 0x7B:
		return false
	var v: Variant = JSON.parse_string(pkt.get_string_from_utf8())
	return v is Dictionary and _number((v as Dictionary).get("lw")) and int((v as Dictionary).lw) == PROTOCOL \
		and (v as Dictionary).get("t") == "seek" and (v as Dictionary).get("id") != my_id


static func _number(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))


func _send_datagram(d: Dictionary, ip := "", port := 0) -> void:
	if _udp == null:
		return
	var bytes := JSON.stringify(d).to_utf8_buffer()
	if ip != "":
		_udp.set_dest_address(ip, port)
		_udp.put_packet(bytes)
		return
	for addr in broadcast_addresses():
		for p in dest_ports:
			_udp.set_dest_address(addr, p)
			_udp.put_packet(bytes)


func _poll_udp(delta: float, now: int) -> void:
	if _udp == null:
		return
	var n := 0
	while _udp.get_available_packet_count() > 0 and n < 64:
		n += 1
		var pkt := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var port := _udp.get_packet_port()
		if role == "host":
			if is_seek(pkt) and _tcp == null:
				_send_datagram(beacon(), ip, port)
		elif role == "join":
			var b := read_beacon(pkt)
			if b.is_empty() or b.id == my_id or Game.is_blocked(String(b.id)):
				continue
			if not hosts.has(b.id) and hosts.size() >= MAX_HOSTS:
				continue
			var known: bool = hosts.has(b.id) and String(hosts[b.id].name) == b.name and String(hosts[b.id].ip) == ip \
				and String(hosts[b.id].nonce) == b.nonce
			b["ip"] = ip
			b["seen"] = now
			hosts[b.id] = b
			if not known:
				hosts_changed.emit()
	_beacon_t -= delta
	if _beacon_t <= 0.0:
		_beacon_t = 1.0
		if role == "host" and _tcp == null:
			_send_datagram(beacon())
		elif role == "join":
			_send_datagram({"lw": PROTOCOL, "t": "seek", "id": my_id})
	if role == "join":
		var gone := []
		for id in hosts:
			if now - int(hosts[id].seen) > HOST_TIMEOUT_MS:
				gone.append(id)
		for id in gone:
			hosts.erase(id)
		if not gone.is_empty():
			hosts_changed.emit()


# ---------------------------------------------------------------- pairing

## The key the pairing code stretches to (the host's nonce and id make it new for each HOST).
static func pairing_key(pin: String, nonce: String, host_id: String) -> PackedByteArray:
	var c := Crypto.new()
	var k := ("lonewolfarena-lan|%s|%s|%s" % [pin, nonce, host_id]).sha256_buffer()
	for i in STRETCH:
		k = c.hmac_digest(HashingContext.HASH_SHA256, k, nonce.to_utf8_buffer())
	return k


## What a pairing message signs and tags: who asks whom (with the name and outfit it shows), the
## wrapped secret and the host's nonce.
static func pair_text(guest_id: String, host_id: String, box: String, nonce: String, who: String, bundle: String) -> String:
	return "lanpair|%s|%s|%s|%s|%s|%s" % [guest_id, host_id, box, nonce, who, bundle]


## The room's AES-256 and HMAC keys from the guest's secret and the pairing key: [aes, mac].
static func room_keys(secret: PackedByteArray, pkey: PackedByteArray) -> Array:
	var c := Crypto.new()
	var a := secret.duplicate()
	a.append_array("aes".to_utf8_buffer())
	var m := secret.duplicate()
	m.append_array("mac".to_utf8_buffer())
	return [c.hmac_digest(HashingContext.HASH_SHA256, pkey, a), c.hmac_digest(HashingContext.HASH_SHA256, pkey, m)]


## The guest's "pair" message for a listed host and the code typed: [message, [aes, mac]] ([] when
## the host's key does not load).
func pair_message(h: Dictionary, pin: String) -> Array:
	var pub := CryptoKey.new()
	if pub.load_from_string(String(h.pk), true) != OK:
		return []
	var secret := _crypto.generate_random_bytes(32)
	var wrapped := _crypto.encrypt(pub, secret)
	if wrapped.is_empty():
		return []
	var box := Marshalls.raw_to_base64(wrapped)
	var pkey := pairing_key(pin, String(h.nonce), String(h.id))
	var text := pair_text(my_id, String(h.id), box, String(h.nonce), String(Game.profile.name), String(Game.profile.bundle))
	var msg := {"lw": PROTOCOL, "t": "pair", "id": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "pk": _pk_pem, "box": box, "nonce": String(h.nonce),
		"tag": _crypto.hmac_digest(HashingContext.HASH_SHA256, pkey, text.to_utf8_buffer()).hex_encode(),
		"sig": _sign(text)}
	return [msg, room_keys(secret, pkey)]


## The host's check of a "pair" message: {"ok": true, "who": {id, name, bundle}, "keys": [aes, mac]}
## or {"ok": false, "why": "code" | "busy" | "bad"}. A wrong code counts towards MAX_TRIES.
func check_pair(d: Dictionary) -> Dictionary:
	for k in ["id", "name", "bundle", "pk", "box", "nonce", "tag", "sig"]:
		if typeof(d.get(k)) != TYPE_STRING or String(d.get(k)).length() > 1200:
			return {"ok": false, "why": "bad"}
	var id := String(d.id)
	if not _number(d.get("lw")) or int(d.lw) != PROTOCOL or d.get("t") != "pair" or id == my_id \
			or id != String(d.pk).sha256_text().left(32):
		return {"ok": false, "why": "bad"}
	if role != "host" or _room != "" or in_session:
		return {"ok": false, "why": "busy"}
	if Game.is_blocked(id):
		return {"ok": false, "why": "busy"}
	if String(d.nonce) != _nonce:
		return {"ok": false, "why": "code"}         # made for an older code
	var pkey := pairing_key(code, _nonce, my_id)
	var text := pair_text(id, my_id, String(d.box), _nonce, String(d.name), String(d.bundle))
	var tag := _crypto.hmac_digest(HashingContext.HASH_SHA256, pkey, text.to_utf8_buffer())
	if String(d.tag).length() != 64 or not _crypto.constant_time_compare(tag, String(d.tag).hex_decode()):
		_tries += 1
		if _tries >= MAX_TRIES:
			_new_code()
		return {"ok": false, "why": "code"}
	if not verify_signed(String(d.pk), text, String(d.sig)):
		return {"ok": false, "why": "bad"}
	var secret := _crypto.decrypt(_key, Marshalls.base64_to_raw(String(d.box)))
	if secret.size() != 32:
		return {"ok": false, "why": "bad"}
	var who := Game.clean_name(String(d.name).left(64))
	return {"ok": true, "keys": room_keys(secret, pkey), "who": {"id": id, "name": who if who != "" else "PLAYER",
		"bundle": String(CharacterModel.bundle_info(String(d.bundle).left(32)).id)}}


## JOIN on a listed host with the code typed: connects and asks to pair. False when it cannot
## start (no such host, a code that is not CODE_DIGITS digits, a match going on).
func join(host_id: String, pin: String) -> bool:
	pin = pin.strip_edges()
	if not hosts.has(host_id) or pin.length() != CODE_DIGITS or not pin.is_valid_int() or in_session or _room != "":
		return false
	var h: Dictionary = hosts[host_id]
	var made := pair_message(h, pin)
	if made.is_empty():
		return false
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(String(h.ip), int(h.port)) != OK:
		_tcp = null
		return false
	_tcp.set_no_delay(true)
	_rxb = PackedByteArray()
	_outq.clear()
	_ok = false
	_peer_ip = String(h.ip)
	_send_frame(JSON.stringify(made[0]).to_utf8_buffer())
	is_host = false
	session_rules = {}
	_enter_room({"id": host_id, "name": h.name, "bundle": h.bundle, "room": "lan", "aes": made[1][0], "mac": made[1][1]})
	_accept_ms = Time.get_ticks_msec()         # Cloud._tick_room gives up after JOIN_TIMEOUT_MS
	return true


## HOST or JOIN waits for this phone's key (made once, a few seconds on a first run).
func getting_ready() -> bool:
	return _want != ""


## Who this phone is pairing with or plays ("" when nobody).
func paired_with() -> String:
	return String(opponent.get("name", "")) if _room != "" else ""


# ---------------------------------------------------------------- the connection

func _poll_server(now: int) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var c := _server.take_connection()
		if _pending.size() >= MAX_PENDING or _room != "" or role != "host":
			c.disconnect_from_host()
			continue
		c.set_no_delay(true)
		_pending.append({"tcp": c, "rx": PackedByteArray(), "t": now})
	var keep: Array = []
	for c: Dictionary in _pending:
		var tcp := c.tcp as StreamPeerTCP
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED or now - int(c.t) > PAIR_WAIT_MS:
			tcp.disconnect_from_host()
			continue
		var rx: PackedByteArray = c.rx
		var avail := tcp.get_available_bytes()
		if avail > 0:
			rx.append_array(tcp.get_data(mini(avail, Cloud.MAX_MESSAGE))[1])
			c.rx = rx                      # (a PackedByteArray is a value: put it back)
		if rx.size() < 2:
			keep.append(c)
			continue
		var size := rx[0] << 8 | rx[1]
		if size == 0 or size > Cloud.MAX_MESSAGE:
			tcp.disconnect_from_host()
			continue
		if rx.size() < 2 + size:
			keep.append(c)
			continue
		var v: Variant = JSON.parse_string(rx.slice(2, 2 + size).get_string_from_utf8())
		var r := check_pair(v as Dictionary) if v is Dictionary else {"ok": false, "why": "bad"}
		if not r.ok or _room != "":
			_frame_to(tcp, {"t": "no", "why": String(r.get("why", "busy"))})
			tcp.get_data(tcp.get_available_bytes())      # (unread bytes would make the close a reset that loses the answer)
			tcp.disconnect_from_host()
			continue
		_tcp = tcp
		_peer_ip = tcp.get_connected_host()
		_rxb = rx.slice(2 + size)
		_outq.clear()
		_frame_to(tcp, {"t": "ok"})
		_ok = true
		is_host = true
		session_rules = {}
		var who: Dictionary = r.who
		_enter_room({"id": who.id, "name": who.name, "bundle": who.bundle, "room": "lan", "aes": r.keys[0], "mac": r.keys[1]})
		_accept_ms = now
	_pending = keep


func _frame_to(tcp: StreamPeerTCP, d: Dictionary) -> void:
	var b := JSON.stringify(d).to_utf8_buffer()
	var f := PackedByteArray([b.size() >> 8 & 0xFF, b.size() & 0xFF])
	f.append_array(b)
	tcp.put_data(f)


func _send_frame(b: PackedByteArray) -> void:
	if _tcp == null or b.size() > Cloud.MAX_MESSAGE:
		return
	var f := PackedByteArray([b.size() >> 8 & 0xFF, b.size() & 0xFF])
	f.append_array(b)
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_tcp.put_data(f)
	else:
		_outq.append(f)


func _poll_tcp() -> void:
	if _tcp == null:
		return
	_tcp.poll()
	var st := _tcp.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		_tcp = null
		status = "offline"
		if in_session:
			end_session("connection lost" if _dropped_out() else "left")     # else the other phone closed it
		elif _room != "":
			_leave_room()
			pair_failed.emit("gone")
		return
	status = "online"
	for f in _outq:
		_tcp.put_data(f)
	_outq.clear()
	var avail := _tcp.get_available_bytes()
	if avail > 0:
		_rxb.append_array(_tcp.get_data(mini(avail, 1 << 16))[1])
	var n := 0
	while _rxb.size() >= 2 and n < 200 and _tcp != null:
		n += 1
		var size := _rxb[0] << 8 | _rxb[1]
		if size == 0 or size > Cloud.MAX_MESSAGE:
			_rxb = PackedByteArray()
			if in_session:
				end_session("left")
			else:
				_leave_room()
			return
		if _rxb.size() < 2 + size:
			break
		var f := _rxb.slice(2, 2 + size)
		_rxb = _rxb.slice(2 + size)
		_on_frame(f)


func _on_frame(f: PackedByteArray) -> void:
	if f[0] == 1:
		if _room != "":
			_on_room(f)
		return
	if is_host or f[0] != 0x7B:
		return
	var v: Variant = JSON.parse_string(f.get_string_from_utf8())
	if v is Dictionary and (v as Dictionary).get("t") == "ok":
		_ok = true
	elif v is Dictionary and (v as Dictionary).get("t") == "no" and not in_session:
		var why := String((v as Dictionary).get("why", "busy"))
		_leave_room()
		pair_failed.emit(why if why in ["code", "busy"] else "busy")


## The room's messages go on the connection (Cloud publishes them on the relay).
func _room_send(d: Dictionary) -> void:
	if _room == "" or _tcp == null or not _ok:
		return
	_send_frame(_room_packet(d))


func _leave_room() -> void:
	super._leave_room()
	if _tcp:
		_tcp.disconnect_from_host()
		_tcp = null
	_rxb = PackedByteArray()
	_outq.clear()
	_my_ip = ""
	_ok = false
	status = "offline"


# ---------------------------------------------------------------- every frame

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	_check_away(now)                         # before anything that waits is read
	if _want != "" and _identity():
		var w := _want
		_want = ""
		if not (host() if w == "host" else seek()):
			pair_failed.emit("gone")
		code_changed.emit()
	_poll_udp(delta, now)
	_poll_server(now)
	_poll_tcp()
	if _room == "":
		return
	_pong_budget = minf(_pong_budget + delta, 3.0)
	_tick_room(delta, now)
	if in_session and now - _last_heard > SILENCE_MS:
		end_session("left")
	if in_session:
		# This phone's Wi-Fi went away (Wi-Fi off, out of range, the hotspot closed): it is the
		# one that dropped out.
		_ip_t -= delta
		if _ip_t <= 0.0:
			_ip_t = 1.0
			if _my_ip == "":
				_my_ip = address_towards(_peer_ip) if Game.autotest == "" else "127.0.0.1"
			elif _dropped_out():
				end_session("connection lost")


## The local match keeps the old waits: a silent other phone has left after SILENCE_MS (its socket
## goes too), and this phone away AWAY_MS has dropped out (Cloud's relay grace is for the relay).
func grace_ms() -> int:
	return SILENCE_MS


## PLAY WITHOUT INTERNET keeps no session file: a closed app cannot come back to its match.
func resume_allowed() -> bool:
	return false


func self_grace_ms() -> int:
	return AWAY_MS


## This phone's address on the other phone's network (the same first three numbers), else any local one.
static func address_towards(peer: String) -> String:
	var net := peer.substr(0, peer.rfind(".") + 1)
	for a in IP.get_local_addresses():
		if net != "" and a.begins_with(net):
			return a
	return local_address()


## The address this phone had in the match is gone: its Wi-Fi or hotspot went away.
func _dropped_out() -> bool:
	return _my_ip != "" and Game.autotest == "" and not _my_ip in IP.get_local_addresses()


# ---------------------------------------------------------------- Android

## Android drops broadcast packets to save power unless the app holds a Wi-Fi multicast lock
## (CHANGE_WIFI_MULTICAST_STATE): held only while HOST or JOIN is open.
func _multicast_lock(on: bool) -> void:
	if OS.get_name() != "Android":
		return
	if on and _mlock == null:
		var rt: Object = Engine.get_singleton("AndroidRuntime") if Engine.has_singleton("AndroidRuntime") else null
		var ctx: Variant = rt.call("getApplicationContext") if rt else null
		var wifi: Variant = (ctx as Object).call("getSystemService", "wifi") if ctx is Object else null
		if wifi is Object:
			var lock: Variant = (wifi as Object).call("createMulticastLock", "lonewolf")
			if lock is Object:
				(lock as Object).call("setReferenceCounted", false)
				(lock as Object).call("acquire")
				_mlock = lock
	elif not on and _mlock != null:
		_mlock.call("release")
		_mlock = null


## A local-network session already runs straight between the two phones: it never asks a STUN
## server or sends an address (NetDirect stays off).
func direct_allowed() -> bool:
	return false


## The match HUD's tag under the ping: the match goes over the local network.
func link_tag() -> String:
	return "LOCAL"
