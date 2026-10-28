extends Node
## Tamper protection for an offline game. Nothing here talks to a server (the game has no
## network permission). It makes the usual mobile cheats fail or get noticed:
## - memory scanners that search for and freeze values (HP, ammo, items): those values live
##   XOR-masked with a checksum in SecureNum, so they can't be found and edits are detected;
## - speed hacks: the game clock is compared with the wall clock;
## - edited save files: the profile is signed with an HMAC tied to this device;
## - repackaged APKs: on Android the installed APK's v2/v3 signing block must carry the
##   certificate the official build was signed with (res://build_signer.txt, written by
##   tools/build_apk.sh). The game reads its own APK file, so no Java call can misreport it:
##   anything it cannot read counts as "unknown" (allowed), only a different certificate counts.
## A detection ends the running match without XP ("INTEGRITY CHECK FAILED").

signal tampered(reason: String)

const SIGNER_FILE := "res://build_signer.txt"
const SPEED_WINDOW_USEC := 3000000
## APK Signing Block entry IDs of the v2, v3 and v3.1 signature schemes.
const APK_SIG_IDS := [0x7109871a, 0xf05368c0, 0x1b93ad61]

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
	var apk := _apk_path()
	if apk == "":
		signature_state = "unknown (no apk path)"
		return
	var certs := apk_signer_hashes(apk)
	if certs.is_empty():
		signature_state = "unknown (no signing block)"
		return
	signature_state = "ok" if expected in certs else "mismatch"
	print("[LoneWolf] signature ", signature_state)
	if signature_state == "mismatch":
		flag("signature")


## Path of the installed APK (Context.getPackageCodePath()), or "" when unavailable.
func _apk_path() -> String:
	if not Engine.has_singleton("AndroidRuntime"):
		return ""
	var ctx: Variant = Engine.get_singleton("AndroidRuntime").call("getApplicationContext")
	if not ctx is Object or ctx == null:
		return ""
	var path: Variant = (ctx as Object).call("getPackageCodePath")
	return String(path) if typeof(path) == TYPE_STRING else ""


## SHA-256 (lower-case hex) of every signer certificate in an APK's v2 / v3 / v3.1 signing
## block. Empty when the file can't be read or has no such block (e.g. v1-only signing).
static func apk_signer_hashes(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var size := f.get_length()
	# End-of-central-directory record: within the last 22 bytes + up to 64 KB of comment.
	var tail_len := mini(size, 65535 + 22)
	f.seek(size - tail_len)
	var tail := f.get_buffer(tail_len)
	var eocd := -1
	for i in range(tail_len - 22, -1, -1):
		if tail.decode_u32(i) == 0x06054b50:
			eocd = i
			break
	if eocd < 0:
		return out
	# The signing block sits right before the central directory and ends with its own size
	# and the magic "APK Sig Block 42".
	var cd_offset := tail.decode_u32(eocd + 16)
	if cd_offset < 32 or cd_offset > size:
		return out
	f.seek(cd_offset - 24)
	var footer := f.get_buffer(24)
	if footer.slice(8, 24).get_string_from_ascii() != "APK Sig Block 42":
		return out
	var block_size := footer.decode_u64(0)
	var start := cd_offset - block_size - 8
	if block_size < 32 or block_size > 32 * 1024 * 1024 or start < 0:
		return out
	f.seek(start)
	var block := f.get_buffer(block_size + 8)
	if block.decode_u64(0) != block_size:
		return out
	# ID-value pairs: uint64 length (of id + value), uint32 id, value.
	var pos := 8
	var end := block.size() - 24
	while pos + 12 <= end:
		var plen := block.decode_u64(pos)
		var vend := pos + 8 + plen
		if plen < 4 or vend > end:
			break
		if block.decode_u32(pos + 8) in APK_SIG_IDS:
			_collect_certs(block, pos + 12, vend, out)
		pos = vend
	return out


## v2/v3 value: [signers: [signer: [signed data: [digests] [certificates: [cert]...] ...] ...]...]
## where every [...] is a uint32 length-prefixed field.
static func _collect_certs(b: PackedByteArray, start: int, end: int, out: PackedStringArray) -> void:
	var signers := _lp(b, start, end)
	if signers.is_empty():
		return
	var p: int = signers[0]
	while p < signers[1]:
		var signer := _lp(b, p, signers[1])
		if signer.is_empty():
			return
		var signed := _lp(b, signer[0], signer[1])
		var digests := _lp(b, signed[0], signed[1]) if not signed.is_empty() else []
		var certs := _lp(b, digests[1], signed[1]) if not digests.is_empty() else []
		if not certs.is_empty():
			var c: int = certs[0]
			while c < certs[1]:
				var cert := _lp(b, c, certs[1])
				if cert.is_empty():
					break
				var h := HashingContext.new()
				h.start(HashingContext.HASH_SHA256)
				h.update(b.slice(cert[0], cert[1]))
				var hex := h.finish().hex_encode()
				if not hex in out:
					out.append(hex)
				c = cert[1]
		p = signer[1]


## The uint32 length-prefixed field at p: [content start, content end], or [] if it overruns.
static func _lp(b: PackedByteArray, p: int, limit: int) -> Array:
	if p < 0 or p + 4 > limit:
		return []
	var n := b.decode_u32(p)
	if p + 4 + n > limit:
		return []
	return [p + 4, p + 4 + n]
