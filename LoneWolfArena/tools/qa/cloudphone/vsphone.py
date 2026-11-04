#!/usr/bin/env python3
"""Test Wolf Arena on a real phone rented from VSPhone, through the VSPhone OpenAPI.

The owner's keys never enter the repository. Put them in ~/.lonewolf/vsphone.env (chmod 600),
one per line:
    VSP_AK=<Access Key ID>
    VSP_SK=<Secret Access Key>
    VSP_PAD=<cloud phone code; optional while the account has a single phone>
Exported variables with the same names win over the file; VSP_KEYS names another file.

Only the endpoints in ALLOWED can be called, so this tool can never buy, renew, reset or
reflash a phone. Requests use the API's HMAC-SHA256 signature (VSPhone's docs call it V4).
Needs python3 with requests.

    vsphone.py pads                     list the account's phones
    vsphone.py sh 'COMMAND' [SECONDS]   run a shell command on the phone and print its output
    vsphone.py shot OUT.png             save the current screen
    vsphone.py tap X Y                  tap (screen pixels)
    vsphone.py swipe X1 Y1 X2 Y2 [MS]   drag
    vsphone.py install URL              have the phone download an APK and install it
    vsphone.py start | stop             open or close Wolf Arena
"""
import datetime
import hashlib
import hmac
import json
import os
import sys
import time

import requests

HOST = "api.vsphone.com"
PREFIX = "/vsphone/api/padApi/"
PACKAGE = "com.lonewolf.arena"
ALLOWED = {"infos", "asyncCmd", "executeScriptInfo", "getLongGenerateUrl", "uploadFileV3"}
FINISHED = {3, -1, -2, -3, -4}  # done, failed, partly failed, cancelled, timed out


def settings():
    conf = {}
    path = os.environ.get("VSP_KEYS") or os.path.expanduser("~/.lonewolf/vsphone.env")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.strip().partition("=")
                if sep and not key.startswith("#"):
                    conf[key.strip()] = value.strip()
    for key in ("VSP_AK", "VSP_SK", "VSP_PAD"):
        if os.environ.get(key):
            conf[key] = os.environ[key]
    if not conf.get("VSP_AK") or not conf.get("VSP_SK"):
        sys.exit("no VSPhone keys: put VSP_AK and VSP_SK in " + path)
    return conf


def signed_headers(body, access_key, secret_key):
    """HMAC-SHA256 over host, date, content type and body hash, with a per-day derived key."""
    x_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    day = x_date[:8]
    content_type = "application/json;charset=UTF-8"
    names = "content-type;host;x-content-sha256;x-date"
    canonical = "\n".join((
        "host:" + HOST,
        "x-date:" + x_date,
        "content-type:" + content_type,
        "signedHeaders:" + names,
        "x-content-sha256:" + hashlib.sha256(body).hexdigest(),
    ))
    to_sign = "\n".join(("HMAC-SHA256", x_date, day + "/armcloud-paas/request",
                         hashlib.sha256(canonical.encode()).hexdigest()))
    key = secret_key.encode()
    for part in (day, "armcloud-paas", "request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    return {
        "content-type": content_type,
        "x-date": x_date,
        "x-host": HOST,
        "authorization": "HMAC-SHA256 Credential=%s, SignedHeaders=%s, Signature=%s"
                         % (access_key, names, signature),
    }


def call(endpoint, payload, strict=True):
    """POST to the API; on an error exit (strict) or return None (used while polling)."""
    if endpoint not in ALLOWED:
        sys.exit("endpoint not allowed: " + endpoint)
    conf = settings()
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    try:
        reply = requests.post("https://" + HOST + PREFIX + endpoint, data=body, timeout=90,
                              headers=signed_headers(body, conf["VSP_AK"], conf["VSP_SK"]))
        answer = reply.json()
        problem = None if answer.get("code") == 200 else "%s %s" % (answer.get("code"), answer.get("msg"))
    except (requests.RequestException, ValueError) as error:
        answer, problem = {}, str(error)
    if problem:
        if strict:
            sys.exit("%s: %s" % (endpoint, problem))
        return None
    return answer.get("data")


def phones():
    return (call("infos", {"page": 1, "rows": 50}) or {}).get("pageData") or []


def pad():
    chosen = settings().get("VSP_PAD")
    if chosen:
        return chosen
    found = phones()
    if len(found) != 1:
        sys.exit("set VSP_PAD to one of: " + ", ".join(p["padCode"] for p in found))
    return found[0]["padCode"]


def shell(command, wait=90):
    """Run a shell command on the phone; returns (finished_ok, output)."""
    task = call("asyncCmd", {"padCodes": [pad()], "scriptContent": command})[0]["taskId"]
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(2.5)
        info = (call("executeScriptInfo", {"taskIds": [task]}, strict=False) or [{}])[0]
        if info.get("taskStatus") in FINISHED:
            return info.get("taskStatus") == 3, info.get("taskResult") or info.get("errorMsg") or ""
    return False, "no answer from the phone within %d s" % wait


def screenshot(path):
    shot = call("getLongGenerateUrl", {"padCodes": [pad()], "format": "png"})[0]
    if not shot.get("success"):
        sys.exit("screenshot failed: %s" % shot.get("reason"))
    image = requests.get(shot["url"], timeout=90)
    image.raise_for_status()
    with open(path, "wb") as f:
        f.write(image.content)


def run(command):
    ok, out = shell(command)
    if out.strip():
        print(out.rstrip())
    return 0 if ok else 1


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "pads":
        for p in phones():
            print(p.get("padCode"), p.get("padType"), p.get("screenLayoutCode"),
                  "status", p.get("padStatus"))
        return 0
    if cmd == "sh" and rest:
        ok, out = shell(rest[0], int(rest[1]) if len(rest) > 1 else 90)
        print(out.rstrip())
        return 0 if ok else 1
    if cmd == "shot" and rest:
        screenshot(rest[0])
        return 0
    if cmd == "tap" and len(rest) == 2:
        return run("input tap %d %d" % (int(rest[0]), int(rest[1])))
    if cmd == "swipe" and len(rest) in (4, 5):
        x1, y1, x2, y2 = (int(v) for v in rest[:4])
        return run("input swipe %d %d %d %d %d" % (x1, y1, x2, y2, int(rest[4]) if len(rest) == 5 else 300))
    if cmd == "install" and rest:
        task = call("uploadFileV3", {"padCodes": [pad()], "url": rest[0], "autoInstall": 1,
                                     "packageName": PACKAGE, "fileName": "WolfArena.apk"})
        print("install task", task[0]["taskId"])
        return 0
    if cmd == "start":
        return run("monkey -p %s -c android.intent.category.LAUNCHER 1 >/dev/null && echo started" % PACKAGE)
    if cmd == "stop":
        return run("am force-stop %s && echo stopped" % PACKAGE)
    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
