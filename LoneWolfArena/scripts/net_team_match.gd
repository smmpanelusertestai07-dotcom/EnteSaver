class_name TeamMatch
extends Node
## QUICK MATCH for DUO / SQUAD: LONE WOLF's START with DUO or SQUAD searches for another player
## searching the same size (the relay side is Cloud's: team_seek_start / team_seek_stop / send_seek /
## seeker_seen / team_invite). "seek" on ROOT/mm/t<size> (never retained, every SEEK_S; builds
## before 1.4.0 never listen there); the lower id of two seekers that see each other sends a quick
## team challenge (Cloud.team_invite(id, size, false, true): "tinv", which older builds ignore), the
## other takes it at once; the challenger hosts. Each player then leads bot teammates against the
## other (the lobby loads the match on Cloud.session_started: LobbyFriends._on_net_session,
## TeamArena.link_match). Nobody within fill_s(): the match is played against bots on this phone
## (TeamArena.offline_match, counted as DUO / SQUAD), said plainly on its loading card ("NO PLAYER
## FOUND: YOUR TEAM VS BOTS"). The popup (node "Modal": "TeamStatus", "TeamTimer", "TeamFill" BOTS
## IN 0:nn, "TeamNote", "TeamCancel") is like QUICK MATCH's; CANCEL, X and back stop the search.
## The 1 vs 1 QUICK MATCH (NetMatch) is untouched.

const SEEK_S := 2.0
const FILL_S := 25.0                      # LW_FILL_S overrides it in test runs
const SEEN_MS := 6000                     # a seeker not heard this long is left out of "saw"
const SNUB_MS := 15000                    # a seeker that said no is skipped this long

var lobby: Lobby
var size := 2
var searching := false
var elapsed := 0.0
var _seek_t := 0.0
var _asked := ""                          # the seeker our quick team challenge went to
var _snubbed := {}                        # id -> ms
var _modal: Control
var _status: Label
var _timer: Label
var _fill: Label
var _note: Label
var _cancel: Button


## START with DUO / SQUAD in LONE WOLF: opens the search (or brings back the one running).
static func open(owner_lobby: Lobby, team_size: int) -> TeamMatch:
	var m := owner_lobby.get_node_or_null("TeamMatch") as TeamMatch
	if m == null:
		m = TeamMatch.new()
		m.name = "TeamMatch"
		m.lobby = owner_lobby
		owner_lobby.add_child(m)
	if m.searching and m.size != team_size:
		m.stop()
	m.size = team_size
	m.start()
	return m


## How long the search waits for another player before the match against bots: FILL_S, or
## LW_FILL_S in test runs of the editor binary (never an exported game).
static func fill_s() -> float:
	if not OS.has_feature("template") and OS.get_environment("LW_FILL_S") != "":
		return maxf(float(OS.get_environment("LW_FILL_S")), 1.0)
	return FILL_S


func start() -> void:
	var cloud := Game.cloud_service()
	_build()
	if int(Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE)) == Game.CHALLENGES_NOBODY:
		_end("DUEL CHALLENGES FROM IS NOBODY (SETTINGS, ONLINE): NOBODY CAN BE MATCHED WITH YOU. TRAINING GROUND PLAYS %s AGAINST BOTS." % _word())
		return
	if searching:
		return
	searching = true
	elapsed = 0.0
	_seek_t = 0.0
	_asked = ""
	cloud.start_lobby()
	cloud.team_seek_start(size)
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
	cloud.team_seek_stop()


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
	var left := maxf(fill_s() - elapsed, 0.0)
	if _timer:
		_timer.text = "%d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]
	if _fill:
		_fill.text = "BOTS IN %d:%02d" % [int(ceilf(left)) / 60, int(ceilf(left)) % 60]
	if _status:
		if not cloud.opponent.is_empty():
			_status.text = "PLAYER FOUND: %s" % String(cloud.opponent.get("name", "PLAYER"))
		elif cloud.status != "online":
			_status.text = "CONNECTING..."
		else:
			_status.text = "SEARCHING..."
	_seek_t -= delta
	if _seek_t <= 0.0 and cloud.seek_team == size:      # (seeks go out only on the team topic, never the 1 vs 1's)
		_seek_t = SEEK_S
		cloud.send_seek(_saw(cloud))
	# Nobody in time: this player's team against bots, here (a pairing under way is let finish).
	if left <= 0.0 and cloud.opponent.is_empty() and cloud.waiting_for() == "" and not cloud.has_invite():
		_fill_with_bots()


## The seekers heard lately (they go out with this phone's seek).
func _saw(cloud: Cloud) -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	for id: String in cloud.quick_seen:
		if now - int(cloud.quick_seen[id]) < SEEN_MS and NetMatch.allowed(id, cloud.my_id):
			out.append(id)
	return out


func _on_seeker(id: String, saw: Array) -> void:
	var cloud := Game.cloud_service()
	if not searching or cloud.in_session or not cloud.opponent.is_empty() or cloud.waiting_for() != "":
		return
	if not NetMatch.allowed(id, cloud.my_id) or Time.get_ticks_msec() - int(_snubbed.get(id, -SNUB_MS)) < SNUB_MS:
		return
	# Both see each other: the lower id challenges, the other one takes it at once (Cloud).
	if cloud.my_id < id and saw.has(cloud.my_id) and cloud.team_invite(id, size, false, true):
		_asked = id


func _on_answered(accepted: bool, _who: String) -> void:
	if searching and not accepted and _asked != "":
		_snubbed[_asked] = Time.get_ticks_msec()
		_asked = ""


func _on_failed(_who: String) -> void:
	if searching:
		_asked = ""


## Nobody found: the match is this player's team against bots on this phone (NORMAL bots), counted
## as DUO / SQUAD; its loading card says so.
func _fill_with_bots() -> void:
	stop()
	if lobby == null or lobby.start_btn.disabled:
		return
	if _status:
		_status.text = "NO PLAYER FOUND"
	Game.team_match = TeamArena.offline_match(size, "duo" if size == 2 else "squad", 1)
	lobby.dialogs.close_modal()
	lobby.load_match()


func _word() -> String:
	return "DUO" if size == 2 else "SQUAD"


## The popup: SEARCHING..., the time searched, BOTS IN 0:nn, CANCEL.
func _build() -> void:
	if _modal and is_instance_valid(_modal) and lobby.dialogs.modal == _modal:
		return
	var v := lobby.dialogs.open_modal("%s MATCH" % _word(), 640.0)
	_modal = lobby.dialogs.modal
	_modal.set_meta("on_back", cancel)
	_status = UI.label("SEARCHING...", 30, UI.ACCENT)
	_status.name = "TeamStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_status)
	_timer = UI.label("0:00", 40, UI.TEXT)
	_timer.name = "TeamTimer"
	_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_timer)
	var left := int(ceilf(fill_s()))
	_fill = UI.label("BOTS IN %d:%02d" % [left / 60, left % 60], 20, UI.TEXT, "heavy")
	_fill.name = "TeamFill"
	_fill.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_fill)
	var mates := "a bot" if size == 2 else "%d bots" % (size - 1)
	_note = UI.label("A random player who pressed START in LONE WOLF %s too: each of you leads %s. Nobody found in time: your team plays against bots." % [_word(), mates],
		17, UI.TEXT_DIM, "semi")
	_note.name = "TeamNote"
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(560, 0)
	v.add_child(_note)
	_cancel = UI.button("CANCEL", 22, "dark", Vector2(240, 56))
	_cancel.name = "TeamCancel"
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
	if _fill:
		_fill.text = ""
	if _note:
		_note.text = why
	if _cancel:
		UI.set_caption(_cancel, "OK")
