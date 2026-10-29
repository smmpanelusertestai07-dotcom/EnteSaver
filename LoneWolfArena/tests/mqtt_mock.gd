extends SceneTree
## A tiny MQTT 3.1.1 broker over WebSocket (QoS 0: CONNECT, SUBSCRIBE, UNSUBSCRIBE, PUBLISH to
## every subscriber of the exact topic, sender included, PINGREQ) standing in for the public
## brokers Cloud uses, for tests/cloud_check.gd:
##   godot --headless -s res://tests/mqtt_mock.gd -- 47810
## Quits after 180 s.

var _server := TCPServer.new()
var _clients: Array = []      # [WebSocketPeer, rx buffer]
var _subs := {}               # topic -> {client index: true}
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
		ws.supported_protocols = PackedStringArray(["mqtt"])
		ws.accept_stream(_server.take_connection())
		_clients.append([ws, PackedByteArray()])
	for i in _clients.size():
		var c: Array = _clients[i]
		if c.is_empty():
			continue
		var ws: WebSocketPeer = c[0]
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_drop(i)
			continue
		while ws.get_ready_state() == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
			var buf: PackedByteArray = c[1]      # packed arrays are values: write the copy back
			buf.append_array(ws.get_packet())
			c[1] = buf
		_parse(i)
	return _t > 180.0


func _send(i: int, p: PackedByteArray) -> void:
	if _clients[i].is_empty():
		return
	var ws: WebSocketPeer = _clients[i][0]
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send(p)


func _parse(i: int) -> void:
	var rx: PackedByteArray = _clients[i][1]
	while rx.size() >= 2:
		var mult := 1
		var length := 0
		var k := 1
		var done := false
		while k < rx.size() and k <= 4:
			var b := rx[k]
			length += (b & 0x7F) * mult
			mult *= 128
			k += 1
			if b & 0x80 == 0:
				done = true
				break
		if not done or rx.size() < k + length:
			break
		var header := rx[0]
		var body := rx.slice(k, k + length)
		var whole := rx.slice(0, k + length)
		rx = rx.slice(k + length)
		match header & 0xF0:
			0x10:
				_send(i, PackedByteArray([0x20, 2, 0, 0]))
			0x80:
				var tl := (body[2] << 8) | body[3]
				var topic := body.slice(4, 4 + tl).get_string_from_utf8()
				if not _subs.has(topic):
					_subs[topic] = {}
				_subs[topic][i] = true
				_send(i, PackedByteArray([0x90, 3, body[0], body[1], 0]))
			0xA0:
				var tl2 := (body[2] << 8) | body[3]
				var topic2 := body.slice(4, 4 + tl2).get_string_from_utf8()
				if _subs.has(topic2):
					_subs[topic2].erase(i)
				_send(i, PackedByteArray([0xB0, 2, body[0], body[1]]))
			0x30:
				var tl3 := (body[0] << 8) | body[1]
				var topic3 := body.slice(2, 2 + tl3).get_string_from_utf8()
				if _subs.has(topic3):
					for j in _subs[topic3]:
						_send(j, whole)
			0xC0:
				_send(i, PackedByteArray([0xD0, 0]))
			0xE0:
				_drop(i)
				return
	if not _clients[i].is_empty():
		_clients[i][1] = rx


func _drop(i: int) -> void:
	for topic in _subs:
		_subs[topic].erase(i)
	_clients[i] = []
