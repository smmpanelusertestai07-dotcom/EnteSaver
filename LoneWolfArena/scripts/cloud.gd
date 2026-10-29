class_name Cloud
extends Node
## Internet 1 vs 1 with no account and no server of our own: free public MQTT brokers (TLS
## WebSocket) only relay messages, and everything in a match is end-to-end encrypted on the two
## phones, so the relay sees scrambled bytes. Same interface as Lan, so the arena runs either.
##
## Lobby (topic ROOT/lobby): while PLAY ONLINE is open every phone announces {id, name, outfit,
## RSA-2048 public key} every 3 s and lists the others; the id is a hash of the key, so nobody can
## announce someone else's id with their own key. CHALLENGE sends that phone (topic ROOT/u/<id>)
## a fresh room name, AES-256 key and HMAC key encrypted with its public key; the answers carry an
## HMAC only the holders of those keys can make. In the room (ROOT/r/<room>) every message is
## AES-256-CBC with a random IV plus an HMAC-SHA256 over it, and carries the sender's id and a
## counter (replays are dropped). The inviter hosts. State goes out 10 times a second; a silent
## opponent or a "bye" ends the match. Anyone can publish to a public broker, so invites are rate
## limited and the list is capped. The lobby shows names, outfits and public keys only; nothing is
## stored by the game anywhere.

signal peers_changed
signal invited(peer_name: String)
signal invite_cancelled
signal invite_answered(accepted: bool, peer_name: String)
signal session_started(host: bool)
signal session_ended(reason: String)
signal event_received(kind: String, data: Array)
signal state_received(state: PackedFloat32Array)

const ROOT := "lonewolfarena/v1"
const BROKERS := ["wss://broker.emqx.io:8084/mqtt", "wss://broker.hivemq.com:8884/mqtt"]
const ANNOUNCE_S := 3.0
const PEER_TIMEOUT_MS := 10000
const INVITE_TIMEOUT_MS := 25000
const SILENCE_MS := 8000
const PING_S := 20.0
const MAX_MESSAGE := 4096
const MAX_PEERS := 40
const INBOX_RATE := 4.0        # inbox messages handled per second (each invite costs an RSA decrypt)

var state_interval := 0.1      # seconds between state packets
var my_id := ""                # hash of this phone's public key (set once the key exists)
var peers := {}                # id -> {"name", "bundle", "pk", "seen"}
var in_session := false
var is_host := false
var opponent := {}             # {"id", "name", "bundle"}
var queue: Array = []
var status := ""               # "preparing", "connecting", "online", "offline"
var _brokers: Array = BROKERS
var _broker_i := 0
var _ws: WebSocketPeer
var _connected := false        # CONNACK received
var _sent_connect := false
var _rx := PackedByteArray()
var _pid := 0
var _ping_t := 0.0
var _announce_t := 0.0
var _retry_t := 0.0
var _connect_t := 0.0
var _want_lobby := false
var _key: CryptoKey            # this phone's RSA key (made once per run, off the main thread)
var _pk_pem := ""
var _keygen := -1
var _keygen_out: Array = []
var _room := ""
var _aes := PackedByteArray()
var _mac := PackedByteArray()
var _seq := 0
var _their_seq := -1
var _join_t := 0.0
var _outgoing := {}            # {"id", "name", "bundle", "room", "aes", "mac", "t"}
var _incoming := {}            # {"id", "name", "bundle", "room", "aes", "mac", "t"}
var _last_heard := 0
var _inbox_budget := 8.0
var _crypto := Crypto.new()


func _ready() -> void:
	name = "Cloud"
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.has_feature("template") and OS.get_environment("LW_MQTT_URL") != "":
		_brokers = [OS.get_environment("LW_MQTT_URL")]      # tests: a local broker


func configured() -> bool:
	return true


# ---------------------------------------------------------------- connection

func start_lobby() -> void:
	_want_lobby = true
	if _key == null and _keygen == -1:
		status = "preparing"
		_keygen = WorkerThreadPool.add_task(_make_key)
	elif _key != null:
		_connect()
		if _connected:
			_subscribe(ROOT + "/lobby")
			_announce_t = 0.0


func stop_lobby() -> void:
	_want_lobby = false
	peers.clear()
	if _connected:
		_unsubscribe(ROOT + "/lobby")
	if not in_session and _outgoing.is_empty() and _room == "" and _ws != null:
		_send_packet(PackedByteArray([0xE0, 0x00]))
		_ws.close()
		_ws = null
		_connected = false


func _make_key() -> void:
	_keygen_out.append(Crypto.new().generate_rsa(2048))     # appended once; read on the main thread


func _connect() -> void:
	if _ws != null:
		return
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray(["mqtt"])
	_ws.inbound_buffer_size = 1 << 20      # a public broker forwards anyone's messages up to 1 MB
	_rx.clear()
	_connected = false
	_sent_connect = false
	_connect_t = 0.0
	if _ws.connect_to_url(String(_brokers[_broker_i])) != OK:
		_ws = null
		_next_broker()
		return
	status = "connecting"


func _next_broker() -> void:
	_broker_i = (_broker_i + 1) % _brokers.size()
	_retry_t = 2.0
	status = "offline"


func _process(delta: float) -> void:
	if _keygen != -1 and not _keygen_out.is_empty():
		WorkerThreadPool.wait_for_task_completion(_keygen)
		_keygen = -1
		_key = _keygen_out[0]
		_pk_pem = _key.save_to_string(true)
		my_id = _pk_pem.sha256_text().left(32)
		_keygen_out.clear()
		if _want_lobby:
			_connect()
	if _ws == null:
		if (_want_lobby or in_session) and _key != null:
			_retry_t -= delta
			if _retry_t <= 0.0:
				_connect()
		return
	_inbox_budget = minf(_inbox_budget + delta * INBOX_RATE, 8.0)
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		_ws = null
		_connected = false
		if in_session:
			end_session("connection lost")
		_next_broker()
		return
	if st == WebSocketPeer.STATE_OPEN:
		if not _sent_connect:
			_send_connect()
		var n := 0
		while _ws.get_available_packet_count() > 0 and n < 200:
			n += 1
			_rx.append_array(_ws.get_packet())
		_parse()
	_connect_t += delta
	if not _connected and _connect_t > 8.0:
		_ws.close()          # no answer from this broker: try the next one
		_ws = null
		_next_broker()
		return
	if not _connected:
		return
	_ping_t -= delta
	if _ping_t <= 0.0:
		_ping_t = PING_S
		_send_packet(PackedByteArray([0xC0, 0x00]))
	if _room != "" and not in_session:
		_join_t -= delta
		if _join_t <= 0.0:
			_join_t = 1.0
			_room_send({"k": "join"})
	if _want_lobby:
		_announce_t -= delta
		if _announce_t <= 0.0:
			_announce_t = ANNOUNCE_S
			_publish_json(ROOT + "/lobby", {"t": "hi", "id": my_id, "name": String(Game.profile.name),
				"bundle": String(Game.profile.bundle), "pk": _pk_pem})
	var now := Time.get_ticks_msec()
	var gone := []
	for id in peers:
		if now - int(peers[id].seen) > PEER_TIMEOUT_MS:
			gone.append(id)
	for id in gone:
		peers.erase(id)
	if not gone.is_empty():
		peers_changed.emit()
	if in_session and now - _last_heard > SILENCE_MS:
		end_session("left")
	if not _outgoing.is_empty() and not in_session and now - int(_outgoing.t) > INVITE_TIMEOUT_MS:
		var who := String(_outgoing.name)
		cancel_invite()
		invite_answered.emit(false, who)
	if not _incoming.is_empty() and now - int(_incoming.t) > INVITE_TIMEOUT_MS:
		_incoming = {}
		invite_cancelled.emit()


# ---------------------------------------------------------------- MQTT 3.1.1 (QoS 0)

static func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray([(b.size() >> 8) & 0xFF, b.size() & 0xFF])
	out.append_array(b)
	return out


static func _packet(header: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([header])
	var n := body.size()
	while true:
		var byte := n % 128
		n = n / 128
		if n > 0:
			byte |= 0x80
		out.append(byte)
		if n == 0:
			break
	out.append_array(body)
	return out


func _send_packet(p: PackedByteArray) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(p)


func _send_connect() -> void:
	var body := _str("MQTT")
	body.append_array(PackedByteArray([4, 0x02, 0, 60]))       # level 4, clean session, keep-alive 60 s
	body.append_array(_str("lw" + my_id.left(20)))           # MQTT allows 23-character client ids
	_send_packet(_packet(0x10, body))
	_sent_connect = true


func _next_pid() -> PackedByteArray:
	_pid = _pid % 65535 + 1
	return PackedByteArray([_pid >> 8, _pid & 0xFF])


func _subscribe(topic: String) -> void:
	var body := _next_pid()
	body.append_array(_str(topic))
	body.append(0)
	_send_packet(_packet(0x82, body))


func _unsubscribe(topic: String) -> void:
	var body := _next_pid()
	body.append_array(_str(topic))
	_send_packet(_packet(0xA2, body))


func _publish(topic: String, payload: PackedByteArray) -> void:
	if not _connected:
		return
	var body := _str(topic)
	body.append_array(payload)
	_send_packet(_packet(0x30, body))


func _publish_json(topic: String, d: Dictionary) -> void:
	_publish(topic, JSON.stringify(d).to_utf8_buffer())


func _parse() -> void:
	while _rx.size() >= 2:
		var mult := 1
		var length := 0
		var i := 1
		var complete := false
		while i < _rx.size() and i <= 4:
			var b := _rx[i]
			length += (b & 0x7F) * mult
			mult *= 128
			i += 1
			if b & 0x80 == 0:
				complete = true
				break
		if not complete:
			if i > 4:
				_rx.clear()            # malformed
			return
		if _rx.size() < i + length:
			return
		var header := _rx[0]
		var body := _rx.slice(i, i + length)
		_rx = _rx.slice(i + length)
		match header & 0xF0:
			0x20:                    # CONNACK
				if body.size() >= 2 and body[1] == 0:
					_connected = true
					status = "online"
					_ping_t = PING_S
					_subscribe(ROOT + "/u/" + my_id)
					if _want_lobby:
						_subscribe(ROOT + "/lobby")
						_announce_t = 0.0
					if _room != "":
						_subscribe(ROOT + "/r/" + _room)
				else:
					_ws.close()
			0x30:                    # PUBLISH
				if body.size() < 2:
					continue
				var tl := (body[0] << 8) | body[1]
				if body.size() < 2 + tl:
					continue
				var topic := body.slice(2, 2 + tl).get_string_from_utf8()
				var start := 2 + tl + (2 if (header & 0x06) != 0 else 0)
				var payload := body.slice(start)
				if payload.size() <= MAX_MESSAGE:
					_on_publish(topic, payload)


func _on_publish(topic: String, payload: PackedByteArray) -> void:
	if topic == ROOT + "/lobby" or topic == ROOT + "/u/" + my_id:
		var d: Variant = JSON.parse_string(payload.get_string_from_utf8())
		if d is Dictionary and typeof(d.get("id", d.get("from"))) == TYPE_STRING:
			if topic == ROOT + "/lobby":
				_on_lobby(d)
			else:
				_on_inbox(d)
	elif _room != "" and topic == ROOT + "/r/" + _room:
		_on_room(payload)


# ---------------------------------------------------------------- lobby and invites

func _on_lobby(d: Dictionary) -> void:
	if String(d.get("t", "")) != "hi":
		return
	var id := String(d.id)
	if id == my_id or typeof(d.get("pk")) != TYPE_STRING or String(d.pk).length() > 1200 or id != String(d.pk).sha256_text().left(32):
		return
	if not peers.has(id) and peers.size() >= MAX_PEERS:
		return
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	var known := peers.has(id) and String(peers[id].name) == who
	peers[id] = {"name": who if who != "" else "PLAYER", "bundle": b, "pk": String(d.pk), "seen": Time.get_ticks_msec()}
	if not known:
		peers_changed.emit()


func _on_inbox(d: Dictionary) -> void:
	var from := String(d.get("from", "")).left(32)
	if from == "" or from == my_id or _inbox_budget < 1.0:
		return
	_inbox_budget -= 1.0
	match String(d.get("t", "")):
		"inv":
			if typeof(d.get("sec")) != TYPE_STRING:
				return
			var sec := _crypto.decrypt(_key, Marshalls.base64_to_raw(String(d.sec)))
			if sec.size() != 80:
				return
			var inv := {"id": from, "room": sec.slice(0, 16).hex_encode(), "aes": sec.slice(16, 48), "mac": sec.slice(48, 80)}
			if in_session or not _outgoing.is_empty() or not _incoming.is_empty():
				_publish_json(ROOT + "/u/" + from, {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
				return
			var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
			inv.name = who if who != "" else "PLAYER"
			inv.bundle = String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
			inv.t = Time.get_ticks_msec()
			_incoming = inv
			invited.emit(String(_incoming.name))
		"can":
			if String(_incoming.get("id", "")) == from and _tagged(d, _incoming, "can", from):
				_incoming = {}
				invite_cancelled.emit()
		"dec":
			if String(_outgoing.get("id", "")) == from and _tagged(d, _outgoing, "dec", from):
				var who_out := String(_outgoing.name)
				cancel_invite(false)
				invite_answered.emit(false, who_out)
		"acc":
			if String(_outgoing.get("id", "")) == from and _tagged(d, _outgoing, "acc", from):
				_last_heard = Time.get_ticks_msec()     # the room handshake follows


## Proof that the sender holds an invite's keys: an HMAC over what it says, the room and its id.
func _tag(inv: Dictionary, what: String, sender: String) -> String:
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, inv.mac, (what + String(inv.room) + sender).to_utf8_buffer()).hex_encode()


func _tagged(d: Dictionary, inv: Dictionary, what: String, sender: String) -> bool:
	return typeof(d.get("mac")) == TYPE_STRING and _crypto.constant_time_compare(
		_tag(inv, what, sender).to_utf8_buffer(), String(d.mac).to_utf8_buffer())


## Challenges a listed player: its public key wraps a fresh room name and the room's keys.
func invite(peer_id: String) -> bool:
	if in_session or not _outgoing.is_empty() or not peers.has(peer_id) or not _connected:
		return false
	var pub := CryptoKey.new()
	if pub.load_from_string(String(peers[peer_id].pk), true) != OK:
		return false
	var sec := _crypto.generate_random_bytes(80)
	var wrapped := _crypto.encrypt(pub, sec)
	if wrapped.is_empty():
		return false
	var info: Dictionary = peers[peer_id]
	_outgoing = {"id": peer_id, "name": info.name, "bundle": info.bundle, "room": sec.slice(0, 16).hex_encode(),
		"aes": sec.slice(16, 48), "mac": sec.slice(48, 80), "t": Time.get_ticks_msec()}
	is_host = true
	_enter_room(_outgoing)
	_publish_json(ROOT + "/u/" + peer_id, {"t": "inv", "from": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "sec": Marshalls.raw_to_base64(wrapped)})
	return true


func cancel_invite(tell := true) -> void:
	if _outgoing.is_empty():
		return
	if tell:
		_publish_json(ROOT + "/u/" + String(_outgoing.id), {"t": "can", "from": my_id, "mac": _tag(_outgoing, "can", my_id)})
	_outgoing = {}
	if not in_session:
		_leave_room()


func has_invite() -> bool:
	return not _incoming.is_empty()


func waiting_for() -> String:
	return String(_outgoing.get("name", ""))


func answer(accept: bool) -> void:
	if _incoming.is_empty():
		return
	var inv := _incoming
	_incoming = {}
	if not accept:
		_publish_json(ROOT + "/u/" + String(inv.id), {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
		return
	is_host = false
	_enter_room(inv)
	_publish_json(ROOT + "/u/" + String(inv.id), {"t": "acc", "from": my_id, "mac": _tag(inv, "acc", my_id)})


func _enter_room(info: Dictionary) -> void:
	opponent = {"id": info.id, "name": info.name, "bundle": info.bundle}
	_room = String(info.room)
	_aes = info.aes
	_mac = info.mac
	_seq = 0
	_their_seq = -1
	_join_t = 0.0
	_last_heard = Time.get_ticks_msec()
	_subscribe(ROOT + "/r/" + _room)


func _leave_room() -> void:
	if _room != "":
		_unsubscribe(ROOT + "/r/" + _room)
	_room = ""
	_aes = PackedByteArray()
	_mac = PackedByteArray()
	opponent = {}


# ---------------------------------------------------------------- the room (end-to-end encrypted)

func _room_send(d: Dictionary) -> void:
	if _room == "":
		return
	_seq += 1
	d["f"] = my_id
	d["n"] = _seq
	var plain := JSON.stringify(d).to_utf8_buffer()
	var pad := 16 - plain.size() % 16
	for i in pad:
		plain.append(pad)
	var iv := _crypto.generate_random_bytes(16)
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_ENCRYPT, _aes, iv)
	var body := PackedByteArray([1])
	body.append_array(iv)
	body.append_array(ctx.update(plain))
	ctx.finish()
	body.append_array(_crypto.hmac_digest(HashingContext.HASH_SHA256, _mac, body))
	_publish(ROOT + "/r/" + _room, body)


func _on_room(msg: PackedByteArray) -> void:
	if msg.size() < 1 + 16 + 16 + 32 or msg[0] != 1 or (msg.size() - 49) % 16 != 0:
		return
	var body := msg.slice(0, msg.size() - 32)
	if not _crypto.constant_time_compare(_crypto.hmac_digest(HashingContext.HASH_SHA256, _mac, body), msg.slice(msg.size() - 32)):
		return                       # not from a phone that holds this room's keys
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_DECRYPT, _aes, body.slice(1, 17))
	var plain := ctx.update(body.slice(17))
	ctx.finish()
	var pad := plain[plain.size() - 1] if plain.size() > 0 else 0
	if pad < 1 or pad > 16:
		return
	var d: Variant = JSON.parse_string(plain.slice(0, plain.size() - pad).get_string_from_utf8())
	if not d is Dictionary or String((d as Dictionary).get("f", "")) != String(opponent.get("id", "")):
		return                       # our own message coming back, or someone else's
	var n: Variant = (d as Dictionary).get("n", 0)
	if (typeof(n) != TYPE_FLOAT and typeof(n) != TYPE_INT) or int(n) <= _their_seq:
		return                       # replayed (the broker keeps one sender's messages in order)
	_their_seq = int(n)
	_last_heard = Time.get_ticks_msec()
	var kind := String((d as Dictionary).get("k", ""))
	match kind:
		"join", "joined":
			# Each side says "join" every second until the other answers (a message sent before
			# the other phone subscribed is lost); "joined" is the answer.
			if kind == "join":
				_room_send({"k": "joined"})
			_outgoing = {}
			if not in_session:
				in_session = true
				queue.clear()
				session_started.emit(is_host)
		"st":
			var s: Variant = (d as Dictionary).get("s", [])
			if in_session and s is Array and (s as Array).size() == RemoteFighter.STATE_SIZE:
				var out := PackedFloat32Array()
				for v: Variant in s:
					if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
						return
					out.append(float(v))
				state_received.emit(out)
		"ev":
			var ev: Variant = (d as Dictionary).get("e", "")
			var data: Variant = (d as Dictionary).get("d", [])
			if not in_session or typeof(ev) != TYPE_STRING or not data is Array or (data as Array).size() > 16:
				return
			for v: Variant in data:
				if typeof(v) not in [TYPE_FLOAT, TYPE_INT, TYPE_STRING, TYPE_BOOL]:
					return
			if String(ev) == "bye":
				end_session("left")
			elif event_received.get_connections().is_empty():
				queue.append([String(ev), data])
			else:
				event_received.emit(String(ev), data)


func end_session(reason := "left") -> void:
	var was := in_session
	if in_session:
		_room_send({"k": "ev", "e": "bye", "d": []})
	in_session = false
	_outgoing = {}
	_leave_room()
	if was:
		session_ended.emit(reason)


func send_state(s: PackedFloat32Array) -> void:
	if in_session:
		var a := []
		for v in s:
			a.append(snappedf(v, 0.001))
		_room_send({"k": "st", "s": a})


func send_event(kind: String, data: Array = []) -> void:
	if in_session:
		_room_send({"k": "ev", "e": kind, "d": data})
