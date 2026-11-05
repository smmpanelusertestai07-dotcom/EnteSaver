class_name NetMatch
extends Node
## QUICK MATCH: LONE WOLF's START finds a random 1 vs 1 opponent through the relay.
## While searching, this phone says "seek" on Cloud.SEEK_TOPIC every SEEK_S (short-lived, never
## retained) with its id and the seekers it heard lately. Once two seekers see each other (the
## other's seek lists this phone), the one with the lower id sends the usual encrypted duel
## challenge marked quick (Cloud.invite(id, {"quick": true})); the other takes it at once, but only
## from a seeker it heard (Cloud._on_inbox), and the duel goes on as any other (host = the
## challenger): the lobby loads the match on Cloud.session_started. Never this phone itself, never a
## blocked player, only who DUEL CHALLENGES FROM allows; after GIVE_UP_S a short note ends it.
## The popup (node "Modal": "QuickStatus", "QuickTimer", "QuickNote", "QuickCancel") shows the
## time searched; CANCEL, its X and Android back stop the search. Friends' direct duels (ONLINE 1
## VS 1) are untouched.

const SEEK_S := 2.0
const GIVE_UP_S := 60.0
const SEEN_MS := 6000          # a seeker not heard this long is left out of "saw"
const SNUB_MS := 15000         # a seeker that said no (or never got going) is skipped this long

var lobby: Lobby
var searching := false
var elapsed := 0.0
var _seek_t := 0.0
var _asked := ""               # the seeker our quick challenge went to
var _snubbed := {}             # id -> ms
var _modal: Control
var _status: Label
var _timer: Label
var _note: Label
var _cancel: Button


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
	_build()
	if int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE)) == Game.CHALLENGES_NOBODY:
		_end("DUEL CHALLENGES FROM IS NOBODY (SETTINGS, ONLINE): NOBODY CAN BE MATCHED WITH YOU.")
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


## CANCEL, X, back: the search stops (a challenge on its way is called off).
func cancel() -> void:
	stop()
	if lobby and lobby.dialogs.modal == _modal:
		lobby.dialogs.close_modal()


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
	if _timer:
		_timer.text = "%d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]
	if _status:
		if not cloud.opponent.is_empty():
			_status.text = "OPPONENT FOUND: %s" % String(cloud.opponent.get("name", "PLAYER"))
		elif cloud.status != "online":
			_status.text = "CONNECTING..."
		else:
			_status.text = "SEARCHING..."
	_seek_t -= delta
	if _seek_t <= 0.0:
		_seek_t = SEEK_S
		cloud.send_seek(_saw(cloud))
	# 60 s without a match: a short note (a pairing already under way is let finish).
	if elapsed >= GIVE_UP_S and cloud.opponent.is_empty() and cloud.waiting_for() == "":
		_end("NO OPPONENT FOUND. TRY AGAIN LATER, OR CHALLENGE A FRIEND IN ONLINE 1 VS 1.")


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


## The popup: SEARCHING..., the time searched, CANCEL.
func _build() -> void:
	if _modal and is_instance_valid(_modal) and lobby.dialogs.modal == _modal:
		return
	var v := lobby.dialogs.open_modal("QUICK MATCH", 640.0)
	_modal = lobby.dialogs.modal
	_modal.set_meta("on_back", cancel)
	_status = UI.label("SEARCHING...", 30, UI.ACCENT)
	_status.name = "QuickStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_status)
	_timer = UI.label("0:00", 40, UI.TEXT)
	_timer.name = "QuickTimer"
	_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_timer)
	_note = UI.label("A random player who pressed START in LONE WOLF too", 17, UI.TEXT_DIM, "semi")
	_note.name = "QuickNote"
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_note)
	_cancel = UI.button("CANCEL", 22, "dark", Vector2(240, 54))
	_cancel.name = "QuickCancel"
	_cancel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel.pressed.connect(cancel)
	v.add_child(_cancel)
	if not lobby.dialogs.modal_closed.is_connected(_on_modal_closed):
		lobby.dialogs.modal_closed.connect(_on_modal_closed)


## Our popup went (the match loads, another popup took its place): the search ends with it.
func _on_modal_closed() -> void:
	if _modal and (not is_instance_valid(_modal) or _modal.is_queued_for_deletion()) and searching:
		stop()


## The search is over without a match: the note, and CANCEL becomes OK.
func _end(why: String) -> void:
	stop()
	if _status:
		_status.text = "NO MATCH"
	if _note:
		_note.text = why
	if _cancel:
		UI.set_caption(_cancel, "OK")
