class_name Cloud
extends Node
## Internet 1 vs 1 through the owner's own Supabase project (Realtime: Presence + Broadcast over
## a TLS WebSocket). Nothing is stored anywhere: messages pass through the project's realtime
## server and are gone. The project URL and its public anon key come from the build
## (build_keys.gd, written by tools/build_apk.sh from ~/.lonewolf/online.cfg; never committed).
## Same interface as Lan, so the arena runs either.
##
## Lobby: every player in PLAY ONLINE tracks {name, outfit} in the presence of channel LOBBY.
## CHALLENGE broadcasts an invite addressed to that player's random id with a fresh random room
## name; ACCEPT answers and both join "lw-room-<room>", where each says "join" until it has heard
## the other. The match traffic (state 10 times a second, events) is broadcast in that room; the
## inviter hosts. All incoming data is type- and size-checked.

signal peers_changed
signal invited(peer_name: String)
signal invite_cancelled
signal invite_answered(accepted: bool, peer_name: String)
signal session_started(host: bool)
signal session_ended(reason: String)
signal event_received(kind: String, data: Array)
signal state_received(state: PackedFloat32Array)

const LOBBY := "lw-lobby"
const STATE_SIZE := 9
const INVITE_TIMEOUT_MS := 20000
const SILENCE_MS := 8000           # no traffic from the opponent this long = it left
const HEARTBEAT_S := 25.0
## Seconds between state packets (the realtime server limits messages per second).
var state_interval := 0.1

var url := ""            # wss://<project>.supabase.co/realtime/v1/websocket
var key := ""            # the project's anon (public) key
var my_id := ""
var peers := {}          # id -> {"name", "bundle"}
var in_session := false
var is_host := false
var opponent := {}       # {"id", "name", "bundle", "room"}
var queue: Array = []
var status := ""         # "connecting", "online", "offline"
var _ws: WebSocketPeer
var _ref := 0
var _joined := {}        # topic -> join ref (sent)
var _ready_topics := {}  # topics whose join was confirmed
var _join_refs := {}     # join ref -> topic
var _hb_t := 0.0
var _retry_t := 0.0
var _want_lobby := false
var _room := ""
var _heard_join := false
var _outgoing := {}
var _incoming := {}
var _last_heard := 0


func _ready() -> void:
	name = "Cloud"
	process_mode = Node.PROCESS_MODE_ALWAYS
	my_id = Crypto.new().generate_random_bytes(8).hex_encode()
	var k: Dictionary = (Guard.get_script() as Script).call("build_keys")
	set_project(String(k.get("ONLINE_URL", "")), String(k.get("ONLINE_KEY", "")))
	if not OS.has_feature("template") and OS.get_environment("LW_ONLINE_URL") != "":
		set_project(OS.get_environment("LW_ONLINE_URL"), OS.get_environment("LW_ONLINE_KEY"))


## https://<ref>.supabase.co (or a ws(s) realtime URL, for tests) and the anon key.
func set_project(project_url: String, anon_key: String) -> void:
	project_url = project_url.strip_edges().trim_suffix("/")
	if project_url.begins_with("https://"):
		project_url = "wss://" + project_url.substr(8) + "/realtime/v1/websocket"
	url = project_url if project_url.begins_with("wss://") or project_url.begins_with("ws://") else ""
	key = anon_key.strip_edges()


func configured() -> bool:
	return url != "" and key != ""


# ---------------------------------------------------------------- connection

func start_lobby() -> void:
	if not configured():
		return
	_want_lobby = true
	_connect()
	if _ready_topics.has("phoenix"):
		_join(LOBBY, my_id)


func stop_lobby() -> void:
	_want_lobby = false
	peers.clear()
	if _joined.has(LOBBY):
		_leave(LOBBY)
	if not in_session and _outgoing.is_empty() and _room == "" and _ws != null:
		_ws.close()
		_ws = null
		_reset_channels()


func _connect() -> void:
	if _ws != null and _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		return
	_reset_channels()
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 18
	if _ws.connect_to_url("%s?apikey=%s&vsn=1.0.0" % [url, key.uri_encode()]) != OK:
		status = "offline"
		_ws = null
		return
	status = "connecting"


func _reset_channels() -> void:
	_joined.clear()
	_ready_topics.clear()
	_join_refs.clear()


func _process(delta: float) -> void:
	if _ws == null:
		if _want_lobby and configured():
			_retry_t -= delta
			if _retry_t <= 0.0:
				_retry_t = 3.0
				_connect()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _ready_topics.has("phoenix"):
				_ready_topics["phoenix"] = true
				status = "online"
				if _want_lobby:
					_join(LOBBY, my_id)
				if _room != "":
					_join(_room_topic(), "")
			var n := 0
			while _ws.get_available_packet_count() > 0 and n < 200:
				n += 1
				var text := _ws.get_packet().get_string_from_utf8()
				if text.length() <= 65536:
					var m: Variant = JSON.parse_string(text)
					if m is Dictionary:
						_on_message(m)
			_hb_t -= delta
			if _hb_t <= 0.0:
				_hb_t = HEARTBEAT_S
				_send_raw({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": _next_ref()})
		WebSocketPeer.STATE_CLOSED:
			_ws = null
			status = "offline"
			_reset_channels()
			if in_session:
				end_session("connection lost")
			return
	var now := Time.get_ticks_msec()
	if in_session and now - _last_heard > SILENCE_MS:
		end_session("left")
	if not _outgoing.is_empty() and now - int(_outgoing.t) > INVITE_TIMEOUT_MS:
		var who := String(_outgoing.name)
		cancel_invite()
		invite_answered.emit(false, who)
	if not _incoming.is_empty() and now - int(_incoming.t) > INVITE_TIMEOUT_MS:
		_incoming = {}
		invite_cancelled.emit()


func _next_ref() -> String:
	_ref += 1
	return str(_ref)


func _send_raw(m: Dictionary) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(m))


func _send(topic: String, event: String, payload: Dictionary) -> void:
	if not _joined.has(topic):
		return
	_send_raw({"topic": "realtime:" + topic, "event": event, "payload": payload, "ref": _next_ref(),
		"join_ref": _joined[topic]})


func _join(topic: String, presence_key: String) -> void:
	if _joined.has(topic):
		return
	var r := _next_ref()
	_joined[topic] = r
	_join_refs[r] = topic
	var cfg := {"broadcast": {"ack": false, "self": false}, "presence": {"key": presence_key}, "private": false}
	_send_raw({"topic": "realtime:" + topic, "event": "phx_join", "payload": {"config": cfg, "access_token": key},
		"ref": r, "join_ref": r})


func _leave(topic: String) -> void:
	if _joined.has(topic):
		_send(topic, "phx_leave", {})
		_joined.erase(topic)
		_ready_topics.erase(topic)


func _broadcast(topic: String, event: String, data: Dictionary) -> void:
	_send(topic, "broadcast", {"type": "broadcast", "event": event, "payload": data})


func _room_topic() -> String:
	return "lw-room-" + _room


# ---------------------------------------------------------------- messages

func _on_message(m: Dictionary) -> void:
	var topic := String(m.get("topic", "")).trim_prefix("realtime:")
	var event := String(m.get("event", ""))
	var payload: Variant = m.get("payload", {})
	if not payload is Dictionary:
		return
	var p: Dictionary = payload
	match event:
		"phx_reply":
			var r := String(m.get("ref", ""))
			if _join_refs.has(r) and String(p.get("status", "")) == "ok":
				var t := String(_join_refs[r])
				_ready_topics[t] = true
				if t == LOBBY:
					_send(LOBBY, "presence", {"type": "presence", "event": "track", "payload": {
						"id": my_id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle)}})
				elif t == _room_topic():
					_broadcast(t, "join", {"id": my_id})
		"presence_state":
			if topic == LOBBY:
				peers.clear()
				_presence_add(p)
				peers_changed.emit()
		"presence_diff":
			if topic == LOBBY:
				var joins: Variant = p.get("joins", {})
				var leaves: Variant = p.get("leaves", {})
				if leaves is Dictionary:
					for k in leaves:
						peers.erase(String(k))
				if joins is Dictionary:
					_presence_add(joins)
				peers_changed.emit()
		"broadcast":
			var ev := String(p.get("event", ""))
			var data: Variant = p.get("payload", {})
			if data is Dictionary:
				if topic == LOBBY:
					_on_lobby(ev, data)
				elif _room != "" and topic == _room_topic():
					_on_room(ev, data)


func _presence_add(entries: Dictionary) -> void:
	for k in entries:
		var id := String(k).left(32)
		var e: Variant = entries[k]
		if id == my_id or not e is Dictionary:
			continue
		var metas: Variant = (e as Dictionary).get("metas", [])
		if not metas is Array or (metas as Array).is_empty() or not (metas as Array)[0] is Dictionary:
			continue
		var meta: Dictionary = (metas as Array)[0]
		var who := Game.clean_name(String(meta.get("name", ""))) if typeof(meta.get("name")) == TYPE_STRING else ""
		var b := String(CharacterModel.bundle_info(String(meta.get("bundle", "default")) if typeof(meta.get("bundle")) == TYPE_STRING else "default").id)
		peers[id] = {"name": who if who != "" else "PLAYER", "bundle": b}


func _on_lobby(ev: String, d: Dictionary) -> void:
	if String(d.get("to", "")) != my_id or typeof(d.get("from")) != TYPE_STRING:
		return
	var from := String(d.from).left(32)
	match ev:
		"invite":
			var room := String(d.get("room", ""))
			if in_session or not _outgoing.is_empty() or not _incoming.is_empty() or not room.is_valid_hex_number() or room.length() != 32:
				_broadcast(LOBBY, "decline", {"to": from, "from": my_id})
				return
			var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else "PLAYER"
			var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
			_incoming = {"id": from, "name": who if who != "" else "PLAYER", "bundle": b, "room": room, "t": Time.get_ticks_msec()}
			invited.emit(String(_incoming.name))
		"cancel":
			if String(_incoming.get("id", "")) == from:
				_incoming = {}
				invite_cancelled.emit()
		"decline":
			if String(_outgoing.get("id", "")) == from:
				var who_out := String(_outgoing.name)
				cancel_invite(false)
				invite_answered.emit(false, who_out)
		"accept":
			if String(_outgoing.get("id", "")) == from:
				opponent = _outgoing
				_outgoing = {}
				_last_heard = Time.get_ticks_msec()


func _on_room(ev: String, d: Dictionary) -> void:
	if String(d.get("id", opponent.get("id", ""))) != String(opponent.get("id", "")):
		return
	_last_heard = Time.get_ticks_msec()
	match ev:
		"join":
			_outgoing = {}
			if not _heard_join:
				_heard_join = true
				_broadcast(_room_topic(), "join", {"id": my_id})     # in case ours went out before it joined
			if not in_session:
				in_session = true
				queue.clear()
				session_started.emit(is_host)
		"state":
			var s: Variant = d.get("s", [])
			if in_session and s is Array and (s as Array).size() == STATE_SIZE:
				var out := PackedFloat32Array()
				for v: Variant in s:
					if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
						return
					out.append(float(v))
				state_received.emit(out)
		"ev":
			var kind: Variant = d.get("k", "")
			var data: Variant = d.get("d", [])
			if not in_session or typeof(kind) != TYPE_STRING or not data is Array or (data as Array).size() > 16:
				return
			if String(kind) == "bye":
				end_session("left")
			elif event_received.get_connections().is_empty():
				queue.append([String(kind), data])
			else:
				event_received.emit(String(kind), data)


# ---------------------------------------------------------------- invites and the session

func invite(peer_id: String) -> bool:
	if in_session or not _outgoing.is_empty() or not peers.has(peer_id) or not _ready_topics.has(LOBBY):
		return false
	var info: Dictionary = peers[peer_id]
	_room = Crypto.new().generate_random_bytes(16).hex_encode()
	_heard_join = false
	is_host = true
	_outgoing = {"id": peer_id, "name": info.name, "bundle": info.bundle, "room": _room, "t": Time.get_ticks_msec()}
	opponent = _outgoing
	_join(_room_topic(), "")
	_broadcast(LOBBY, "invite", {"to": peer_id, "from": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "room": _room})
	return true


func cancel_invite(tell := true) -> void:
	if _outgoing.is_empty():
		return
	if tell:
		_broadcast(LOBBY, "cancel", {"to": String(_outgoing.id), "from": my_id})
	_outgoing = {}
	if not in_session and _room != "":
		_leave(_room_topic())
		_room = ""
		opponent = {}


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
		_broadcast(LOBBY, "decline", {"to": String(inv.id), "from": my_id})
		return
	opponent = inv
	is_host = false
	_room = String(inv.room)
	_heard_join = false
	_last_heard = Time.get_ticks_msec()
	_broadcast(LOBBY, "accept", {"to": String(inv.id), "from": my_id})
	_join(_room_topic(), "")


func end_session(reason := "left") -> void:
	var was := in_session
	if _room != "":
		if in_session:
			_broadcast(_room_topic(), "ev", {"id": my_id, "k": "bye", "d": []})
		_leave(_room_topic())
	in_session = false
	_room = ""
	_outgoing = {}
	opponent = {}
	if was:
		session_ended.emit(reason)


# ---------------------------------------------------------------- match traffic

func send_state(s: PackedFloat32Array) -> void:
	if in_session:
		var a := []
		for v in s:
			a.append(snappedf(v, 0.001))
		_broadcast(_room_topic(), "state", {"id": my_id, "s": a})


func send_event(kind: String, data: Array = []) -> void:
	if in_session:
		_broadcast(_room_topic(), "ev", {"id": my_id, "k": kind, "d": data})
