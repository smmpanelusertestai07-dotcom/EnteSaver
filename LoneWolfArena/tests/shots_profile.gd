extends Node
## PROFILE screenshot tour, with real taps and checks:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_profile.gd
## tools/qa/run_checks.sh runs it headless as well (every check, no pictures; the canvas is set to
## the phone's 1560 x 720 then).
## A played-in profile (made up here). The lobby's player card shows its picture and opens PROFILE
## on CAREER (rates, averages, the row per mode); HISTORY with its matches (scrolled by a finger
## swipe that starts on a row), NAME CARD (a banner and a picture picked by taps: the name card
## follows at once), the signature editor, COPY (the whole player ID on the clipboard), BLOCKED
## (UNBLOCK asks first; a blocked player's card offers UNBLOCK), HISTORY empty; back closes
## PROFILE. Then other players' cards from the ONLINE window: a friend who is online (FRIENDS tab:
## DUEL 1 VS 1, REMOVE FRIEND) and a stranger who is offline (ALL PLAYERS: ADD FRIEND, no duel),
## BLOCK asked first, after which the stranger is gone from the list; a swipe on a name scrolls
## the long ALL PLAYERS list without opening a card. A challenge that comes in over an open
## question waits for it, then shows with BLOCK; back declines it. Every button on these screens is checked for
## a 56 px touch target, and nothing in a scrolling list may keep a finger's touch from the
## scroll. The online service is pointed at a local port nobody listens on, so no public relay is
## reached and every other player shown is made up here. Returns the number of failed checks.

## The made-up players: [id seed, name, outfit, picture, banner, level, signature, seconds since seen].
const FRIEND := ["tour-friend", "NIGHTFOX21", "shadow", "shadow", "gold_rush", 23, "DUEL ME AFTER 9 PM", 40]
const STRANGER := ["tour-stranger", "IRONFALCON07", "desert", "desert", "shards", 7, "NO CAMPING PLEASE", 3 * 3600 + 600]
const BLOCKED_KNOWN := ["tour-blocked-1", "TOXICTOM", "default", "emblem", "default", 2, "", 2 * 86400]
const BLOCKED_UNKNOWN := "tour-blocked-2"
## More players under ALL PLAYERS (offline, seen days ago), so the list is longer than the
## screen: [name, days since seen].
const CROWD := [["SWIFTRAVEN11", 1], ["NEONLYNX42", 2], ["IRONBISON07", 2], ["GOLDVIPER88", 3], ["FROSTPUMA19", 4],
	["WILDHAWK03", 5], ["STEELCOBRA61", 6], ["DUSTYSHARK25", 8], ["NIGHTTIGER14", 9], ["ROGUEEAGLE70", 11],
	["LUCKYFALCON5", 13], ["STORMJACKAL9", 15], ["TURBOBEAR33", 18], ["SILENTFOX46", 21], ["BLAZERHINO12", 26],
	["GHOSTWOLF77", 30]]

var _fails := 0
var _at: Node


func run(at: Node) -> int:
	_at = at
	if DisplayServer.get_name() == "headless":
		get_tree().root.size = Vector2i(1560, 720)      # a headless window has no size of its own
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	var first := await _wait_scene("Lobby", 30.0)
	# A fresh online service that only knows a dead local relay (read when it starts), then a new
	# lobby with the made-up profile. The lobby's service is replaced once its key exists (it is
	# made on a worker thread, which keeps the service busy; the new one loads the saved key).
	OS.set_environment("LW_MQTT_URL", "ws://127.0.0.1:9")
	var old_cloud := Game.cloud_service()
	var wait_t := 0.0
	while old_cloud.my_id == "" and wait_t < 60.0:
		await _at.wait(0.2)
		wait_t += 0.2
	_check(old_cloud.my_id != "", "the lobby's online service has its key")
	old_cloud.free()
	Game.cloud = null
	Game.profile = _sample_profile()
	Game.goto_lobby()
	var lobby := await _next_lobby(first)
	if lobby == null:
		return _done(saved_profile)
	await _settle(1.0)
	var cloud := Game.cloud_service()
	var t := 0.0
	while cloud.my_id == "" and t < 20.0:
		await _at.wait(0.2)
		t += 0.2
	_check(cloud.my_id != "", "the player ID exists (key made or loaded)")
	await _at.shot("p00_lobby")
	# The player card opens PROFILE on CAREER.
	var card := lobby.find_child("PlayerCard", true, false) as Control
	_check(card != null and lobby.find_child("PlayerAvatar", true, false) != null, "the lobby's player card shows the profile picture")
	_touch_targets(card, "the lobby's player card (its pencil)")
	if card:
		await _tap_at(card.get_global_rect().position + Vector2(34, 31))
		await _settle(0.6)
	var layer := lobby.find_child("Profile", true, false) as Control
	_check(layer != null, "the player card opens PROFILE")
	if layer == null:
		return _done(saved_profile)
	_check(_text(layer, "Career_matches") == "48" and _text(layer, "Career_win_rate") == "60.4%" and _text(layer, "Career_kd") == "1.56"
		and _text(layer, "Career_headshot_rate") == "9.0%" and _text(layer, "Career_accuracy") == "37.3%"
		and _text(layer, "Career_avg_damage") == "1,276" and _text(layer, "Career_time_played") == "8H 24M",
		"CAREER shows the numbers, rates and averages")
	var lw := layer.find_child("CareerMode_lonewolf", true, false)
	_check(layer.find_child("CareerMode_training", true, false) != null and lw != null and _text(lw, "Matches") == "12"
		and _text(lw, "Wins") == "6" and _text(lw, "Kills") == "34", "CAREER has a row per mode")
	_check(_text(layer, "CardName") == "SHADOWHUNTER99" and _text(layer, "CardLevel") == "LV 12"
		and _text(layer, "CardId") == "#" + Cloud.friend_code(cloud.my_id) and _text(layer, "CardSignature") == "“ALWAYS ONE MORE ROUND”"
		and _text(layer, "CardSince").begins_with("PLAYING SINCE ") and _text(layer, "CardOutfit") == "NEON STRIKER",
		"the name card: name, level, short player ID, signature, outfit, playing since")
	var grid := layer.find_child("Career", true, false) as Control
	var body0 := layer.find_child("ProfileBody", true, false) as Control
	_check(grid != null and body0 != null and grid.get_global_rect().end.x <= body0.get_global_rect().end.x + 0.5,
		"CAREER's plates (HEADSHOT RATE (PER HIT) the longest caption) fit the tab")
	_touch_targets(layer, "CAREER")
	await _at.shot("p01_career")
	# HISTORY: every match, newest first; it scrolls.
	await _tap(layer.find_child("ProfileTab_history", true, false) as Control)
	await _settle(0.4)
	var rows := 0
	for i in 30:
		if layer.find_child("HistoryRow_%d" % i, true, false):
			rows += 1
	var row0 := layer.find_child("HistoryRow_0", true, false)
	_check(rows == (Game.profile.history as Array).size() and row0 != null and _text(row0, "Result") == "VICTORY"
		and _text(row0, "Enemy") == "VS  NIGHTFOX21" and _text(row0, "Score") == "5 - 3" and _text(row0, "When").ends_with("MIN AGO"),
		"HISTORY lists every match, newest first (%d rows)" % rows)
	_touch_targets(layer, "HISTORY")
	await _at.shot("p02_history")
	# A match against another player opens their card (a bot match is a plain row); back returns.
	_check(row0 is BaseButton and not (layer.find_child("HistoryRow_2", true, false) is BaseButton),
		"HISTORY: a row against another player is a button, a bot match is not")
	await _tap(row0 as Control)
	await _settle(0.6)
	var opp := lobby.get("_modal") as Control
	_check(opp != null and _text(opp, "CardName") == FRIEND[1] and opp.find_child("PlayerBlock", true, false) != null,
		"a HISTORY row opens the opponent's card (to add, challenge or block them)")
	await _at.shot("p02c_history_card")
	_back()
	await _settle(0.4)
	_check(lobby.get("_modal") == null and _tab_of(lobby) == "history", "back closes the card, HISTORY is still open")
	# A finger swipe that starts on a row (here the button row) scrolls the list and opens nothing.
	var body := layer.find_child("ProfileBody", true, false) as ScrollContainer
	row0 = layer.find_child("HistoryRow_0", true, false)
	if body and row0:
		await _swipe((row0 as Control).get_global_rect().get_center(), -300.0)
		_check(body.scroll_vertical > 0 and lobby.get("_modal") == null,
			"a finger swipe that starts on a HISTORY row scrolls the list (%d px) and opens no card" % body.scroll_vertical)
	await _at.shot("p02b_history_scrolled")
	# NAME CARD: a banner and a picture by taps; the name card and the lobby's card follow.
	await _tap(layer.find_child("ProfileTab_namecard", true, false) as Control)
	await _settle(0.4)
	_check(layer.find_child("Banner_contour", true, false) != null and layer.find_child("Avatar_emblem", true, false) != null,
		"NAME CARD offers the banners and the profile pictures")
	await _tap(layer.find_child("Banner_hive", true, false) as Control)
	await _settle(0.2)
	await _tap(layer.find_child("Avatar_royal", true, false) as Control)
	await _settle(0.4)
	_check(Game.profile.banner == "hive" and Game.profile.avatar == "royal", "tapping a banner and a picture picks them at once")
	_check(Cloud.my_card().banner == "hive" and Cloud.my_card().avatar == "royal", "the public card follows the picks")
	_touch_targets(layer, "NAME CARD")
	await _at.shot("p03_namecard")
	# The signature editor (cleaned like a name).
	await _tap(layer.find_child("CardEditSignature", true, false) as Control)
	await _settle(0.5)
	var sig_edit := lobby.find_child("SignatureEdit", true, false) as LineEdit
	_check(sig_edit != null, "the signature's EDIT opens its editor")
	if sig_edit:
		sig_edit.text = "momentum wins matches, warrior"         # a long one: 29 characters once cleaned
		_touch_targets(lobby.get("_modal") as Node, "the signature editor")
		await _at.shot("p03b_signature")
		await _tap(lobby.find_child("SignatureOk", true, false) as Control)
		await _settle(0.4)
	_check(Game.profile.signature == "MOMENTUM WINS MATCHES WARRIOR" and _text(layer, "CardSignature") == "“MOMENTUM WINS MATCHES WARRIOR”"
		and lobby.get("_modal") == null, "OK keeps the cleaned signature and the card shows it (%s)" % Game.profile.signature)
	_check(_text_fits(layer.find_child("CardSignature", true, false) as Label), "a long signature fits the name card whole (no ...)")
	# COPY: the whole player ID on the clipboard, COPIED for a moment (a headless run has no
	# clipboard, the engine would only complain: there it is left out).
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		await _tap(layer.find_child("CardCopy", true, false) as Control)
		await _settle(0.2)
		var copy := layer.find_child("CardCopy", true, false) as Button
		_check(DisplayServer.clipboard_get() == cloud.my_id and copy != null and copy.text == "COPIED",
			"COPY puts the whole player ID on the clipboard and says COPIED")
	# BLOCKED: the name kept with the block (nothing else here knows TOXICTOM), the short ID for a
	# block without one; UNBLOCK asks first. While it shows, the player cards are listened to.
	await _tap(layer.find_child("ProfileTab_blocked", true, false) as Control)
	await _settle(0.4)
	_check(_cards_wanted(cloud, "profile"), "BLOCKED listens to the player cards (their names and cards arrive)")
	var known_id := _id(BLOCKED_KNOWN[0])
	var unknown_id := _id(BLOCKED_UNKNOWN)
	var known_btn := layer.find_child("Player_" + Cloud.friend_code(known_id), true, false) as Button
	var unknown_btn := layer.find_child("Player_" + Cloud.friend_code(unknown_id), true, false) as Button
	_check(known_btn != null and known_btn.text == "TOXICTOM  #" + Cloud.friend_code(known_id) and unknown_btn != null
		and unknown_btn.text == "#" + Cloud.friend_code(unknown_id), "BLOCKED: the name when known, else the short ID")
	_touch_targets(layer, "BLOCKED")
	await _at.shot("p04_blocked")
	await _tap(layer.find_child("Unblock_" + Cloud.friend_code(unknown_id), true, false) as Control)
	await _settle(0.4)
	var ask := lobby.get("_modal") as Control
	_check(ask != null and ask.find_child("ConfirmOk", true, false) != null and Game.is_blocked(unknown_id), "UNBLOCK asks first")
	if ask:
		_touch_targets(ask, "the UNBLOCK question")
	await _at.shot("p04b_unblock_question")
	await _tap(lobby.find_child("ConfirmCancel", true, false) as Control)
	await _settle(0.4)
	_check(Game.is_blocked(unknown_id) and lobby.get("_modal") == null and lobby.find_child("Profile", true, false) != null,
		"CANCEL keeps the block, PROFILE stays open")
	# A blocked player's card: UNBLOCK, no friend or duel buttons; back returns to BLOCKED.
	await _tap(layer.find_child("Player_" + Cloud.friend_code(known_id), true, false) as Control)
	await _settle(0.5)
	var pop := lobby.get("_modal") as Control
	_check(pop != null and _text(pop, "CardName") == "TOXICTOM" and (pop.find_child("PlayerBlock", true, false) as Button).text == "UNBLOCK"
		and pop.find_child("PlayerFriend", true, false) == null and pop.find_child("PlayerDuel", true, false) == null
		and _text(pop, "PlayerSignature") == "NO NAME CARD SEEN YET", "a blocked player's card offers UNBLOCK only")
	await _at.shot("p04c_blocked_card")
	_back()
	await _settle(0.4)
	_check(lobby.get("_modal") == null and layer.find_child("BlockedRow_" + Cloud.friend_code(known_id), true, false) != null,
		"back closes the card and BLOCKED is still there")
	# A change made elsewhere shows in BLOCKED: TOXICTOM (online now) is unblocked on their card,
	# DUEL 1 VS 1 there opens the ONLINE window over PROFILE, and its X goes back to BLOCKED.
	cloud.peers[known_id] = {"name": BLOCKED_KNOWN[1], "bundle": BLOCKED_KNOWN[2], "pk": "", "seen": Time.get_ticks_msec()}
	await _tap(layer.find_child("Player_" + Cloud.friend_code(known_id), true, false) as Control)
	await _settle(0.5)
	pop = lobby.get("_modal") as Control
	if pop:
		await _tap(pop.find_child("PlayerBlock", true, false) as Control)
		await _settle(0.4)
		await _tap(lobby.find_child("ConfirmOk", true, false) as Control)
		await _settle(0.5)
	pop = lobby.get("_modal") as Control
	var duel: Control = pop.find_child("PlayerDuel", true, false) as Control if pop else null
	_check(not Game.is_blocked(known_id) and duel != null, "UNBLOCK on the card: they can be challenged again")
	if duel:
		await _tap(duel)
		await _settle(0.5)
	var over := lobby.get("_modal") as Control
	_check(over != null and over.find_child("Tab_online", true, false) != null and lobby.find_child("Profile", true, false) != null,
		"DUEL 1 VS 1 opens the ONLINE window over PROFILE")
	_back()
	await _settle(0.8)
	_check(lobby.get("_modal") == null and layer.find_child("BlockedRow_" + Cloud.friend_code(known_id), true, false) == null
		and _has_label(layer, "1 OF %d" % Game.MAX_BLOCKED), "back on BLOCKED, it lists only who is still blocked")
	Game.block(known_id, BLOCKED_KNOWN[1])                # as from the ONLINE window over PROFILE
	cloud.peers.erase(known_id)
	await _settle(0.8)
	var back_btn := layer.find_child("Player_" + Cloud.friend_code(known_id), true, false) as Button
	_check(back_btn != null and back_btn.text == "TOXICTOM  #" + Cloud.friend_code(known_id) and _has_label(layer, "2 OF %d" % Game.MAX_BLOCKED),
		"a block made elsewhere shows up in BLOCKED, by name")
	# HISTORY with no match yet.
	var history: Array = Game.profile.history
	Game.profile.history = []
	await _tap(layer.find_child("ProfileTab_history", true, false) as Control)
	await _settle(0.4)
	_check(layer.find_child("HistoryEmpty", true, false) != null and layer.find_child("HistoryRow_0", true, false) == null,
		"HISTORY without matches says so")
	await _at.shot("p05_history_empty")
	Game.profile.history = history
	_check(not _cards_wanted(cloud, "profile"), "PROFILE stops listening to the player cards when BLOCKED is left")
	# Android back closes PROFILE.
	_back()
	await _settle(0.5)
	_check(lobby.find_child("Profile", true, false) == null and (lobby.get("_main_ui") as Control).visible, "back closes PROFILE")
	await _tour_cards(lobby, cloud)
	await _tour_challenge(lobby, cloud)
	return _done(saved_profile)


## A challenge that comes in while a question is open waits for it (it would swallow the answer);
## its popup has BLOCK, and X / Android back decline it (the challenger hears at once).
func _tour_challenge(lobby: Node, cloud: Cloud) -> void:
	var dialogs: LobbyDialogs = lobby.get("dialogs")
	var keys := Crypto.new()
	var who := _id("tour-challenger")
	dialogs.confirm("REMOVE FRIEND", "A question that is open when the challenge comes in.", "REMOVE", func() -> void: pass)
	await _settle(0.2)
	cloud._incoming = {"id": who, "name": "QUICKDRAW", "bundle": "default", "room": keys.generate_random_bytes(16).hex_encode(),
		"aes": keys.generate_random_bytes(32), "mac": keys.generate_random_bytes(32), "t": Time.get_ticks_msec()}
	cloud.invited.emit("QUICKDRAW")
	await _settle(0.2)
	_check(lobby.find_child("ConfirmOk", true, false) != null and lobby.find_child("AcceptButton", true, false) == null,
		"a challenge does not replace an open question")
	_back()
	await _settle(0.4)
	var accept := lobby.find_child("AcceptButton", true, false)
	_check(accept != null and lobby.find_child("ChallengeBlock", true, false) != null,
		"the challenge shows once the question closed, with BLOCK")
	await _at.shot("p13_challenge")
	_back()
	await _settle(0.3)
	_check(not cloud.has_invite() and lobby.get("_modal") == null, "Android back on a challenge declines it")


## Other players' cards from the ONLINE window: a friend online (FRIENDS tab) and a stranger
## offline (ALL PLAYERS), then BLOCK on the stranger's card.
func _tour_cards(lobby: Node, cloud: Cloud) -> void:
	var now := int(Time.get_unix_time_from_system())
	var friend_id := _id(FRIEND[0])
	var stranger_id := _id(STRANGER[0])
	for p: Array in [FRIEND, STRANGER, BLOCKED_KNOWN]:
		cloud.directory[_id(p[0])] = {"name": p[1], "bundle": p[2], "pk": "", "ts": now - int(p[7]), "v": 2, "avatar": p[3],
			"banner": p[4], "level": p[5], "signature": p[6]}
	for i in CROWD.size():
		cloud.directory[_id("tour-crowd-%d" % i)] = {"name": CROWD[i][0], "bundle": "default", "pk": "",
			"ts": now - int(CROWD[i][1]) * 86400 - i * 600, "v": 2, "avatar": "emblem", "banner": "default", "level": 3 + i, "signature": ""}
	cloud.peers[friend_id] = {"name": FRIEND[1], "bundle": FRIEND[2], "pk": "", "seen": Time.get_ticks_msec()}
	await _tap(lobby.find_child("FriendsButton", true, false) as Control)
	await _settle(0.5)
	var win := lobby.get("_modal") as Control
	if win:
		await _tap(win.find_child("Tab_friends", true, false) as Control)
		await _settle(0.6)
	win = lobby.get("_modal") as Control
	var friend_btn: Control = win.find_child("Player_" + Cloud.friend_code(friend_id), true, false) as Control if win else null
	_check(friend_btn != null, "the FRIENDS tab lists the friend by name")
	if friend_btn:
		_touch_targets(win, "the FRIENDS tab")
		await _at.shot("p06a_friends_tab")
		await _tap(friend_btn)
		await _settle(0.6)
	var pop := lobby.get("_modal") as Control
	_check(pop != null and _text(pop, "CardName") == FRIEND[1] and _text(pop, "CardLevel") == "LV %d" % FRIEND[5]
		and _text(pop, "PlayerStatus") == "ONLINE NOW" and _text(pop, "PlayerId") == "#" + Cloud.friend_code(friend_id)
		and _text(pop, "PlayerSignature") == "“%s”" % FRIEND[6] and pop.find_child("PlayerDuel", true, false) != null
		and (pop.find_child("PlayerFriend", true, false) as Button).text == "REMOVE FRIEND",
		"a friend's card: picture, banner, level, ONLINE NOW, signature, DUEL 1 VS 1 and REMOVE FRIEND")
	if pop:
		_touch_targets(pop, "a friend's card")
	await _at.shot("p06_card_friend_online")
	_back()
	await _settle(0.6)
	win = lobby.get("_modal") as Control
	_check(win != null and win.find_child("FriendSearch", true, false) != null, "back on the card returns to the FRIENDS tab")
	if win:
		await _tap(win.find_child("Tab_online", true, false) as Control)
		await _settle(0.6)
	win = lobby.get("_modal") as Control
	var stranger_btn: Control = win.find_child("Player_" + Cloud.friend_code(stranger_id), true, false) as Control if win else null
	_check(stranger_btn != null and win.find_child("Player_" + Cloud.friend_code(_id(BLOCKED_KNOWN[0])), true, false) == null,
		"ALL PLAYERS lists the stranger and leaves the blocked player out")
	if stranger_btn:
		_touch_targets(win, "the ONLINE tab")
		await _at.shot("p07a_online_tab")
		await _tap(stranger_btn)
		await _settle(0.6)
	pop = lobby.get("_modal") as Control
	_check(pop != null and _text(pop, "CardName") == STRANGER[1] and _text(pop, "PlayerStatus") == "LAST SEEN 3 H AGO"
		and pop.find_child("PlayerDuel", true, false) == null and (pop.find_child("PlayerFriend", true, false) as Button).text == "ADD FRIEND"
		and (pop.find_child("PlayerBlock", true, false) as Button).text == "BLOCK", "a stranger's card: last seen, ADD FRIEND and BLOCK, no duel")
	if pop:
		_touch_targets(pop, "a stranger's card")
	await _at.shot("p07_card_stranger_offline")
	if pop:
		await _tap(pop.find_child("PlayerBlock", true, false) as Control)
		await _settle(0.5)
	var ask := lobby.get("_modal") as Control
	_check(ask != null and ask.find_child("ConfirmOk", true, false) != null and not Game.is_blocked(stranger_id), "BLOCK asks first")
	await _at.shot("p08_block_question")
	if ask:
		await _tap(ask.find_child("ConfirmOk", true, false) as Control)
		await _settle(0.8)
	win = lobby.get("_modal") as Control
	_check(Game.is_blocked(stranger_id) and win != null and win.find_child("Tab_online", true, false) != null
		and win.find_child("Player_" + Cloud.friend_code(stranger_id), true, false) == null,
		"BLOCK hides the player: back on the ONLINE tab without them")
	var last_block: Dictionary = (Game.profile.blocked as Array).back()
	_check(last_block.id == stranger_id and last_block.name == STRANGER[1]
		and String((lobby.get("friends") as Object).get("_net_note")) == STRANGER[1] + " BLOCKED",
		"the block keeps their name, and the ONLINE window says who was blocked")
	await _at.shot("p09_online_after_block")
	# ALL PLAYERS is longer than the screen: a finger swipe that starts on a player's name scrolls
	# it and opens no card.
	var ns: ScrollContainer = win.find_child("NetScroll", true, false) as ScrollContainer if win else null
	var crowd_btn: Control = win.find_child("Player_" + Cloud.friend_code(_id("tour-crowd-1")), true, false) as Control if win else null
	_check(ns != null and crowd_btn != null, "ALL PLAYERS lists the crowd")
	if ns and crowd_btn:
		var before := ns.scroll_vertical
		await _swipe(crowd_btn.get_global_rect().get_center(), -240.0, 0.3)
		var still := lobby.get("_modal") as Control
		_check(ns.scroll_vertical > before + 100 and still != null and still.find_child("NetScroll", true, false) == ns
			and still.find_child("PlayerCardPopup", true, false) == null,
			"a finger swipe on a player's name scrolls the ONLINE list (%d px) and opens no card" % (ns.scroll_vertical - before))
		await _at.shot("p09b_online_scrolled")
		# A card opened from down the list and closed again: the list is back where it was.
		var spot := ns.scroll_vertical
		var down_btn := _visible_row_button(ns)
		var tapped := down_btn != null                  # (the button goes with the list it was in)
		if tapped:
			await _tap(down_btn)
			await _settle(0.5)
			pop = lobby.get("_modal") as Control
			_check(pop != null and pop.find_child("PlayerCardPopup", true, false) != null, "a tap on a name down the list opens the card")
			_back()
			await _settle(0.6)
		win = lobby.get("_modal") as Control
		var ns2: ScrollContainer = win.find_child("NetScroll", true, false) as ScrollContainer if win else null
		_check(tapped and ns2 != null and spot > 0 and absi(ns2.scroll_vertical - spot) <= 2,
			"closing the card brings the ONLINE list back where it was (%d, was %d)" % [ns2.scroll_vertical if ns2 else -1, spot])
	_back()
	await _settle(0.4)


## A played-in profile: numbers, a dozen matches, a friend, two blocked players.
func _sample_profile() -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	var p: Dictionary = Game.DEFAULT_PROFILE.duplicate(true)
	p.merge({"name": "SHADOWHUNTER99", "name_set": true, "guest_ok": true, "created": now - 41 * 86400, "avatar": "neon",
		"banner": "contour", "signature": "ALWAYS ONE MORE ROUND", "bundle": "neon", "xp": 5740, "matches": 48, "wins": 29,
		"kills": 151, "deaths": 97, "headshots": 63, "damage": 61234, "shots": 1880, "hits": 702, "rounds_won": 178,
		"rounds_lost": 131, "time_played": 30250,
		"modes": {"training": {"matches": 36, "wins": 23, "kills": 117}, "lonewolf": {"matches": 12, "wins": 6, "kills": 34}},
		"friends": {_id(FRIEND[0]): {"name": FRIEND[1]}},
		"blocked": [{"id": _id(BLOCKED_UNKNOWN), "name": "", "t": now - 9 * 86400},
			{"id": _id(BLOCKED_KNOWN[0]), "name": BLOCKED_KNOWN[1], "t": now - 2 * 86400}]}, true)
	# [result, mode, opponent, score, theirs, kills, damage, headshots, minutes ago]
	var matches := [["won", "lonewolf", FRIEND[1], 5, 3, 5, 1214, 3, 25], ["lost", "lonewolf", "VIPERQUEEN", 2, 5, 2, 640, 1, 130],
		["won", "training", "BOT VIPER", 5, 2, 5, 1176, 3, 190], ["draw", "training", "BOT ONYX", 4, 4, 4, 912, 1, 300],
		["won", "training", "BOT KAI", 5, 0, 5, 1003, 6, 1500], ["lost", "training", "BOT TITAN", 3, 5, 3, 801, 0, 1600],
		["left", "training", "BOT ONYX", 1, 2, 1, 356, 0, 1700],
		["won", "lonewolf", STRANGER[1], 5, 4, 5, 1390, 2, 2900], ["won", "training", "BOT REX", 5, 1, 5, 1120, 4, 4400],
		["lost", "lonewolf", "SILENTLYNX12", 1, 5, 1, 420, 0, 5800], ["won", "training", "BOT NOVA", 5, 3, 5, 1085, 2, 7300],
		["won", "training", "BOT ZED", 5, 2, 5, 990, 1, 8700], ["draw", "lonewolf", "GHOSTRAVEN", 3, 3, 3, 777, 1, 11600]]
	var history := []
	var ids := {FRIEND[1]: _id(FRIEND[0]), STRANGER[1]: _id(STRANGER[0])}
	for m: Array in matches:
		# an online opponent's id is kept (a row that opens their card), a bot has none
		var opp_id := "" if m[1] == "training" else String(ids.get(m[2], _id("tour-" + String(m[2]).to_lower())))
		history.append({"result": m[0], "mode": m[1], "enemy": m[2], "id": opp_id,
			"score": m[3], "enemy_score": m[4], "kills": m[5], "damage": m[6], "headshots": m[7], "t": now - int(m[8]) * 60})
	p.history = history
	return p


static func _id(seed_text: String) -> String:
	return seed_text.sha256_text().left(32)


## Every visible button under `root` is a 56 px touch target at least (the 720 px canvas).
func _touch_targets(root: Node, where: String) -> void:
	if root == null:
		return
	var small := PackedStringArray()
	for n in root.find_children("*", "BaseButton", true, false):
		var c := n as Control
		if c.is_visible_in_tree() and (c.size.y < 55.5 or c.size.x < 55.5):
			small.append("%s %dx%d" % [c.name, roundi(c.size.x), roundi(c.size.y)])
	_check(small.is_empty(), "touch targets of 56 px at least in %s %s" % [where, ", ".join(small)])
	var sc := root.find_child("ProfileBody", true, false) as ScrollContainer
	if sc == null:
		sc = root.find_child("NetScroll", true, false) as ScrollContainer
	if sc and sc.get_child_count() > 0:
		var keepers := _touch_keepers(sc.get_child(0))
		_check(keepers.is_empty(), "nothing in the list of %s keeps a finger's touch from scrolling it %s" % [where, ", ".join(keepers)])


## Controls under a scrolling list's content that keep a touch to themselves (MOUSE_FILTER_STOP:
## buttons, plates): a drag that starts on one of them could not scroll the list (UI.drag_scroll).
func _touch_keepers(content: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for n in content.find_children("*", "Control", true, false):
		if (n as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
			out.append(String(n.name))
	return out


## A finger swipe that starts at `p` (canvas) and moves `dy` px in 10 steps, as a phone sends it
## (touch, drags, release). hold: the finger rests that long before it lifts, so the list stops
## where the finger stopped (no fling).
func _swipe(p: Vector2, dy: float, hold := 0.0) -> void:
	var fx: Transform2D = get_tree().root.get_final_transform()
	var w := fx * p
	var step := fx.basis_xform(Vector2(0, dy / 10.0))
	_at.touch(0, w, true)
	await get_tree().process_frame
	for k in 10:
		w += step
		_at.drag(0, w, step)
		await get_tree().process_frame
	if hold > 0.0:
		await _at.wait(hold)
	_at.touch(0, w, false)
	await _settle(0.6)


func _done(saved_profile: Dictionary) -> int:
	Game.profile = saved_profile
	_at.log_line("PROFILE TOUR DONE fails=%d" % _fails)
	return _fails


## A player's name button that shows whole (top to bottom) inside the scrolled list `sc`, else null.
func _visible_row_button(sc: ScrollContainer) -> Control:
	var view := sc.get_global_rect()
	for n in sc.find_children("Player_*", "Button", true, false):
		var r := (n as Control).get_global_rect()
		if r.position.y >= view.position.y + 4.0 and r.end.y <= view.end.y - 4.0:
			return n as Control
	return null


## The open PROFILE tab ("" when PROFILE is closed).
func _tab_of(lobby: Node) -> String:
	var pui: Object = lobby.get("profile_ui")
	return String(pui.get("tab")) if pui and pui.get("layer") != null else ""


## Whether a label's whole text fits its width at its font size (nothing cut off by "...").
func _text_fits(l: Label) -> bool:
	if l == null:
		return false
	var w := l.get_theme_font("font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x
	return w <= l.size.x + 0.5


## Whether a Label under `root` says exactly `text`.
func _has_label(root: Node, text: String) -> bool:
	for n in root.find_children("*", "Label", true, false):
		if (n as Label).text == text:
			return true
	return false


## Whether `by` (Cloud.start_directory) has the online service listening to the player cards.
func _cards_wanted(cloud: Cloud, by: String) -> bool:
	return (cloud.get("_dir_wants") as Dictionary).has(by)


## The text of the Label (or Button) named `node_name` under `root` ("" when there is none).
func _text(root: Node, node_name: String) -> String:
	var n := root.find_child(node_name, true, false) if root else null
	if n is Label:
		return (n as Label).text
	if n is Button:
		return (n as Button).text
	return ""


## The new lobby after `old` (Game.goto_lobby() replaced it).
func _next_lobby(old: Node) -> Node:
	var t := 0.0
	while t < 30.0:
		var s := get_tree().current_scene
		if s and s != old and s.name == "Lobby":
			return s
		await _at.wait(0.1)
		t += 0.1
	_check(false, "a new lobby within 30 s")
	return null


func _wait_scene(scene_name: String, timeout: float) -> Node:
	var t := 0.0
	while t < timeout:
		var s := get_tree().current_scene
		if s and s.name == scene_name:
			return s
		await _at.wait(0.1)
		t += 0.1
	_check(false, "scene %s within %.0fs" % [scene_name, timeout])
	return null


## Android back as the engine delivers it (the node, then its children by index).
func _back() -> void:
	_prop(get_tree().root)


func _prop(n: Node) -> void:
	n.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	var i := 0
	while i < n.get_child_count():
		var c := n.get_child(i)
		if not (c is Window):
			_prop(c)
		i += 1


## Waits `sec` of process time and at least 3 drawn frames.
func _settle(sec: float) -> void:
	var t := 0.0
	var frames := 0
	while t < sec or frames < 3:
		await get_tree().process_frame
		t += get_process_delta_time()
		frames += 1


## A real tap (touch down / up, emulated as a mouse click by the engine) on a control's centre.
func _tap(c: Control, hold := 0.08) -> void:
	if c == null:
		_check(false, "tap target exists")
		return
	await _tap_at(c.get_global_rect().get_center(), hold)


func _tap_at(p: Vector2, hold := 0.08) -> void:
	var w: Vector2 = get_tree().root.get_final_transform() * p
	_at.touch(0, w, true)
	await _at.wait(hold)
	_at.touch(0, w, false)
	await _at.wait(0.12)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	_at.log_line(("ok   " if ok else "FAIL ") + what)
