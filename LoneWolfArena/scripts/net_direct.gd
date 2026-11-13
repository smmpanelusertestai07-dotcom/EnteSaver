class_name NetDirect
extends RefCounted
## The direct path of an online match (DIRECT CONNECTION, Settings ONLINE, on by default): the two
## phones send the 20-a-second state straight to each other over UDP instead of through the relay
## abroad, which roughly halves the round trip. No server of ours: public STUN servers only tell a
## phone the address the internet sees it from. The relay (Cloud) stays the match's backbone: it
## carries the handshake, every match event, chat and voice, and the state again whenever the
## direct path is down.
##  1. The match starts (Cloud.session_started): each phone opens ONE UDP socket and gathers its
##     candidates: its own addresses (IP.get_local_addresses, no loopback or link-local) with the
##     socket's port, and its public address from a STUN Binding Request (RFC 5389, sent over that
##     same socket to STUN_SERVERS; XOR-MAPPED-ADDRESS, IPv4 and IPv6) within STUN_WAIT_MS.
##  2. Cloud swaps the candidates over the end-to-end encrypted room ("dh" hello, "dc" candidates):
##     only when BOTH players have DIRECT CONNECTION on, so a player who turned it off never sends
##     an address (and never gets one).
##  3. Both phones send PUNCH packets to every candidate of the other (simultaneous open): PUNCH_S
##     apart for PUNCH_MS, then every RETRY_S while the path is down. Every packet is sealed with keys
##     derived from the room's own (fresh for each match): header (MAGIC, direction byte, sequence
##     number), IV, AES-256-CBC of a short JSON, HMAC-SHA256 over all of it. A packet counts only if
##     it authenticates, comes the other way and is newer than the last one taken from that
##     direction (replays and late packets are dropped).
##  4. Every packet says whether its sender heard this phone lately ("h"): once this phone hears
##     the other AND the other hears it, its state goes direct (can_send). Nothing heard for
##     TIMEOUT_MS: back to the relay at once, punching on in the background (and new candidates are
##     gathered and swapped every REGATHER_MS while it stays down).
##  5. A ping every PING_S over the direct path gives `rtt`, the match HUD's ping while it is up.
##  6. Punching reaches the other phone by every address that works, so packets can come from
##     several (its Wi-Fi address on a shared network, its IPv6 address, its IPv4 address behind the
##     carrier's NAT). This phone sends to the best one heard within PATH_FRESH_MS (path_rank: the same
##     local network first, then IPv6, which most Indian mobile networks give and which needs no
##     NAT, then IPv4), not to whichever packet came last, so the path and its ping do not flip
##     between them.
## What comes in goes through the same checks as the relay's (Cloud, Arena's token buckets and item
## caps, RemoteFighter's finite numbers). Automated runs stay off unless LW_DIRECT=local: then the
## only candidate is 127.0.0.1 and no STUN server is asked (two copies on one machine).

const MAGIC := 0xD7              # first byte of a sealed packet (a STUN message starts with 0b00)
const STUN_SERVERS := [["stun.l.google.com", 19302], ["stun1.l.google.com", 19302], ["stun.cloudflare.com", 3478]]
const STUN_COOKIE := 0x2112A442
const STUN_WAIT_MS := 1500       # how long candidates are gathered
const STUN_RESEND_MS := 500      # a Binding Request with no answer yet goes out again this often
const PUNCH_MS := 4000           # the punching burst after candidates come (or the path drops)
const PUNCH_S := 0.2
const RETRY_S := 1.0             # punching while the path is down after the burst
const TIMEOUT_MS := 1500         # nothing heard this long: the state goes back to the relay
const PATH_FRESH_MS := 1000      # an address heard from within this counts for the choice of path
const REGATHER_MS := 15000       # down this long: gather and swap candidates again
const PING_S := 0.5
const MAX_CANDIDATES := 8
const MAX_PACKET := 1200
const MAX_IN_PER_FRAME := 64     # packets read per frame (a flood is dropped by the socket)

var host := false                # the host sends direction 0, the guest direction 1
var local_mode := false          # LW_DIRECT=local (tests): loopback only, no STUN
var blocked := false             # tests: the direct path cut (nothing sent, nothing read)
var port := 0
var candidates: Array = []       # this phone's [ip, port] (gathered)
var gathered := false
var peer_candidates: Array = []  # the other phone's [ip, port]
var rtt := -1                    # ms, direct round trip (-1 until measured)
var states_in := 0               # counters (tests, logs)
var states_out := 0
var _sock: PacketPeerUDP
var _crypto := Crypto.new()
var _aes := PackedByteArray()
var _mac := PackedByteArray()
var _out_seq := 0
var _in_seq := 0
var _start_ms := 0
var _stun: Array = []            # [{"host", "port", "v6", "rid", "ip", "tx", "sent_ms"}]
var _punch_from_ms := -1         # when the current punching burst began (-1: no candidates yet)
var _punch_t := 0.0
var _ping_t := 0.0
var _ping_n := 0
var _pings := {}                 # ping number -> ms sent
var _pong_budget := 4.0
var _rx_ms := -1                 # when the last valid packet came (-1: never)
var _peer_hears := false         # the last valid packet said its sender heard us
var _peer_ip := ""               # where the last valid packet came from (sent to first)
var _peer_port := 0
var _paths := {}                 # "ip|port" -> [ip, port, ms last heard]: every address the other phone answered from
var _down_ms := 0                # when the path was last seen down (for REGATHER_MS)
var _mapped := {}                # STUN answers: "ip|port" -> [ip, port]
var _regathers := 0
var _v4_only := false            # the socket could open for IPv4 only (no IPv6 sends then)
var _was_up := false


## Off, on or "local" for this run: off in automated runs unless LW_DIRECT=local, else the
## player's DIRECT CONNECTION setting.
static func mode() -> String:
	if not OS.has_feature("template"):
		var env := OS.get_environment("LW_DIRECT")
		if env == "local":
			return "local"
		if env == "off" or Game.autotest != "":
			return "off"
	return "on" if bool(Game.settings.get("direct_connect", true)) else "off"


func _init(is_host: bool, room_mac: PackedByteArray, local := false) -> void:
	host = is_host
	local_mode = local
	# Keys of their own, derived from the match's HMAC key: a relay message never opens here.
	_aes = _crypto.hmac_digest(HashingContext.HASH_SHA256, room_mac, "lonewolf-direct-aes".to_utf8_buffer())
	_mac = _crypto.hmac_digest(HashingContext.HASH_SHA256, room_mac, "lonewolf-direct-mac".to_utf8_buffer())
	# The sequence starts at the wall clock (ms), not at 0: a phone that comes back into its match
	# after its app was closed makes a new path with the same keys, and its packets must count as
	# newer than every one the other phone already took (a path sends far less than 1000 a second).
	_out_seq = int(Time.get_unix_time_from_system() * 1000.0)


## Opens the socket and starts gathering (now: the tick clock). False when no socket could open.
func open(now: int) -> bool:
	_sock = PacketPeerUDP.new()
	if _sock.bind(0, "*") != OK:
		_sock = PacketPeerUDP.new()
		_v4_only = true
		if _sock.bind(0, "0.0.0.0") != OK:
			_sock = null
			return false
	port = _sock.get_local_port()
	_start_ms = now
	_down_ms = now
	_gather(now)
	return true


func close() -> void:
	if _sock != null:
		_sock.close()
	_sock = null
	for s: Dictionary in _stun:
		if int(s.rid) >= 0:
			IP.erase_resolve_item(int(s.rid))
	_stun.clear()


func is_open() -> bool:
	return _sock != null


func _gather(now: int) -> void:
	gathered = false
	_mapped.clear()
	candidates.clear()
	if local_mode:
		candidates = [["127.0.0.1", port]]
		gathered = true
		return
	for a: String in IP.get_local_addresses():
		# (room is kept for the public addresses STUN gives, which go first)
		if local_usable(a) and candidates.size() < MAX_CANDIDATES - 2 and not (_v4_only and a.contains(":")):
			candidates.append([a, port])
	for s: Dictionary in _stun:
		if int(s.rid) >= 0:
			IP.erase_resolve_item(int(s.rid))
	_stun.clear()
	for srv: Array in STUN_SERVERS:
		for v6 in [false, true]:
			var rid := IP.resolve_hostname_queue_item(String(srv[0]), IP.TYPE_IPV6 if v6 else IP.TYPE_IPV4)
			_stun.append({"port": int(srv[1]), "rid": rid, "ip": "", "tx": _crypto.generate_random_bytes(12), "sent_ms": -1})
	_start_ms = now


## Every frame (now: the tick clock): STUN, punching, pings; returns the states that came in
## (Dictionaries {"k": "st", "s", "t"} for Cloud; pings and punches are handled here).
func poll(now: int, delta: float) -> Array:
	var out := []
	if _sock == null:
		return out
	if not gathered:
		_tick_stun(now)
	var n := 0
	while _sock.get_available_packet_count() > 0 and n < MAX_IN_PER_FRAME:
		n += 1
		var pkt := _sock.get_packet()
		var ip := _sock.get_packet_ip()
		var from_port := _sock.get_packet_port()
		if blocked or pkt.size() > MAX_PACKET or pkt.is_empty():
			continue
		if pkt[0] != MAGIC:
			if not gathered:
				_on_stun(pkt)
			continue
		var d := open_packet(pkt)
		if d.is_empty():
			continue
		_rx_ms = now
		_peer_hears = d.get("h") == 1
		_heard_from(ip, from_port, now)
		match String(d.get("k", "")):
			"pi":
				var i: Variant = d.get("i")
				if (i is int or i is float) and _pong_budget >= 1.0:
					_pong_budget -= 1.0
					_send({"k": "po", "i": int(i)}, now)
			"po":
				var i: Variant = d.get("i")
				if (i is int or i is float) and _pings.has(int(i)):
					rtt = NetPing.smooth(rtt, now - int(_pings[int(i)]))
					_pings.erase(int(i))
			"st":
				states_in += 1
				out.append(d)
	_pong_budget = minf(_pong_budget + delta * 4.0, 4.0)
	if not up(now):
		if _down_ms == 0:
			_down_ms = now
		if _was_up and _punch_from_ms >= 0:
			_punch_from_ms = now           # just dropped: a fresh burst
			_punch_t = 0.0
		_was_up = false
		if _punch_from_ms >= 0:
			_punch_t -= delta
			if _punch_t <= 0.0:
				_punch_t = PUNCH_S if now - _punch_from_ms < PUNCH_MS else RETRY_S
				_punch(now)
	else:
		_down_ms = 0
		_was_up = true
	if heard(now):
		_ping_t -= delta
		if _ping_t <= 0.0:
			_ping_t = PING_S
			_ping_n += 1
			_pings[_ping_n] = now
			_pings.erase(_ping_n - 6)
			_send({"k": "pi", "i": _ping_n}, now)
	return out


## A valid packet came from ip:from_port: the address this phone sends to is the best one heard
## lately (best_path), so a worse path's packets do not pull the sends over to it.
func _heard_from(ip: String, from_port: int, now: int) -> void:
	var key := ip + "|" + str(from_port)
	if not _paths.has(key) and _paths.size() >= MAX_CANDIDATES * 2:
		for k: String in _paths.keys():
			if now - int(_paths[k][2]) >= TIMEOUT_MS:
				_paths.erase(k)
		if _paths.size() >= MAX_CANDIDATES * 2:
			_peer_ip = ip
			_peer_port = from_port
			return
	_paths[key] = [ip, from_port, now]
	var best := best_path(_paths.values(), now, PATH_FRESH_MS)
	_peer_ip = String(best[0])
	_peer_port = int(best[1])


## The address to send to among `paths` ([ip, port, ms last heard]): the best path_rank heard within
## `fresh_ms` of `now`, the most recent of those on a tie; [] when none is fresh.
static func best_path(paths: Array, now: int, fresh_ms: int) -> Array:
	var best := []
	for p: Array in paths:
		if now - int(p[2]) >= fresh_ms:
			continue
		if best.is_empty() or path_rank(String(p[0])) > path_rank(String(best[0])) \
				or (path_rank(String(p[0])) == path_rank(String(best[0])) and int(p[2]) > int(best[2])):
			best = p
	return best


## How good a path to the other phone at `ip` is: 3 the same local network (a private IPv4 address
## or an IPv6 unique-local one: both phones on one Wi-Fi or hotspot, a few ms), 2 a global IPv6
## address (no carrier NAT on the way), 1 an IPv4-mapped IPv6 or 100.64/10 (carrier NAT) address,
## 0 any other (public IPv4).
static func path_rank(ip: String) -> int:
	var a := ip.to_lower()
	if a.begins_with("::ffff:"):
		a = a.substr(7)
	if not a.contains(":"):
		var o := a.split(".")
		if o.size() != 4:
			return 0
		var x := int(o[0])
		var y := int(o[1])
		if x == 10 or (x == 192 and y == 168) or (x == 172 and y >= 16 and y < 32):
			return 3
		return 1 if x == 100 and y >= 64 and y < 128 else 0
	return 3 if a.begins_with("fc") or a.begins_with("fd") else 2


## The path has been down REGATHER_MS (and candidates were swapped): gather again (true once).
func wants_regather(now: int) -> bool:
	if local_mode or not gathered or _punch_from_ms < 0 or _down_ms == 0 or now - _down_ms < REGATHER_MS \
			or _regathers >= 4:
		return false
	_regathers += 1
	_down_ms = now
	_gather(now)
	return true


## The other phone's candidates (already checked by candidate_ok): punching starts (again).
func set_peer_candidates(list: Array, now: int) -> void:
	for c: Array in list:
		if not peer_candidates.has(c) and peer_candidates.size() < MAX_CANDIDATES * 2:
			peer_candidates.append(c)
	_punch_from_ms = now
	_punch_t = 0.0


## This phone heard the other lately (sealed packets that authenticated).
func heard(now: int) -> bool:
	return _rx_ms >= 0 and now - _rx_ms < TIMEOUT_MS


## The path works both ways: this phone hears the other, and the other said it hears this one.
func up(now: int) -> bool:
	return heard(now) and _peer_hears


## Whether the state goes out direct (else through the relay).
func can_send(now: int) -> bool:
	return not blocked and up(now)


func send_state(a: Array, t: int, now: int) -> void:
	states_out += 1
	_send({"k": "st", "s": a, "t": t}, now)


func _punch(now: int) -> void:
	var sent := {}
	if _peer_ip != "":
		sent[_peer_ip + "|" + str(_peer_port)] = true
		_send_to({"k": "pu"}, _peer_ip, _peer_port, now)
	for c: Array in peer_candidates:
		var key := String(c[0]) + "|" + str(c[1])
		if not sent.has(key):
			sent[key] = true
			_send_to({"k": "pu"}, String(c[0]), int(c[1]), now)


func _send(d: Dictionary, now: int) -> void:
	if _peer_ip != "":
		_send_to(d, _peer_ip, _peer_port, now)


func _send_to(d: Dictionary, ip: String, to_port: int, now: int) -> void:
	if _sock == null or blocked or (_v4_only and ip.contains(":") and not ip.begins_with("::ffff:")):
		return
	d["h"] = 1 if heard(now) else 0
	_sock.set_dest_address(ip, to_port)
	_sock.put_packet(seal(JSON.stringify(d).to_utf8_buffer()))


# ---------------------------------------------------------------- sealed packets

## A packet as it goes out: MAGIC, direction (0 host -> guest, 1 guest -> host), sequence number
## (8 bytes, one more each packet, starting at the wall clock in ms so that it stays ahead across
## an app restart), IV, AES-256-CBC of the payload, HMAC-SHA256 over all of it.
func seal(payload: PackedByteArray) -> PackedByteArray:
	_out_seq += 1
	var body := PackedByteArray([MAGIC, 0 if host else 1])
	body.resize(10)
	body.encode_s64(2, _out_seq)
	var iv := _crypto.generate_random_bytes(16)
	body.append_array(iv)
	var plain := payload.duplicate()
	var pad := 16 - plain.size() % 16
	for i in pad:
		plain.append(pad)
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_ENCRYPT, _aes, iv)
	body.append_array(ctx.update(plain))
	ctx.finish()
	body.append_array(_crypto.hmac_digest(HashingContext.HASH_SHA256, _mac, body))
	return body


## The payload of a packet from the other phone as a Dictionary, {} when it does not authenticate,
## comes from this phone's own direction, is not newer than the last one taken, or is not JSON.
func open_packet(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 10 + 16 + 16 + 32 or (pkt.size() - 58) % 16 != 0 or pkt[0] != MAGIC or pkt[1] != (1 if host else 0):
		return {}
	var body := pkt.slice(0, pkt.size() - 32)
	if not _crypto.constant_time_compare(_crypto.hmac_digest(HashingContext.HASH_SHA256, _mac, body), pkt.slice(pkt.size() - 32)):
		return {}
	var seq := body.decode_s64(2)
	if seq <= _in_seq:
		return {}                    # a replay, or older than one already taken
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_DECRYPT, _aes, body.slice(10, 26))
	var plain := ctx.update(body.slice(26))
	ctx.finish()
	var pad := plain[plain.size() - 1] if plain.size() > 0 else 0
	if pad < 1 or pad > 16:
		return {}
	var d: Variant = JSON.parse_string(plain.slice(0, plain.size() - pad).get_string_from_utf8())
	if not d is Dictionary:
		return {}
	_in_seq = seq
	return d


# ---------------------------------------------------------------- candidates

## One of this phone's own addresses worth offering: not loopback, link-local or unspecified.
static func local_usable(ip: String) -> bool:
	if not ip.is_valid_ip_address() or ip.contains("%"):
		return false
	var low := ip.to_lower()
	return not (low.begins_with("127.") or low == "::1" or low.begins_with("fe80:") or low.begins_with("169.254.")
		or low == "0.0.0.0" or low == "::" or low.begins_with("::ffff:127."))


## A candidate from the other phone that this one may send to: a real unicast address (loopback
## only in LW_DIRECT=local runs) and a port from 1024 up (never a well-known service).
static func candidate_ok(ip: Variant, p: Variant, local := false) -> bool:
	if typeof(ip) != TYPE_STRING or String(ip).length() > 45 or not (p is int or p is float):
		return false
	var a := String(ip)
	if int(p) < 1024 or int(p) > 65535 or not a.is_valid_ip_address() or a.contains("%"):
		return false
	if local:
		return a == "127.0.0.1"
	if not local_usable(a) or a.to_lower().begins_with("ff"):
		return false                  # (IPv6 multicast)
	if a.contains(":"):
		return true
	var first := int(a.get_slice(".", 0))
	return first >= 1 and first < 224  # no multicast, broadcast or reserved IPv4


## The other phone's candidate list from a room message: the valid entries ([ip, port]), at most
## MAX_CANDIDATES.
static func candidates_from(v: Variant, local := false) -> Array:
	var out := []
	if not v is Array:
		return out
	for c: Variant in (v as Array).slice(0, MAX_CANDIDATES):
		if c is Array and (c as Array).size() == 2 and candidate_ok(c[0], c[1], local):
			out.append([String(c[0]), int(c[1])])
	return out


# ---------------------------------------------------------------- STUN (RFC 5389)

func _tick_stun(now: int) -> void:
	for s: Dictionary in _stun:
		if String(s.ip) == "" and int(s.rid) >= 0:
			var st := IP.get_resolve_item_status(int(s.rid))
			if st == IP.RESOLVER_STATUS_DONE:
				s.ip = IP.get_resolve_item_address(int(s.rid))
			if st != IP.RESOLVER_STATUS_WAITING:
				IP.erase_resolve_item(int(s.rid))
				s.rid = -1
		if String(s.ip) != "" and (int(s.sent_ms) < 0 or now - int(s.sent_ms) >= STUN_RESEND_MS) \
				and not (_v4_only and String(s.ip).contains(":")):
			s.sent_ms = now
			_sock.set_dest_address(String(s.ip), int(s.port))
			_sock.put_packet(stun_request(s.tx))
	if now - _start_ms >= STUN_WAIT_MS:
		for c: Array in _mapped.values():
			if not candidates.has(c):
				candidates.push_front(c)        # the public addresses first
		candidates = candidates.slice(0, MAX_CANDIDATES)
		gathered = true


func _on_stun(pkt: PackedByteArray) -> void:
	for s: Dictionary in _stun:
		var m := stun_parse(pkt, s.tx)
		if not m.is_empty():
			_mapped[String(m.ip) + "|" + str(m.port)] = [String(m.ip), int(m.port)]
			return


## A Binding Request: type 0x0001, no attributes, the magic cookie, the 12-byte transaction id.
static func stun_request(tx: PackedByteArray) -> PackedByteArray:
	var p := PackedByteArray([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])
	p.append_array(tx)
	return p


## The mapped address of a Binding Success Response to transaction `tx` as {"ip", "port"}
## (XOR-MAPPED-ADDRESS, else MAPPED-ADDRESS; IPv4 or IPv6), {} for anything else.
static func stun_parse(pkt: PackedByteArray, tx: PackedByteArray) -> Dictionary:
	if pkt.size() < 20 or tx.size() != 12 or pkt[0] != 0x01 or pkt[1] != 0x01:
		return {}
	var length := (pkt[2] << 8) | pkt[3]
	if length % 4 != 0 or 20 + length != pkt.size() or pkt.slice(4, 8) != PackedByteArray([0x21, 0x12, 0xA4, 0x42]) \
			or pkt.slice(8, 20) != tx:
		return {}
	var at := 20
	var plain := {}
	while at + 4 <= pkt.size():
		var kind := (pkt[at] << 8) | pkt[at + 1]
		var n := (pkt[at + 2] << 8) | pkt[at + 3]
		if at + 4 + n > pkt.size():
			return {}
		var v := pkt.slice(at + 4, at + 4 + n)
		if kind == 0x0020:
			return _address(v, pkt.slice(4, 20))
		if kind == 0x0001 and plain.is_empty():
			plain = _address(v, PackedByteArray())
		at += 4 + n + (4 - n % 4) % 4
	return plain


## A (XOR-)MAPPED-ADDRESS value: family 1 (IPv4, 8 bytes) or 2 (IPv6, 20 bytes); `x` is the cookie
## and transaction id it is XORed with (empty: not XORed).
static func _address(v: PackedByteArray, x: PackedByteArray) -> Dictionary:
	if v.size() < 8 or v[1] not in [1, 2] or v.size() != (8 if v[1] == 1 else 20):
		return {}
	var p := (v[2] << 8) | v[3]
	if not x.is_empty():
		p ^= 0x2112
	var raw := v.slice(4)
	if not x.is_empty():
		for i in raw.size():
			raw[i] = raw[i] ^ x[i]
	var ip := ""
	if v[1] == 1:
		ip = "%d.%d.%d.%d" % [raw[0], raw[1], raw[2], raw[3]]
	else:
		var groups := PackedStringArray()
		for i in 8:
			groups.append("%x" % ((raw[i * 2] << 8) | raw[i * 2 + 1]))
		ip = ":".join(groups)
	if p == 0:
		return {}
	return {"ip": ip, "port": p}
