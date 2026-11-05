class_name TeamMatch
extends Node
## STEP-0 SKELETON v2 (contract). Owner after step 0: WP-B1 (lobby); the relay side is Cloud's
## (WP-N: team_seek_start / team_seek_stop / send_seek / seeker_seen / team_invite).
## QUICK MATCH for DUO / SQUAD: LONE WOLF's START with DUO or SQUAD (alone) searches for another
## player searching the same size: "seek" on ROOT/mm/t<size> (never retained, every SEEK_S; builds
## before 1.4.0 never listen there), the lower id of two seekers that see each other sends a quick
## team challenge (Cloud.team_invite(id, size, false, true): "tinv", which older builds ignore), the
## other takes it at once; the challenger hosts. Each player then has bot teammates against the
## other. Nobody within FILL_S: the match is played against bots on this phone
## (TeamArena.offline_match), said plainly ("NO PLAYER FOUND: YOUR TEAM VS BOTS"). The popup (node
## "Modal": "TeamStatus", "TeamTimer", "TeamFill" BOTS IN 0:nn, "TeamCancel") is like QUICK MATCH's;
## CANCEL, X and back stop the search. The 1 vs 1 QUICK MATCH (NetMatch) is untouched.

const SEEK_S := 2.0
const FILL_S := 25.0                      # LW_FILL_S overrides it in test runs

var lobby: Lobby
var size := 2
var searching := false
var elapsed := 0.0


## START with DUO / SQUAD in LONE WOLF: opens the search (or brings back the one running).
static func open(owner_lobby: Lobby, team_size: int) -> TeamMatch:
	var m := owner_lobby.get_node_or_null("TeamMatch") as TeamMatch
	if m == null:
		m = TeamMatch.new()
		m.name = "TeamMatch"
		m.lobby = owner_lobby
		owner_lobby.add_child(m)
	m.size = team_size
	return m


func cancel() -> void:
	searching = false
