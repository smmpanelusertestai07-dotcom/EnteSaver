class_name HudTeam
extends Control
## STEP-0 SKELETON (contract). Owner after step 0: WP-B2 (match UI).
## DUO / SQUAD on the match HUD (HUD.bind attaches it when arena.team_size > 1, node "HudTeam", over
## the HUD like HudNet: its buttons take their touches first): the teammates under the minimap (a
## numbered badge in the team's blue, name, HP bar, KNOCKED with the bleed-out bar, OUT, LEFT), the
## REVIVE button beside FIRE while arena.revive_candidate(player) is not null (a tap:
## arena.start_revive; the progress ring; moving or firing cancels), the player's own KNOCKED
## overlay (BLEEDING OUT bar, "BEING REVIVED" with its progress), and once out "SPECTATING <NAME>"
## with NEXT (arena.spectate_next()). Reads the TeamArena API only.

var hud: HUD
var arena: Node


static func attach(h: HUD, a: Node) -> HudTeam:
	var t := HudTeam.new()
	t.name = "HudTeam"
	t.hud = h
	t.arena = a
	h.add_child(t)
	return t
