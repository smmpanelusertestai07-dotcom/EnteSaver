extends SceneTree
## A tiny stand-in for the realtime server Cloud talks to (Phoenix channels as Supabase Realtime
## speaks them: phx_join / phx_reply, presence track -> presence_state / presence_diff,
## broadcast to the other members of a topic, heartbeat), for tests/cloud_check.gd:
##   godot --headless -s res://tests/realtime_mock.gd -- 47810
## Quits after 180 s.

var _server := TCPServer.new()
var _clients: Array[WebSocketPeer] = []
var _members := {}        # topic -> {client index -> {"key", "meta"}}
var _t := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var port := int(args[0]) if args.size() > 0 else 47810
	if _server.listen(port, "127.0.0.1") != OK:
		print("MOCK cannot listen")
		quit(1)
	print("MOCK listening on ", port)


func _process(delta: float) -> bool:
	_t += delta
	while _server.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.accept_stream(_server.take_connection())
		_clients.append(ws)
	for i in _clients.size():
		var ws := _clients[i]
		if ws == null:
			continue
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_drop(i)
			continue
		while ws.get_ready_state() == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
			var m: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if m is Dictionary:
				_on(i, m)
	return _t > 180.0


func _send(i: int, m: Dictionary) -> void:
	var ws := _clients[i]
	if ws and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(m))


func _reply(i: int, m: Dictionary) -> void:
	_send(i, {"topic": m.topic, "event": "phx_reply", "payload": {"status": "ok", "response": {}}, "ref": m.get("ref")})


func _on(i: int, m: Dictionary) -> void:
	var topic := String(m.get("topic", ""))
	var p: Dictionary = m.get("payload", {})
	match String(m.get("event", "")):
		"heartbeat":
			_reply(i, m)
		"phx_join":
			var key := String(p.get("config", {}).get("presence", {}).get("key", ""))
			if not _members.has(topic):
				_members[topic] = {}
			_members[topic][i] = {"key": key if key != "" else str(i), "meta": null}
			_reply(i, m)
			var state := {}
			for j in _members[topic]:
				var mem: Dictionary = _members[topic][j]
				if mem.meta != null:
					state[mem.key] = {"metas": [mem.meta]}
			_send(i, {"topic": topic, "event": "presence_state", "payload": state, "ref": null})
		"phx_leave":
			_leave(i, topic)
			_reply(i, m)
		"presence":
			if _members.has(topic) and _members[topic].has(i):
				var mem: Dictionary = _members[topic][i]
				var meta: Dictionary = p.get("payload", {})
				meta["phx_ref"] = "r%d" % i
				mem.meta = meta
				for j in _members[topic]:
					_send(j, {"topic": topic, "event": "presence_diff", "payload": {"joins": {mem.key: {"metas": [meta]}}, "leaves": {}}, "ref": null})
		"broadcast":
			if _members.has(topic):
				for j in _members[topic]:
					if j != i:
						_send(j, {"topic": topic, "event": "broadcast", "payload": p, "ref": null})


func _leave(i: int, topic: String) -> void:
	if not _members.has(topic) or not _members[topic].has(i):
		return
	var mem: Dictionary = _members[topic][i]
	_members[topic].erase(i)
	if mem.meta != null:
		for j in _members[topic]:
			_send(j, {"topic": topic, "event": "presence_diff", "payload": {"joins": {}, "leaves": {mem.key: {"metas": [mem.meta]}}}, "ref": null})


func _drop(i: int) -> void:
	for topic in _members.keys():
		_leave(i, topic)
	_clients[i] = null
