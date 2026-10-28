extends Node
## Tamper protection for an offline game. Nothing here talks to a server (the game has no
## network permission). It makes the usual mobile cheats fail or get noticed:
## - memory scanners that search for and freeze values (HP, ammo, items): those values live
##   XOR-masked with a checksum in SecureNum, so they can't be found and edits are detected;
## - speed hacks: the game clock is compared with the wall clock;
## - edited save files: the profile is signed with an HMAC tied to this device;
## - repackaged APKs: on Android the installed package must carry the signing certificate the
##   official build was made with (res://build_signer.txt, written by tools/build_apk.sh).
## A detection ends the running match without XP ("INTEGRITY CHECK FAILED").

signal tampered(reason: String)

const SIGNER_FILE := "res://build_signer.txt"
const CERT_INPUT_SHA256 := 1
const SPEED_WINDOW_USEC := 3000000

var flags: PackedStringArray = []
var signature_state := "unchecked"

var _salt := 0
var _mask_state := 0
var _hmac_key := PackedByteArray()
var _tick_start := 0
var _wall_start := 0.0
var _speed_strikes := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_salt = rng.randi() | (rng.randi() << 31)
	_mask_state = rng.randi() | 1
	var seed_text := "lw-arena|%s|%s" % [OS.get_unique_id(), "7f3c91e2a85d4b06"]
	_hmac_key = seed_text.sha256_buffer()
	_reset_clock()
	_check_signature.call_deferred()


# ---------------------------------------------------------------- masked values

func next_mask() -> int:
	# xorshift64*: a new mask for every write, so a value's bytes never repeat in memory.
	var x := _mask_state
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	_mask_state = x if x != 0 else 0x2545F491
	return _mask_state


func checksum(raw: int, mask: int) -> int:
	return ((raw * 0x9E3779B1) ^ (mask >> 7) ^ _salt) & 0x3FFFFFFFFFFFFFFF


# ---------------------------------------------------------------- detections

func flag(reason: String) -> void:
	if reason in flags:
		return
	flags.append(reason)
	push_warning("[Guard] integrity check failed: " + reason)
	print("[LoneWolf] integrity flag: ", reason)
	tampered.emit(reason)


func is_clean() -> bool:
	return flags.is_empty()


func _reset_clock() -> void:
	_tick_start = Time.get_ticks_usec()
	_wall_start = Time.get_unix_time_from_system()


func _process(_delta: float) -> void:
	var ticks := Time.get_ticks_usec() - _tick_start
	if ticks < SPEED_WINDOW_USEC:
		return
	var wall := Time.get_unix_time_from_system() - _wall_start
	# A speed hack makes the game clock run ahead of real time. (Slower is ignored: the
	# monotonic clock legitimately stops while the phone sleeps.)
	if wall > 0.5 and float(ticks) / 1e6 / wall > 1.6:
		_speed_strikes += 1
		if _speed_strikes >= 2:
			flag("speed")
	else:
		_speed_strikes = maxi(_speed_strikes - 1, 0)
	_reset_clock()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_PAUSED]:
		_reset_clock()
		_speed_strikes = 0


# ---------------------------------------------------------------- signed saves

func sign_text(text: String) -> String:
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, _hmac_key)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()


## JSON turns every number into a float on load, so whole numbers are signed as ints on both
## sides (otherwise 3 and 3.0 would sign differently).
static func _canonical(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if is_equal_approx(v, roundf(v)) and absf(v) < 1.0e15 else v
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[String(k)] = _canonical(v[k])
			return d
		TYPE_ARRAY:
			var a := []
			for x in v:
				a.append(_canonical(x))
			return a
	return v


func sign_dict(data: Dictionary) -> Dictionary:
	var body: Dictionary = _canonical(data)
	body.erase("_sig")
	var out := body.duplicate(true)
	out["_sig"] = sign_text(JSON.stringify(body, "", true))
	return out


## Returns {"ok": bool, "unsigned": bool, "data": Dictionary-without-signature}.
func verify_dict(data: Dictionary) -> Dictionary:
	var body: Dictionary = _canonical(data)
	var sig := String(body.get("_sig", ""))
	body.erase("_sig")
	if sig == "":
		return {"ok": true, "unsigned": true, "data": body}
	return {"ok": sig == sign_text(JSON.stringify(body, "", true)), "unsigned": false, "data": body}


# ---------------------------------------------------------------- APK signature (Android)

func _check_signature() -> void:
	if OS.get_name() != "Android":
		signature_state = "not android"
		return
	if not FileAccess.file_exists(SIGNER_FILE):
		signature_state = "unknown (no signer file)"
		return
	var expected := FileAccess.get_file_as_string(SIGNER_FILE).strip_edges().to_lower().replace(":", "")
	if expected.length() != 64:
		signature_state = "unknown (bad signer file)"
		return
	# PackageManager.hasSigningCertificate() exists from Android 9 (API 28).
	if OS.get_version().get_slice(".", 0).to_int() < 9:
		signature_state = "unknown (android < 9)"
		return
	if not Engine.has_singleton("AndroidRuntime"):
		signature_state = "unknown (no runtime)"
		return
	var runtime: Object = Engine.get_singleton("AndroidRuntime")
	var ctx: Variant = runtime.call("getApplicationContext")
	if not ctx is Object or ctx == null:
		signature_state = "unknown (no context)"
		return
	var pm: Variant = (ctx as Object).call("getPackageManager")
	var pkg: Variant = (ctx as Object).call("getPackageName")
	if not pm is Object or pm == null or typeof(pkg) != TYPE_STRING:
		signature_state = "unknown (no package manager)"
		return
	var has_cert: Variant = (pm as Object).call("hasSigningCertificate", pkg, expected.hex_decode(), CERT_INPUT_SHA256)
	if typeof(has_cert) != TYPE_BOOL:
		signature_state = "unknown (no answer)"
		return
	signature_state = "ok" if has_cert else "mismatch"
	print("[LoneWolf] signature ", signature_state)
	if not has_cert:
		flag("signature")
