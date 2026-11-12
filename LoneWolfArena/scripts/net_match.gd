class_name NetMatch
extends Node
## QUICK MATCH: LONE WOLF's START finds a random 1 vs 1 opponent through the relay.
## While searching, this phone says "seek" on Cloud.SEEK_TOPIC every SEEK_S (short-lived, never
## retained) with its id and the seekers it heard lately. Once two seekers see each other (the
## other's seek lists this phone), the one with the lower id sends the usual encrypted duel
## challenge marked quick (Cloud.invite(id, {"quick": true})); the other takes it at once, but only
## from a seeker it heard (Cloud._on_inbox), and the duel goes on as any other (host = the
## challenger): the lobby loads the match on Cloud.session_started. Never this phone itself, never a
## blocked player, only who DUEL CHALLENGES FROM allows. The search never gives up by itself: it
## runs until CANCEL.
## No popup: the lobby's search tab (SearchTab, Lobby.search_tab) shows the time searched and
## status_line(), its X (and Android back with no window open) calls cancel(); the lobby stays
## usable meanwhile. Friends' direct duels (ONLINE 1 VS 1) are untouched.

const SEEK_S := 2.0
const SEEN_MS := 6000          # a seeker not heard this long is left out of "saw"
const SNUB_MS := 15000         # a seeker that said no (or never got going) is skipped this long

var lobby: Lobby
var searching := false
var elapsed := 0.0
var _seek_t := 0.0
var _asked := ""               # the seeker our quick challenge went to
var _snubbed := {}             # id -> ms


## START in LONE WOLF: opens the search (or brings back the one running).
static func open(owner_lobby: Lobby) -> NetMatch:
	var m := owner_lobby.get_node_or_null("NetMatch") as NetMatch
	if m == null:
		m = NetMatch.new()
		m.name = "NetMatch"
		m.lobby = owner_lobby
		owner_lobby.add_child(m)
	m.start()
	return m


## May a quick match pair this phone with `id`? DUEL CHALLENGES FROM decides (everyone, friends
## only, nobody); blocked players and this phone itself never.
static func allowed(id: String, mine: String) -> bool:
	if id == "" or id == mine or Game.is_blocked(id):
		return false
	var who_may := int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE))
	return who_may == Game.CHALLENGES_EVERYONE or (who_may == Game.CHALLENGES_FRIENDS and Game.is_friend(id))


func start() -> void:
	var cloud := Game.cloud_service()
	if int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE)) == Game.CHALLENGES_NOBODY:
		stop()
		if lobby:
			lobby.dialogs.notice("QUICK MATCH", "DUEL CHALLENGES FROM IS NOBODY (SETTINGS, ONLINE): NOBODY CAN BE MATCHED WITH YOU.")
		return
	if searching:
		return
	searching = true
	elapsed = 0.0
	_seek_t = 0.0
	_asked = ""
	cloud.start_lobby()
	cloud.seek_start()
	if not cloud.seeker_seen.is_connected(_on_seeker):
		cloud.seeker_seen.connect(_on_seeker)
		cloud.invite_answered.connect(_on_answered)
		cloud.invite_failed.connect(_on_failed)


## The search tab's X, back: the search stops (a challenge on its way is called off).
func cancel() -> void:
	stop()


func stop() -> void:
	var cloud := Game.cloud_service()
	if searching and not cloud.in_session and _asked != "" and cloud.waiting_for() != "":
		cloud.cancel_invite()
	searching = false
	_asked = ""
	cloud.seek_stop()


func _exit_tree() -> void:
	if searching:
		stop()
	var cloud := Game.cloud
	if cloud and cloud.seeker_seen.is_connected(_on_seeker):
		cloud.seeker_seen.disconnect(_on_seeker)
		cloud.invite_answered.disconnect(_on_answered)
		cloud.invite_failed.disconnect(_on_failed)


func _process(delta: float) -> void:
	if not searching:
		return
	var cloud := Game.cloud_service()
	if cloud.in_session:
		stop()                       # paired: the lobby loads the match
		return
	elapsed += delta
	_seek_t -= delta
	if _seek_t <= 0.0:
		_seek_t = SEEK_S
		cloud.send_seek(_saw(cloud))


## The seekers heard lately (they go out with this phone's seek).
func _saw(cloud: Cloud) -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	for id: String in cloud.quick_seen:
		if now - int(cloud.quick_seen[id]) < SEEN_MS and allowed(id, cloud.my_id):
			out.append(id)
	return out


func _on_seeker(id: String, saw: Array) -> void:
	var cloud := Game.cloud_service()
	if not searching or cloud.in_session or not cloud.opponent.is_empty() or cloud.waiting_for() != "":
		return
	if not allowed(id, cloud.my_id) or Time.get_ticks_msec() - int(_snubbed.get(id, -SNUB_MS)) < SNUB_MS:
		return
	# Both see each other: the lower id challenges, the other one waits for it.
	if cloud.my_id < id and saw.has(cloud.my_id) and cloud.invite(id, {"quick": true}):
		_asked = id


func _on_answered(accepted: bool, _who: String) -> void:
	if searching and not accepted and _asked != "":
		_snubbed[_asked] = Time.get_ticks_msec()
		_asked = ""


func _on_failed(_who: String) -> void:
	if searching:
		_asked = ""


## The search tab's small line: CONNECTING... while the relay is not reached, the opponent's name
## once one is found, else "" (the tab's own estimate / STILL SEARCHING...).
func status_line() -> String:
	var cloud := Game.cloud_service()
	if not cloud.opponent.is_empty():
		return "OPPONENT FOUND: %s" % String(cloud.opponent.get("name", "PLAYER"))
	if cloud.status != "online":
		return "CONNECTING..."
	return ""
