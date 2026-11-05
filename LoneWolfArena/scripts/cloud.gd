class_name Cloud
extends Node
## Internet 1 vs 1 with no account and no server of our own: free public MQTT brokers (TLS
## WebSocket) only relay messages, and everything in a match is end-to-end encrypted on the two
## phones, so the relay sees scrambled bytes. It is the game's only transport: LONE WOLF (online
## 1 vs 1) plays through it, the arena reaches it as Game.session.
##
## Lobby (topic ROOT/lobby): from the first time the game's lobby opens (presence then stays on,
## through matches too) every phone announces {id, name, outfit, RSA-2048 public key} every 5 s
## (and soon after it first hears a player new to it, so a phone that just came online sees the
## others within a second or so) and lists the others; the id is a hash of the key, so nobody can
## announce someone else's id with their own key. DUEL 1 VS 1 sends that phone (topic ROOT/u/<id>)
## a fresh room name, AES-256 key and HMAC key encrypted with its public key, signed with the
## sender's key (invite_text); the answers carry an HMAC only the holders of those keys can make. In the room (ROOT/r/<room>) every message is
## AES-256-CBC with a random IV plus an HMAC-SHA256 over it, and carries the sender's id and a
## counter (replays are dropped). The inviter hosts. State goes out 20 times a second (a state
## that did not change only twice, then every STATE_IDLE_MS) with the sender's clock, so the other
## phone can draw the fighter a little in the past, smoothly (RemoteFighter); a silent
## opponent or a "bye" ends the match ("left"); a phone that hears nothing at all from the relay,
## or was away (background, screen off) longer than the other phone waits, ends it as "connection
## lost" (it is the one that dropped out; a link that went quiet outside a match is replaced too).
## While a phone loads the match it sends a keep-alive, so a slow load is not taken for leaving.
## The state can take a faster way: with DIRECT CONNECTION on for both players, the two phones open
## a direct UDP path (NetDirect: candidates swapped in the room, hole punching, packets sealed with
## keys derived from the room's) and the state goes over it while it works both ways (direct_up),
## through the relay again after NetDirect.TIMEOUT_MS of silence; everything else stays here.
## Anyone can publish to a public broker, so invites are rate limited and the list is capped. The
## lobby shows names, outfits and public keys only; nothing is stored by the game anywhere.
## Each player decides who reaches them (the ONLINE settings): DUEL CHALLENGES FROM everyone,
## friends only or nobody (challenge_allowed: the others are declined at once, unseen) and FRIEND
## REQUESTS on or off (requests_allowed: off, they are ignored).
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
## accepted, with the v2 fields at their defaults. Card v3 ("v": 3) adds the career summary
## (career_summary: matches, wins, kills, K/D and headshot rate as whole numbers) while the setting
## SHOW MY CAREER is on, {} while it is off, and "sig3" over every field including it (card3_text);
## its sig2 and sig still sign the v2 and v1 texts, so older builds keep listing the player. Nothing
## else of the profile is published: my_card() is the whole list (the card's JSON adds only the id,
## the public key, the time and the signatures). A change to any of it publishes the card again
## (CARD_CHANGE_S later, so a run of taps in NAME CARD makes one card).

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
signal chat_received(text: String)     # the opponent's chat line in a match (cleaned, NetChat.MATCH_MAX)
signal voice_received(frame: PackedByteArray)    # the opponent's push-to-talk audio (a NetVoice frame)
signal friend_chat_changed(id: String) # a friend's chat message came in (NetChat)
signal seeker_seen(id: String, saw: Array)    # QUICK MATCH: another searching player's "seek" (NetMatch)

const ROOT := "lonewolfarena/v1"
## QUICK MATCH (NetMatch): searching players say so here every SEEK_S, never retained.
const SEEK_TOPIC := ROOT + "/mm/seek"
## The relays, nearest to the players first (every phone settles on the same one, see
## _maybe_return_home). FreeMQTT runs in Mumbai (about 25 ms from Indian networks, measured with
## free public probes on 2026-11-05) and asks for the shared login its operator publishes on its
## home page for everyone (not an account, not a secret); HiveMQ (Frankfurt) and EMQX (Europe /
## US) take over if it is down.
const BROKERS := ["wss://broker.freemqtt.com:8084/mqtt", "wss://broker.hivemq.com:8884/mqtt", "wss://broker.emqx.io:8084/mqtt"]
## Relays that refuse anonymous clients: [user, password], both published by the relay itself.
const BROKER_LOGINS := {"wss://broker.freemqtt.com:8084/mqtt": ["freemqtt", "public"]}
## The lobby announcement's period: light on the free relays (whose terms ask for light use); a
## player new to this phone gets an answer within ANNOUNCE_REPLY_S instead (_on_lobby).
const ANNOUNCE_S := 5.0
const ANNOUNCE_REPLY_S := 0.6
const PEER_TIMEOUT_MS := 12000   # two announcements lost in a row: the player has left the lobby
const INVITE_TIMEOUT_MS := 25000
const SILENCE_MS := 8000
## A phone that was away, or heard nothing at all from the relay, this long in a match has dropped
## out of it: it says so to itself a little before the other phone's SILENCE_MS runs out, so the
## two never both take the other for the one who left.
const AWAY_MS := SILENCE_MS - 1500
const QUIET_MS := 15000        # nothing at all from the relay this long outside a match: the link is dead
const KEEP_ALIVE_MS := 60000   # the keep-alive CONNECT asks for: the relay has dropped a phone away longer
const LOAD_KEEP_MS := 30000    # a new session's keep-alives while its arena loads stop after this
## A match loading (the scene change, the loading overlay) and the first seconds after its arena
## listens freeze the game while shaders compile (8 s on a phone's first load): a frame gap then is
## the load, not this phone away (only an app pause still counts), and the other phone, whose
## keep-alives said it was loading, is waited for this much longer than SILENCE_MS.
const LOAD_STALL_MS := 6000
const PING_S := 5.0            # PINGREQ while connected: the keep-alive and the relay round trip (relay_rtt)
const PEER_PING_S := 2.0       # encrypted room ping in a match: the round trip to the other phone (peer_rtt)
const STATE_IDLE_MS := 250     # a state that did not change goes out this often (it is sent twice, then skipped)
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

var state_interval := 0.05     # seconds between state packets (20 a second)
var relay_rtt := -1            # ms, round trip to the relay (MQTT ping), -1 until measured on this connection
var peer_rtt := -1             # ms, round trip to the other phone in a match (room ping), -1 until it answered
var last_state_sent_ms := -1   # the sender's clock on the state just received (-1: an older build sent none)
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
var _listen_ms := -1           # when this session's arena began listening (-1: loading, or none)
var _peer_ka_ms := -100000     # when the other phone's last loading keep-alive came
var _keep_t := 0.0             # s until the next keep-alive while the arena loads
var _pingreq_ms := 0           # when the PINGREQ waiting for its PINGRESP went out (0: none)
var _peer_ping_t := 0.0        # s until the next room ping
var _peer_pings := {}          # room ping number -> when it went out (the last few)
var _ping_n := 0
var _pong_budget := 3.0        # room pings answered (a flood of them is not answered in kind)
var _last_state: Array = []    # the state last sent, and how often in a row (send_state skips repeats)
var _same_n := 0
var _state_ms := 0
var _chat_in := [2.0, 0]       # the opponent's chat lines: [tokens, ms] (NetChat.RATE_S)
var _chat_out_ms := 0          # when this phone last sent one
var _voice_in := [10.0, 0]     # the opponent's voice frames: [tokens, ms]
var _fchat_ms := 0             # when this phone last sent a friend a chat message
## The match's direct UDP path (NetDirect, DIRECT CONNECTION): null while off or outside a match.
## The state goes over it while it works both ways; everything else stays on the relay.
var direct: NetDirect = null
var _direct_peer := false      # the other phone can go direct too (its "dh" or "dc" came)
var _direct_sent := false      # this phone's candidates went out (for the current gathering)
var _direct_hello_n := 0
var _direct_hello_t := 0.0
var _state_in_t := -1          # sender's clock on the newest state taken (either path): older ones are dropped
var relay_states_out := 0      # states sent through the relay this session (tests)
var relay_states_in := 0       # states taken from the relay this session (tests)
var seeking := false           # QUICK MATCH searching: listening to SEEK_TOPIC (NetMatch)
var quick_seen := {}           # id -> ms: seekers this search saw (only their quick challenge is taken)
## DUO / SQUAD over this 1 vs 1 session: the team of the session a team invite ("tinv") started, on
## both phones ({"size": 2 | 4, "coop": bool}: coop = both players on one team against bots, else
## each with bot teammates against the other), {} for a 1 vs 1. Set when the invite goes out or is
## accepted, cleared when it is called off and by end_session. seek_team: the size the team search
## runs for (0: none, or the 1 vs 1 QUICK MATCH search).
var session_team := {}
var seek_team := 0
## PLAY AGAIN TOGETHER / a team REMATCH asked for on the results (ResultsScreen): {"id", "size",
## "coop"} while this player wants another team match with exactly that player, {} otherwise. The
## results screen sets it on its tap and clears it when it gives up or closes. While it is set, that
## player's fresh (not quick) team invite with that size and coop is shown to the results screen
## (which takes it at once), friend or not (play_again_wanted, _on_team_invite).
var play_again := {}
const QUICK_SEEN_MAX := 64     # seekers remembered by a search (a flood of made-up ids cannot grow it)


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
	relay_rtt = -1
	_pingreq_ms = 0
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
	if load_stall(_frame_ms if _frame_ms >= 0 else now):
		away = 0                 # the gap began while the match loaded: the load, not this phone away
	_frame_ms = now
	away = maxi(away, _away_wall_ms)
	_away_wall_ms = 0
	if away > AWAY_MS and in_session:
		end_session("connection lost")
	if away > KEEP_ALIVE_MS and _ws != null:
		_reconnect()


## Whether a frame gap that began at `since` (the tick clock) is a match loading (LOAD_STALL_MS):
## in a session whose arena did not listen yet, or began listening at most LOAD_STALL_MS before.
func load_stall(since: int) -> bool:
	if not in_session:
		_listen_ms = -1
		return false
	if event_received.get_connections().is_empty():
		_listen_ms = -1
		return true
	if _listen_ms < 0:
		_listen_ms = since           # (it began listening during the frame the gap began after)
	return since - _listen_ms <= LOAD_STALL_MS


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_paused_unix = Time.get_unix_time_from_system()
	elif what == NOTIFICATION_APPLICATION_RESUMED and _paused_unix > 0.0:
		_away_wall_ms = maxi(int((Time.get_unix_time_from_system() - _paused_unix) * 1000.0), 0)
		_paused_unix = 0.0


func _process(delta: float) -> void:
	_check_away(Time.get_ticks_msec())       # before anything in the buffer is read
	if direct != null:
		_tick_direct(delta)
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
	# Every phone hears its own lobby announcement (5 s), the ping's answer (5 s) and in a match
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
		if _pingreq_ms == 0 or Time.get_ticks_msec() - _pingreq_ms > 4 * int(PING_S * 1000.0):
			_pingreq_ms = Time.get_ticks_msec()        # (an answer lost on the way: measure afresh)
		_send_packet(PackedByteArray([0xC0, 0x00]))
	_pong_budget = minf(_pong_budget + delta, 3.0)
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
	# (the other phone said it was loading LOAD_STALL_MS + SILENCE_MS ago at most: its arena's
	# first frames may stall a while longer)
	var wait_ms := SILENCE_MS + (LOAD_STALL_MS if now - _peer_ka_ms < SILENCE_MS + LOAD_STALL_MS else 0)
	if in_session and now - _last_heard > wait_ms:
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
	if in_session and not event_received.get_connections().is_empty():
		# The round trip to the other phone: a numbered ping it answers at once (NetPing). Only
		# once the arena is up on both: a phone that never gets its match loaded must still fall
		# silent after LOAD_KEEP_MS, so the other one stops waiting for it.
		_peer_ping_t -= delta
		if _peer_ping_t <= 0.0:
			_peer_ping_t = PEER_PING_S
			_ping_n += 1
			_peer_pings[_ping_n] = now
			_peer_pings.erase(_ping_n - 4)
			_room_send({"k": "pi", "i": _ping_n})
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


## The WebSocket writes what is queued when it is polled: polling right after the send puts a
## state or a hit on the wire now instead of a frame later.
func _send_packet(p: PackedByteArray) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(p)
		_ws.poll()


func _send_connect() -> void:
	var body := _str("MQTT")
	var login: Array = BROKER_LOGINS.get(String(_brokers[_broker_i]) if not _brokers.is_empty() else "", [])
	# level 4, clean session (0x02) plus user name and password (0xC0) when the relay wants its login, keep-alive 60 s
	body.append_array(PackedByteArray([4, 0xC2 if login.size() == 2 else 0x02, 0, 60]))
	body.append_array(_str("lw" + my_id.left(20)))           # MQTT allows 23-character client ids
	if login.size() == 2:
		body.append_array(_str(String(login[0])))
		body.append_array(_str(String(login[1])))
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
					_ping_t = 0.0                                  # the first ping now: the round trip shows at once
					_subscribe(ROOT + "/u/" + my_id)
					_subscribe(ROOT + "/fr/" + my_id + "/+")      # friend requests waiting for this phone
					_subscribe(ROOT + "/fa/" + my_id + "/+")      # answers to the ones it sent
					_subscribe(ROOT + "/fm/" + my_id + "/+")      # friends' chat messages (NetChat)
					if not (Game.profile.withdrawn as Array).is_empty():
						_send_withdrawals()                        # requests taken back while offline
						Game.save_profile()
					if not _dir_wants.is_empty():
						_subscribe(ROOT + "/p/+")
					_card_t = 0.0                                  # (re)publish this phone's card now
					if _want_lobby:
						_subscribe(ROOT + "/lobby")
						_announce_t = 0.0
					if seeking:
						_subscribe(_seek_topic())
					if _room != "":
						_subscribe(ROOT + "/r/" + _room)
					if room_code != "":
						_subscribe(ROOT + "/c/" + room_code)
				else:
					# The relay refused this phone (a login it no longer takes, or it is full):
					# trying it again cannot help, so the next relay right away (_next_broker).
					_fail_n = maxi(_fail_n, 2)
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
			0xD0:                    # PINGRESP: the relay's round trip
				if _pingreq_ms > 0:
					relay_rtt = NetPing.smooth(relay_rtt, Time.get_ticks_msec() - _pingreq_ms)
					_pingreq_ms = 0


func _on_publish(topic: String, payload: PackedByteArray) -> void:
	if topic.begins_with(ROOT + "/p/"):
		_on_card(topic, payload)
		return
	if topic == SEEK_TOPIC or topic.begins_with(ROOT + "/mm/t"):
		if topic == _seek_topic():          # only the search running here (1 vs 1, or that team size)
			_on_seek(payload)
		return
	if topic.begins_with(ROOT + "/fm/" + my_id + "/"):
		if not payload.is_empty():
			var m: Variant = JSON.parse_string(payload.get_string_from_utf8())
			if m is Dictionary:
				_on_friend_chat(topic.get_slice("/", 4), m)
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
	var new_here := not peers.has(id)
	peers[id] = {"name": who if who != "" else "PLAYER", "bundle": b, "pk": String(d.pk), "seen": Time.get_ticks_msec()}
	if new_here and _want_lobby:
		_announce_t = minf(_announce_t, ANNOUNCE_REPLY_S * randf_range(0.5, 1.0))   # so it sees this phone soon too
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
			if typeof(d.get("quick")) == TYPE_BOOL and bool(d.quick):
				# QUICK MATCH: taken at once from a seeker this search saw (and may play), never
				# shown; any other quick challenge is declined at once.
				answer(seeking and seek_team == 0 and quick_seen.has(from) and _room == "" and challenge_allowed(from, d) and invite_proven(d, from))
				return
			# The host of the custom room this phone asked to join starts the match: it knows the
			# room's password, so it is accepted at once with the room's rules.
			if join_state == "in" and typeof(d.get("rc")) == TYPE_STRING and _crypto.constant_time_compare(
					_room_tag(_join.key, "inv", from).to_utf8_buffer(), String(d.rc).to_utf8_buffer()):
				answer(true, rules_from(d.get("rules")))
				return
			if invited.get_connections().is_empty() or not challenge_allowed(from, d):
				# In a match (no lobby listening), or DUEL CHALLENGES FROM leaves this player out:
				# a polite no at once (not after 25 s), never shown here.
				answer(false)
				return
			invited.emit(String(_incoming.name))
		"tinv":
			_on_team_invite(from, d)
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
			elif not Game.is_blocked(from) and requests_allowed() and not friend_requests.has(from) \
					and friend_requests.size() < Game.MAX_REQUESTS:
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


# ---------------------------------------------------------------- DUO / SQUAD

## A team invite ("tinv", a kind builds before 1.4.0 ignore, so they never take it for a duel): a
## friend into this player's team against bots (coop), or a team QUICK MATCH challenge (quick: each
## player with bot teammates against the other). Like invite(): the other phone's public key wraps
## a fresh room name and the room's keys, and one more byte with the team (team_byte), so the relay
## sees only that one player sent another a team invite; the whole is signed (team_invite_text).
## The session it starts is a 1 vs 1 session (this phone hosts) whose session_team says the team.
## False when it did not go out.
func team_invite(peer_id: String, size: int, coop: bool, quick := false) -> bool:
	if team_byte(size, coop, quick) < 0 or in_session or not _outgoing.is_empty() or not peers.has(peer_id) or not _connected:
		return false
	var pub := CryptoKey.new()
	if pub.load_from_string(String(peers[peer_id].pk), true) != OK:
		return false
	var sec := _crypto.generate_random_bytes(80)
	sec.append(team_byte(size, coop, quick))
	var wrapped := _crypto.encrypt(pub, sec)
	if wrapped.is_empty():
		return false
	var info: Dictionary = peers[peer_id]
	_outgoing = {"id": peer_id, "name": info.name, "bundle": info.bundle, "room": sec.slice(0, 16).hex_encode(),
		"aes": sec.slice(16, 48), "mac": sec.slice(48, 80), "t": Time.get_ticks_msec()}
	is_host = true
	session_rules = {}
	session_team = {"size": size, "coop": coop}
	_enter_room(_outgoing)
	var sec_text := Marshalls.raw_to_base64(wrapped)
	_publish_json(ROOT + "/u/" + peer_id, {"t": "tinv", "from": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "sec": sec_text, "pk": _pk_pem, "sig": _sign(team_invite_text(my_id, peer_id, sec_text))})
	return true


## The byte after a team invite's 80 key bytes: the size (2 or 4) | coop << 3 | quick << 4; -1 for a
## team that cannot be (another size, or a quick challenge into one's own team).
static func team_byte(size: int, coop: bool, quick: bool) -> int:
	if size not in [2, 4] or (coop and quick):
		return -1
	return size | (8 if coop else 0) | (16 if quick else 0)


## The team a team invite's last byte names ({"size", "coop", "quick"}), {} when it names none.
static func team_from_byte(b: int) -> Dictionary:
	var t := {"size": b & 7, "coop": (b & 8) != 0, "quick": (b & 16) != 0}
	return t if b >= 0 and b < 32 and team_byte(int(t.size), bool(t.coop), bool(t.quick)) == b else {}


## What a team invite signs: who sends it, to whom, and the wrapped room keys with the team.
static func team_invite_text(from: String, to: String, sec: String) -> String:
	return "tinv|%s|%s|%s" % [from, to, sec]


## A team invite signed by its sender's key, whose hash is the id it claims (always required).
func team_invite_proven(d: Dictionary, from: String) -> bool:
	for k in ["pk", "sig", "sec"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return false
	return String(d.pk).length() <= 1200 and from == String(d.pk).sha256_text().left(32) \
		and verify_signed(String(d.pk), team_invite_text(from, my_id, String(d.sec)), String(d.sig))


## A "tinv" in this phone's inbox. Unsigned, from a blocked player or naming no team: ignored. Busy
## (in a match, a challenge going out or waiting here): declined at once, as a duel. A quick one is
## taken at once, never shown, only while this phone searches that size (seek_team) and heard that
## seeker, as NetMatch.allowed lets it; any other quick one is declined. Any other one is shown
## (invited, invite_from().team) only when it comes from a friend, or is the play-again this phone's
## results asked for (play_again_wanted: that player, size and coop), from a player this phone
## takes challenges from (NetMatch.allowed), and only while someone listens (the lobby, or the
## results asking for it; in a match nobody does); otherwise declined at once.
func _on_team_invite(from: String, d: Dictionary) -> void:
	if typeof(d.get("sec")) != TYPE_STRING or Game.is_blocked(from) or not team_invite_proven(d, from):
		return
	var sec := _crypto.decrypt(_key, Marshalls.base64_to_raw(String(d.sec)))
	if sec.size() != 81:
		return
	var team := team_from_byte(sec[80])
	if team.is_empty():
		return
	var inv := {"id": from, "room": sec.slice(0, 16).hex_encode(), "aes": sec.slice(16, 48), "mac": sec.slice(48, 80),
		"team": {"size": int(team.size), "coop": bool(team.coop)}}
	if in_session or not _outgoing.is_empty() or not _incoming.is_empty():
		_publish_json(ROOT + "/u/" + from, {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
		return
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	inv.name = who if who != "" else "PLAYER"
	inv.bundle = String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	inv.t = Time.get_ticks_msec()
	_incoming = inv
	if bool(team.quick):
		answer(seeking and seek_team == int(team.size) and quick_seen.has(from) and _room == "" and NetMatch.allowed(from, my_id))
		return
	if not (Game.is_friend(from) or play_again_wanted(from, team)) or not NetMatch.allowed(from, my_id) \
			or invited.get_connections().is_empty():
		answer(false)
		return
	invited.emit(String(_incoming.name))


## Whether a team invite from `from` naming `team` ({"size", "coop", "quick"}) is the play-again
## this phone's results asked for: not quick, from exactly the player in play_again, with its size
## and coop.
func play_again_wanted(from: String, team: Dictionary) -> bool:
	return not play_again.is_empty() and from != "" and String(play_again.get("id", "")) == from \
		and int(play_again.get("size", 0)) == int(team.get("size", -1)) and bool(play_again.get("coop", false)) == bool(team.get("coop", false)) \
		and not bool(team.get("quick", false))


## The team search (TeamMatch): like seek_start(), on the size's own topic ROOT/mm/t<size>, which
## builds before 1.4.0 never listen to (send_seek then publishes there). team_seek_stop() ends it.
func team_seek_start(size: int) -> void:
	if size not in [2, 4]:
		return
	if seeking and _connected:
		_unsubscribe(_seek_topic())
	seek_team = size
	seeking = true
	quick_seen.clear()
	if _connected:
		_subscribe(_seek_topic())


func team_seek_stop() -> void:
	seek_stop()


## The topic the running search uses: the 1 vs 1 seekers', or the team size's.
func _seek_topic() -> String:
	return SEEK_TOPIC if seek_team == 0 else ROOT + "/mm/t%d" % seek_team


# ---------------------------------------------------------------- QUICK MATCH (NetMatch)

## Starts listening to the other searching players (SEEK_TOPIC); seek_stop() ends it.
func seek_start() -> void:
	if seek_team != 0:
		team_seek_stop()               # (a team search running: its topic is left first)
	seeking = true
	quick_seen.clear()
	if _connected:
		_subscribe(SEEK_TOPIC)


func seek_stop() -> void:
	if seeking and _connected:
		_unsubscribe(_seek_topic())
	seeking = false
	seek_team = 0
	quick_seen.clear()


## One short-lived "seek" (not retained): this phone's id and the seekers it saw lately (`saw`),
## so two seekers know they see each other. False while offline.
func send_seek(saw: Array) -> bool:
	if not _connected or my_id == "":
		return false
	_publish_json(_seek_topic(), {"t": "seek", "id": my_id, "saw": saw.slice(0, 8)})
	return true


func _on_seek(payload: PackedByteArray) -> void:
	if not seeking or payload.size() > 1024:
		return
	var d: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not d is Dictionary or String((d as Dictionary).get("t", "")) != "seek" or typeof(d.get("id")) != TYPE_STRING:
		return
	var id := String(d.id).left(32)
	if id == my_id or id == "" or Game.is_blocked(id):
		return                       # never this phone itself, never a blocked player
	var saw: Array = []
	if d.get("saw") is Array:
		for s: Variant in d.saw:
			if typeof(s) == TYPE_STRING:
				saw.append(String(s).left(32))
	if not quick_seen.has(id) and quick_seen.size() >= QUICK_SEEN_MAX:
		var oldest := ""
		for k: String in quick_seen:
			if oldest == "" or int(quick_seen[k]) < int(quick_seen[oldest]):
				oldest = k
		quick_seen.erase(oldest)       # (the one heard longest ago makes room)
	quick_seen[id] = Time.get_ticks_msec()
	seeker_seen.emit(id, saw)


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
	session_team = {}
	_enter_room(_outgoing)
	var sec_text := Marshalls.raw_to_base64(wrapped)
	var msg := {"t": "inv", "from": my_id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle),
		"sec": sec_text, "pk": _pk_pem, "sig": _sign(invite_text(my_id, peer_id, sec_text))}
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
		session_team = {}
		_leave_room()


## DUEL CHALLENGES FROM (setting challenges_from): may this challenge (`d`, from `from`) be shown?
## Everyone, friends only or nobody; the rest are declined at once (the challenger reads
## DECLINED), so a player who wants quiet is never interrupted. FRIENDS ONLY takes a friend's
## challenge only when it proves its sender (invite_proven), so nobody gets through by writing a
## friend's id. A challenge from the custom room this phone asked to join is not one of these: it
## starts the match it asked for.
func challenge_allowed(from: String, d: Dictionary) -> bool:
	var who_may := int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE))
	if who_may == Game.CHALLENGES_EVERYONE:
		return true
	return who_may == Game.CHALLENGES_FRIENDS and Game.is_friend(from) and invite_proven(d, from)


## What a challenge signs: who sends it, to whom, and the wrapped room keys.
static func invite_text(from: String, to: String, sec: String) -> String:
	return "inv|%s|%s|%s" % [from, to, sec]


## A challenge signed by its sender's key, whose hash is the id it claims (builds before this one
## sign none: they reach a player whose challenges are open to everyone).
func invite_proven(d: Dictionary, from: String) -> bool:
	for k in ["pk", "sig", "sec"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return false
	return String(d.pk).length() <= 1200 and from == String(d.pk).sha256_text().left(32) \
		and verify_signed(String(d.pk), invite_text(from, my_id, String(d.sec)), String(d.sig))


## FRIEND REQUESTS (setting friend_requests): off, a request (straight or waiting on the relay) is
## ignored: not listed, not answered, its waiting copy deleted. A friend's own request still gets
## its yes again; the requests already listed stay to be answered.
static func requests_allowed() -> bool:
	return bool(Game.settings.get("friend_requests", true))


func has_invite() -> bool:
	return not _incoming.is_empty()


## Who the challenge waiting for an answer here comes from: {"id", "name", "team"} ({} when none);
## "team" is {} for a duel, {"size", "coop"} for a TEAM INVITE.
func invite_from() -> Dictionary:
	return {} if _incoming.is_empty() else {"id": String(_incoming.id), "name": String(_incoming.name),
		"team": (_incoming.get("team", {}) as Dictionary).duplicate()}


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


## DELETE MY DATA (SettingsAccount): asks the relay to delete what this phone's id left there or
## has waiting there (an empty retained message deletes a kept one): its player card, the friend
## requests and answers it sent and the ones waiting for it, and the last chat message to and from
## each friend; then it leaves the relay (DISCONNECT after them on the same link, which this node
## keeps polling until the relay closes it) and forgets the key and the id here, ending whatever
## was going on (a challenge either way, a custom room, a session). The caller deletes the key file
## with the other saves; the next guest profile makes a new key. Returns whether the relay was
## told: offline, other phones stop listing the card CARD_MAX_AGE_S after it was last refreshed.
func forget_me() -> bool:
	if _keygen != -1:
		WorkerThreadPool.wait_for_task_completion(_keygen)     # a key still being made is never saved
		_keygen = -1
		_keygen_out.clear()
	if in_session:
		end_session("left")
	cancel_invite()
	answer(false)
	if _room != "":
		_leave_room()
	close_room()
	leave_join()
	var told := _connected and my_id != ""
	if told:
		var p: Dictionary = Game.profile
		var gone := {ROOT + "/p/" + my_id: true}
		for id: Variant in (p.friend_out as Dictionary).keys() + (p.withdrawn as Array):
			gone[ROOT + "/fr/" + String(id) + "/" + my_id] = true
			gone[ROOT + "/fa/" + my_id + "/" + String(id)] = true
		for id: Variant in (p.friend_in as Dictionary):
			gone[ROOT + "/fr/" + my_id + "/" + String(id)] = true
		for id: Variant in (p.friends as Dictionary):
			gone[ROOT + "/fa/" + String(id) + "/" + my_id] = true
			gone[ROOT + "/fm/" + String(id) + "/" + my_id] = true
			gone[ROOT + "/fm/" + my_id + "/" + String(id)] = true
		for topic: String in gone:
			_publish(topic, PackedByteArray(), true)
		_send_packet(PackedByteArray([0xE0, 0x00]))
		_connect_t = 0.0             # (the link closes by itself; _process drops it after 8 s at most)
	elif _ws != null:
		_ws.close()
		_ws = null
	_connected = false
	_want_lobby = false
	peers.clear()
	directory.clear()
	_dir_wants.clear()
	_dir_queue.clear()
	_key = null
	_pk_pem = ""
	my_id = ""
	_card_sig = ""
	_card_ts = 0
	relay_rtt = -1
	status = "offline"
	return told


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
	session_team = (inv.get("team", {}) as Dictionary).duplicate()
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


## What a v3 card signs ("sig3"): every v2 field and the career summary (career_text).
static func card3_text(id: String, who: String, bundle: String, avatar: String, banner: String, level: int,
		signature: String, career: String, ts: int) -> String:
	return "card3|%s|%s|%s|%s|%s|%d|%s|%s|%d" % [id, who, bundle, avatar, banner, level, signature, career, ts]


## Everything this phone's card shows besides its id, public key and time: the whole public part
## of the profile (name, outfit, profile picture, name card banner, level, signature line and,
## with SHOW MY CAREER on, the career summary; {} with it off).
static func my_card() -> Dictionary:
	var p: Dictionary = Game.profile
	return {"name": String(p.name), "bundle": String(p.bundle), "avatar": String(p.avatar), "banner": String(p.banner),
		"level": clampi(Game.level(), 1, CARD_LEVEL_MAX), "signature": String(p.signature),
		"career": career_summary(p) if bool(Game.settings.get("show_career", true)) else {}}


const CAREER_KEYS := ["matches", "wins", "kills", "kd", "hs"]

## The career summary a v3 card carries (the CAREER tab's lifetime numbers): matches, wins, kills,
## kd = 100 x kills per death (the kills themselves before the first death, -1 with neither) and
## hs = headshots per hit in % (-1 without a hit), all whole numbers.
static func career_summary(p: Dictionary) -> Dictionary:
	var n := {}
	for k: String in ["matches", "wins", "kills", "deaths", "headshots", "hits"]:
		var v: Variant = p.get(k, 0)
		n[k] = clampi(int(v), 0, Game.COUNTER_MAX) if (v is int or v is float) else 0
	return {"matches": n.matches, "wins": mini(n.wins, n.matches), "kills": n.kills,
		"kd": -1 if n.kills == 0 and n.deaths == 0 else roundi(100.0 * n.kills / maxi(n.deaths, 1)),
		"hs": -1 if n.hits == 0 else clampi(roundi(100.0 * n.headshots / n.hits), 0, 100)}


## A career summary in the signed text: "-" when hidden ({}), else its five numbers.
static func career_text(c: Dictionary) -> String:
	if c.is_empty():
		return "-"
	return "%d,%d,%d,%d,%d" % [int(c.matches), int(c.wins), int(c.kills), int(c.kd), int(c.hs)]


## A card's career summary from untrusted data: {} (hidden) or the five whole numbers in range;
## null when it is anything else (the card is rejected).
static func career_from(v: Variant) -> Variant:
	if not v is Dictionary:
		return null
	var d := v as Dictionary
	if d.is_empty():
		return {}
	if d.size() != CAREER_KEYS.size():
		return null
	var out := {}
	for k: String in CAREER_KEYS:
		var x: Variant = d.get(k)
		if not (x is int or x is float) or float(x) != floorf(float(x)):
			return null
		var lo := -1.0 if k in ["kd", "hs"] else 0.0
		var hi := 100.0 if k == "hs" else float(Game.COUNTER_MAX) * 100.0
		if float(x) < lo or float(x) > hi:
			return null
		out[k] = int(x)
	if int(out.wins) > int(out.matches):
		return null
	return out


## A card's content in one string: a change of any field publishes the card again.
static func card_key(c: Dictionary) -> String:
	return "%s|%s|%s|%s|%d|%s|%s" % [c.name, c.bundle, c.avatar, c.banner, int(c.level), c.signature,
		career_text(c.get("career", {}))]


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


## A signed card as published (`key` is the private key of `pk`; tests make cards with it too): v3
## when `c` has a "career" (my_card always has), else v2.
static func card_json(c: Dictionary, id: String, pk: String, ts: int, key: CryptoKey) -> String:
	var who := String(c.name)
	var b := String(c.bundle)
	var level := int(c.level)
	var d := {"t": "card", "v": 2, "id": id, "name": who, "bundle": b, "avatar": String(c.avatar),
		"banner": String(c.banner), "level": level, "signature": String(c.signature), "pk": pk, "ts": ts,
		"sig": _sign_with(key, card_text(id, who, b, ts)),
		"sig2": _sign_with(key, card2_text(id, who, b, String(c.avatar), String(c.banner), level, String(c.signature), ts))}
	if c.get("career") is Dictionary:
		d.v = 3
		d.career = (c.career as Dictionary).duplicate()
		d.sig3 = _sign_with(key, card3_text(id, who, b, String(c.avatar), String(c.banner), level, String(c.signature),
			career_text(c.career), ts))
	return JSON.stringify(d)


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
	var v3 := float(ver) >= 3.0
	var level := 0
	var career: Variant = {}
	if v3:
		career = career_from(d.get("career"))
		if career == null or typeof(d.get("sig3")) != TYPE_STRING:
			return
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
	if v3:
		if not verify_signed(String(d.pk), card3_text(id, String(d.name), String(d.bundle), String(d.avatar), String(d.banner),
				level, String(d.signature), career_text(career), ts), String(d.sig3)):
			return
	elif v2:
		if not verify_signed(String(d.pk), card2_text(id, String(d.name), String(d.bundle), String(d.avatar), String(d.banner),
				level, String(d.signature), ts), String(d.sig2)):
			return
	elif not verify_signed(String(d.pk), card_text(id, String(d.name), String(d.bundle), ts), String(d.sig)):
		return
	var who := Game.clean_name(String(d.name))
	var avatar := String(d.avatar) if v2 else ""
	var banner := String(d.banner) if v2 else ""
	directory[id] = {"name": who if who != "" else "PLAYER", "bundle": String(CharacterModel.bundle_info(String(d.bundle)).id),
		"pk": String(d.pk), "ts": ts, "v": 3 if v3 else (2 if v2 else 1), "career": career,
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
		elif Game.is_blocked(from) or not requests_allowed():
			_publish(topic, PackedByteArray(), true)     # ignored: deleted unanswered, never shown
		elif not friend_requests.has(from) and friend_requests.size() < Game.MAX_REQUESTS:
			friend_requests[from] = {"name": who if who != "" else "PLAYER", "t": ts}
			Game.save_profile()
			friends_changed.emit()
	else:
		_publish(topic, PackedByteArray(), true)
		if (Game.profile.friend_out as Dictionary).has(from):
			_became_friends(from, who)


# ---------------------------------------------------------------- friends chat (NetChat)

## A chat message to a friend (NetChat): encrypted to their public key, signed, left on the relay
## for them (retained: the last unread one waits while they are offline). "" when it went out,
## else why not: "OFFLINE", "OFF" (FRIENDS CHAT is off), "NOT A FRIEND", "EMPTY", "WAIT" (one a
## second), "NO KEY" (their key is not known yet: it comes with their player card).
func send_friend_chat(id: String, text: String) -> String:
	if not bool(Game.settings.get("friend_chat", true)):
		return "OFF"
	if not Game.is_friend(id) or Game.is_blocked(id):
		return "NOT A FRIEND"
	if not _connected or _key == null:
		return "OFFLINE"
	var line := NetChat.clean(text, NetChat.FRIEND_MAX)
	if line == "":
		return "EMPTY"
	var now := Time.get_ticks_msec()
	if _fchat_ms > 0 and now - _fchat_ms < NetChat.FRIEND_RATE_MS:
		return "WAIT"
	var ts := maxi(int(Time.get_unix_time_from_system()), NetChat.last_sent(id) + 1)
	var d := NetChat.seal(line, my_id, id, ts, friend_key(id), _key, _pk_pem)
	if d.is_empty():
		return "NO KEY"
	_fchat_ms = now
	_publish(ROOT + "/fm/" + id + "/" + my_id, JSON.stringify(d).to_utf8_buffer(), true)
	NetChat.add(id, ts, true, line)
	return ""


## A friend's public key: from the lobby, their player card or their last message.
func friend_key(id: String) -> String:
	if peers.has(id):
		return String(peers[id].pk)
	if directory.has(id):
		return String(directory[id].pk)
	return NetChat.cached_key(id)


## A friend's message that waited for this phone (or came now): checked (NetChat.open_message),
## kept, and deleted from the relay. From anyone who is not a friend, a blocked player, or with
## FRIENDS CHAT off, it is deleted unread.
func _on_friend_chat(from: String, d: Dictionary) -> void:
	if not Game.is_player_id(from) or from == my_id:
		return
	var topic := ROOT + "/fm/" + my_id + "/" + from
	if not Game.is_friend(from) or Game.is_blocked(from) or not bool(Game.settings.get("friend_chat", true)):
		_publish(topic, PackedByteArray(), true)
		return
	if _inbox_budget < 1.0:
		return                       # (it stays on the relay: read at the next connection)
	_inbox_budget -= 1.0
	var line := NetChat.open_message(d, from, my_id, _key, int(Time.get_unix_time_from_system()), NetChat.last_received(from))
	_publish(topic, PackedByteArray(), true)
	if line == "":
		return
	NetChat.cache_key(from, String(d.pk))
	NetChat.add(from, int(d.ts), false, line)
	friend_chat_changed.emit(from)


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
				peer_rtt = -1
				_peer_ping_t = 0.0
				_peer_pings.clear()
				_last_state = []
				_chat_in = [2.0, Time.get_ticks_msec()]
				_chat_out_ms = 0
				queue.clear()
				_direct_begin()
				session_started.emit(is_host)
		"st":
			if _on_state_msg(d as Dictionary):
				relay_states_in += 1
		"dh":
			# The other phone can go direct (DIRECT CONNECTION on there): ours go out once gathered.
			if in_session and direct != null:
				_direct_peer = true
		"dc":
			# Its candidates (checked: real unicast addresses, ports from 1024): punching starts.
			if in_session and direct != null:
				_direct_peer = true
				var list := NetDirect.candidates_from((d as Dictionary).get("c"), direct.local_mode)
				if not list.is_empty():
					direct.set_peer_candidates(list, Time.get_ticks_msec())
		"ka":
			_peer_ka_ms = _last_heard
		"pi":
			# The other phone measures its round trip: answered at once (not a flood of answers).
			var i: Variant = (d as Dictionary).get("i")
			if in_session and (i is float or i is int) and _pong_budget >= 1.0 and not event_received.get_connections().is_empty():
				_pong_budget -= 1.0
				_room_send({"k": "po", "i": int(i)})
		"po":
			var i: Variant = (d as Dictionary).get("i")
			if (i is float or i is int) and _peer_pings.has(int(i)):
				peer_rtt = NetPing.smooth(peer_rtt, Time.get_ticks_msec() - int(_peer_pings[int(i)]))
				_peer_pings.erase(int(i))
		"chat":
			# A chat line: only with CHAT on, never from a blocked player, at most one per
			# NetChat.RATE_S (a short burst of two), cleaned and cut to NetChat.MATCH_MAX.
			var x: Variant = (d as Dictionary).get("x")
			if not in_session or typeof(x) != TYPE_STRING or not bool(Game.settings.get("chat", true)) \
					or Game.is_blocked(String(opponent.get("id", ""))):
				return
			var now := Time.get_ticks_msec()
			var tokens := minf(2.0, float(_chat_in[0]) + float(now - int(_chat_in[1])) / 1000.0 / NetChat.RATE_S)
			_chat_in = [tokens - 1.0 if tokens >= 1.0 else tokens, now]
			var line := NetChat.clean(String(x).left(NetChat.MATCH_MAX * 4), NetChat.MATCH_MAX)
			if tokens >= 1.0 and line != "":
				chat_received.emit(line)
		"vo":
			# Push-to-talk audio (NetVoice): with VOICE CHAT on here, never from a blocked player,
			# at most NetVoice.MAX_FRAMES_S frames a second, each a frame NetVoice can play.
			var a: Variant = (d as Dictionary).get("a")
			if not in_session or typeof(a) != TYPE_STRING or String(a).length() > NetVoice.MAX_B64 \
					or not bool(Game.settings.get("voice_chat", false)) or Game.is_blocked(String(opponent.get("id", ""))):
				return
			var now := Time.get_ticks_msec()
			var tokens := minf(NetVoice.MAX_FRAMES_S, float(_voice_in[0]) + float(now - int(_voice_in[1])) / 1000.0 * NetVoice.MAX_FRAMES_S)
			_voice_in = [tokens - 1.0 if tokens >= 1.0 else tokens, now]
			var frame := Marshalls.base64_to_raw(String(a))
			if tokens >= 1.0 and NetVoice.frame_ok(frame):
				voice_received.emit(frame)
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
	session_team = {}
	peer_rtt = -1
	_peer_pings.clear()
	_outgoing = {}
	_direct_end()
	_leave_room()
	if was:
		session_ended.emit(reason)


## The fighter's state (RemoteFighter.pack) in short numbers: whole values as integers, the
## position to the centimetre, angles to a thousandth of a radian, HP to a tenth; "t" is this
## phone's clock (the other phone draws the fighter from it). A state like the last one goes out
## once more (so the other phone sees it stand still) and then only every STATE_IDLE_MS. At most
## one state goes out a millisecond: a slow frame runs several physics steps back to back, and a
## second state with the same "t" would be thrown away on the other phone (it takes only a newer
## "t", _on_state_msg), so it is not sent at all. Returns whether it went out.
func send_state(s: PackedFloat32Array) -> bool:
	if not in_session:
		return false
	var a := compact_state(s)
	var now := Time.get_ticks_msec()
	if now <= _state_ms:
		return false
	if a == _last_state:
		_same_n += 1
		if _same_n > 1 and now - _state_ms < STATE_IDLE_MS:
			return false
	else:
		_same_n = 0
		_last_state = a
	_state_ms = now
	if direct != null and direct.can_send(now):
		direct.send_state(a, now, now)
	else:
		relay_states_out += 1
		_room_send({"k": "st", "s": a, "t": now})
	return true


## A state from the other phone (the relay's "st" or the direct path's): STATE_SIZE numbers and
## the sender's clock "t". One the other path brought already, or older than the newest taken, is
## dropped. Returns whether it was taken (the arena then applies its own limits).
func _on_state_msg(d: Dictionary) -> bool:
	var s: Variant = d.get("s", [])
	if not in_session or not s is Array or (s as Array).size() != RemoteFighter.STATE_SIZE:
		return false
	var out := PackedFloat32Array()
	for v: Variant in s:
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			return false
		out.append(float(v))
	var t: Variant = d.get("t")
	var sent := int(t) if (t is float or t is int) and is_finite(float(t)) else -1
	if sent >= 0:
		if sent <= _state_in_t:
			return false
		_state_in_t = sent
	last_state_sent_ms = sent
	state_received.emit(out)
	return true


# ---------------------------------------------------------------- the direct path (NetDirect)

## The session started: with DIRECT CONNECTION on (NetDirect.mode) the socket opens and gathering
## starts; a hello ("dh") tells the other phone. Candidates go out only once its hello (or its
## candidates) came, so a phone whose player turned it off never gets this phone's addresses.
func _direct_begin() -> void:
	_direct_end()
	_state_in_t = -1
	relay_states_out = 0
	relay_states_in = 0
	var m := NetDirect.mode()
	if m == "off" or not direct_allowed():
		return
	direct = NetDirect.new(is_host, _mac, m == "local")
	if not direct.open(Time.get_ticks_msec()):
		direct = null
		return
	_direct_sent = false
	_direct_hello_n = 0
	_direct_hello_t = 0.0


## Whether this session's matches may try the direct path: those through the internet relay do. A
## session whose room already runs straight between the phones (a local-network one) returns false,
## so it never asks a STUN server or sends an address.
func direct_allowed() -> bool:
	return true


func _direct_end() -> void:
	if direct != null:
		direct.close()
	direct = null
	_direct_peer = false


func _tick_direct(delta: float) -> void:
	if not in_session or _room == "":
		_direct_end()
		return
	var now := Time.get_ticks_msec()
	if not _direct_peer:
		_direct_hello_t -= delta
		if _direct_hello_t <= 0.0 and _direct_hello_n < 5:
			_direct_hello_t = 2.0
			_direct_hello_n += 1
			_room_send({"k": "dh"})
	if direct.wants_regather(now):
		_direct_sent = false
	if _direct_peer and direct.gathered and not _direct_sent:
		_direct_sent = true
		_room_send({"k": "dc", "c": direct.candidates})
	for d: Dictionary in direct.poll(now, delta):
		_on_state_msg(d)


## Whether the state goes straight to the other phone right now (the match HUD's DIRECT tag).
func direct_up() -> bool:
	return direct != null and direct.can_send(Time.get_ticks_msec())


## How the match state travels, for the tag under the match HUD's ping: "DIRECT" or "RELAY".
func link_tag() -> String:
	return "DIRECT" if direct_up() else "RELAY"


## The relay's round trip while this phone is connected to it, else -1 (the ping chip of a match
## without the other phone: TRAINING GROUND).
func relay_ping() -> int:
	return relay_rtt if _connected else -1


## The match HUD's ping: the direct round trip while that path is up, else the room ping (NetPing).
func match_ping() -> int:
	if direct_up() and direct.rtt >= 0:
		return direct.rtt
	return NetPing.match_ms(peer_rtt, relay_rtt, status == "online")


static func compact_state(s: PackedFloat32Array) -> Array:
	var a := []
	for i in s.size():
		var v := snappedf(s[i], 0.01 if i < 3 else (0.001 if i < 5 else 0.1))
		if v == floorf(v) and absf(v) < 1.0e9:
			a.append(int(v))
		else:
			a.append(v)
	return a


## A chat line in the match (CHAT on, NetChat.clean, at most one per NetChat.RATE_S): "" when it
## went out, else why not ("WAIT" too soon, "OFF", "EMPTY").
func send_chat(text: String) -> String:
	if not in_session:
		return "OFF"
	if not bool(Game.settings.get("chat", true)):
		return "OFF"
	var line := NetChat.clean(text, NetChat.MATCH_MAX)
	if line == "":
		return "EMPTY"
	var now := Time.get_ticks_msec()
	if _chat_out_ms > 0 and now - _chat_out_ms < int(NetChat.RATE_S * 1000.0):
		return "WAIT"
	_chat_out_ms = now
	_room_send({"k": "chat", "x": line})
	return ""


## One push-to-talk frame (NetVoice), sent only while the button is held.
func send_voice(frame: PackedByteArray) -> void:
	if in_session and NetVoice.frame_ok(frame):
		_room_send({"k": "vo", "a": Marshalls.raw_to_base64(frame)})


func send_event(kind: String, data: Array = []) -> void:
	if in_session:
		_room_send({"k": "ev", "e": kind, "d": data})
