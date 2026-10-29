class_name Lan
extends Node
## Serverless 1 vs 1 over the local network (the same Wi-Fi, or one phone's hotspot); nothing
## goes to the internet and there is no server. Lives under Game (/root/Game/Lan on both phones,
## so its RPCs reach each other across scene changes).
##
## Discovery: while the lobby is open every phone broadcasts {name, outfit} on UDP port
## DISCOVERY_PORT once a second and lists the phones it hears. CHALLENGE sends an invite
## straight to that phone and opens an ENet server (the inviter hosts); ACCEPT replies and
## connects, and the client proves who it is with a "join" event before the match starts.
## In the match each phone owns its own player: it sends that player's state 20 times a second
## and its shots, the hits it lands, grenades and walls as events; the phone that is hit applies
## the damage to itself and reports its own death. Packets are validated and size-limited.

signal peers_changed
signal invited(peer_name: String)
signal invite_cancelled
signal invite_answered(accepted: bool, peer_name: String)
signal session_started(host: bool)
signal session_ended(reason: String)
signal event_received(kind: String, data: Array)
signal state_received(state: PackedFloat32Array)

const DISCOVERY_PORT := 47790
const GAME_PORT := 47791
const PROTOCOL := 1
const PEER_TIMEOUT_MS := 4500
const INVITE_TIMEOUT_MS := 20000
const MAX_PACKET := 512

var my_id := ""
var peers := {}             # id -> {"name", "bundle", "ip", "seen"}
var in_session := false
var is_host := false
var opponent := {}          # {"id", "name", "bundle", "ip"}
## Ports hellos and invites go to (tests run two copies on one machine with their own ports).
var dest_ports: Array[int] = [DISCOVERY_PORT]
var listen_port := DISCOVERY_PORT
var queue: Array = []       # events that arrived before the arena listened
var state_interval := 0.05  # seconds between state packets
var _udp: PacketPeerUDP
var _udp_port := 0
var _discovering := false
var _hello_t := 0.0
var _outgoing := {}         # the invite we sent: {"id", "name", "bundle", "ip", "t"}
var _incoming := {}         # the invite we got: {"id", "name", "bundle", "ip", "t"}
var _peer_id := 0           # ENet id of the opponent
var _mlock: Object = null


func _ready() -> void:
	name = "Lan"
	process_mode = Node.PROCESS_MODE_ALWAYS
	my_id = Crypto.new().generate_random_bytes(8).hex_encode()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func() -> void: _fail("could not connect"))
	multiplayer.server_disconnected.connect(func() -> void: end_session("left"))


# ---------------------------------------------------------------- discovery

func start_discovery() -> void:
	if _udp != null and _udp_port != listen_port and not in_session:
		_udp.close()
		_udp = null
	if _udp == null:
		_udp = PacketPeerUDP.new()
		if _udp.bind(listen_port) != OK:
			push_warning("[Lan] cannot listen on port %d" % listen_port)
			_udp = null
			return
		_udp_port = listen_port
		_udp.set_broadcast_enabled(true)
	_multicast_lock(true)
	_discovering = true
	_hello_t = 0.0


func stop_discovery() -> void:
	_discovering = false
	peers.clear()
	if not in_session and _outgoing.is_empty() and _udp != null:
		_udp.close()
		_udp = null
		_multicast_lock(false)


func _process(delta: float) -> void:
	if _udp == null:
		return
	var n := 0
	while _udp.get_available_packet_count() > 0 and n < 64:
		n += 1
		var pkt := _udp.get_packet()
		if pkt.size() <= MAX_PACKET:
			_on_packet(pkt, _udp.get_packet_ip())
	if not _discovering:
		return
	_hello_t -= delta
	if _hello_t <= 0.0:
		_hello_t = 1.0
		_broadcast({"t": "hello"})
	var now := Time.get_ticks_msec()
	var gone := []
	for id in peers:
		if now - int(peers[id].seen) > PEER_TIMEOUT_MS:
			gone.append(id)
	for id in gone:
		peers.erase(id)
	if not gone.is_empty():
		peers_changed.emit()
	if not _outgoing.is_empty() and now - int(_outgoing.t) > INVITE_TIMEOUT_MS:
		var who := String(_outgoing.name)
		cancel_invite()
		invite_answered.emit(false, who)
	if not _incoming.is_empty() and now - int(_incoming.t) > INVITE_TIMEOUT_MS:
		_incoming = {}
		invite_cancelled.emit()


func _packet(kind: String) -> Dictionary:
	return {"lw": PROTOCOL, "t": kind, "id": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle)}


func _broadcast(extra: Dictionary) -> void:
	var p := _packet(String(extra.t))
	var bytes := JSON.stringify(p).to_utf8_buffer()
	for addr in _broadcast_addresses():
		for port in dest_ports:
			_udp.set_dest_address(addr, port)
			_udp.put_packet(bytes)


func _send_to(ip: String, kind: String) -> void:
	if _udp == null:
		return
	var bytes := JSON.stringify(_packet(kind)).to_utf8_buffer()
	for port in dest_ports:
		_udp.set_dest_address(ip, port)
		_udp.put_packet(bytes)


## The limited broadcast plus each private IPv4 network's /24 broadcast (a phone's hotspot does
## not route 255.255.255.255 on every Android version).
func _broadcast_addresses() -> PackedStringArray:
	var out := PackedStringArray(["255.255.255.255"])
	for a in IP.get_local_addresses():
		var parts := a.split(".")
		if parts.size() == 4 and (a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172.")):
			var b := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
			if not b in out:
				out.append(b)
	if Game.autotest != "":
		out.append("127.0.0.1")
	return out


## The Wi-Fi addresses of this phone, for the panel ("" when there is no local network).
func local_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
	return ""


func _on_packet(pkt: PackedByteArray, ip: String) -> void:
	var d: Variant = JSON.parse_string(pkt.get_string_from_utf8())
	if not d is Dictionary:
		return
	var m: Dictionary = d
	if typeof(m.get("lw")) != TYPE_FLOAT or int(m.lw) != PROTOCOL:
		return
	if typeof(m.get("id")) != TYPE_STRING or typeof(m.get("t")) != TYPE_STRING:
		return
	var id := String(m.id).left(32)
	if id == my_id or id == "":
		return
	var who := Game.clean_name(String(m.get("name", ""))) if typeof(m.get("name")) == TYPE_STRING else ""
	if who == "":
		who = "PLAYER"
	var bundle := String(CharacterModel.bundle_info(String(m.get("bundle", "default")) if typeof(m.get("bundle")) == TYPE_STRING else "default").id)
	match String(m.t):
		"hello":
			var known := peers.has(id) and String(peers[id].name) == who and String(peers[id].ip) == ip
			peers[id] = {"name": who, "bundle": bundle, "ip": ip, "seen": Time.get_ticks_msec()}
			if not known:
				peers_changed.emit()
		"invite":
			if in_session or not _outgoing.is_empty() or not _incoming.is_empty():
				_send_to(ip, "busy")
				return
			_incoming = {"id": id, "name": who, "bundle": bundle, "ip": ip, "t": Time.get_ticks_msec()}
			invited.emit(who)
		"cancel":
			if String(_incoming.get("id", "")) == id:
				_incoming = {}
				invite_cancelled.emit()
		"decline", "busy":
			if String(_outgoing.get("id", "")) == id:
				var name_out := String(_outgoing.name)
				cancel_invite(false)
				invite_answered.emit(false, name_out)


# ---------------------------------------------------------------- invites and the session

## Challenges a discovered phone: opens the game port and asks it to join.
func invite(peer_id: String) -> bool:
	if in_session or not _outgoing.is_empty() or not peers.has(peer_id):
		return false
	var p := ENetMultiplayerPeer.new()
	if p.create_server(GAME_PORT, 1) != OK:
		return false
	multiplayer.multiplayer_peer = p
	var info: Dictionary = peers[peer_id]
	_outgoing = {"id": peer_id, "name": info.name, "bundle": info.bundle, "ip": info.ip, "t": Time.get_ticks_msec()}
	_send_to(String(info.ip), "invite")
	return true


func cancel_invite(tell := true) -> void:
	if _outgoing.is_empty():
		return
	if tell:
		_send_to(String(_outgoing.ip), "cancel")
	_outgoing = {}
	if not in_session:
		_close_peer()


func has_invite() -> bool:
	return not _incoming.is_empty()


func waiting_for() -> String:
	return String(_outgoing.get("name", ""))


## Answers the invite we got: ACCEPT connects to the inviter, DECLINE tells it no.
func answer(accept: bool) -> void:
	if _incoming.is_empty():
		return
	var inv := _incoming
	_incoming = {}
	if not accept:
		_send_to(String(inv.ip), "decline")
		return
	var p := ENetMultiplayerPeer.new()
	if p.create_client(String(inv.ip), GAME_PORT) != OK:
		_fail("could not connect")
		return
	multiplayer.multiplayer_peer = p
	opponent = inv
	is_host = false


func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if _outgoing.is_empty() or in_session:
		(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(id)
		return
	_peer_id = id        # it still has to say who it is ("join")


func _on_connected() -> void:
	_peer_id = 1
	in_session = true
	queue.clear()
	_r_event.rpc_id(1, "join", [my_id])
	stop_discovery()
	session_started.emit(false)


func _on_peer_disconnected(id: int) -> void:
	if id == _peer_id:
		end_session("left")


func _fail(reason: String) -> void:
	_close_peer()
	in_session = false
	session_ended.emit(reason)


func end_session(reason := "left") -> void:
	var was := in_session or multiplayer.multiplayer_peer is ENetMultiplayerPeer
	in_session = false
	_peer_id = 0
	_outgoing = {}
	_close_peer()
	if was:
		session_ended.emit(reason)


## Closed on the next frame: the engine crashes when a peer is replaced inside its own
## disconnect signal. Only that peer is dropped (a new invite may have opened another).
func _close_peer() -> void:
	var p := multiplayer.multiplayer_peer
	if p is ENetMultiplayerPeer:
		_drop_peer.call_deferred(p)


func _drop_peer(p: MultiplayerPeer) -> void:
	p.close()
	if multiplayer.multiplayer_peer == p:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


# ---------------------------------------------------------------- match traffic

func send_state(s: PackedFloat32Array) -> void:
	if in_session and _peer_id != 0:
		_r_state.rpc_id(_peer_id, s)


func send_event(kind: String, data: Array = []) -> void:
	if in_session and _peer_id != 0:
		_r_event.rpc_id(_peer_id, kind, data)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _r_state(s: PackedFloat32Array) -> void:
	if not in_session or multiplayer.get_remote_sender_id() != _peer_id or s.size() != RemoteFighter.STATE_SIZE:
		return
	state_received.emit(s)


@rpc("any_peer", "call_remote", "reliable", 0)
func _r_event(kind: String, data: Array) -> void:
	if multiplayer.get_remote_sender_id() != _peer_id or data.size() > 16:
		return
	if kind == "join":
		# The host starts only for the phone it invited.
		if in_session or _outgoing.is_empty() or data.size() != 1 or String(data[0]) != String(_outgoing.id):
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(_peer_id)
			return
		opponent = _outgoing
		_outgoing = {}
		is_host = true
		in_session = true
		queue.clear()
		stop_discovery()
		session_started.emit(true)
		return
	if not in_session:
		return
	if event_received.get_connections().is_empty():
		queue.append([kind, data])
	else:
		event_received.emit(kind, data)


# ---------------------------------------------------------------- Android

## Android drops broadcast packets to save power unless the app holds a Wi-Fi multicast lock.
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
