class_name Cloud
extends Node
## Internet 1 vs 1 with no account and no server of our own: free public MQTT brokers (TLS
## WebSocket) only relay messages, and everything in a match is end-to-end encrypted on the two
## phones, so the relay sees scrambled bytes. It is the game's only transport: LONE WOLF (online
## 1 vs 1) plays through it, the arena reaches it as Game.session.
##
## Lobby (topic ROOT/lobby): from the first time the game's lobby opens (presence then stays on,
## through matches too) every phone announces {id, name, outfit, RSA-2048 public key} every 3 s
## and lists the others; the id is a hash of the key, so nobody can announce someone else's id
## with their own key. DUEL 1 VS 1 sends that phone (topic ROOT/u/<id>)
## a fresh room name, AES-256 key and HMAC key encrypted with its public key; the answers carry an
## HMAC only the holders of those keys can make. In the room (ROOT/r/<room>) every message is
## AES-256-CBC with a random IV plus an HMAC-SHA256 over it, and carries the sender's id and a
## counter (replays are dropped). The inviter hosts. State goes out 10 times a second; a silent
## opponent or a "bye" ends the match ("left"); a phone that hears nothing at all from the relay,
## or was away (background, screen off) longer than the other phone waits, ends it as "connection
## lost" (it is the one that dropped out; a link that went quiet outside a match is replaced too).
## While a phone loads the match it sends a keep-alive, so a slow load is not taken for leaving.
## Anyone can publish to a public broker, so invites are rate limited and the list is capped. The
## lobby shows names, outfits and public keys only; nothing is stored by the game anywhere.
##
## Player cards (topic ROOT/p/<id>, kept by the broker as a RETAINED message): every phone that
## has gone online leaves {id, name, outfit, public key, last-seen time} signed with its own key,
## so the ONLINE tab can list every player who ever played, online or not, and a friend request
## can reach a player who is offline: it waits as a retained, signed message on ROOT/fr/<to>/<from>
## (the answer on ROOT/fa/<to>/<from>) until that phone comes online, which then clears it.
## Card v2 ("v": 2) adds what another player's card popup shows (LobbyProfile.open_player): the
## profile picture, the name card's banner, the level and the signature line, all signed together
## with the name, outfit and time (card2_text, "sig2"); its "sig" still signs the v1 text, so
## builds from before v2 keep listing the player. Cards from those builds (no "v") are still
## accepted, with the v2 fields at their defaults. Nothing else of the profile is published:
## my_card() is the whole list (the card's JSON adds only the id, the public key, the time and the
## two signatures). A change to any of it publishes the card again (CARD_CHANGE_S later, so a run
## of taps in NAME CARD makes one card).

signal peers_changed
signal invited(peer_name: String)
signal invite_cancelled
signal invite_failed(peer_name: String)    # a challenge this phone accepted never got going
signal invite_answered(accepted: bool, peer_name: String)
signal session_started(host: bool)
signal session_ended(reason: String)
signal event_received(kind: String, data: Array)
signal state_received(state: PackedFloat32Array)
signal friends_changed                 # a friend request came in or was answered
signal room_changed                    # the hosted custom room got a player / a join attempt ended
signal directory_changed               # a player card came in (the ALL PLAYERS list)

const ROOT := "lonewolfarena/v1"
const BROKERS := ["wss://broker.emqx.io:8084/mqtt", "wss://broker.hivemq.com:8884/mqtt"]
const ANNOUNCE_S := 3.0
const PEER_TIMEOUT_MS := 10000
const INVITE_TIMEOUT_MS := 25000
const SILENCE_MS := 8000
## A phone that was away, or heard nothing at all from the relay, this long in a match has dropped
## out of it: it says so to itself a little before the other phone's SILENCE_MS runs out, so the
## two never both take the other for the one who left.
const AWAY_MS := SILENCE_MS - 1500
const QUIET_MS := 15000        # nothing at all from the relay this long outside a match: the link is dead
const KEEP_ALIVE_MS := 60000   # the keep-alive CONNECT asks for: the relay has dropped a phone away longer
const LOAD_KEEP_MS := 30000    # a new session's keep-alives while its arena loads stop after this
const PING_S := 20.0
const MAX_MESSAGE := 4096
const MAX_PEERS := 40
const INBOX_RATE := 4.0        # inbox messages handled per second (each invite costs an RSA decrypt)
const JOIN_TIMEOUT_MS := 15000 # a custom-room join attempt gives up after this
const MAX_QUEUED := 32         # room events kept for the arena while it loads (queue)
const ROOM_RULES := {"rounds": 5, "ammo": false, "walls": false, "frags": false}
const CARD_REFRESH_S := 1800.0             # this phone's card is published again (last seen) every 30 min
const CARD_MAX_AGE_S := 60 * 86400         # cards not refreshed for 60 days are not listed
const REQUEST_MAX_AGE_S := 30 * 86400      # waiting friend requests and answers older than this are dropped
const MAX_DIRECTORY := 400
const CARDS_PER_FRAME := 6                 # signature checks per frame
const CARD_LEVEL_MAX := 999                # a card's level is shown as 1..999
const CARD_FIELD_MAX := 64                 # longest avatar, banner or signature text a card may carry
const CARD_CHANGE_S := 1.5                 # a changed card goes out this long after the change

var state_interval := 0.1      # seconds between state packets
var my_id := ""                # hash of this phone's public key (set once the key exists)
var peers := {}                # id -> {"name", "bundle", "pk", "seen"}
var in_session := false
var is_host := false
var opponent := {}             # {"id", "name", "bundle"}
var queue: Array = []
var status := ""               # "preparing", "connecting", "online", "offline"
var session_rules := {}        # the custom room's rules for this session ({} = a plain duel)
## Friend requests to answer and the ones this phone sent live in the (signed) profile, so they
## survive a restart: id -> {"name", "t"}.
var friend_requests: Dictionary:
	get:
		return Game.profile.friend_in
## id -> {"name", "bundle", "pk", "ts", "v", "avatar", "banner", "level", "signature"}: every player
## with a card (ALL PLAYERS); a v1 card has v 1, the emblem, the default banner, level 0 (unknown)
## and no signature.
var directory := {}
var room_code := ""            # custom room this phone hosts: 6 digits ("" = none)
var room_pin := ""             # its password (digits)
var room_rules := {}
var room_guest := {}           # {"id", "name"}: who joined it with the right password
var join_state := ""           # custom room this phone joins: "", "asking", "in", "wrong", "none"
var _brokers: Array = BROKERS
var _broker_i := 0
var _fail_n := 0               # failed connects in a row on the current broker
var _alone_t := 0.0            # seconds on a backup broker with nobody else in the lobby
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
var _dir_wants := {}           # who wants the player cards (the ONLINE window, PROFILE): listened to while any does
var _dir_queue: Array = []     # cards waiting for their signature check
var _card_t := 0.0             # seconds until this phone's card is published again
var _card_sig := ""            # what the card last published shows (card_key)
var _card_ts := 0              # its time: each new card is at least a second later (others keep the newest)
var _join := {}                # {"code", "key", "t", "ask_t"}: the custom-room join in progress
var last_end_reason := ""      # why the last session ended: "left" or "connection lost"
var _last_rx_ms := 0           # when the relay last sent this phone anything (its own echoes too)
var _frame_ms := -1            # when _process last ran (the tick clock; -1 before the first frame)
var _paused_unix := 0.0        # wall-clock time the app was paused (the tick clock stops in sleep)
var _away_wall_ms := 0         # how long the last pause lasted by the wall clock, once resumed
var _accept_ms := 0            # when this phone accepted a challenge whose room handshake is pending
var _session_ms := 0           # when the session started
var _keep_t := 0.0             # s until the next keep-alive while the arena loads


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
		var saved := CryptoKey.new()
		if FileAccess.file_exists(_key_path()) and saved.load(_key_path()) == OK:
			_use_key(saved)
			_connect()
			return
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


## Loads this phone's key, or starts making it, WITHOUT going online (the first profile setup
## shows the player ID): my_id is set once the key exists; start_lobby() later reuses it.
func prepare_identity() -> void:
	if _key != null or _keygen != -1:
		return
	var saved := CryptoKey.new()
	if FileAccess.file_exists(_key_path()) and saved.load(_key_path()) == OK:
		_use_key(saved)
		return
	status = "preparing"
	_keygen = WorkerThreadPool.add_task(_make_key)


## The phone keeps its key, so its id (and the friend code friends know it by) stays the same.
## Local test runs share one data folder: each role (LW_NET_ROLE) keeps its own.
static func _key_path() -> String:
	var role := OS.get_environment("LW_NET_ROLE") if not OS.has_feature("template") else ""
	return "user://net_identity%s.key" % ("_" + role if role != "" else "")


func _use_key(k: CryptoKey) -> void:
	_key = k
	_pk_pem = _key.save_to_string(true)
	my_id = _pk_pem.sha256_text().left(32)


## The short code a player is known by (the start of the id).
static func friend_code(id: String) -> String:
	return id.left(8).to_upper()


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
	_last_rx_ms = Time.get_ticks_msec()
	if _ws.connect_to_url(String(_brokers[_broker_i])) != OK:
		_ws = null
		_next_broker()
		return
	status = "connecting"


## Every phone should sit on the SAME broker or players never see each other: a dropped
## connection retries the first broker (three tries) before falling back to the next one, and a
## phone that is alone on a backup broker goes back to the first one (see _process).
func _next_broker() -> void:
	_fail_n += 1
	if _fail_n >= 3:
		_broker_i = (_broker_i + 1) % _brokers.size()
		_fail_n = 0
	_retry_t = 2.0
	status = "offline"


## Drops a connection that went dead without closing and connects again soon; a match going on is
## over for this phone ("connection lost").
func _reconnect() -> void:
	if in_session:
		end_session("connection lost")
	if _ws != null:
		_ws.close()
	_ws = null
	_connected = false
	_rx.clear()
	status = "offline"
	_retry_t = 0.5


## Once a frame (now: the tick clock): how long this phone was gone since the last frame, the gap
## on the tick clock or an app pause measured on the wall clock (the tick clock stops while the
## phone sleeps). Away about as long as the other phone waits, it is this phone that dropped out
## of a match (the other may have ended it by now): whatever waits in its buffer (old states, the
## other's "bye") must not say otherwise. Away longer than the keep-alive, its link is gone too.
func _check_away(now: int) -> void:
	var away := now - _frame_ms if _frame_ms >= 0 else 0
	_frame_ms = now
	away = maxi(away, _away_wall_ms)
	_away_wall_ms = 0
	if away > AWAY_MS and in_session:
		end_session("connection lost")
	if away > KEEP_ALIVE_MS and _ws != null:
		_reconnect()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_paused_unix = Time.get_unix_time_from_system()
	elif what == NOTIFICATION_APPLICATION_RESUMED and _paused_unix > 0.0:
		_away_wall_ms = maxi(int((Time.get_unix_time_from_system() - _paused_unix) * 1000.0), 0)
		_paused_unix = 0.0


func _process(delta: float) -> void:
	_check_away(Time.get_ticks_msec())       # before anything in the buffer is read
	if _keygen != -1 and not _keygen_out.is_empty():
		WorkerThreadPool.wait_for_task_completion(_keygen)
		_keygen = -1
		_use_key(_keygen_out[0])
		_key.save(_key_path())
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
	# Every phone hears its own lobby announcement (3 s), the ping's answer (20 s) and in a match
	# its own room messages back from the relay: nothing at all for this long means the link died
	# without closing (the network went away, the relay stalls). In a match that is this phone
	# dropping out, not the other one leaving.
	if Time.get_ticks_msec() - _last_rx_ms > (AWAY_MS if in_session else QUIET_MS):
		_reconnect()
		return
	if _broker_i != 0 and not in_session and _room == "" and room_code == "" and _outgoing.is_empty() \
			and _join.is_empty() and peers.is_empty():
		_alone_t += delta
		if _alone_t > 20.0:
			_alone_t = 0.0
			_broker_i = 0
			_fail_n = 0
			_send_packet(PackedByteArray([0xE0, 0x00]))
			_ws.close()
			_ws = null
			_connected = false
			_retry_t = 0.5
			status = "offline"
			return
	else:
		_alone_t = 0.0
	_ping_t -= delta
	if _ping_t <= 0.0:
		_ping_t = PING_S
		_send_packet(PackedByteArray([0xC0, 0x00]))
	_tick_room(delta)
	_card_t -= delta
	if card_key(my_card()) != _card_sig:
		_card_t = minf(_card_t, CARD_CHANGE_S)
	if _card_t <= 0.0:
		_publish_card()
	var checked := 0
	while not _dir_queue.is_empty() and checked < CARDS_PER_FRAME:
		checked += 1
		_check_card(_dir_queue.pop_front())
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


## Every frame while connected (now: the tick clock): the room handshake (and how long a challenge
## accepted here may take), the keep-alive while the match loads, the custom-room join.
func _tick_room(delta: float, now := Time.get_ticks_msec()) -> void:
	if _room != "" and not in_session:
		_join_t -= delta
		if _join_t <= 0.0:
			_join_t = 1.0
			_room_send({"k": "join"})
		# A challenge accepted here whose room handshake never completes (the challenger went
		# away right after): give up, so the popup does not wait for ever.
		if _accept_ms > 0 and now - _accept_ms > JOIN_TIMEOUT_MS:
			var who := String(opponent.get("name", "PLAYER"))
			_leave_room()
			invite_failed.emit(who)
	elif in_session and event_received.get_connections().is_empty() and now - _session_ms < LOAD_KEEP_MS:
		# The match is loading here (the arena listens once it is up): a keep-alive every second,
		# so the other phone does not take a slow load for leaving.
		_keep_t -= delta
		if _keep_t <= 0.0:
			_keep_t = 1.0
			_room_send({"k": "ka"})
	if not _join.is_empty() and not in_session:
		# Asking to join, then (let in) asking again now and then: the host answers while its room
		# is open, so a room that closed or a host that left is noticed (join_state "none").
		_join.ask_t = float(_join.ask_t) - delta
		if _join.ask_t <= 0.0 and join_state in ["asking", "in"]:
			_join.ask_t = 2.0 if join_state == "asking" else 5.0
			_publish_json(ROOT + "/c/" + String(_join.code), {"t": "ask", "from": my_id, "name": String(Game.profile.name),
				"bundle": String(Game.profile.bundle), "pk": _pk_pem, "mac": _room_tag(_join.key, "ask", my_id)})
		if now - int(_join.t) > JOIN_TIMEOUT_MS and join_state in ["asking", "in"]:
			join_state = "none"
			room_changed.emit()


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


## retain: the broker keeps the message for whoever subscribes later (an empty retained message
## deletes the kept one).
func _publish(topic: String, payload: PackedByteArray, retain := false) -> void:
	if not _connected:
		return
	var body := _str(topic)
	body.append_array(payload)
	_send_packet(_packet(0x31 if retain else 0x30, body))


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
		_last_rx_ms = Time.get_ticks_msec()      # any packet: the link is alive
		match header & 0xF0:
			0x20:                    # CONNACK
				if body.size() >= 2 and body[1] == 0:
					_connected = true
					_fail_n = 0
					status = "online"
					_ping_t = PING_S
					_subscribe(ROOT + "/u/" + my_id)
					_subscribe(ROOT + "/fr/" + my_id + "/+")      # friend requests waiting for this phone
					_subscribe(ROOT + "/fa/" + my_id + "/+")      # answers to the ones it sent
					if not (Game.profile.withdrawn as Array).is_empty():
						_send_withdrawals()                        # requests taken back while offline
						Game.save_profile()
					if not _dir_wants.is_empty():
						_subscribe(ROOT + "/p/+")
					_card_t = 0.0                                  # (re)publish this phone's card now
					if _want_lobby:
						_subscribe(ROOT + "/lobby")
						_announce_t = 0.0
					if _room != "":
						_subscribe(ROOT + "/r/" + _room)
					if room_code != "":
						_subscribe(ROOT + "/c/" + room_code)
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
	if topic.begins_with(ROOT + "/p/"):
		_on_card(topic, payload)
		return
	if topic.begins_with(ROOT + "/fr/" + my_id + "/") or topic.begins_with(ROOT + "/fa/" + my_id + "/"):
		if not payload.is_empty():
			var w: Variant = JSON.parse_string(payload.get_string_from_utf8())
			if w is Dictionary:
				_on_waiting(topic.get_slice("/", 2) == "fr", topic.get_slice("/", 4), w)
		return
	if topic == ROOT + "/lobby" or topic == ROOT + "/u/" + my_id:
		# Anyone can publish there: a lobby announcement needs its "id", an inbox message its "from".
		var json := JSON.new()
		if json.parse(payload.get_string_from_utf8()) != OK or not json.data is Dictionary:
			return
		var d: Dictionary = json.data
		if topic == ROOT + "/lobby":
			if typeof(d.get("id")) == TYPE_STRING:
				_on_lobby(d)
		elif typeof(d.get("from")) == TYPE_STRING:
			_on_inbox(d)
	elif _room != "" and topic == ROOT + "/r/" + _room:
		_on_room(payload)
	elif room_code != "" and topic == ROOT + "/c/" + room_code:
		var a: Variant = JSON.parse_string(payload.get_string_from_utf8())
		if a is Dictionary:
			_on_room_ask(a)


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
			if typeof(d.get("sec")) != TYPE_STRING or Game.is_blocked(from):
				return                   # a blocked player's challenge is ignored (no answer)
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
			# The host of the custom room this phone asked to join starts the match: it knows the
			# room's password, so it is accepted at once with the room's rules.
			if join_state == "in" and typeof(d.get("rc")) == TYPE_STRING and _crypto.constant_time_compare(
					_room_tag(_join.key, "inv", from).to_utf8_buffer(), String(d.rc).to_utf8_buffer()):
				answer(true, rules_from(d.get("rules")))
				return
			if invited.get_connections().is_empty():
				answer(false)            # in a match (no lobby listening): say no at once, not after 25 s
				return
			invited.emit(String(_incoming.name))
		"can":
			if String(_incoming.get("id", "")) == from and _tagged(d, _incoming, "can", from):
				_incoming = {}
				invite_cancelled.emit()
			elif _accept_ms > 0 and String(opponent.get("id", "")) == from and _tagged(d, {"mac": _mac, "room": _room}, "can", from):
				var who := String(opponent.get("name", "PLAYER"))       # called off just as it was accepted
				_leave_room()
				invite_failed.emit(who)
		"dec":
			if String(_outgoing.get("id", "")) == from and _tagged(d, _outgoing, "dec", from):
				var who_out := String(_outgoing.name)
				cancel_invite(false)
				invite_answered.emit(false, who_out)
		"acc":
			if String(_outgoing.get("id", "")) == from and not Game.is_blocked(from) and _tagged(d, _outgoing, "acc", from):
				_last_heard = Time.get_ticks_msec()     # the room handshake follows
		"frq":
			# A friend request: its key proves the sender's id. Already friends: say yes again.
			if typeof(d.get("pk")) != TYPE_STRING or from != String(d.pk).sha256_text().left(32):
				return
			var asker := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
			if Game.is_friend(from):
				_publish_json(ROOT + "/u/" + from, {"t": "fra", "from": my_id, "name": String(Game.profile.name)})
			elif not Game.is_blocked(from) and not friend_requests.has(from) and friend_requests.size() < Game.MAX_REQUESTS:
				friend_requests[from] = {"name": asker if asker != "" else "PLAYER", "t": int(Time.get_unix_time_from_system())}
				Game.save_profile()
				friends_changed.emit()
		"fra":
			if (Game.profile.friend_out as Dictionary).has(from):
				var friend := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
				_became_friends(from, friend)
		"rin", "rno":
			# The custom room's host: the password was right (wait for START) or wrong; a "rin"
			# while in the room says it is still open.
			if join_state in ["asking", "in"] and String(d.get("code", "")) == String(_join.get("code", "")):
				var state := "in" if String(d.t) == "rin" else "wrong"
				_join.t = Time.get_ticks_msec()
				if state != join_state:
					join_state = state
					room_changed.emit()


## Proof that the sender holds an invite's keys: an HMAC over what it says, the room and its id.
func _tag(inv: Dictionary, what: String, sender: String) -> String:
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, inv.mac, (what + String(inv.room) + sender).to_utf8_buffer()).hex_encode()


func _tagged(d: Dictionary, inv: Dictionary, what: String, sender: String) -> bool:
	return typeof(d.get("mac")) == TYPE_STRING and _crypto.constant_time_compare(
		_tag(inv, what, sender).to_utf8_buffer(), String(d.mac).to_utf8_buffer())


## Challenges a listed player: its public key wraps a fresh room name and the room's keys.
func invite(peer_id: String, extra := {}) -> bool:
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
	session_rules = {}
	_enter_room(_outgoing)
	var msg := {"t": "inv", "from": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "sec": Marshalls.raw_to_base64(wrapped)}
	msg.merge(extra)
	_publish_json(ROOT + "/u/" + peer_id, msg)
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


## Who the challenge waiting for an answer here comes from: {"id", "name"} ({} when none).
func invite_from() -> Dictionary:
	return {} if _incoming.is_empty() else {"id": String(_incoming.id), "name": String(_incoming.name)}


func waiting_for() -> String:
	return String(_outgoing.get("name", ""))


## Blocking a player (LobbyProfile, before Game.block) ends what is going on with them here: the
## challenge this phone sent them (they could still accept it and start the match) is called
## off, theirs waiting for an answer is dropped unanswered (like any challenge from a blocked
## player), they lose their seat in the custom room this phone hosts, and the friend request it
## sent them is taken back (withdraw_request; no friends_changed: the caller redraws its list).
## From then on their challenges, answers, requests and room messages are ignored
## (Game.is_blocked).
func drop_player(id: String) -> void:
	if String(_outgoing.get("id", "")) == id and not in_session:
		cancel_invite()
	if String(_incoming.get("id", "")) == id:
		_incoming = {}
		invite_cancelled.emit()
	if String(room_guest.get("id", "")) == id:
		room_guest = {}
		room_changed.emit()
	if friend_asked(id):
		withdraw_request(id, false)


func answer(accept: bool, rules := {}) -> void:
	if _incoming.is_empty():
		return
	var inv := _incoming
	_incoming = {}
	if not accept:
		_publish_json(ROOT + "/u/" + String(inv.id), {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
		return
	is_host = false
	session_rules = rules
	_enter_room(inv)
	_accept_ms = Time.get_ticks_msec()
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
	_accept_ms = 0
	_aes = PackedByteArray()
	_mac = PackedByteArray()
	opponent = {}


# ---------------------------------------------------------------- friends

## Asks a player to be friends, online or not: the signed request waits for them as a retained
## message (and goes straight to a phone that is online right now, older versions included).
func request_friend(peer_id: String) -> bool:
	if not _connected or peer_id == my_id or not Game.is_player_id(peer_id) or Game.is_friend(peer_id):
		return false
	if not peers.has(peer_id) and not directory.has(peer_id):
		return false
	var out: Dictionary = Game.profile.friend_out
	if not out.has(peer_id) and out.size() >= Game.MAX_REQUESTS:
		return false
	var who := String(peers[peer_id].name) if peers.has(peer_id) else String(directory[peer_id].name)
	out[peer_id] = {"name": who, "t": int(Time.get_unix_time_from_system())}
	(Game.profile.withdrawn as Array).erase(peer_id)     # a new request: no older one to delete any more
	Game.save_profile()
	_publish_waiting("frq", peer_id)
	if peers.has(peer_id):
		_publish_json(ROOT + "/u/" + peer_id, {"t": "frq", "from": my_id, "name": String(Game.profile.name), "pk": _pk_pem})
	friends_changed.emit()
	return true


func friend_asked(peer_id: String) -> bool:
	return (Game.profile.friend_out as Dictionary).has(peer_id)


## Takes back a friend request this phone sent (blocking that player, drop_player): no longer
## waiting for an answer here, and its retained copy on the broker is deleted, so it does not
## reach them later (a phone that is offline gets it when it comes back). Offline the delete waits
## in the profile ("withdrawn", kept over a restart) and goes out as soon as the relay answers
## again (CONNACK). notify: emits friends_changed (a caller that redraws its own list passes
## false: the signal would also pop up a friend request that is still waiting to be seen).
func withdraw_request(to: String, notify := true) -> void:
	if not Game.is_player_id(to):
		return
	(Game.profile.friend_out as Dictionary).erase(to)
	var owed: Array = Game.profile.withdrawn
	if not owed.has(to):
		owed.append(to)
	while owed.size() > Game.MAX_REQUESTS:
		owed.pop_front()
	_send_withdrawals()
	Game.save_profile()
	if notify:
		friends_changed.emit()


## Deletes the retained copies of the friend requests taken back (profile "withdrawn") once
## connected; the list is then empty (the caller saves the profile).
func _send_withdrawals() -> void:
	var owed: Array = Game.profile.withdrawn
	if not _connected or my_id == "" or owed.is_empty():
		return
	for to: String in owed:
		_publish(ROOT + "/fr/" + to + "/" + my_id, PackedByteArray(), true)
	owed.clear()


## ACCEPT / DECLINE of a friend request: online only (the FRIENDS tab greys them out otherwise),
## as the answer deletes the waiting request on the relay; offline that delete would be lost and
## a declined request would come back with the next connection.
func answer_friend(peer_id: String, accept: bool) -> void:
	if not friend_requests.has(peer_id) or not _connected:
		return
	var req: Dictionary = friend_requests[peer_id]
	friend_requests.erase(peer_id)
	Game.save_profile()
	_publish(ROOT + "/fr/" + my_id + "/" + peer_id, PackedByteArray(), true)     # the waiting request is answered
	if accept:
		Game.add_friend(peer_id, String(req.name))
		_publish_waiting("fra", peer_id)
		_publish_json(ROOT + "/u/" + peer_id, {"t": "fra", "from": my_id, "name": String(Game.profile.name)})
	friends_changed.emit()


func _became_friends(id: String, friend_name: String) -> void:
	(Game.profile.friend_out as Dictionary).erase(id)
	Game.add_friend(id, friend_name if friend_name != "" else "PLAYER")      # (saves the profile)
	friends_changed.emit()


# ---------------------------------------------------------------- player cards (ALL PLAYERS)

## Someone wants every player card the broker keeps: `by` names who (the ONLINE window "window",
## PROFILE's BLOCKED and the cards it opens "profile"); the cards are listened to while anyone
## does, so one closing does not cut off the other.
func start_directory(by := "window") -> void:
	var first := _dir_wants.is_empty()
	_dir_wants[by] = true
	if first and _connected:
		_subscribe(ROOT + "/p/+")


func stop_directory(by := "window") -> void:
	if not _dir_wants.erase(by) or not _dir_wants.is_empty():
		return
	_dir_queue.clear()
	if _connected:
		_unsubscribe(ROOT + "/p/+")


func _sign(text: String) -> String:
	return Marshalls.raw_to_base64(_crypto.sign(HashingContext.HASH_SHA256, text.sha256_buffer(), _key))


## Checks a signature made with the private key that belongs to `pk` (a PEM public key).
static func verify_signed(pk: String, text: String, sig: String) -> bool:
	if pk.length() > 1200 or sig.length() > 700:
		return false
	var pub := CryptoKey.new()
	if pub.load_from_string(pk, true) != OK:
		return false
	var raw := Marshalls.base64_to_raw(sig)
	if raw.size() != 256:
		return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, text.sha256_buffer(), raw, pub)


## What a v1 card signs (builds from before card v2 check only this; v2 cards sign it as "sig" too).
static func card_text(id: String, who: String, bundle: String, ts: int) -> String:
	return "card|%s|%s|%s|%d" % [id, who, bundle, ts]


## What a v2 card signs ("sig2"): every field it shows, so changing any of them breaks it.
static func card2_text(id: String, who: String, bundle: String, avatar: String, banner: String, level: int,
		signature: String, ts: int) -> String:
	return "card2|%s|%s|%s|%s|%s|%d|%s|%d" % [id, who, bundle, avatar, banner, level, signature, ts]


## Everything this phone's card shows besides its id, public key and time: the whole public part
## of the profile (name, outfit, profile picture, name card banner, level, signature line).
static func my_card() -> Dictionary:
	var p: Dictionary = Game.profile
	return {"name": String(p.name), "bundle": String(p.bundle), "avatar": String(p.avatar), "banner": String(p.banner),
		"level": clampi(Game.level(), 1, CARD_LEVEL_MAX), "signature": String(p.signature)}


## A card's content in one string: a change of any field publishes the card again.
static func card_key(c: Dictionary) -> String:
	return "%s|%s|%s|%s|%d|%s" % [c.name, c.bundle, c.avatar, c.banner, int(c.level), c.signature]


static func waiting_text(kind: String, from: String, to: String, ts: int) -> String:
	return "%s|%s|%s|%d" % [kind, from, to, ts]


func _publish_card() -> void:
	_card_t = CARD_REFRESH_S
	if not _connected or _key == null or my_id == "":
		return
	var c := my_card()
	_card_sig = card_key(c)
	_card_ts = maxi(int(Time.get_unix_time_from_system()), _card_ts + 1)
	_publish(ROOT + "/p/" + my_id, card_json(c, my_id, _pk_pem, _card_ts, _key).to_utf8_buffer(), true)


## A signed v2 card as published (`key` is the private key of `pk`; tests make cards with it too).
static func card_json(c: Dictionary, id: String, pk: String, ts: int, key: CryptoKey) -> String:
	var who := String(c.name)
	var b := String(c.bundle)
	var level := int(c.level)
	return JSON.stringify({"t": "card", "v": 2, "id": id, "name": who, "bundle": b, "avatar": String(c.avatar),
		"banner": String(c.banner), "level": level, "signature": String(c.signature), "pk": pk, "ts": ts,
		"sig": _sign_with(key, card_text(id, who, b, ts)),
		"sig2": _sign_with(key, card2_text(id, who, b, String(c.avatar), String(c.banner), level, String(c.signature), ts))})


static func _sign_with(key: CryptoKey, text: String) -> String:
	return Marshalls.raw_to_base64(Crypto.new().sign(HashingContext.HASH_SHA256, text.sha256_buffer(), key))


## A friend request ("frq") or its acceptance ("fra") that waits for `to` as a retained message.
func _publish_waiting(kind: String, to: String) -> void:
	if not _connected or _key == null:
		return
	var ts := int(Time.get_unix_time_from_system())
	var topic := ROOT + ("/fr/" if kind == "frq" else "/fa/") + to + "/" + my_id
	_publish(topic, JSON.stringify({"t": kind, "from": my_id, "to": to, "name": String(Game.profile.name), "pk": _pk_pem,
		"ts": ts, "sig": _sign(waiting_text(kind, my_id, to, ts))}).to_utf8_buffer(), true)


func _on_card(topic: String, payload: PackedByteArray) -> void:
	if payload.is_empty():
		var gone := topic.get_slice("/", 3)
		if directory.erase(gone):
			directory_changed.emit()
		return
	if not _dir_wants.is_empty() and _dir_queue.size() < MAX_DIRECTORY * 2:
		_dir_queue.append(payload)


## A card off the broker (anyone can publish one): checked field by field, its signature verified
## (v2: "sig2" over every field; a card without "v" is v1: "sig" over the name, outfit and time),
## then listed with every shown value cleaned. A card over MAX_MESSAGE bytes, wrong types, an
## over-long field, a "|" inside a v2 field (it would blur where the signed fields part) or a level
## that is not a whole number from 0 up reject the whole card; an avatar or banner this build does
## not have shows as the default one (a newer build may have more), the level is kept to
## 1..CARD_LEVEL_MAX and the signature goes through Game.clean_text (SIGNATURE_MAX).
func _check_card(payload: PackedByteArray) -> void:
	if payload.size() > MAX_MESSAGE:
		return
	var d: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not (d is Dictionary) or String((d as Dictionary).get("t", "")) != "card":
		return
	for k in ["id", "name", "bundle", "pk", "sig"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return
	if not (d.get("ts") is float or d.get("ts") is int):
		return
	var ver: Variant = d.get("v", 1)
	if not (ver is float or ver is int) or ((d as Dictionary).has("v") and float(ver) < 2.0):
		return
	var v2 := float(ver) >= 2.0
	var level := 0
	if v2:
		for k in ["avatar", "banner", "signature", "sig2"]:
			if typeof(d.get(k)) != TYPE_STRING:
				return
		for k in ["name", "bundle", "avatar", "banner", "signature"]:
			if "|" in String(d[k]) or (k != "name" and k != "bundle" and String(d[k]).length() > CARD_FIELD_MAX):
				return
		var lv: Variant = d.get("level")
		if not (lv is float or lv is int) or float(lv) != floorf(float(lv)) or float(lv) < 0.0 or float(lv) > 1.0e9:
			return
		level = int(lv)
	var id := String(d.id)
	var ts := int(d.ts)
	var now := int(Time.get_unix_time_from_system())
	if id == my_id or id != String(d.pk).sha256_text().left(32) or ts > now + 600 or now - ts > CARD_MAX_AGE_S:
		return
	if directory.has(id) and int(directory[id].ts) >= ts:
		return
	if v2:
		if not verify_signed(String(d.pk), card2_text(id, String(d.name), String(d.bundle), String(d.avatar), String(d.banner),
				level, String(d.signature), ts), String(d.sig2)):
			return
	elif not verify_signed(String(d.pk), card_text(id, String(d.name), String(d.bundle), ts), String(d.sig)):
		return
	var who := Game.clean_name(String(d.name))
	var avatar := String(d.avatar) if v2 else ""
	var banner := String(d.banner) if v2 else ""
	directory[id] = {"name": who if who != "" else "PLAYER", "bundle": String(CharacterModel.bundle_info(String(d.bundle)).id),
		"pk": String(d.pk), "ts": ts, "v": 2 if v2 else 1,
		"avatar": avatar if avatar in Game.avatar_ids() else String(Game.DEFAULT_PROFILE.avatar),
		"banner": banner if banner in Game.BANNERS else String(Game.DEFAULT_PROFILE.banner),
		"level": clampi(level, 1, CARD_LEVEL_MAX) if v2 else 0,
		"signature": Game.clean_text(String(d.signature), Game.SIGNATURE_MAX) if v2 else ""}
	if directory.size() > MAX_DIRECTORY:
		var oldest := ""
		for k: String in directory:
			if oldest == "" or int(directory[k].ts) < int(directory[oldest].ts):
				oldest = k
		directory.erase(oldest)
	if Game.is_friend(id) and who != "" and String(Game.profile.friends[id].name) != who:
		Game.add_friend(id, who)          # a friend's new name
	directory_changed.emit()


## A signed friend request or answer that waited for this phone (retained): checked, used once,
## then deleted from the broker.
func _on_waiting(is_request: bool, from: String, d: Dictionary) -> void:
	var kind := "frq" if is_request else "fra"
	var topic := ROOT + ("/fr/" if is_request else "/fa/") + my_id + "/" + from
	for k in ["from", "to", "name", "pk", "sig"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return
	if not (d.get("ts") is float or d.get("ts") is int) or String(d.get("t", "")) != kind:
		return
	var ts := int(d.ts)
	var now := int(Time.get_unix_time_from_system())
	if String(d.from) != from or String(d.to) != my_id or from == my_id or from != String(d.pk).sha256_text().left(32) \
			or ts > now + 600 or now - ts > REQUEST_MAX_AGE_S:
		return
	if _inbox_budget < 1.0:
		return
	_inbox_budget -= 1.0
	if not verify_signed(String(d.pk), waiting_text(kind, from, my_id, ts), String(d.sig)):
		return
	var who := Game.clean_name(String(d.name))
	if is_request:
		if Game.is_friend(from):
			_publish(topic, PackedByteArray(), true)
			_publish_waiting("fra", from)            # already friends: answer yes again
		elif Game.is_blocked(from):
			_publish(topic, PackedByteArray(), true)
		elif not friend_requests.has(from) and friend_requests.size() < Game.MAX_REQUESTS:
			friend_requests[from] = {"name": who if who != "" else "PLAYER", "t": ts}
			Game.save_profile()
			friends_changed.emit()
	else:
		_publish(topic, PackedByteArray(), true)
		if (Game.profile.friend_out as Dictionary).has(from):
			_became_friends(from, who)


# ---------------------------------------------------------------- custom rooms

## Opens a custom room: a random 6-digit number plus the host's numeric password. A player who
## sends both is listed in the room; the host starts the match with the room's rules.
func open_room(pin: String, rules: Dictionary, code := "") -> String:
	close_room()
	var r := _crypto.generate_random_bytes(4)
	room_code = code if code.length() == 6 and code.is_valid_int() and not OS.has_feature("template") \
		else "%06d" % (r.decode_u32(0) % 1000000)
	room_pin = pin
	room_rules = rules_from(rules)
	room_guest = {}
	if _connected:
		_subscribe(ROOT + "/c/" + room_code)
	room_changed.emit()
	return room_code


func close_room() -> void:
	if room_code != "" and _connected:
		_unsubscribe(ROOT + "/c/" + room_code)
	room_code = ""
	room_guest = {}


## Starts the hosted room's match with the player who joined it.
func start_room_match() -> bool:
	if room_guest.is_empty():
		return false
	var key := _room_key(room_code, room_pin)
	var ok := invite(String(room_guest.id), {"rc": _room_tag(key, "inv", my_id), "rules": room_rules})
	if ok:
		session_rules = room_rules
	return ok


## Asks to join a custom room with its number and password; join_state tells how it goes.
func join_room(code: String, pin: String) -> void:
	_join = {"code": code, "key": _room_key(code, pin), "t": Time.get_ticks_msec(), "ask_t": 0.0}
	join_state = "asking"
	room_changed.emit()


func leave_join() -> void:
	_join = {}
	join_state = ""


func _on_room_ask(d: Dictionary) -> void:
	var from := String(d.get("from", "")).left(32)
	if String(d.get("t", "")) != "ask" or from == "" or from == my_id or _inbox_budget < 1.0 or Game.is_blocked(from):
		return
	_inbox_budget -= 1.0
	if typeof(d.get("pk")) != TYPE_STRING or String(d.pk).length() > 1200 or from != String(d.pk).sha256_text().left(32):
		return
	var right := typeof(d.get("mac")) == TYPE_STRING and _crypto.constant_time_compare(
		_room_tag(_room_key(room_code, room_pin), "ask", from).to_utf8_buffer(), String(d.mac).to_utf8_buffer())
	if not right:
		_publish_json(ROOT + "/u/" + from, {"t": "rno", "from": my_id, "code": room_code})
		return
	if not room_guest.is_empty() and String(room_guest.id) != from:
		return                       # the room is full (1 vs 1)
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	peers[from] = {"name": who if who != "" else "PLAYER", "bundle": b, "pk": String(d.pk), "seen": Time.get_ticks_msec()}
	var fresh := room_guest.is_empty()
	room_guest = {"id": from, "name": String(peers[from].name)}
	_publish_json(ROOT + "/u/" + from, {"t": "rin", "from": my_id, "code": room_code})
	if fresh:
		room_changed.emit()


## The room password's key (stretched a little: it is only a few digits).
func _room_key(code: String, pin: String) -> PackedByteArray:
	var k := ("lonewolfarena-room|%s|%s" % [code, pin]).sha256_buffer()
	for i in 2000:
		k = _crypto.hmac_digest(HashingContext.HASH_SHA256, k, code.to_utf8_buffer())
	return k


func _room_tag(key: PackedByteArray, what: String, sender: String) -> String:
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, key, (what + sender).to_utf8_buffer()).hex_encode()


## A room's rules from untrusted data: known keys only, values in range.
static func rules_from(v: Variant) -> Dictionary:
	var out := ROOM_RULES.duplicate()
	if v is Dictionary:
		var d := v as Dictionary
		var r: Variant = d.get("rounds", 5)
		if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT:
			out.rounds = clampi(int(r), 1, 7)
		for k in ["ammo", "walls", "frags"]:
			out[k] = d.get(k, false) == true
	return out


# ---------------------------------------------------------------- the room (end-to-end encrypted)

func _room_send(d: Dictionary) -> void:
	if _room == "":
		return
	_publish(ROOT + "/r/" + _room, _room_packet(d))


## A room message as it goes out: version byte, IV, the AES-256-CBC of the JSON (with this phone's
## id and the next counter), then the HMAC-SHA256 over all of that.
func _room_packet(d: Dictionary) -> PackedByteArray:
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
	return body


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
			# the other phone subscribed is lost); "joined" is the answer. No match starts with a
			# player blocked meanwhile (drop_player has normally left their room already).
			if Game.is_blocked(String(opponent.get("id", ""))):
				return
			if kind == "join":
				_room_send({"k": "joined"})
			_outgoing = {}
			if not in_session:
				in_session = true
				_accept_ms = 0
				_session_ms = Time.get_ticks_msec()
				_keep_t = 0.0
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
				if queue.size() < MAX_QUEUED:          # (only "ready" comes before the arena listens)
					queue.append([String(ev), data])
			else:
				event_received.emit(String(ev), data)


## Ends the match's session: "left" (the other phone said bye or went silent, or this one leaves
## the arena) or "connection lost" (this phone lost the relay or was away too long).
func end_session(reason := "left") -> void:
	var was := in_session
	if in_session:
		_room_send({"k": "ev", "e": "bye", "d": []})
		last_end_reason = reason
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
