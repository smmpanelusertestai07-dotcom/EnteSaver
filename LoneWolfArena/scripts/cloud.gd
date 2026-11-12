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
## phone can draw the fighter a little in the past, smoothly (RemoteFighter); a "bye" ends the
## match ("left"). A bad network or a backgrounded app does not: an opponent silent AWAY_AFTER_MS is
## AWAY (peer_away_changed: its fighter stands frozen on the other phones, which decide its HP) and
## only silent past AWAY_GRACE_MS has it LEFT; a dropped or dead relay link reconnects and
## subscribes the room again with the session, its keys and its counters kept, and this phone away
## (background, screen off, no link) a little less than that grace ends its match as "connection
## lost" (it is the one that dropped out). Back in time, it waits for the other phone's word on its
## fighter (rejoining: the arena's "back" / "sync") before it sends its own states again.
## While a phone loads the match it sends a keep-alive, so a slow load is not taken for leaving.
## The state can take a faster way: with DIRECT CONNECTION on for both players, the two phones open
## a direct UDP path (NetDirect: candidates swapped in the room, hole punching, packets sealed with
## keys derived from the room's) and the state goes over it while it works both ways (direct_up),
## through the relay again after NetDirect.TIMEOUT_MS of silence; everything else stays here.
## Anyone can publish to a public broker, so invites are rate limited and the list is capped. The
## lobby shows names, outfits and public keys only; nothing is stored by the game anywhere but on
## the phone (a live 1 vs 1's sealed session file, so a closed app can rejoin it: see "the session
## file" below).
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
## GROUPS and all-human team matches (design/GROUPS.txt section 3; the lobby uses only these):
signal group_changed                   # members, leader, sides, status or search progress changed
signal group_invited(from_name: String) # a group invite waits: group_invite_from()
signal member_left(id: String)         # an all-human match: that member left (its slot is LEFT)
signal event_from(kind: String, data: Array, from_id: String)      # an all-human match's event, with its sender
signal state_from(state: PackedFloat32Array, from_id: String)      # an all-human match's state, with its sender
signal peer_away_changed(id: String, away: bool)   # a match player fell silent (AWAY_AFTER_MS) / was heard again

const ROOT := "lonewolfarena/v1"
## QUICK MATCH (NetMatch): searching players say so here every SEEK_S, never retained.
const SEEK_TOPIC := ROOT + "/mm/seek"
## The relays, nearest to the players first (every phone settles on the same one, see
## _maybe_return_home). FreeMQTT runs in Mumbai (about 25 ms from Indian networks, measured with
## free public probes on 2026-11-05) and asks for the shared login its operator publishes on its
## home page for everyone (not an account, not a secret). Some networks (public Wi-Fi, offices,
## colleges) let only port 443 out: shiftr.io's public relay listens there, so it comes second
## (checked on 2026-11-05 from a network open only on 443: connected, a retained message relayed
## in 132 ms), then HiveMQ (Frankfurt) and EMQX (Europe / US), and last the TBMQ demo relay, also
## on 443. All are free and need no account.
const BROKERS := ["wss://broker.freemqtt.com:8084/mqtt", "wss://public.cloud.shiftr.io:443/mqtt",
	"wss://broker.hivemq.com:8884/mqtt", "wss://broker.emqx.io:8084/mqtt", "wss://demo.tbmq.io:443/mqtt"]
## Relays that refuse anonymous clients: [user, password], both published by the relay itself for
## everyone (an empty password is left out of CONNECT).
const BROKER_LOGINS := {"wss://broker.freemqtt.com:8084/mqtt": ["freemqtt", "public"],
	"wss://public.cloud.shiftr.io:443/mqtt": ["public", "public"], "wss://demo.tbmq.io:443/mqtt": ["demo", ""]}
## A phone that could not reach the first relay (three tries, or it refused the phone) stays on the
## one it reached for this long before trying the first again when alone there: a network that
## blocks the first relay's port would otherwise keep it offline most of the time.
const HOME_RETRY_MS := 300000
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
## In a match over the relay: a player silent AWAY_AFTER_MS is AWAY (its fighter frozen, the host
## deciding its HP) and has LEFT only after AWAY_GRACE_MS; this phone away (paused, no link) for
## SELF_GRACE_MS has dropped out, a little before the other phone's grace runs out.
const AWAY_AFTER_MS := 3000
const AWAY_GRACE_MS := 90000
const SELF_GRACE_MS := AWAY_GRACE_MS - 1500
## What a phone says while its match loads (keep-alive, the direct link's offer): heard from an
## AWAY phone, these do not bring its fighter back (its arena is not up to report it yet).
const LOAD_KINDS := ["ka", "dh", "dc"]
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
var join_state := ""           # custom room this phone joins: "", "asking", "in", "wrong", "full", "none"
var room_notice := ""          # why this phone is out of the room it joined (KICK, closed, host gone): the lobby says it once
var _room_kicked := {}         # ids this host KICKed from its room: never let in again while it is open
var _brokers: Array = BROKERS
var _broker_i := 0
var _fail_n := 0               # failed connects in a row on the current broker
var _home_bad_ms := -1         # when the first relay last failed this phone (may_return_home), -1 never
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
var _last_live := 0             # the last message from the other phone that its arena is up (LOAD_KINDS aside)
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
var _absent := false           # in a match: this phone is away from it (paused, no link) since _absent_ms
var _absent_ms := 0            # (tick clock; it may be below 0 for an absence that began before the app did)
var _rejoin := false           # back from an absence: the arena waits for the other phone's "sync"
var _away_ids := {}            # match players taken for AWAY now (id -> true)
var _back_ms := 0              # when this phone, absent, heard the match again (the "sync" is waited for a while)
const REJOIN_WAIT_MS := 6000   # back in a match, states wait this long at most for the other phone's "sync"
var _grace_override := 0       # LW_AWAY_GRACE_MS (checks only, never in a release build): grace_ms()
## Rejoining after the app was closed (see "the session file" below).
const RESUME_V := 1
const SEQ_RESERVE := 2000      # the counter the file keeps runs this far ahead of the one in use
const RESUME_SAVE_MS := 3000   # the file's "last in the match" time is this fresh at worst
var resumed := false           # this session was entered again from the file after a restart
var resume_note := {}          # the arena's note on the match: {"counted", "mine", "theirs", "mode"} (note_match)
var _seq_kept := 0             # the counter the file holds: this phone's counter stays below it
var _resume_save_ms := -100000 # when the file was last written (the tick clock)
var _in_match_unix := 0.0      # the wall-clock time this phone was last in its match (present)
var _resume_emit := false      # a session entered from the file: session_started once the relay is up
var _resume_wait := false      # ... and its arena waits for the other phone's "sync" however long it takes (the grace ends it)
## A session entered from the file that ended before its arena was up: what the lobby (or the
## arena that found it gone) says about it, [title, text], or [] (LEAVE MATCH: nothing to say).
var rejoin_notice: Array = []
var _resume_off := false       # this session's result is in the profile: no file for it any more (match_recorded)
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

## GROUPS (design/GROUPS.txt): up to GROUP_MAX players in the lobby, one of them the LEADER, in the
## group's own end-to-end encrypted room ROOT/g/<gid> (the match room's packets with the group's
## keys, a counter per sender). `group` is {} or {"gid", "leader", "members": [{"id", "name",
## "bundle", "team", "slot"}] (leader first, join order; NetGroup's slots), "status" ("joining",
## "idle", "searching", "starting", "in_match"), "mode", "size"}; only the leader's "groster" is
## the truth for the others. search_found / search_needed: the humans gathered for the match the
## leader's START searches for (0 needed: no search). An all-human match (session_multi) is a
## session in which every member sends: session_roster [{"slot", "id", "name", "bundle", "team"}]
## in slot order, session_host_id the phone that referees (the leader that started it).
const GROUP_MAX := NetGroup.MAX
const GROUP_BEAT_S := 3.0             # the leader's roster and each member's beat
const GROUP_TIMEOUT_MS := 12000       # a member (or the leader) silent this long has left the group
const GROUP_RATE := 6.0               # group room messages taken per second and sender (burst 12)
const MULTI_RATE := 120.0             # match room messages taken per second and member (states, events)
var group := {}
var search_found := 0
var search_needed := 0
var session_multi := false
var session_roster: Array = []
var session_host_id := ""
var _grp := {}                 # the group's keys and bookkeeping: gid, aes, mac, seq, their, seen, invited, ...
var _ginv := {}                # the group invite waiting here: {"id", "name", "bundle", "gid", "room", "aes", "mac", "size", "t"}
var _multi := {}               # the all-human match: ids (id -> slot), seq, heard, ka, joined, left, state_t, t0
var _buckets := {}             # token buckets per sender (group and match rooms): key -> [tokens, ms]


func _ready() -> void:
	name = "Cloud"
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.has_feature("template") and OS.get_environment("LW_MQTT_URL") != "":
		_brokers = [OS.get_environment("LW_MQTT_URL")]      # tests: a local broker
	if not OS.has_feature("template") and OS.get_environment("LW_AWAY_GRACE_MS").is_valid_int():
		_grace_override = maxi(int(OS.get_environment("LW_AWAY_GRACE_MS")), AWAY_AFTER_MS + 2000)    # tests only


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
	if not in_session and _outgoing.is_empty() and _room == "" and _grp.is_empty() and _ws != null:
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
	if _fail_n >= 3 and not in_session:      # (a match stays on its relay: the other phone is there)
		if _broker_i == 0 and _brokers.size() > 1:
			_home_bad_ms = Time.get_ticks_msec()        # (the first relay is out of reach from here for now)
		_broker_i = (_broker_i + 1) % _brokers.size()
		_fail_n = 0
	_retry_t = 2.0
	status = "offline"


## Drops a connection that went dead without closing and connects again soon; a match going on
## goes on (its room is subscribed again on the CONNACK, keys and counters kept): this phone is away
## from it meanwhile (_note_absent).
func _reconnect() -> void:
	if in_session:
		_note_absent(_last_rx_ms)
	if _ws != null:
		_ws.close()
	_ws = null
	_connected = false
	_rx.clear()
	status = "offline"
	_retry_t = 0.5


## Once a frame (now: the tick clock): how long this phone was gone since the last frame, the gap
## on the tick clock or an app pause measured on the wall clock (the tick clock stops while the
## phone sleeps). Away a while in a match, this phone was absent (_note_absent): it asks for the
## match's state when back. Absent about as long as the other phone waits (self_grace_ms), it is
## this phone that dropped out of the match (the other may have ended it by now): whatever waits in
## its buffer (old states, the other's "bye") must not say otherwise. Away longer than the
## keep-alive, its link is gone too.
func _check_away(now: int) -> void:
	var away := now - _frame_ms if _frame_ms >= 0 else 0
	if load_stall(_frame_ms if _frame_ms >= 0 else now):
		away = 0                 # the gap began while the match loaded: the load, not this phone away
	_frame_ms = now
	away = maxi(away, _away_wall_ms)
	_away_wall_ms = 0
	if in_session and away > AWAY_AFTER_MS / 2:
		_note_absent(now - away)
	if in_session and _absent and now - _absent_ms > self_grace_ms():
		end_session("connection lost")
	if away > KEEP_ALIVE_MS and _ws != null:
		_reconnect()


## How long the other phone waits for a silent one in a match (Lan: SILENCE_MS, its socket closes),
## and how long this phone may be away from one before it has dropped out.
## Checks can shorten that grace (LW_AWAY_GRACE_MS, read only outside a release build) so that an
## absence past it takes seconds; this phone's own grace stays 1.5 s shorter than the other's.
func grace_ms() -> int:
	return _grace_override if _grace_override > 0 else AWAY_GRACE_MS


func self_grace_ms() -> int:
	return grace_ms() - (AWAY_GRACE_MS - SELF_GRACE_MS)


## This phone is away from its match since `since` (tick clock): paused, or its link dropped. Back,
## it rejoins: the arena asks for the match's state ("back") and holds its states until it came.
func _note_absent(since: int) -> void:
	if not in_session:
		return
	_absent_ms = mini(_absent_ms, since) if _absent else since     # (away at least that long)
	_absent = true
	_rejoin = true


## Whether this phone is back from an absence and waits for the other phone's word ("sync").
func rejoining() -> bool:
	return in_session and _rejoin and (_absent or _resume_wait or Time.get_ticks_msec() - _back_ms < REJOIN_WAIT_MS)


## This phone hears its match again (the other phone, or an all-human match's host).
func _present(now: int) -> void:
	if _absent:
		_absent = false
		_back_ms = now


func rejoined() -> void:
	_rejoin = false
	_resume_wait = false


## Whether that match player is AWAY now (peer_away_changed).
func peer_is_away(id: String) -> bool:
	return _away_ids.has(id)


## A player of this match was heard (away false) or has been silent AWAY_AFTER_MS (true). Only a
## phone that is there itself takes another for away (an absent one hears nobody).
func _set_away(id: String, away: bool) -> void:
	if id == "" or away == _away_ids.has(id) or (away and (_absent or not _arena_listens())):
		return
	if away:
		_away_ids[id] = true
	else:
		_away_ids.erase(id)
	peer_away_changed.emit(id, away)


## A number both phones of this match get, and nobody else (an HMAC of `what` with the room's key):
## the seed of what must come out the same on both (the safe zone's centre each round).
func match_seed(what: String) -> int:
	var d := _crypto.hmac_digest(HashingContext.HASH_SHA256, _mac if not _mac.is_empty() else PackedByteArray([0]),
		(_room + "/" + what).to_utf8_buffer())
	return d.decode_s64(0) if d.size() >= 8 else 0


## The session (re)starts: nobody away.
func _reset_away() -> void:
	_absent = false
	_rejoin = false
	_away_ids.clear()


## Whether a frame gap that began at `since` (the tick clock) is a match loading (LOAD_STALL_MS):
## in a session whose arena did not listen yet, or began listening at most LOAD_STALL_MS before.
func load_stall(since: int) -> bool:
	if not in_session:
		_listen_ms = -1
		return false
	if not _arena_listens():
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
	if in_session and not _absent and _seq_kept > 0:
		_in_match_unix = Time.get_unix_time_from_system()
		if Time.get_ticks_msec() - _resume_save_ms > RESUME_SAVE_MS:
			_save_resume()
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
			_note_absent(_last_rx_ms)        # (the match goes on: this phone connects again, AWAY meanwhile)
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
	# away (it connects again), not the other one leaving.
	if Time.get_ticks_msec() - _last_rx_ms > (AWAY_MS if in_session else QUIET_MS):
		_reconnect()
		return
	if _broker_i != 0 and not in_session and _room == "" and room_code == "" and _outgoing.is_empty() \
			and _join.is_empty() and peers.is_empty() and may_return_home(Time.get_ticks_msec(), _home_bad_ms):
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
	if not _grp.is_empty():
		_tick_group(delta, Time.get_ticks_msec())
	_tick_code(delta, Time.get_ticks_msec())
	if not _mm.is_empty():
		_tick_mm(delta, Time.get_ticks_msec())
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
	var wait_ms := grace_ms() + (LOAD_STALL_MS if now - _peer_ka_ms < SILENCE_MS + LOAD_STALL_MS else 0)
	if in_session and session_multi:
		_check_members(now)
	elif in_session:
		# (an AWAY phone stays so while it only says it is loading: LOAD_KINDS)
		var opp := String(opponent.get("id", ""))
		_set_away(opp, now - (_last_live if _away_ids.has(opp) else _last_heard) > AWAY_AFTER_MS)
	if in_session and now - _last_heard > wait_ms:
		end_session("left")
	if not _ginv.is_empty() and now - int(_ginv.t) > INVITE_TIMEOUT_MS:
		_ginv = {}
		group_changed.emit()
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
			if not (session_multi and is_host):
				_room_send({"k": "join"})
		# An all-human match whose members do not all say "join" in time: the host starts with those
		# that did (the others are LEFT at once), a member gives up on a host that never answers.
		if session_multi:
			if now - int(_multi.t0) > JOIN_TIMEOUT_MS:
				if is_host and not (_multi.joined as Dictionary).is_empty():
					_multi_start()
				else:
					_multi_abort()
		# A challenge accepted here whose room handshake never completes (the challenger went
		# away right after): give up, so the popup does not wait for ever.
		elif _accept_ms > 0 and now - _accept_ms > JOIN_TIMEOUT_MS:
			var who := String(opponent.get("name", "PLAYER"))
			_leave_room()
			invite_failed.emit(who)
	elif in_session and not _arena_listens() and now - _session_ms < LOAD_KEEP_MS:
		# The match is loading here (the arena listens once it is up): a keep-alive every second,
		# so the other phone does not take a slow load for leaving.
		_keep_t -= delta
		if _keep_t <= 0.0:
			_keep_t = 1.0
			_room_send({"k": "ka"})
	if in_session and _arena_listens() and not (session_multi and is_host):
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
	# level 4, keep-alive 60 s; the flags: clean session plus the relay's login (connect_flags)
	body.append_array(PackedByteArray([4, connect_flags(login), 0, 60]))
	body.append_array(_str("lw" + my_id.left(20)))           # MQTT allows 23-character client ids
	if login.size() == 2 and String(login[0]) != "":
		body.append_array(_str(String(login[0])))
		if String(login[1]) != "":
			body.append_array(_str(String(login[1])))
	_send_packet(_packet(0x10, body))
	_sent_connect = true


## CONNECT's flags for a relay's login ([user, password] or none): clean session (0x02), a user
## name (0x80) when there is one, a password (0x40) only with a user name and when not empty.
static func connect_flags(login: Array) -> int:
	var f := 0x02
	if login.size() == 2 and String(login[0]) != "":
		f |= 0x80
		if String(login[1]) != "":
			f |= 0x40
	return f


## Whether a phone alone on a backup relay goes back to the first now: not within HOME_RETRY_MS of
## the first one failing it (home_bad_ms: when it last did, -1 never).
static func may_return_home(now: int, home_bad_ms: int) -> bool:
	return home_bad_ms < 0 or now - home_bad_ms > HOME_RETRY_MS


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
					if _resume_emit:
						_resume_emit = false
						session_started.emit.call_deferred(is_host)     # (the lobby loads the arena)
					if not _grp.is_empty():
						_subscribe(ROOT + "/g/" + String(_grp.gid))
					if not _mm.is_empty():
						_subscribe(_mm_topic())
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
	if topic.begins_with(ROOT + "/mm/g"):
		if not _mm.is_empty() and topic == _mm_topic():
			_on_gseek(payload)
		return
	if topic.begins_with(ROOT + "/gc/"):
		if _code_topic != "" and topic == _code_topic:
			var ca: Variant = JSON.parse_string(payload.get_string_from_utf8())
			if ca is Dictionary:
				_on_code_ask(ca)
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
	elif not _grp.is_empty() and topic == ROOT + "/g/" + String(_grp.gid):
		_on_group(payload)
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
			if in_session or session_multi or not _outgoing.is_empty() or not _incoming.is_empty():
				_publish_json(ROOT + "/u/" + from, {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
				return
			var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
			inv.name = who if who != "" else "PLAYER"
			inv.bundle = String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
			inv.t = Time.get_ticks_msec()
			_incoming = inv
			if typeof(d.get("quick")) == TYPE_BOOL and bool(d.quick):
				# QUICK MATCH: taken at once from a seeker this search saw (and may play), never
				# shown; any other quick challenge is declined at once, and so is every one while a
				# GROUP INVITE waits for this player's answer (a friend's duel challenge waiting
				# already declines it above).
				inv.quick = true
				answer(seeking and seek_team == 0 and quick_seen.has(from) and _room == "" and _ginv.is_empty()
					and challenge_allowed(from, d) and invite_proven(d, from))
				return
			# The host of the custom room this phone asked to join starts the match: it knows the
			# room's password, so it is accepted at once with the room's rules.
			if join_state == "in" and typeof(d.get("rc")) == TYPE_STRING and _crypto.constant_time_compare(
					_room_tag(_join.key, "inv", from).to_utf8_buffer(), String(d.rc).to_utf8_buffer()):
				answer(true, rules_from(d.get("rules")))
				return
			# The leader of this phone's group of two starts a DUEL (group_duel): taken at once from
			# the leader, and only with the group's own tag over it.
			if typeof(d.get("gd")) == TYPE_STRING and in_group() and not in_room() and from == String(group.leader) \
					and _crypto.constant_time_compare(group_duel_tag(from).to_utf8_buffer(), String(d.gd).to_utf8_buffer()) \
					and invite_proven(d, from):
				answer(true)
				return
			if invited.get_connections().is_empty() or not challenge_allowed(from, d):
				# In a match (no lobby listening), or DUEL CHALLENGES FROM leaves this player out:
				# a polite no at once (not after 25 s), never shown here.
				answer(false)
				return
			invited.emit(String(_incoming.name))
		"tinv":
			_on_team_invite(from, d)
		"ginv":
			_on_group_invite(from, d)
		"gmatch":
			if not Game.is_blocked(from):
				_on_gmatch(from, d)
		"gacc":
			_on_gmatch_answer(from, d, true)
		"gin", "gno":
			_on_code_answer(from, d)
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
			elif not _grp.is_empty() and (_grp.invited as Dictionary).has(from) \
					and _tagged(d, {"mac": _grp.mac, "room": _grp.gid}, "dec", from):
				(_grp.invited as Dictionary).erase(from)      # a group invite declined (or busy there)
				group_changed.emit()
			else:
				_on_gmatch_answer(from, d, false)             # a unit did not take the host's match
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
				var state := "in" if String(d.t) == "rin" else ("full" if typeof(d.get("full")) == TYPE_BOOL and bool(d.full) else "wrong")
				_join.t = Time.get_ticks_msec()
				if state == "in" and typeof(d.get("sec")) == TYPE_STRING:
					_room_enter(from, d)        # a room with slots: its group's keys
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
	if team_byte(size, coop, quick) < 0 or in_session or session_multi or not _outgoing.is_empty() or not peers.has(peer_id) or not _connected:
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
	if in_session or session_multi or not _outgoing.is_empty() or not _incoming.is_empty():
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


## Challenges a listed player: its public key wraps a fresh room name and the room's keys. A
## QUICK MATCH challenge (extra "quick") never goes out while a challenge or a group invite waits
## for this player's answer (answer_waiting): the popup's ACCEPT would enter the friend's room over
## it and leave the stranger waiting alone.
func invite(peer_id: String, extra := {}) -> bool:
	if in_session or session_multi or not _outgoing.is_empty() or not peers.has(peer_id) or not _connected:
		return false
	if bool(extra.get("quick", false)) and answer_waiting():
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


## True while a duel challenge, a TEAM INVITE or a GROUP INVITE waits for this player's answer (a
## popup is up): QUICK MATCH neither challenges nor takes a quick challenge meanwhile (NetMatch).
func answer_waiting() -> bool:
	return not _incoming.is_empty() or not _ginv.is_empty()


## Who the challenge waiting for an answer here comes from: {"id", "name", "team"} ({} when none);
## "team" is {} for a duel, {"size", "coop"} for a TEAM INVITE.
func invite_from() -> Dictionary:
	return {} if _incoming.is_empty() else {"id": String(_incoming.id), "name": String(_incoming.name),
		"team": (_incoming.get("team", {}) as Dictionary).duplicate()}


func waiting_for() -> String:
	return String(_outgoing.get("name", ""))


## The id of the player this phone's challenge or team invite waits for ("" when none).
func waiting_for_id() -> String:
	return String(_outgoing.get("id", ""))


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
	if String(_ginv.get("id", "")) == id:
		_ginv = {}
		group_changed.emit()
	if not group.is_empty() and _group_has(id):
		if String(group.leader) == id:
			leave_group()              # (the group's leader blocked: this phone leaves it)
		elif is_group_leader():
			kick_from_group(id)


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
	answer_group_invite(false)
	leave_group()
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
	if seeking and seek_team == 0 and not bool(inv.get("quick", false)):
		seek_stop()                      # a friend's challenge taken ends the QUICK MATCH search (NetMatch sees it)
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


# ---------------------------------------------------------------- the session file (rejoining)
# A 1 vs 1 over the relay survives the app being closed (swiped away, killed by the system): its
# session lives in one file (resume_path) from its start to its end, whatever ends it. It holds
# what entering the room again needs: the relay, the room and its two keys, the opponent, who
# hosts, the custom room's rules, this phone's counter (SEQ_RESERVE ahead of the one in use, so a
# restart never repeats one without a write per message), the other's counter (replays stay
# dropped), the arena's note (counted, score, mode: note_match) and the wall-clock time this phone
# was last in the match (written every RESUME_SAVE_MS). At rest it is sealed as the room packets
# are (AES-256-CBC + HMAC-SHA256) with keys derived from this install's private identity key and
# this player's id; a file that fails its check, or holds another id, is deleted and ignored.
# Opened again (try_resume, from the lobby) less than self_grace_ms after that time, the session is
# entered as it was, this phone away from it: the lobby shows REJOINING MATCH... and loads the
# arena once the relay is up (session_started), the arena asks for the match ("back") and enters it
# where the other phone's "sync" says it stands. Too late, the match counts as LEFT (once: it was
# counted when its first fight began). DUO / SQUAD and all-human matches, and PLAY WITHOUT
# INTERNET (resume_allowed), keep no file.

## The file (each test role keeps its own, as with the identity key).
static func resume_path() -> String:
	var role := OS.get_environment("LW_NET_ROLE") if not OS.has_feature("template") else ""
	return "user://match_resume%s.bin" % ("_" + role if role != "" else "")


## Whether the app is in the background now (paused, not yet resumed). Android closes a paused app
## by tearing its scene down: the match's arena then leaves the tree with the app, and must not end
## the session (no "bye", the file kept), so that it can be rejoined.
func app_paused() -> bool:
	return _paused_unix > 0.0


## Whether this service's sessions can be entered again after a restart (Lan: no).
func resume_allowed() -> bool:
	return true


## The file's two keys [aes, mac]: HMAC-SHA256 of this install's private key with a label and the id.
func _resume_keys() -> Array:
	var base := _key.save_to_string(false).to_utf8_buffer()
	return [_crypto.hmac_digest(HashingContext.HASH_SHA256, base, ("match-file-aes/" + my_id).to_utf8_buffer()),
		_crypto.hmac_digest(HashingContext.HASH_SHA256, base, ("match-file-mac/" + my_id).to_utf8_buffer())]


## Writes the live session to the file (a 1 vs 1 over the relay only), atomically.
func _save_resume() -> void:
	if _resume_off or not in_session or session_multi or not session_team.is_empty() or not resume_allowed() or _key == null or _room == "":
		return
	_resume_save_ms = Time.get_ticks_msec()
	_seq_kept = _seq + SEQ_RESERVE
	var d := {"v": RESUME_V, "me": my_id, "relay": String(_brokers[_broker_i]), "room": _room,
		"aes": Marshalls.raw_to_base64(_aes), "mac": Marshalls.raw_to_base64(_mac), "opp": opponent.duplicate(),
		"host": is_host, "rules": session_rules.duplicate(), "seq": _seq_kept, "their": _their_seq,
		"t": _in_match_unix, "note": resume_note.duplicate()}
	var k := _resume_keys()
	var tmp := resume_path() + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(_seal(d, my_id, 0, k[0], k[1]))
	f.close()
	DirAccess.rename_absolute(tmp, resume_path())


## The session is over (or never to be entered again): the file goes.
func clear_resume() -> void:
	_seq_kept = 0
	if FileAccess.file_exists(resume_path()):
		DirAccess.remove_absolute(resume_path())


## The match's result is in the profile (its results, or QUIT MATCH's LEFT): the file goes and is
## not written again for this session, so closing the app on the results screen records nothing
## more later (no LEFT on top of the result), and opening it again never rejoins a match that is over.
func match_recorded() -> void:
	_resume_off = true
	clear_resume()


## The arena's note on its match, kept in the file: whether it was counted, the score (this
## phone's rounds, the other's) and the mode's name (a LEFT recorded without the arena needs them).
func note_match(counted: bool, mine: int, theirs: int, mode: String) -> void:
	resume_note = {"counted": counted, "mine": mine, "theirs": theirs, "mode": mode}
	_save_resume()


## The file, opened and checked: what it holds, or {} (none; one that fails its check is deleted).
func load_resume() -> Dictionary:
	if _key == null or not resume_allowed() or not FileAccess.file_exists(resume_path()):
		return {}
	var k := _resume_keys()
	var d := _unseal(FileAccess.get_file_as_bytes(resume_path()), k[0], k[1])
	var ok := not d.is_empty() and String(d.get("f", "")) == my_id and String(d.get("me", "")) == my_id \
		and int(d.get("v", 0)) == RESUME_V and typeof(d.get("room")) == TYPE_STRING and String(d.room).length() == 32 \
		and String(d.room).is_valid_hex_number() and typeof(d.get("aes")) == TYPE_STRING and typeof(d.get("mac")) == TYPE_STRING \
		and typeof(d.get("relay")) == TYPE_STRING and d.get("opp") is Dictionary and typeof((d.opp as Dictionary).get("id")) == TYPE_STRING \
		and (d.get("seq") is float or d.get("seq") is int) and (d.get("their") is float or d.get("their") is int) \
		and (d.get("t") is float or d.get("t") is int) and d.get("host") is bool and d.get("note") is Dictionary
	if ok:
		ok = Marshalls.base64_to_raw(String(d.aes)).size() == 32 and Marshalls.base64_to_raw(String(d.mac)).size() == 32
	if not ok:
		clear_resume()
		return {}
	return d


## How long this phone may still take to come back to the match the file holds (ms; <= 0: too late).
func resume_left_ms(d: Dictionary) -> int:
	return self_grace_ms() - int((Time.get_unix_time_from_system() - float(d.get("t", 0.0))) * 1000.0)


## At start, once the game can go online (the lobby): a session in the file is entered again
## (true: the lobby shows REJOINING MATCH... and session_started follows once the relay is up). Too
## late for it, the match counts as LEFT if it was counted, and the file goes.
func try_resume() -> bool:
	if in_session or _room != "":
		return false
	var d := load_resume()
	if d.is_empty():
		return false
	resume_note = (d.note as Dictionary).duplicate()
	_resume_off = false
	rejoin_notice = []
	opponent = d.opp
	var left := resume_left_ms(d)
	if left <= 0:
		_record_resume_left()
		opponent = {}
		resume_note = {}
		clear_resume()
		return false
	var i := _brokers.find(String(d.relay))
	if i >= 0 and i != _broker_i:
		_broker_i = i                # the relay the other phone is on
		if _ws != null:
			_ws.close()
			_ws = null
			_connected = false
			_retry_t = 0.0
	var now := Time.get_ticks_msec()
	var o: Dictionary = d.opp
	opponent = {"id": String(o.id), "name": String(o.get("name", "PLAYER")), "bundle": String(o.get("bundle", "default"))}
	_room = String(d.room)
	_aes = Marshalls.base64_to_raw(String(d.aes))
	_mac = Marshalls.base64_to_raw(String(d.mac))
	_seq = int(d.seq)
	_seq_kept = _seq
	_their_seq = int(d.their)
	is_host = bool(d.host)
	var rr: Variant = d.get("rules")
	session_rules = rules_from(rr) if rr is Dictionary and not (rr as Dictionary).is_empty() else {}
	session_team = {}
	_outgoing = {}
	in_session = true
	resumed = true
	_reset_away()
	_absent = true                   # away from the match since the file's time, back once heard
	_absent_ms = now - (self_grace_ms() - left)
	_rejoin = true
	_resume_wait = true
	_in_match_unix = float(d.t)
	_accept_ms = 0
	_session_ms = now
	_keep_t = 0.0
	peer_rtt = -1
	_peer_ping_t = 0.0
	_peer_pings.clear()
	_last_state = []
	_chat_in = [2.0, now]
	_chat_out_ms = 0
	_last_heard = now
	queue.clear()
	_direct_begin()
	if _connected:
		_subscribe(ROOT + "/r/" + _room)
		session_started.emit.call_deferred(is_host)
	else:
		_resume_emit = true
	return true


## A match entered from the file that ends before its arena is up (too late, LEAVE MATCH, lost
## again): counted when its first fight began, it goes into the profile as QUIT MATCH puts it.
func _record_resume_left() -> void:
	if not bool(resume_note.get("counted", false)):
		return
	resume_note.counted = false
	Game.record_match({"won": false, "draw": false, "left": true, "invalid": false, "kills": 0, "damage": 0, "headshots": 0,
		"accuracy": 0.0, "time": 0.0, "xp": 0, "enemy": String(opponent.get("name", "PLAYER")), "mode": String(resume_note.get("mode", "")),
		"mode_id": "lonewolf", "map": "", "weapon": "", "score_player": int(resume_note.get("mine", 0)),
		"score_bot": int(resume_note.get("theirs", 0)), "hp_left": 0, "difficulty": "ONLINE", "taken": 0, "shots": 0, "hits": 0,
		"deaths": 0, "enemy_id": String(opponent.get("id", "")), "local": false, "opponent_left": false})


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
## CUSTOM ROOM WITH SLOTS: the room is a GROUP (its own group room and keys, this phone its leader:
## the HOST) whose players joined by the code and password instead of an invite. size: the mode the
## host picked, SOLO 1 (2 places: 1 VS 1), DUO 2 (4: 2 VS 2), SQUAD 4 (8: 4 VS 4), the places in
## BLUE / ORANGE (NetGroup.places with room). A player with the right password ("ask", tagged with
## the password's key) gets the group's keys RSA-wrapped for their own key in "rin" (tagged too, so
## only a phone that knows the password could send it), then says "gjoin" in the group room and
## takes the first free place (the team with fewer players). Only the host's roster ("groster")
## counts; a player asks for an empty place with "gslot" (room_take); the host's KICK is the
## group's "gkick" (that id is never let in again while the room is open). START (room_start, the
## host's only): SOLO is the 1 vs 1 with the room's rules, DUO / SQUAD the all-human match of the
## players in their places (uneven teams allowed, empty places stay empty: never a bot).
func open_room(pin: String, rules: Dictionary, code := "", size := 1) -> String:
	close_room()
	var r := _crypto.generate_random_bytes(4)
	room_code = code if code.length() == 6 and code.is_valid_int() and not OS.has_feature("template") \
		else "%06d" % (r.decode_u32(0) % 1000000)
	room_pin = pin
	room_rules = rules_from(rules)
	room_guest = {}
	_room_kicked = {}
	if my_id != "" and not in_session and not session_multi:
		if not group.is_empty():
			_group_close(true)            # (a room is its own group: a group this phone was in is left)
		_group_create(size if size in [1, 2, 4] else 1)
		group.room = room_code
		_grp.manual = true
		NetGroup.arrange(group.members, int(group.size), true, true)
	if _connected:
		_subscribe(ROOT + "/c/" + room_code)
	room_changed.emit()
	group_changed.emit()
	return room_code


func close_room() -> void:
	if room_code != "" and _connected:
		_unsubscribe(ROOT + "/c/" + room_code)
	var was_room := in_room() and String(group.leader) == my_id
	room_code = ""
	room_guest = {}
	if was_room:
		_group_close(true)                # "gend": every player in the room hears it is closed
		group_changed.emit()


## In a CUSTOM ROOM's group: hosting it, or joined to it by its code.
func in_room() -> bool:
	return not _grp.is_empty() and String(group.get("room", "")) != ""


## The room host's START (only the host's works). SOLO: the 1 vs 1 with the room's rules
## (start_room_match). DUO / SQUAD: the all-human match of the players in their places
## (_group_launch: "gstart" to every player), uneven teams allowed, empty places staying empty.
## "" when it goes, else the notice to show.
func room_start() -> String:
	if not in_room() or String(group.leader) != my_id:
		return "ONLY THE HOST CAN START"
	if in_session or session_multi or not _outgoing.is_empty():
		return "A MATCH IS ALREADY STARTING"
	if not _connected:
		return "OFFLINE: THE MATCH NEEDS THE INTERNET"
	var size := int(group.size)
	if size == 1:
		return "" if start_room_match() else "WAITING FOR A PLAYER"
	if NetGroup.plan(group.members, size) != "match":
		return "BOTH TEAMS NEED A PLAYER"
	_group_launch(size)
	return ""


## A tap on an empty place of the room (team 0 BLUE / 1 ORANGE, place 0..): the host takes it at
## once; a player asks the host ("gslot") and its roster then shows the move. False outside a room
## (or still joining it) or when the place is not a free one.
func room_take(team: int, place: int) -> bool:
	if not in_room() or bool(_grp.joining) or place < 0:
		return false
	var size := int(group.size)
	var slot := team * NetGroup.per_team(size) + place
	if String(group.leader) == my_id:
		if not NetGroup.take_empty(group.members, my_id, team, slot, size):
			return false
		_group_roster()
		group_changed.emit()
		return true
	if not NetGroup.take_empty((group.members as Array).duplicate(true), my_id, team, slot, size):
		return false
	_group_send({"k": "gslot", "t": team, "s": slot})
	return true


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
	room_notice = ""
	room_changed.emit()


## Stops joining; a player in the room's group leaves it ("gleave").
func leave_join() -> void:
	_join = {}
	join_state = ""
	if in_room() and String(group.leader) != my_id:
		_group_close(true)
		group_changed.emit()


## A joiner: the host's "rin" carries its room group's keys, RSA-wrapped for this phone's key and
## tagged with the password's key over the wrapped part and the host's id. This phone then joins the
## group as an invitee does (answer_group_invite): "gjoin" until the host's roster has it.
func _room_enter(host: String, d: Dictionary) -> void:
	var sec_text := String(d.sec)
	if in_room() or in_session or session_multi or _key == null or typeof(d.get("rt")) != TYPE_STRING or sec_text.length() > 1024 \
			or not _crypto.constant_time_compare(_room_tag(_join.key, "rin" + sec_text, host).to_utf8_buffer(), String(d.rt).to_utf8_buffer()):
		return
	var sec := _crypto.decrypt(_key, Marshalls.base64_to_raw(sec_text))
	if sec.size() != 81 or not int(sec[80]) in [1, 2, 4]:
		return
	if not group.is_empty():
		_group_close(true)                # (a group this phone was in is left for the room)
	var gid := sec.slice(0, 16).hex_encode()
	_grp = {"gid": gid, "aes": sec.slice(16, 48), "mac": sec.slice(48, 80), "seq": _group_seq0(), "their": {}, "seen": {}, "invited": {},
		"beat_t": GROUP_BEAT_S, "join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": true, "manual": true}
	group = {"gid": gid, "leader": host, "members": [{"id": host, "name": "HOST", "bundle": "default", "team": 0, "slot": 0}],
		"status": "joining", "mode": "lonewolf", "size": int(sec[80]), "room": String(_join.code)}
	_subscribe(ROOT + "/g/" + gid)
	group_changed.emit()


## This phone is out of the room it joined (KICK, the host closed it, the host gone): the join ends
## and the lobby says why once (room_notice with room_changed). A match that started from the room
## says nothing (the room closes then).
func _room_gone(why: String) -> void:
	var code := String(group.get("room", ""))
	_group_close(false)
	_join = {}
	join_state = ""
	if not in_session and not session_multi:
		room_notice = why % code
	room_changed.emit()
	group_changed.emit()


## The host lets a player with the right password into its room's group: a place waits for them
## (_grp.invited, as for a group invite, kept while they keep asking). False when the room is full.
func _room_let_in(from: String) -> bool:
	if _group_has(from):
		return true
	var inv: Dictionary = _grp.invited
	if not inv.has(from) and (group.members as Array).size() + inv.size() >= NetGroup.cap(int(group.size), true):
		return false
	inv[from] = Time.get_ticks_msec()
	return true


## The room group's id, keys and size (16 + 32 + 32 + 1 bytes) RSA-wrapped for a player's key, as
## base64 ("" when that key is no key).
func _room_sec(pk: String) -> String:
	var pub := CryptoKey.new()
	if pub.load_from_string(pk, true) != OK:
		return ""
	var sec := String(_grp.gid).hex_decode()
	sec.append_array(_grp.aes)
	sec.append_array(_grp.mac)
	sec.append(int(group.size))
	var wrapped := _crypto.encrypt(pub, sec)
	return Marshalls.raw_to_base64(wrapped) if not wrapped.is_empty() else ""


func _on_room_ask(d: Dictionary) -> void:
	var from := String(d.get("from", "")).left(32)
	if String(d.get("t", "")) != "ask" or from == "" or from == my_id or _inbox_budget < 1.0 or Game.is_blocked(from):
		return
	_inbox_budget -= 1.0
	if typeof(d.get("pk")) != TYPE_STRING or String(d.pk).length() > 1200 or from != String(d.pk).sha256_text().left(32):
		return
	var key := _room_key(room_code, room_pin)
	var right := typeof(d.get("mac")) == TYPE_STRING and _crypto.constant_time_compare(
		_room_tag(key, "ask", from).to_utf8_buffer(), String(d.mac).to_utf8_buffer())
	if not right:
		_publish_json(ROOT + "/u/" + from, {"t": "rno", "from": my_id, "code": room_code})
		return
	if _room_kicked.has(from):
		return                       # KICKed from this room: not let in again
	var slots := in_room()
	if slots and not _room_let_in(from):
		_publish_json(ROOT + "/u/" + from, {"t": "rno", "from": my_id, "code": room_code, "full": true})
		return
	if not slots and not room_guest.is_empty() and String(room_guest.id) != from:
		return                       # the room is full (1 vs 1)
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	peers[from] = {"name": who if who != "" else "PLAYER", "bundle": b, "pk": String(d.pk), "seen": Time.get_ticks_msec()}
	var fresh := false
	if not slots or (int(group.size) == 1 and room_guest.is_empty()):
		fresh = room_guest.is_empty()
		room_guest = {"id": from, "name": String(peers[from].name)}      # (the 1 vs 1's other player)
	var msg := {"t": "rin", "from": my_id, "code": room_code}
	if slots and not _group_has(from):
		var sec := _room_sec(String(d.pk))
		if sec != "":
			msg.sec = sec
			msg.rt = _room_tag(key, "rin" + sec, my_id)
	_publish_json(ROOT + "/u/" + from, msg)
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
	if _seq_kept > 0 and _seq >= _seq_kept - 100:
		_save_resume()               # (the file's counter keeps ahead of the one in use)
	return _seal(d, my_id, _seq, _aes, _mac)


## A sealed room packet (a match room's or a group room's, by the keys): sender `from`, counter `n`.
func _seal(d: Dictionary, from: String, n: int, aes: PackedByteArray, mac: PackedByteArray) -> PackedByteArray:
	d["f"] = from
	d["n"] = n
	var plain := JSON.stringify(d).to_utf8_buffer()
	var pad := 16 - plain.size() % 16
	for i in pad:
		plain.append(pad)
	var iv := _crypto.generate_random_bytes(16)
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_ENCRYPT, aes, iv)
	var body := PackedByteArray([1])
	body.append_array(iv)
	body.append_array(ctx.update(plain))
	ctx.finish()
	body.append_array(_crypto.hmac_digest(HashingContext.HASH_SHA256, mac, body))
	return body


## A room packet opened with these keys: what it says (with its sender "f" and counter "n"), or {}
## when it is not from a holder of the keys or is malformed. The counter is the caller's to check.
func _unseal(msg: PackedByteArray, aes: PackedByteArray, mac: PackedByteArray) -> Dictionary:
	if aes.size() != 32 or mac.size() != 32 or msg.size() < 1 + 16 + 16 + 32 or msg[0] != 1 or (msg.size() - 49) % 16 != 0:
		return {}
	var body := msg.slice(0, msg.size() - 32)
	if not _crypto.constant_time_compare(_crypto.hmac_digest(HashingContext.HASH_SHA256, mac, body), msg.slice(msg.size() - 32)):
		return {}                    # not from a phone that holds this room's keys
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_DECRYPT, aes, body.slice(1, 17))
	var plain := ctx.update(body.slice(17))
	ctx.finish()
	var pad := plain[plain.size() - 1] if plain.size() > 0 else 0
	if pad < 1 or pad > 16:
		return {}
	var d: Variant = JSON.parse_string(plain.slice(0, plain.size() - pad).get_string_from_utf8())
	if not d is Dictionary or typeof((d as Dictionary).get("f")) != TYPE_STRING:
		return {}
	var n: Variant = (d as Dictionary).get("n", 0)
	if typeof(n) != TYPE_FLOAT and typeof(n) != TYPE_INT:
		return {}
	return d as Dictionary


func _on_room(msg: PackedByteArray) -> void:
	var d := _unseal(msg, _aes, _mac)
	if d.is_empty():
		return
	if session_multi:
		_on_multi(d)
		return
	if String(d.get("f", "")) != String(opponent.get("id", "")):
		return                       # our own message coming back, or someone else's
	var n: Variant = d.get("n", 0)
	if int(n) <= _their_seq:
		return                       # replayed (the broker keeps one sender's messages in order)
	_their_seq = int(n)
	_last_heard = Time.get_ticks_msec()
	_present(_last_heard)            # (this phone is back in the match: it hears the other one)
	var kind := String((d as Dictionary).get("k", ""))
	if in_session and not kind in LOAD_KINDS:
		# (a phone that comes back after a restart says "ka" while its arena loads, and offers
		# its direct link: its fighter stays frozen here, and can be hit, until the arena is up)
		_last_live = _last_heard
		_set_away(String(opponent.get("id", "")), false)
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
				_reset_away()
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
				resumed = false
				resume_note = {}
				_resume_off = false
				_in_match_unix = Time.get_unix_time_from_system()
				_save_resume()
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
			if in_session and (i is float or i is int) and _pong_budget >= 1.0 and _arena_listens():
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
				end_session("left", true)
			elif event_received.get_connections().is_empty():
				if queue.size() < MAX_QUEUED:          # (only "ready" comes before the arena listens)
					queue.append([String(ev), data])
			else:
				event_received.emit(String(ev), data)


## Ends the match's session: "left" (the other phone said bye, `theirs`, or went silent, or this
## one leaves the arena) or "connection lost" (this phone lost the relay or was away too long).
## A session entered from the file whose arena is not up yet: this phone's own end (LEAVE MATCH,
## lost again) puts a counted match into the profile as LEFT; the other phone's "bye" meanwhile
## (it quit, or lost its own link: a LEFT for it) never does.
func end_session(reason := "left", theirs := false) -> void:
	var was := in_session
	if in_session:
		_room_send({"k": "ev", "e": "bye", "d": []})
		last_end_reason = reason
		if resumed and not _arena_listens():
			# (entered from the file, ended before its arena was up)
			var counted := bool(resume_note.get("counted", false))
			if theirs:
				rejoin_notice = ["OPPONENT LEFT", "%s left the match while you were rejoining: it does not count as a defeat."
					% String(opponent.get("name", "PLAYER"))]
			else:
				_record_resume_left()
				rejoin_notice = [] if reason == "left" else ["CONNECTION LOST", "The match could not be rejoined in time: it counts as LEFT (a defeat)."
					if counted else "The match could not be rejoined in time. Nothing was counted."]
	in_session = false
	_resume_emit = false
	_resume_wait = false
	clear_resume()
	_reset_away()
	session_team = {}
	if session_multi:
		_multi_reset()
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


## Whether the match's arena listens (the 1 vs 1's event_received, an all-human match's event_from).
func _arena_listens() -> bool:
	return not event_received.get_connections().is_empty() or not event_from.get_connections().is_empty()


## A token bucket per sender and kind (`burst` at once, then `rate` a second): false = drop it.
func _bucket(key: String, rate: float, burst: float) -> bool:
	var now := Time.get_ticks_msec()
	var b: Array = _buckets.get(key, [burst, now])
	var tokens := minf(burst, float(b[0]) + float(now - int(b[1])) / 1000.0 * rate)
	var ok := tokens >= 1.0
	_buckets[key] = [tokens - 1.0 if ok else tokens, now]
	return ok


# ---------------------------------------------------------------- GROUPS (design/GROUPS.txt)
# The group's room ROOT/g/<gid> carries room packets (_seal) under the group's own AES and HMAC keys,
# which only ever travel inside an invite's RSA part ("ginv") or the group room itself. Every sender
# counts its own packets from its wall clock in ms (so a member who leaves and comes back keeps
# counting up) and a receiver keeps the newest counter per sender: a replay is dropped. Only current
# members are heard, plus a "gjoin" from an id the leader invited; a blocked player never. Messages
# ("k"): "gjoin" {name, bundle} (the invitee after ACCEPT, every GROUP_JOIN_S until the roster has
# it), "groster" {members: [[id, name, bundle, team, slot]], mode, size, status} (the leader, on
# every change and every GROUP_BEAT_S: the truth for everyone), "gbeat" (each member every
# GROUP_BEAT_S), "gleave" (EXIT GROUP), "gkick" {id} (the leader's REMOVE), "gend" (DISBAND),
# "gstart" {room, aes, mac, size, roster: [[slot, id, name, bundle, team]]} (the leader's START of the
# group's own match: every member joins that match room). Silent GROUP_TIMEOUT_MS: a member is
# dropped by the leader; the leader silent that long, the group is gone.
const GROUP_JOIN_S := 1.0


func in_group() -> bool:
	return not group.is_empty() and (group.members as Array).size() > 1


## True for the group's leader, and for a player in no group (a solo leads itself).
func is_group_leader() -> bool:
	return group.is_empty() or String(group.get("leader", "")) == my_id


## [{"id", "name", "bundle", "leader", "me", "team", "slot"}], the leader first, then in join order.
func group_members() -> Array:
	var out := []
	if group.is_empty():
		return out
	for m: Dictionary in group.members:
		out.append({"id": String(m.id), "name": String(m.name), "bundle": String(m.bundle), "leader": String(m.id) == String(group.leader),
			"me": String(m.id) == my_id, "team": int(m.team), "slot": int(m.slot)})
	return out


func _group_has(id: String) -> bool:
	if group.is_empty():
		return false
	for m: Dictionary in group.members:
		if String(m.id) == id:
			return true
	return false


## What a group invite signs: who sends it, to whom, and the wrapped group keys with the size.
static func group_invite_text(from: String, to: String, sec: String) -> String:
	return "ginv|%s|%s|%s" % [from, to, sec]


## A group invite signed by its sender's key, whose hash is the id it claims (always required).
func group_invite_proven(d: Dictionary, from: String) -> bool:
	for k in ["pk", "sig", "sec"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return false
	return String(d.pk).length() <= 1200 and from == String(d.pk).sha256_text().left(32) \
		and verify_signed(String(d.pk), group_invite_text(from, my_id, String(d.sec)), String(d.sig))


## The leader (or a solo: the first invite makes the group, this phone its leader) invites a friend:
## their public key wraps the group's id and keys and the mode's size (16 + 32 + 32 + 1 bytes), the
## whole signed. False when it cannot go out: offline, not listed, blocked, already in, the group
## full (members and invites waiting), this phone a member but not the leader, or in a match.
func group_invite(friend_id: String) -> bool:
	if not _connected or my_id == "" or _key == null or in_session or session_multi or friend_id == my_id \
			or not peers.has(friend_id) or Game.is_blocked(friend_id) or not is_group_leader() or in_room():
		return false
	if not group.is_empty() and (_group_has(friend_id) or (group.members as Array).size() + (_grp.invited as Dictionary).size() >= GROUP_MAX):
		return false
	var pub := CryptoKey.new()
	if pub.load_from_string(String(peers[friend_id].pk), true) != OK:
		return false
	var made := group.is_empty()
	if made:
		_group_create(clampi(int(Game.team_size), 1, 4))
	var sec := String(_grp.gid).hex_decode()
	sec.append_array(_grp.aes)
	sec.append_array(_grp.mac)
	sec.append(int(group.size) if int(group.size) in [1, 2, 4] else 2)
	var wrapped := _crypto.encrypt(pub, sec)
	if wrapped.is_empty():
		if made:
			_group_close(false)
		return false
	var sec_text := Marshalls.raw_to_base64(wrapped)
	_code_kicked.erase(friend_id)
	(_grp.invited as Dictionary)[friend_id] = Time.get_ticks_msec()
	_publish_json(ROOT + "/u/" + friend_id, {"t": "ginv", "from": my_id, "name": String(Game.profile.name),
		"bundle": String(Game.profile.bundle), "sec": sec_text, "pk": _pk_pem, "sig": _sign(group_invite_text(my_id, friend_id, sec_text))})
	group_changed.emit()
	return true


func _me_entry() -> Dictionary:
	return {"id": my_id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle), "team": 0, "slot": 0}


## This phone's counter in a group room starts from the wall clock (ms): never below one it used
## before in the same group, so the others never take its packets for replays.
static func _group_seq0() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func _group_create(size: int) -> void:
	seek_stop()                          # (a QUICK MATCH search ends: a group never plays a random 1 vs 1)
	var gid := _crypto.generate_random_bytes(16).hex_encode()
	_grp = {"gid": gid, "aes": _crypto.generate_random_bytes(32), "mac": _crypto.generate_random_bytes(32), "seq": _group_seq0(),
		"their": {}, "seen": {}, "invited": {}, "beat_t": 0.0, "join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": false, "manual": false}
	group = {"gid": gid, "leader": my_id, "members": [_me_entry()], "status": "idle", "mode": "lonewolf", "size": size}
	NetGroup.arrange(group.members, size, false)
	_subscribe(ROOT + "/g/" + gid)


## A "ginv" in this phone's inbox. Unsigned, from a blocked player, or not the 81 bytes: ignored.
## Shown (group_invited) only from a friend this phone takes challenges from (NetMatch.allowed),
## while the lobby listens, and when not busy (in a match, in a group or joining one, another group
## invite waiting); otherwise declined at once ("dec" with the invite's tag, as a duel's).
func _on_group_invite(from: String, d: Dictionary) -> void:
	if typeof(d.get("sec")) != TYPE_STRING or Game.is_blocked(from) or not group_invite_proven(d, from):
		return
	var sec := _crypto.decrypt(_key, Marshalls.base64_to_raw(String(d.sec)))
	if sec.size() != 81 or not int(sec[80]) in [1, 2, 4]:
		return
	var gid := sec.slice(0, 16).hex_encode()
	var inv := {"id": from, "gid": gid, "room": gid, "aes": sec.slice(16, 48), "mac": sec.slice(48, 80), "size": int(sec[80])}
	var busy := in_session or session_multi or in_group() or (not group.is_empty() and not is_group_leader()) or not _ginv.is_empty() or in_room()
	if busy or not Game.is_friend(from) or not NetMatch.allowed(from, my_id) or group_invited.get_connections().is_empty():
		_publish_json(ROOT + "/u/" + from, {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
		return
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	inv.name = who if who != "" else "PLAYER"
	inv.bundle = String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	inv.t = Time.get_ticks_msec()
	_ginv = inv
	group_invited.emit(String(inv.name))


## Who the group invite waiting here comes from: {"id", "name", "bundle"}, {} when none.
func group_invite_from() -> Dictionary:
	return {} if _ginv.is_empty() else {"id": String(_ginv.id), "name": String(_ginv.name), "bundle": String(_ginv.bundle)}


## ACCEPT: this phone enters the group's room and says "gjoin" until the leader's roster has it (no
## match starts). DECLINE: "dec". A group of one that this phone led (its invite still out) is
## dropped for the new one.
func answer_group_invite(accept: bool) -> void:
	if _ginv.is_empty():
		return
	var inv := _ginv
	_ginv = {}
	if not accept or in_session or session_multi or in_group():
		_publish_json(ROOT + "/u/" + String(inv.id), {"t": "dec", "from": my_id, "mac": _tag(inv, "dec", my_id)})
		group_changed.emit()
		return
	seek_stop()                          # (the QUICK MATCH search ends: NetMatch sees it and stops)
	_mm_stop()
	search_needed = 0
	search_found = 0
	if not group.is_empty():
		_group_close(false)
	_grp = {"gid": inv.gid, "aes": inv.aes, "mac": inv.mac, "seq": _group_seq0(), "their": {}, "seen": {}, "invited": {},
		"beat_t": GROUP_BEAT_S, "join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": true, "manual": false}
	group = {"gid": inv.gid, "leader": inv.id, "members": [{"id": inv.id, "name": inv.name, "bundle": inv.bundle, "team": 0, "slot": 0}],
		"status": "joining", "mode": "lonewolf", "size": int(inv.size)}
	_subscribe(ROOT + "/g/" + String(inv.gid))
	group_changed.emit()


## EXIT GROUP ("gleave"); the leader's is DISBAND ("gend": everyone leaves).
func leave_group() -> void:
	if group.is_empty():
		return
	_group_close(true)
	group_changed.emit()


## The leader's REMOVE: that member is told ("gkick") and leaves the roster.
func kick_from_group(id: String) -> void:
	if group.is_empty() or String(group.leader) != my_id or id == my_id or not _group_has(id):
		return
	if in_room():
		_room_kicked[id] = true          # (the room's KICK: not let in again while it is open)
	_code_kicked[id] = true              # (nor by the GROUP CODE this run: an invite still can)
	_group_send({"k": "gkick", "id": id})
	_group_drop(id)


## The leader's SELECT MODE pick, shown to the members (their SELECT MODE follows it).
func set_group_mode(mode: String, size: int) -> void:
	if group.is_empty() or String(group.leader) != my_id or size not in [1, 2, 4] or in_room():
		return                           # (a room keeps the mode its host opened it with)
	group.mode = mode.left(16)
	if int(group.size) != size:
		group.size = size
		NetGroup.arrange(group.members, size, bool(_grp.manual))
	_group_roster()
	group_changed.emit()


## The leader puts a member on a side: team 0 BLUE / 1 ORANGE, slot the roster slot (-1: the first
## free one of that team; a slot someone holds swaps the two). Teams may be uneven, a slot may stay
## empty (never a bot). Echoed to everyone in "groster". False when it cannot be.
func set_group_team(member_id: String, team: int, slot := -1) -> bool:
	if group.is_empty() or String(group.leader) != my_id or not NetGroup.move(group.members, member_id, team, slot, int(group.size)):
		return false
	_grp.manual = true
	_group_roster()
	group_changed.emit()
	return true


## The leader's START (LONE WOLF online, never bots). "" when it goes: the group's own match starts
## at once when both teams have a player (the default sides: DUO with 3 or 4; or the leader's own,
## uneven allowed), else the search for the rest runs (search_found / search_needed). Otherwise the
## notice to show. A solo's 1 VS 1 is QUICK MATCH (NetMatch): "" here, nothing started.
func group_start(size: int) -> String:
	if in_room():
		return room_start()
	if not is_group_leader():
		return "ONLY THE LEADER CAN START"
	if size == 1:
		return "A GROUP CANNOT PLAY 1 VS 1: EXIT GROUP OR PICK DUO / SQUAD" if in_group() else ""
	if size not in [2, 4]:
		return "PICK DUO OR SQUAD"
	if in_session or session_multi:
		return "A MATCH IS ALREADY STARTING"
	if not in_group():
		_search_begin(size)
		return ""
	if int(group.size) != size:
		set_group_mode(String(group.mode), size)
	var plan := NetGroup.plan(group.members, size)
	if plan == "search":
		if (group.members as Array).size() > NetGroup.per_team(size):
			return "TOO MANY PLAYERS FOR ONE %s TEAM" % ("DUO" if size == 2 else "SQUAD")
		_search_begin(size)
		return ""
	if plan != "match":
		return plan
	if not _connected:
		return "OFFLINE: THE MATCH NEEDS THE INTERNET"
	_group_launch(size)
	return ""


## CANCEL of the search.
func group_search_stop() -> void:
	var was := search_needed > 0
	_mm_stop()
	search_needed = 0
	search_found = 0
	if not group.is_empty() and String(group.leader) == my_id and String(group.status) == "searching":
		group.status = "idle"
		_group_roster()
	if was:
		group_changed.emit()


## The search for the rest of the match (no bots ever): this unit (a group whole, or a solo) waits
## for other searching units (matchmaking below) until both teams are full of real players.
func _search_begin(size: int) -> void:
	search_needed = 2 * size
	search_found = maxi((group.members as Array).size(), 1) if not group.is_empty() else 1
	_mm_begin(size)
	if not group.is_empty():
		group.status = "searching"
		_group_roster()
	group_changed.emit()


# ---------------------------------------------------------------- GROUP CODE (join by code)
# Every group has a GROUP CODE of CODE_LEN digits (group_code: the leader's my_code; a solo shows its
# own, the code of the group it would lead): 2 random bucket digits, then 8 random secret digits.
# JOIN BY CODE is built on the custom room's discovery and key exchange, with the code itself the
# secret: the joiner says "gask" {from, name, bundle, pk, mac} on ROOT/gc/<bucket> (code_topic: the
# code's first 2 digits, which are separate random digits, so the topic tells nothing of the 8
# secret ones), mac = HMAC(code key, "gask" + from) with the code's stretched key (_code_key,
# CODE_STRETCH HMAC rounds). Every leader listening on that bucket checks the tag against its own code and stays
# silent when it is not theirs. The leader whose code it is answers in the joiner's inbox: "gin"
# {sec, rt} with the group's id and keys RSA-wrapped for the joiner's key (as a room's "rin") and rt
# = HMAC(code key, "gin" + sec + leader), or "gno" {full: true, rt} when the group is full. The
# joiner then says "gjoin" in the group room as an invitee does; the leader's roster is the truth.
# Rules: nobody listens until the leader (or solo) turns JOIN BY CODE on (code_join, OFF at the
# start of every run; COPY of the code turns it on, since copying means sharing); an ask is answered
# only from a player DUEL CHALLENGES FROM lets in (NetMatch.allowed: never a blocked one, none with
# NOBODY, only friends with FRIENDS), never from one the leader REMOVEd this run (_code_kicked), and
# not while this phone is in QUICK MATCH (seeking); a joiner never takes a "gin" from a leader it
# blocked; a host checks at most CODE_RATE asks a second (and one a 2 s per asker), a joiner starts
# at most CODE_TRIES_MAX attempts a minute, each asks every CODE_ASK_S and gives up after
# CODE_WAIT_MS ("NO GROUP WITH THIS CODE"). A custom room has its own code and password: no group
# code in a room.
const CODE_ASK_S := 1.5
const CODE_WAIT_MS := 8000
const CODE_TRIES_MAX := 5
const CODE_RATE := 4.0
const CODE_LEN := 10           # 2 bucket digits + 8 secret digits
const CODE_STRETCH := 10000    # HMAC rounds that make a code's key
var my_code := ""              # this phone's group code (CODE_LEN digits), made once per run
var code_join := false         # the leader's switch JOIN BY CODE (off until turned on, every run)
var code_state := ""           # this phone's own JOIN BY CODE: "", "asking", "in", "full", "none", "blocked", "failed"
var _cjoin := {}               # {"code", "key", "t", "ask_t"}: the join by code under way
var _code_topic := ""          # the bucket this phone listens on for asks with its code
var _code_keys := {}           # code -> its stretched key (the own one, the one being joined)
var _code_tries: Array = []    # when the last join attempts began (ms)
var _code_kicked := {}         # ids this leader REMOVEd this run: their code asks are never answered


## The GROUP CODE the GROUP bar shows: a member's is the leader's (from the roster), a leader's or
## a solo's its own; "" in a custom room.
func group_code() -> String:
	if in_room():
		return ""
	if not group.is_empty() and String(group.leader) != my_id:
		return String(group.get("code", ""))
	if my_code == "" and my_id != "":
		var r := _crypto.generate_random_bytes(8)
		my_code = "%02d%08d" % [r.decode_u32(0) % 100, r.decode_u32(4) % 100000000]
	return my_code


## The bucket topic asks for a code go to: its first 2 digits, random and apart from the 8 secret
## ones (so the topic never narrows the secret down).
static func code_topic(code: String) -> String:
	return ROOT + "/gc/" + code.left(2)


## True for a GROUP CODE as typed: CODE_LEN digits, nothing else (spaces taken out first).
static func is_group_code(code: String) -> bool:
	if code.length() != CODE_LEN:
		return false
	for ch in code:
		if not ch in "0123456789":
			return false
	return true


## How the GROUP bar shows a code: "12 3456 7890" (COPY and the joiner use the bare digits).
static func code_display(code: String) -> String:
	if code.length() != CODE_LEN:
		return code
	return "%s %s %s" % [code.left(2), code.substr(2, 4), code.right(4)]


## A code's key (stretched: CODE_STRETCH HMAC rounds, so an ask seen on the relay is slow to test
## codes against).
func _code_key(code: String) -> PackedByteArray:
	if _code_keys.has(code):
		return _code_keys[code]
	var k := ("lonewolfarena-gcode|%s" % code).sha256_buffer()
	for i in CODE_STRETCH:
		k = _crypto.hmac_digest(HashingContext.HASH_SHA256, k, code.to_utf8_buffer())
	if _code_keys.size() > 8:
		_code_keys.clear()
	_code_keys[code] = k
	return k


func _code_tag(key: PackedByteArray, what: String) -> String:
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, key, what.to_utf8_buffer()).hex_encode()


## The leader's (or a solo's) switch JOIN BY CODE. A leader's roster carries it at once ("cj"), so
## a member shows the code only while it works (code_open).
func set_code_join(on: bool) -> void:
	if code_join != on:
		code_join = on
		_group_roster()
		group_changed.emit()


## Whether the GROUP CODE this phone shows lets anyone in: a leader's or a solo's own switch, a
## member's from the leader's roster ("cj"; off until a roster says on). A member shows the code and
## COPY only while it is on (its COPY cannot turn the leader's switch on).
func code_open() -> bool:
	if not group.is_empty() and String(group.leader) != my_id:
		return bool(group.get("code_join", false))
	return code_join


## JOIN BY CODE: "" when the ask went out (code_state then tells how it goes), else the notice.
func join_group_code(code: String) -> String:
	code = code.replace(" ", "").replace("-", "").strip_edges()
	if not is_group_code(code):
		return "A GROUP CODE HAS %d DIGITS" % CODE_LEN
	if code_state == "in" and bool(_grp.get("joining", false)) and not in_room() and code == String(group.get("code", "")):
		_group_close(true)               # the same code again while its join waits to be let in: asked afresh
		code_state = ""
	if code == group_code():
		return "THIS IS YOUR OWN GROUP CODE"
	if in_group() or in_room() or (not group.is_empty() and String(group.leader) != my_id):
		return "EXIT YOUR GROUP FIRST"
	if in_session or session_multi:
		return "A MATCH IS ALREADY STARTING"
	if seeking or search_needed > 0:
		return "CANCEL THE SEARCH FIRST"
	if not _connected or _key == null:
		return "OFFLINE: JOINING A GROUP NEEDS THE INTERNET"
	if code_state == "asking":
		return "A JOIN IS ALREADY UNDER WAY"
	var now := Time.get_ticks_msec()
	_code_tries = _code_tries.filter(func(t: int) -> bool: return now - t < 60000)
	if _code_tries.size() >= CODE_TRIES_MAX:
		return "TOO MANY TRIES: WAIT A MINUTE"
	_code_tries.append(now)
	_cjoin = {"code": code, "key": _code_key(code), "t": now, "ask_t": 0.0}
	code_state = "asking"
	group_changed.emit()
	return ""


## The joiner's "gask" as it goes out.
func _code_ask_msg() -> Dictionary:
	return {"t": "gask", "from": my_id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle), "pk": _pk_pem,
		"mac": _code_tag(_cjoin.key, "gask" + my_id)}


## Every frame: the leader listens on its code's bucket while code joins can come in (JOIN BY CODE
## on, not in QUICK MATCH); a join by code asks every CODE_ASK_S until answered or CODE_WAIT_MS.
func _tick_code(delta: float, now: int) -> void:
	var want := ""
	if _connected and _want_lobby and code_join and my_id != "" and is_group_leader() and not in_room() and room_code == "" \
			and not in_session and not session_multi and not seeking and code_state != "asking":
		want = code_topic(group_code())
	if want != _code_topic:
		if _code_topic != "" and _connected:
			_unsubscribe(_code_topic)
		_code_topic = want
		if want != "":
			_subscribe(want)
	if code_state == "asking" and not _cjoin.is_empty():
		_cjoin.ask_t = float(_cjoin.ask_t) - delta
		if float(_cjoin.ask_t) <= 0.0:
			_cjoin.ask_t = CODE_ASK_S
			_publish_json(code_topic(String(_cjoin.code)), _code_ask_msg())
		if now - int(_cjoin.t) > CODE_WAIT_MS:
			_cjoin = {}
			code_state = "none"
			group_changed.emit()


## A "gask" on this phone's bucket: answered only when its tag is this phone's code's ("" else, the
## ask is another group's). Returns the answer that went out ({} for none).
func _on_code_ask(d: Dictionary) -> Dictionary:
	var from := String(d.get("from", "")).left(32)
	if String(d.get("t", "")) != "gask" or from == "" or from == my_id or typeof(d.get("mac")) != TYPE_STRING:
		return {}
	if not code_join or in_room() or not is_group_leader() or in_session or session_multi or seeking:
		return {}
	if not _bucket("gc", CODE_RATE, 8.0) or not _bucket("gc" + from, 0.5, 3.0):
		return {}
	var key := _code_key(group_code())
	if not _crypto.constant_time_compare(_code_tag(key, "gask" + from).to_utf8_buffer(), String(d.mac).to_utf8_buffer()):
		return {}                    # another group's code in the same bucket
	if not NetMatch.allowed(from, my_id) or _code_kicked.has(from) or typeof(d.get("pk")) != TYPE_STRING \
			or String(d.pk).length() > 1200 or from != String(d.pk).sha256_text().left(32):
		return {}                    # blocked, not let in by DUEL CHALLENGES FROM, or REMOVEd: no answer
	var taken := 0
	if not group.is_empty():
		taken = (group.members as Array).size() + (_grp.invited as Dictionary).size()
		if (_grp.invited as Dictionary).has(from):
			taken -= 1
	if not _group_has(from) and taken >= GROUP_MAX:
		var no := {"t": "gno", "from": my_id, "full": true, "rt": _code_tag(key, "gno" + my_id)}
		_publish_json(ROOT + "/u/" + from, no)
		return no
	var made := group.is_empty()
	if made:
		_group_create(clampi(int(Game.team_size), 1, 4))
	var sec := _room_sec(String(d.pk))
	if sec == "":
		if made:
			_group_close(false)
		return {}
	if not _group_has(from):
		(_grp.invited as Dictionary)[from] = Time.get_ticks_msec()
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	if not peers.has(from) and peers.size() < MAX_PEERS:
		peers[from] = {"name": who if who != "" else "PLAYER", "bundle": b, "pk": String(d.pk), "seen": Time.get_ticks_msec()}
	var msg := {"t": "gin", "from": my_id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle), "sec": sec,
		"rt": _code_tag(key, "gin" + sec + my_id)}
	_publish_json(ROOT + "/u/" + from, msg)
	group_changed.emit()
	return msg


## The joiner: the leader's "gin" (the group's keys, wrapped for this phone) or "gno" (full), both
## tagged with the code's key; a "gin" from a leader this phone blocked is refused.
func _on_code_answer(from: String, d: Dictionary) -> void:
	if code_state != "asking" or _cjoin.is_empty() or typeof(d.get("rt")) != TYPE_STRING:
		return
	var key: PackedByteArray = _cjoin.key
	if String(d.t) == "gno":
		if _crypto.constant_time_compare(_code_tag(key, "gno" + from).to_utf8_buffer(), String(d.rt).to_utf8_buffer()):
			_cjoin = {}
			code_state = "full"
			group_changed.emit()
		return
	var sec_text := String(d.get("sec", "")) if typeof(d.get("sec")) == TYPE_STRING else ""
	if sec_text == "" or sec_text.length() > 1024 \
			or not _crypto.constant_time_compare(_code_tag(key, "gin" + sec_text + from).to_utf8_buffer(), String(d.rt).to_utf8_buffer()):
		return
	if Game.is_blocked(from):
		_cjoin = {}
		code_state = "blocked"           # never into the group of a leader this player blocked
		group_changed.emit()
		return
	var sec := PackedByteArray() if _key == null else _crypto.decrypt(_key, Marshalls.base64_to_raw(sec_text))
	if in_group() or in_room() or in_session or session_multi or sec.size() != 81 or not int(sec[80]) in [1, 2, 4]:
		_cjoin = {}
		code_state = "failed"            # the leader's answer cannot be taken here: COULD NOT JOIN
		group_changed.emit()
		return
	var code := String(_cjoin.code)
	_cjoin = {}
	code_state = "in"
	seek_stop()
	_mm_stop()
	search_needed = 0
	search_found = 0
	if not group.is_empty():
		_group_close(false)              # (a group of one this phone led, an invite still out)
	var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
	var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
	var gid := sec.slice(0, 16).hex_encode()
	_grp = {"gid": gid, "aes": sec.slice(16, 48), "mac": sec.slice(48, 80), "seq": _group_seq0(), "their": {}, "seen": {}, "invited": {},
		"beat_t": GROUP_BEAT_S, "join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": true, "manual": false}
	group = {"gid": gid, "leader": from, "members": [{"id": from, "name": who if who != "" else "PLAYER", "bundle": b, "team": 0, "slot": 0}],
		"status": "joining", "mode": "lonewolf", "size": int(sec[80]), "code": code}
	_subscribe(ROOT + "/g/" + gid)
	group_changed.emit()


## The leader of a group of exactly two plays the other member 1 vs 1 (START with SOLO): a plain
## duel challenge (invite) carrying "gd", the group's tag (group_duel_tag), so the member's phone
## takes it at once from its leader and from nobody else (_on_inbox). The match and its results are
## the usual 1 vs 1's; the group stays (its room beats on meanwhile). "" when it went out, else the
## notice to show.
func group_duel() -> String:
	if not in_group() or (group.members as Array).size() != 2 or in_room():
		return "A DUEL NEEDS A GROUP OF TWO"
	if String(group.leader) != my_id:
		return "ONLY THE LEADER CAN START"
	if in_session or session_multi or not _outgoing.is_empty():
		return "A MATCH IS ALREADY STARTING"
	if not _connected:
		return "OFFLINE: THE MATCH NEEDS THE INTERNET"
	var other := {}
	for m: Dictionary in group.members:
		if String(m.id) != my_id:
			other = m
	var oid := String(other.get("id", ""))
	if Game.is_blocked(oid) or not invite(oid, {"gd": group_duel_tag(my_id)}):
		return "%s CANNOT BE REACHED RIGHT NOW" % String(other.get("name", "THE OTHER PLAYER"))
	return ""


## The group's tag over a duel from `sender` (HMAC with the group's MAC key: only members can make it).
func group_duel_tag(sender: String) -> String:
	if _grp.is_empty():
		return ""
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, _grp.mac, ("gduel" + String(_grp.gid) + sender).to_utf8_buffer()).hex_encode()


# ---------------------------------------------------------------- matchmaking (gseek / gmatch)
# Every searching LEADER (a solo searcher leads a unit of one) says "gseek" on ROOT/mm/g<size>
# every MM_SEEK_S (never retained): {"t": "gseek", "id", "pk", "m": [[id, name, bundle], ...] (its
# unit, leader first), "saw": [leader ids it heard]}. Units are never split. The leader with the
# lowest id among itself and the units that see it is the MATCH HOST: once the units it hears fill
# two teams exactly (NetGroup.pick_units) it sends each other unit's leader a signed "gmatch" to the
# inbox: "sec" = RSA(that leader's key, room(16) + aes(32) + mac(32) + size byte), "roster" the
# match's slots (public lobby data: ids, names, outfits), "sig" over gmatch|from|to|sec|roster. The
# leader answers "gacc" (an HMAC with the match keys) or "dec", forwards "gstart" (with the host) in
# its group room and joins the match room; the host, once every unit took it, does the same for its
# own unit. A unit that does not answer within MM_ACCEPT_MS is skipped a while and the host seeks on.
const MM_SEEK_S := 2.0
const MM_SEEN_MS := 6000              # a searching unit not heard this long is left out
const MM_ACCEPT_MS := 15000           # the host waits this long for every unit's "gacc"
const MM_SNUB_MS := 20000             # a unit that did not take the host's "gmatch" is skipped this long
const MM_UNITS_MAX := 24
var _mm := {}                  # {"size", "seek_t", "units": id -> {"m", "pk", "saw", "ms"}, "snub": id -> ms, "pending": id -> bool, "pend_ms", "room", "aes", "mac", "roster"}


func _mm_topic() -> String:
	return ROOT + "/mm/g%d" % int(_mm.get("size", 2))


func _mm_begin(size: int) -> void:
	_mm_stop()
	_mm = {"size": size, "seek_t": 0.0, "units": {}, "snub": {}, "pending": {}, "pend_ms": 0, "room": "", "aes": PackedByteArray(),
		"mac": PackedByteArray(), "roster": []}
	if _connected:
		_subscribe(_mm_topic())


func _mm_stop() -> void:
	if _mm.is_empty():
		return
	if _connected:
		_unsubscribe(_mm_topic())
	_mm = {}


## This phone's unit as "gseek" carries it: the group's members (leader first) or this player alone.
func _mm_unit() -> Array:
	if group.is_empty():
		var me := _me_entry()
		return [[String(me.id), String(me.name), String(me.bundle)]]
	var out := []
	for m: Dictionary in group.members:
		out.append([String(m.id), String(m.name), String(m.bundle)])
	return out


func _on_gseek(payload: PackedByteArray) -> void:
	if _mm.is_empty() or payload.size() > MAX_MESSAGE:
		return
	var d: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not d is Dictionary or String((d as Dictionary).get("t", "")) != "gseek" or typeof(d.get("id")) != TYPE_STRING \
			or typeof(d.get("pk")) != TYPE_STRING:
		return
	var id := String(d.id)
	var pk := String(d.pk)
	if id == my_id or not Game.is_player_id(id) or pk.length() > 1200 or id != pk.sha256_text().left(32):
		return
	var unit := NetGroup.unit_from(d.get("m"), id, int(_mm.size))
	if unit.is_empty():
		return
	for m: Dictionary in unit:
		if Game.is_blocked(String(m.id)) or String(m.id) == my_id or _group_has(String(m.id)):
			return                       # never with a blocked player (nor a unit that claims one of ours)
	var units: Dictionary = _mm.units
	if not units.has(id) and units.size() >= MM_UNITS_MAX:
		return
	var saw := {}
	if d.get("saw") is Array:
		for s: Variant in (d.saw as Array).slice(0, MM_UNITS_MAX):
			if typeof(s) == TYPE_STRING:
				saw[String(s).left(32)] = true
	units[id] = {"m": unit, "pk": pk, "saw": saw, "ms": Time.get_ticks_msec()}


## Every frame while this leader searches: "gseek", the units heard, the host's pick and its wait.
func _tick_mm(delta: float, now: int) -> void:
	if in_session or session_multi:
		return
	var units: Dictionary = _mm.units
	for id: String in units.keys():
		if now - int(units[id].ms) > MM_SEEN_MS:
			units.erase(id)
	var snub: Dictionary = _mm.snub
	for id: String in snub.keys():
		if now - int(snub[id]) > MM_SNUB_MS:
			snub.erase(id)
	_mm.seek_t = float(_mm.seek_t) - delta
	if float(_mm.seek_t) <= 0.0:
		_mm.seek_t = MM_SEEK_S
		_publish_json(_mm_topic(), {"t": "gseek", "id": my_id, "pk": _pk_pem, "m": _mm_unit(), "saw": units.keys().slice(0, 12)})
	var mine := _mm_unit().size()
	var found := mine
	for id: String in units:
		found += (units[id].m as Array).size()
	found = mini(found, search_needed)
	if found != search_found:
		search_found = found
		_group_roster()
		group_changed.emit()
	var pending: Dictionary = _mm.pending
	if not pending.is_empty():
		var all_in := true
		for id: String in pending:
			all_in = all_in and bool(pending[id])
		if all_in:
			_mm_launch()
		elif now - int(_mm.pend_ms) > MM_ACCEPT_MS:
			for id: String in pending:
				if not bool(pending[id]):
					snub[id] = now
			_mm.pending = {}
		return
	# The host: the lowest id among this leader and the units that hear it.
	var cands := []
	for id: String in units:
		if (units[id].saw as Dictionary).has(my_id) and not snub.has(id):
			if id < my_id:
				return                   # a lower id decides: its "gmatch" comes here
			cands.append(id)
	cands.sort_custom(func(a: String, b: String) -> bool: return (units[a].m as Array).size() > (units[b].m as Array).size())
	var list := [{"n": mine}]
	for id: String in cands:
		list.append({"n": (units[id].m as Array).size()})
	var pick := NetGroup.pick_units(list, int(_mm.size))
	if pick.is_empty():
		return
	_mm_offer(pick, cands)


## The host's pick: the match roster (BLUE first, each unit in its order) and a "gmatch" to each
## other unit's leader.
func _mm_offer(pick: Array, cands: Array) -> void:
	var size := int(_mm.size)
	var per := NetGroup.per_team(size)
	var next := [0, per]
	var roster := []
	var leaders := []
	for p: Array in pick:
		var i := int(p[0])
		var t := int(p[1])
		var members: Array = []
		if i == 0:
			for e: Array in _mm_unit():
				members.append({"id": String(e[0]), "name": String(e[1]), "bundle": String(e[2])})
		else:
			members = (_mm.units[String(cands[i - 1])].m as Array)
			leaders.append(String(cands[i - 1]))
		for m: Dictionary in members:
			roster.append({"slot": int(next[t]), "id": String(m.id), "name": String(m.name), "bundle": String(m.bundle), "team": t})
			next[t] = int(next[t]) + 1
	roster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.slot) < int(b.slot))
	var room := _crypto.generate_random_bytes(16)
	var aes := _crypto.generate_random_bytes(32)
	var mac := _crypto.generate_random_bytes(32)
	var packed := NetGroup.pack_roster(roster)
	var pending := {}
	for id: String in leaders:
		var pub := CryptoKey.new()
		if pub.load_from_string(String(_mm.units[id].pk), true) != OK:
			return
		var sec := room.duplicate()
		sec.append_array(aes)
		sec.append_array(mac)
		sec.append(size)
		var wrapped := _crypto.encrypt(pub, sec)
		if wrapped.is_empty():
			return
		var sec_text := Marshalls.raw_to_base64(wrapped)
		_publish_json(ROOT + "/u/" + id, {"t": "gmatch", "from": my_id, "sec": sec_text, "roster": packed,
			"sig": _sign(gmatch_text(my_id, id, sec_text, packed))})
		pending[id] = false
	_mm.pending = pending
	_mm.pend_ms = Time.get_ticks_msec()
	_mm.room = room.hex_encode()
	_mm.aes = aes
	_mm.mac = mac
	_mm.roster = roster


## What a "gmatch" signs.
static func gmatch_text(from: String, to: String, sec: String, roster: Array) -> String:
	return "gmatch|%s|%s|%s|%s" % [from, to, sec, JSON.stringify(roster)]


## Every unit took the host's match: the host's own unit goes in (its members by "gstart").
func _mm_launch() -> void:
	var room := String(_mm.room)
	var aes: PackedByteArray = _mm.aes
	var mac: PackedByteArray = _mm.mac
	var roster: Array = _mm.roster
	_group_launch_with(int(_mm.size), roster, room, aes, mac, my_id)


## A searching leader's inbox: the host's "gmatch". Taken only from a unit this search heard (its
## signed key), while searching that size and not deciding itself; its roster must hold this
## unit whole on one team and the host. Then "gacc", the group's "gstart", the match room.
func _on_gmatch(from: String, d: Dictionary) -> void:
	if _mm.is_empty() or not (_mm.pending as Dictionary).is_empty() or in_session or session_multi or not is_group_leader() \
			or not (_mm.units as Dictionary).has(from) or typeof(d.get("sec")) != TYPE_STRING or typeof(d.get("sig")) != TYPE_STRING:
		return
	var packed: Variant = d.get("roster")
	if not packed is Array or not verify_signed(String(_mm.units[from].pk), gmatch_text(from, my_id, String(d.sec), packed), String(d.sig)):
		return
	var sec := _crypto.decrypt(_key, Marshalls.base64_to_raw(String(d.sec)))
	var size := int(_mm.size)
	if sec.size() != 81 or int(sec[80]) != size:
		return
	var room := sec.slice(0, 16).hex_encode()
	var aes := sec.slice(16, 48)
	var mac := sec.slice(48, 80)
	var roster := NetGroup.roster_from(packed, size)
	var team := -1
	var ok := not roster.is_empty()
	var ids := {}
	for e: Dictionary in roster:
		ids[String(e.id)] = int(e.team)
	for e: Array in _mm_unit():
		var id := String(e[0])
		if not ids.has(id) or (team >= 0 and int(ids[id]) != team):
			ok = false
		elif team < 0:
			team = int(ids[id])
	ok = ok and ids.has(from)
	if not ok:
		_publish_json(ROOT + "/u/" + from, {"t": "dec", "from": my_id, "mac": _tag({"mac": mac, "room": room}, "dec", my_id)})
		return
	_publish_json(ROOT + "/u/" + from, {"t": "gacc", "from": my_id, "mac": _tag({"mac": mac, "room": room}, "gacc", my_id)})
	_group_launch_with(size, roster, room, aes, mac, from)


## The host hears a unit's answer to its "gmatch" ("gacc" or "dec", tagged with the match keys).
func _on_gmatch_answer(from: String, d: Dictionary, accepted: bool) -> bool:
	if _mm.is_empty() or not (_mm.pending as Dictionary).has(from) \
			or not _tagged(d, {"mac": _mm.mac, "room": _mm.room}, "gacc" if accepted else "dec", from):
		return false
	if accepted:
		_mm.pending[from] = true
	else:
		_mm.snub[from] = Time.get_ticks_msec()
		_mm.pending = {}               # (the units that took it give up on this host after a while)
	return true


func _group_send(d: Dictionary) -> void:
	if _grp.is_empty():
		return
	_grp.seq = int(_grp.seq) + 1
	_publish(ROOT + "/g/" + String(_grp.gid), _seal(d, my_id, int(_grp.seq), _grp.aes, _grp.mac))


## The leader's roster: the truth for every member.
func _group_roster() -> void:
	if group.is_empty() or String(group.leader) != my_id:
		return
	_group_send(_roster_msg())


## The leader's "groster" as it goes out: the members, mode, size, status and, out of a room, the
## GROUP CODE with the switch JOIN BY CODE ("cj"), inside the group room's encryption.
func _roster_msg() -> Dictionary:
	var msg := {"k": "groster", "members": NetGroup.pack_members(group.members), "mode": String(group.mode),
		"size": int(group.size), "status": String(group.status), "found": search_found}
	if not in_room():
		msg.code = group_code()          # (inside the group room's encryption: only members read it)
		msg.cj = code_join
	return msg


## Leaves the group here (tell: "gleave", the leader's "gend") and forgets its keys.
func _group_close(tell: bool) -> void:
	if code_state == "in" and bool(_grp.get("joining", false)):
		code_state = "failed"            # a join by code the leader never let in (it started a match, filled up...)
	if not _grp.is_empty():
		if tell:
			_group_send({"k": "gend"} if String(group.get("leader", "")) == my_id else {"k": "gleave"})
		if _connected:
			_unsubscribe(ROOT + "/g/" + String(_grp.gid))
	_mm_stop()
	_grp = {}
	group = {}
	search_found = 0
	search_needed = 0


## The leader drops a member (EXIT GROUP, REMOVE, silent too long): the others hear the new roster.
func _group_drop(id: String) -> void:
	var members: Array = group.members
	for i in members.size():
		if String(members[i].id) == id:
			members.remove_at(i)
			break
	NetGroup.arrange(members, int(group.size), bool(_grp.manual), in_room())
	if search_needed > 0:
		search_found = members.size()
	if String(room_guest.get("id", "")) == id:
		room_guest = {}
		room_changed.emit()
	_group_roster()
	group_changed.emit()


func _on_group(payload: PackedByteArray) -> void:
	var d := _unseal(payload, _grp.aes, _grp.mac)
	if d.is_empty():
		return
	var f := String(d.f)
	var k := String(d.get("k", ""))
	if f == my_id or Game.is_blocked(f):
		return
	var leader := String(group.leader)
	if not _group_has(f) and not (leader == my_id and k == "gjoin" and (_grp.invited as Dictionary).has(f)):
		return                       # only members, and a "gjoin" from an id the leader invited
	var n := int(d.n)
	if n <= int((_grp.their as Dictionary).get(f, -1)):
		return                       # replayed
	if not _bucket("g" + f, GROUP_RATE, 12.0):
		return
	_grp.their[f] = n
	var now := Time.get_ticks_msec()
	_grp.seen[f] = now
	if f == leader:
		_grp.leader_ms = now
	match k:
		"gjoin":
			if leader == my_id:
				_on_gjoin(f, d)
		"groster":
			if f == leader and leader != my_id:
				_on_groster(d)
		"gleave":
			if leader == my_id:
				_group_drop(f)
		"gkick":
			if f == leader and String(d.get("id", "")) == my_id:
				if in_room():
					_room_gone("THE HOST REMOVED YOU FROM ROOM %s")
				else:
					_group_close(false)
					group_changed.emit()
		"gend":
			if f == leader:
				if in_room():
					_room_gone("THE HOST CLOSED ROOM %s")
				else:
					_group_close(false)
					group_changed.emit()
		"gstart":
			if f == leader and leader != my_id:
				_on_gstart(d)
		"gslot":
			if leader == my_id and in_room():
				_on_gslot(f, d)


## The room's host: a player taps an empty place ("gslot" {"t": team, "s": the roster slot}); a
## place someone holds, or one that is not that team's, changes nothing.
func _on_gslot(f: String, d: Dictionary) -> void:
	var t: Variant = d.get("t")
	var s: Variant = d.get("s")
	if not NetGroup._whole(t) or not NetGroup._whole(s) or absf(float(t)) > 8.0 or absf(float(s)) > 64.0:
		return
	if NetGroup.take_empty(group.members, f, int(t), int(s), int(group.size)):
		_group_roster()
		group_changed.emit()


## The leader: an invited player joins (a new member gets its default side or the first free slot);
## a member that says it again gets the roster again.
func _on_gjoin(f: String, d: Dictionary) -> void:
	var members: Array = group.members
	var room := in_room()
	if not _group_has(f):
		if members.size() >= NetGroup.cap(int(group.size), room) or in_session or session_multi:
			return
		(_grp.invited as Dictionary).erase(f)
		var who := Game.clean_name(String(d.get("name", ""))) if typeof(d.get("name")) == TYPE_STRING else ""
		var b := String(CharacterModel.bundle_info(String(d.get("bundle", "default")) if typeof(d.get("bundle")) == TYPE_STRING else "default").id)
		members.append({"id": f, "name": who if who != "" else "PLAYER", "bundle": b, "team": NetGroup.room_side(members) if room else -1, "slot": -1})
		NetGroup.arrange(members, int(group.size), bool(_grp.manual), room)
		if search_needed > 0:
			search_found = members.size()
		group_changed.emit()
	_group_roster()


## A member: the leader's roster (checked by NetGroup.members_from) replaces what this phone had.
## Without this phone in it the leader dropped it (unless it is still joining).
func _on_groster(d: Dictionary) -> void:
	var size := int(d.get("size", 2)) if (d.get("size") is float or d.get("size") is int) else 2
	if size not in [1, 2, 4]:
		return
	var list := NetGroup.members_from(d.get("members"), String(group.leader), size, in_room())
	if list.is_empty():
		return
	var mine := false
	for m: Dictionary in list:
		mine = mine or String(m.id) == my_id
	if not mine:
		if bool(_grp.joining):
			pass
		elif in_room():
			_room_gone("YOU ARE NO LONGER IN ROOM %s")
		else:
			_group_close(false)
			group_changed.emit()
		return
	var g_status := String(d.get("status", "idle")) if typeof(d.get("status")) == TYPE_STRING else "idle"
	if g_status not in ["idle", "searching", "starting", "in_match"]:
		g_status = "idle"
	var mode := String(d.get("mode", "lonewolf")).left(16) if typeof(d.get("mode")) == TYPE_STRING else "lonewolf"
	var before := JSON.stringify([group.members, group.status, group.mode, group.size, search_found, search_needed, group.get("code", ""), group.get("code_join", false)])
	if bool(_grp.joining) and code_state == "in":
		code_state = ""                  # the join by code is done: in the group
	_grp.joining = false
	var gc: Variant = d.get("code")
	if typeof(gc) == TYPE_STRING and is_group_code(String(gc)):
		group.code = String(gc)
	group.code_join = typeof(d.get("cj")) == TYPE_BOOL and bool(d.cj)
	group.members = list
	group.status = g_status
	group.mode = mode
	group.size = size
	search_needed = 2 * size if g_status == "searching" and size in [2, 4] else 0
	var found: Variant = d.get("found")
	search_found = clampi(int(found) if (found is float or found is int) else list.size(), list.size(), search_needed) if search_needed > 0 else 0
	if JSON.stringify([group.members, group.status, group.mode, group.size, search_found, search_needed, group.get("code", ""), group.get("code_join", false)]) != before:
		group_changed.emit()


## Every frame while in a group: "gjoin" until in, the beats, the silent dropped, invites expired.
func _tick_group(delta: float, now: int) -> void:
	var leader := String(group.leader)
	if bool(_grp.joining):
		_grp.join_t = float(_grp.join_t) - delta
		if float(_grp.join_t) <= 0.0:
			_grp.join_t = GROUP_JOIN_S
			_group_send({"k": "gjoin", "name": String(Game.profile.name), "bundle": String(Game.profile.bundle)})
		if now - int(_grp.leader_ms) > JOIN_TIMEOUT_MS:
			if in_room():
				_room_gone("ROOM %s DID NOT LET YOU IN")
			else:
				_group_close(false)          # the leader never let this phone in
				group_changed.emit()
		return
	_grp.beat_t = float(_grp.beat_t) - delta
	if float(_grp.beat_t) <= 0.0:
		_grp.beat_t = GROUP_BEAT_S
		if leader == my_id:
			_group_roster()
		else:
			_group_send({"k": "gbeat"})
	if leader != my_id:
		if now - int(_grp.leader_ms) > GROUP_TIMEOUT_MS:
			if in_room():
				_room_gone("THE HOST OF ROOM %s LEFT")
			else:
				_group_close(false)          # the leader is gone: so is the group
				group_changed.emit()
		return
	var gone := []
	for m: Dictionary in group.members:
		if String(m.id) != my_id and now - int((_grp.seen as Dictionary).get(String(m.id), now)) > GROUP_TIMEOUT_MS:
			gone.append(String(m.id))
	for id: String in gone:
		_group_drop(id)
	var pending: Dictionary = _grp.invited
	for id: String in pending.keys():
		if now - int(pending[id]) > INVITE_TIMEOUT_MS:
			pending.erase(id)
			group_changed.emit()
	if (group.members as Array).size() <= 1 and pending.is_empty() and search_needed == 0 and not in_room():
		_group_close(false)              # nobody joined and no invite waits: no group (a room stays open)
		group_changed.emit()


## The leader starts the group's own match: a fresh match room and keys (inside the group room's
## encryption only) and the roster from the sides; everyone joins it, the leader hosts.
func _group_launch(size: int) -> void:
	_group_launch_with(size, NetGroup.match_roster(group.members), _crypto.generate_random_bytes(16).hex_encode(),
		_crypto.generate_random_bytes(32), _crypto.generate_random_bytes(32), my_id)


## This unit goes into a match (its own, or one matchmaking made, hosted by `host_id`): the members
## hear "gstart" in the group room, then this phone enters the match room.
func _group_launch_with(size: int, roster: Array, room: String, aes: PackedByteArray, mac: PackedByteArray, host_id: String) -> void:
	_mm_stop()
	search_needed = 0
	search_found = 0
	if not group.is_empty():
		group.status = "in_match"
		_group_send({"k": "gstart", "room": room, "aes": Marshalls.raw_to_base64(aes), "mac": Marshalls.raw_to_base64(mac), "size": size,
			"roster": NetGroup.pack_roster(roster), "host": host_id})
		_group_roster()
	_multi_enter(room, aes, mac, size, roster, host_id)
	group_changed.emit()


## A member: the leader's START. Its roster must hold this phone, the leader, and members only.
func _on_gstart(d: Dictionary) -> void:
	if in_session or session_multi or typeof(d.get("room")) != TYPE_STRING or typeof(d.get("aes")) != TYPE_STRING \
			or typeof(d.get("mac")) != TYPE_STRING or not (d.get("size") is float or d.get("size") is int):
		return
	var room := String(d.room)
	var aes := Marshalls.base64_to_raw(String(d.aes))
	var mac := Marshalls.base64_to_raw(String(d.mac))
	var size := int(d.size)
	var roster := NetGroup.roster_from(d.get("roster"), size)
	if room.length() != 32 or not room.is_valid_hex_number() or aes.size() != 32 or mac.size() != 32 or roster.is_empty():
		return
	# Only the leader sends it (inside the group's encryption): the group's own match, or one that
	# matchmaking made, hosted by "host" (the leader, or another unit's leader); it holds the whole group.
	var host := String(d.get("host", group.leader)) if typeof(d.get("host", group.leader)) == TYPE_STRING else ""
	var ids := {}
	for e: Dictionary in roster:
		ids[String(e.id)] = true
	if not ids.has(my_id) or not ids.has(String(group.leader)) or not ids.has(host):
		return
	for m: Dictionary in group.members:
		if not ids.has(String(m.id)):
			return
	seek_stop()
	_mm_stop()
	search_needed = 0
	search_found = 0
	group.status = "in_match"
	_multi_enter(room, aes, mac, size, roster, host)
	group_changed.emit()


# ---------------------------------------------------------------- the all-human match (session_multi)
# The match room ROOT/r/<room> with the 1 vs 1's packets, every member a sender with its own counter
# (replays dropped per sender), only roster members heard. Each member says "join" every second; the
# host, once it heard all of them (or JOIN_TIMEOUT_MS passed: those missing are LEFT), starts the
# session and answers "joined", which starts it on each member. Events and states come with their
# sender (event_from, state_from), at most MULTI_RATE a second from one member; "bye" from a member
# is member_left, from the host (or the host silent) the session's end ("left"). The host hears
# every member, so it ends the session when all of them left. No direct UDP path in these matches.

func _multi_enter(room: String, aes: PackedByteArray, mac: PackedByteArray, size: int, roster: Array, host_id: String) -> void:
	if in_session:
		end_session("left")
	clear_resume()
	if seeking:
		seek_stop()
	if _room != "":
		_leave_room()
	session_multi = true
	session_roster = roster.duplicate(true)
	session_host_id = host_id
	is_host = host_id == my_id
	session_rules = {}
	session_team = {"size": size, "coop": false}
	var ids := {}
	for e: Dictionary in roster:
		ids[String(e.id)] = int(e.slot)
	var now := Time.get_ticks_msec()
	_multi = {"ids": ids, "seq": {}, "heard": {}, "ka": {}, "joined": {}, "left": {}, "state_t": {}, "t0": now}
	opponent = {}
	_room = room
	_aes = aes
	_mac = mac
	_seq = 0
	_their_seq = -1
	_join_t = 0.0
	_last_heard = now
	_subscribe(ROOT + "/r/" + _room)


func _multi_start() -> void:
	if in_session or not session_multi:
		return
	var now := Time.get_ticks_msec()
	in_session = true
	_reset_away()
	_accept_ms = 0
	_session_ms = now
	_keep_t = 0.0
	peer_rtt = -1
	_peer_ping_t = 0.0
	_peer_pings.clear()
	_last_state = []
	_chat_in = [2.0, now]
	_chat_out_ms = 0
	queue.clear()
	_direct_end()
	_state_in_t = -1
	relay_states_out = 0
	relay_states_in = 0
	_last_heard = now
	for id: String in _multi.ids:
		if id != my_id:
			_multi.heard[id] = now
	if is_host:
		for id: String in _multi.ids:
			if id != my_id and not (_multi.joined as Dictionary).has(id):
				_multi.left[id] = true       # never came: LEFT from the start (the arena hears it)
		_room_send({"k": "joined"})
	session_started.emit(is_host)
	if is_host:
		for id: String in (_multi.left as Dictionary).keys():
			member_left.emit(id)


## The match never got going (the host never answered, or nobody joined the host).
func _multi_abort() -> void:
	_multi_reset()
	_leave_room()
	if not group.is_empty():
		group.status = "idle"
		_group_roster()
	group_changed.emit()


func _multi_reset() -> void:
	session_multi = false
	session_roster = []
	session_host_id = ""
	_multi = {}
	if not group.is_empty() and String(group.status) in ["starting", "in_match"]:
		group.status = "idle"
		_group_roster()
		group_changed.emit()


func _on_multi(d: Dictionary) -> void:
	var f := String(d.f)
	if f == my_id or not (_multi.ids as Dictionary).has(f) or (_multi.left as Dictionary).has(f) or Game.is_blocked(f):
		return
	var n := int(d.n)
	if n <= int((_multi.seq as Dictionary).get(f, -1)):
		return                       # replayed
	if not _bucket("m" + f, MULTI_RATE, MULTI_RATE):
		return
	_multi.seq[f] = n
	var now := Time.get_ticks_msec()
	_multi.heard[f] = now
	if is_host or f == session_host_id:
		_last_heard = now            # (a member waits on the host; the host on anyone)
		_present(now)
	if in_session:
		_set_away(f, false)
	var kind := String(d.get("k", ""))
	match kind:
		"join":
			if is_host:
				_multi.joined[f] = true
				if in_session:
					_room_send({"k": "joined"})
				elif (_multi.joined as Dictionary).size() >= (_multi.ids as Dictionary).size() - 1:
					_multi_start()
		"joined":
			if not is_host and f == session_host_id:
				_multi_start()
		"ka":
			_multi.ka[f] = now
			if is_host or f == session_host_id:
				_peer_ka_ms = now
		"pi":
			var i: Variant = d.get("i")
			if is_host and in_session and (i is float or i is int) and _pong_budget >= 1.0 and _arena_listens():
				_pong_budget -= 1.0
				_room_send({"k": "po", "i": int(i)})
		"po":
			var i: Variant = d.get("i")
			if f == session_host_id and (i is float or i is int) and _peer_pings.has(int(i)):
				peer_rtt = NetPing.smooth(peer_rtt, now - int(_peer_pings[int(i)]))
				_peer_pings.erase(int(i))
		"chat":
			var x: Variant = d.get("x")
			if in_session and typeof(x) == TYPE_STRING and bool(Game.settings.get("chat", true)) and _bucket("c" + f, 1.0 / NetChat.RATE_S, 2.0):
				var line := NetChat.clean(String(x).left(NetChat.MATCH_MAX * 4), NetChat.MATCH_MAX)
				if line != "":
					chat_received.emit(line)
		"vo":
			var a: Variant = d.get("a")
			if in_session and typeof(a) == TYPE_STRING and String(a).length() <= NetVoice.MAX_B64 and bool(Game.settings.get("voice_chat", false)) \
					and _bucket("v" + f, NetVoice.MAX_FRAMES_S, NetVoice.MAX_FRAMES_S):
				var frame := Marshalls.base64_to_raw(String(a))
				if NetVoice.frame_ok(frame):
					voice_received.emit(frame)
		"st":
			_on_multi_state(d, f)
		"ev":
			var ev: Variant = d.get("e", "")
			var data: Variant = d.get("d", [])
			if not in_session or typeof(ev) != TYPE_STRING or not data is Array or (data as Array).size() > 16:
				return
			for v: Variant in data:
				if typeof(v) not in [TYPE_FLOAT, TYPE_INT, TYPE_STRING, TYPE_BOOL]:
					return
			if String(ev) == "bye":
				_multi_member_left(f)
			elif not _arena_listens():
				if queue.size() < MAX_QUEUED:
					queue.append([String(ev), data, f])
			else:
				event_from.emit(String(ev), data, f)


## A member's state: STATE_SIZE numbers and its clock "t" (older than its newest: dropped).
func _on_multi_state(d: Dictionary, f: String) -> void:
	var s: Variant = d.get("s", [])
	if not in_session or not s is Array or (s as Array).size() != RemoteFighter.STATE_SIZE:
		return
	var out := PackedFloat32Array()
	for v: Variant in s:
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			return
		out.append(float(v))
	var t: Variant = d.get("t")
	var sent := int(t) if (t is float or t is int) and is_finite(float(t)) else -1
	if sent >= 0:
		if sent <= int((_multi.state_t as Dictionary).get(f, -1)):
			return
		_multi.state_t[f] = sent
	last_state_sent_ms = sent
	relay_states_in += 1
	state_from.emit(out, f)


## A member said "bye" or fell silent: LEFT (member_left); the host gone, or everyone gone for the
## host, ends the session ("left").
func _multi_member_left(f: String) -> void:
	if not session_multi or (_multi.left as Dictionary).has(f):
		return
	_multi.left[f] = true
	_away_ids.erase(f)
	if f == session_host_id:
		end_session("left")
		return
	if in_session:
		member_left.emit(f)
	if is_host and (_multi.left as Dictionary).size() >= (_multi.ids as Dictionary).size() - 1:
		end_session("left")


## Every frame in an all-human match: a member silent AWAY_AFTER_MS is AWAY, silent as long as a
## 1 vs 1 opponent may be it has left.
func _check_members(now: int) -> void:
	for id: String in (_multi.ids as Dictionary).keys():
		if id == my_id or (_multi.left as Dictionary).has(id):
			continue
		var heard := int((_multi.heard as Dictionary).get(id, now))
		_set_away(id, now - heard > AWAY_AFTER_MS)
		if id == session_host_id:
			continue
		var ka := int((_multi.ka as Dictionary).get(id, -100000))
		var wait_ms := grace_ms() + (LOAD_STALL_MS if now - ka < SILENCE_MS + LOAD_STALL_MS else 0)
		if now - heard > wait_ms:
			_multi_member_left(id)
			if not session_multi:
				return
