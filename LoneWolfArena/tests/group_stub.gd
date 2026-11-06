extends RefCounted
## TEST-ONLY stand-in for Cloud's group API (design/GROUPS.txt 3, CORE's) so the lobby's group parts
## can be driven before (and without) the real one: put it in LobbyTeam.stand_in before the lobby
## opens, set `group` and emit group_changed. It keeps every call the lobby made in `calls`.
## Member entries in `group.members`: {"id", "name", "bundle"} in join order (the leader is
## group.leader); optional "team" / "slot" (TEAMS).

signal group_changed
signal group_invited(from_name: String)

const GROUP_MAX := 4

var group := {}
var search_found := 0
var search_needed := 0
var my_id := "me".sha256_text().left(32)
var invite := {}                         # what group_invite_from() returns
var start_answer := ""                   # what group_start() returns
var invite_ok := true                    # what group_invite() returns
var calls: Array = []


func in_group() -> bool:
	return not group.is_empty()


func is_group_leader() -> bool:
	return group.is_empty() or String(group.get("leader", "")) == my_id


func group_members() -> Array:
	var out: Array = []
	var lead := String(group.get("leader", ""))
	var list: Array = group.get("members", [])
	for m: Dictionary in list:
		if String(m.id) == lead:
			out.push_front(_member(m, lead))
		else:
			out.append(_member(m, lead))
	return out


func _member(m: Dictionary, lead: String) -> Dictionary:
	var e := {"id": String(m.id), "name": String(m.get("name", "PLAYER")), "bundle": String(m.get("bundle", "default")),
		"leader": String(m.id) == lead, "me": String(m.id) == my_id}
	if m.has("team"):
		e["team"] = int(m.team)
		e["slot"] = int(m.get("slot", 0))
	return e


func group_invite(friend_id: String) -> bool:
	calls.append(["group_invite", friend_id])
	return invite_ok


func group_invite_from() -> Dictionary:
	return invite


func answer_group_invite(accept: bool) -> void:
	calls.append(["answer_group_invite", accept])
	invite = {}


func leave_group() -> void:
	calls.append(["leave_group"])
	group = {}
	group_changed.emit()


func kick_from_group(id: String) -> void:
	calls.append(["kick_from_group", id])


func set_group_mode(mode: String, size: int) -> void:
	calls.append(["set_group_mode", mode, size])
	if not group.is_empty():
		group.mode = mode
		group.size = size


func set_group_team(member_id: String, team: int, slot: int) -> void:
	calls.append(["set_group_team", member_id, team, slot])


func group_start(size: int) -> String:
	calls.append(["group_start", size])
	return start_answer


func group_search_stop() -> void:
	calls.append(["group_search_stop"])
	search_needed = 0
	search_found = 0


## A friend's GROUP INVITE arrives (what Cloud does for a "ginv" while the lobby listens).
func send_invite(from_id: String, from_name: String) -> void:
	invite = {"id": from_id, "name": from_name, "bundle": "default"}
	group_invited.emit(from_name)


## The last call to `method` ([] when none).
func last(method: String) -> Array:
	for i in range(calls.size() - 1, -1, -1):
		if String(calls[i][0]) == method:
			return calls[i]
	return []
