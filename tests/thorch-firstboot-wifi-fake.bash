#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-firstboot/payload/usr/bin/thorch-firstbootctl"

python3 - "${script}" <<'PY'
import contextlib
import io
import json
import pathlib
import runpy
import sys
import tempfile


script = sys.argv[1]
module = runpy.run_path(script, run_name="thorch_firstbootctl")


def invoke(payload, *, nmcli_output=None, run_result=(0, "")):
    wifi_connect = module["wifi_connect_json"]
    wifi_connect.__globals__["require_root"] = lambda: None
    wifi_connect.__globals__["shutil"].which = lambda name: "/usr/bin/nmcli" if name == "nmcli" else None
    if nmcli_output is not None:
        def fake_run(*args, **kwargs):
            class Proc:
                returncode = 0
                stdout = nmcli_output
                stderr = ""
            return Proc()
        wifi_connect.__globals__["subprocess"].run = fake_run

    calls = []

    def fake_run_capture(command, *, input_text=None):
        calls.append(command)
        return run_result

    wifi_connect.__globals__["run_capture"] = fake_run_capture
    sys.stdin = io.StringIO(json.dumps(payload))
    stdout = io.StringIO()
    with contextlib.redirect_stdout(stdout):
        try:
            wifi_connect()
        except SystemExit as exc:
            return exc.code, json.loads(stdout.getvalue()), calls
    raise AssertionError("wifi_connect_json did not exit")


code, payload, calls = invoke(
    {"ssid": "MyWifi", "password": "", "security": "WPA2"},
)
assert code == 1, payload
assert payload["ok"] is False, payload
assert payload["message"] == "Enter the Wi-Fi password for this network.", payload
assert calls == [], calls

code, payload, calls = invoke(
    {"ssid": "CafeWifi", "password": "", "security": "--"},
    run_result=(0, "connected"),
)
assert code == 0, payload
assert payload["ok"] is True, payload
assert calls == [["nmcli", "device", "wifi", "connect", "CafeWifi"]], calls

module["wifi_scan_json"].__globals__["subprocess"].run = lambda *args, **kwargs: type(
    "Proc",
    (),
    {
        "returncode": 0,
        "stdout": "*:CafeWifi:--:61\n:SecuredWifi:WPA2:70\n",
        "stderr": "",
    },
)()
stdout = io.StringIO()
with contextlib.redirect_stdout(stdout):
    try:
        module["wifi_scan_json"].__globals__["shutil"].which = lambda name: "/usr/bin/nmcli" if name == "nmcli" else None
        module["wifi_scan_json"]()
    except SystemExit as exc:
        assert exc.code == 0
scan_payload = json.loads(stdout.getvalue())
assert scan_payload["networks"][0]["security"] == "", scan_payload
assert scan_payload["networks"][1]["security"] == "WPA2", scan_payload

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = pathlib.Path(tmp)
    fstab = tmp_path / "fstab"
    fstab.write_text(
        "\n".join(
            [
                "UUID=root / ext4 rw,relatime 0 1",
                "UUID=boot /boot vfat rw,relatime 0 2",
                "tmpfs /home/thorch/.cache tmpfs rw,nosuid,nodev,relatime,size=536870912,mode=0700,uid=1001,gid=1001 0 0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    entry = type("Entry", (), {"pw_dir": str(tmp_path / "home" / "bear"), "pw_uid": 1234, "pw_gid": 1234})()
    module["retarget_cache_tmpfs"](entry, fstab)
    assert (
        "tmpfs "
        + str(tmp_path / "home" / "bear" / ".cache")
        + " tmpfs rw,nosuid,nodev,relatime,size=536870912,mode=0700,uid=1234,gid=1234 0 0"
    ) in fstab.read_text(encoding="utf-8"), fstab.read_text(encoding="utf-8")

print("ok")
PY
