#!/usr/bin/env python3
"""
brightness-control.py — backend for the Quickshell brightness & gamma app.

Discovery is automatic: the active monitors are read from Hyprland
(`hyprctl monitors -j`) and each one is matched to a control method by its
DRM connector:

  * backlight   — integrated panels exposed through /sys/class/backlight,
                  controlled with brightnessctl.
  * ddcutil     — external monitors controlled over DDC/CI with ddcutil
                  (VCP feature 0x10). Displays are matched to monitors via the
                  DRM connector of their I2C bus (read from
                  /sys/bus/i2c/devices/i2c-N/name).
  * unsupported — no usable control was found (slider shown disabled).

The ddcutil display map (bus -> connector) is cached in /tmp so the
comparatively slow `ddcutil detect` is not re-run on every poll.

Values are plain percentages (0-100).

Subcommands
-----------
  poll                          JSON snapshot of gamma + all monitors/values
  get  backlight <device>       current brightness % of a backlight device
  get  ddcutil <bus>            current brightness % of a DDC display (VCP 0x10)
  get  gamma                    current global gamma % (hyprsunset), -1 if n/a
  set  backlight <device> <pct> set brightness of a backlight device
  set  ddcutil <bus> <pct>      set brightness of a DDC display
  set  gamma <pct>              set global gamma via hyprctl hyprsunset
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

CACHE = f"/tmp/quickshell-brightness-{os.getuid()}.json"
CACHE_TTL = 45

BRIGHTNESSCTL = shutil.which("brightnessctl")
DDCUTIL = shutil.which("ddcutil")
HYPRCTL = shutil.which("hyprctl")
HYPRSUNSET = shutil.which("hyprsunset")


def run(cmd, timeout=5):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", "command not found"
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"


def clamp(value, lo=0, hi=100):
    return max(lo, min(hi, int(value)))


def conn_name(connector):
    """Strip the cardN- prefix from a DRM connector name (card1-eDP-1 -> eDP-1)."""
    return re.sub(r"^card\d+-", "", (connector or "").strip())


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------

def hypr_monitors():
    if not HYPRCTL:
        return []
    rc, out, _ = run([HYPRCTL, "monitors", "-j"], timeout=5)
    if rc != 0:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    monitors = []
    for mon in sorted(data, key=lambda m: m.get("id", 0)):
        if mon.get("disabled"):
            continue
        monitors.append({
            "name": mon.get("name", ""),
            "path": mon.get("path", ""),
            "model": mon.get("model", "") or "",
            "description": mon.get("description", "") or "",
        })
    return monitors


def backlight_map():
    """Map DRM connector name -> sysfs backlight device name."""
    mapping = {}
    base = "/sys/class/backlight"
    try:
        devices = os.listdir(base)
    except OSError:
        return mapping
    for name in devices:
        devdir = os.path.join(base, name)
        if not os.path.isdir(devdir):
            continue
        try:
            connector = os.path.basename(os.path.realpath(os.path.join(devdir, "device")))
        except OSError:
            continue
        mapping[conn_name(connector)] = name
    return mapping


def i2c_bus_connector(bus):
    """DRM connector name served by /dev/i2c-<bus>, read from sysfs."""
    try:
        with open(f"/sys/bus/i2c/devices/i2c-{bus}/name") as fh:
            return fh.read().strip()
    except OSError:
        return None


def parse_detect_output(out):
    """Parse `ddcutil detect --terse` output -> [{display, bus, model}]."""
    displays = []
    current = None
    for line in out.splitlines():
        m = re.match(r"\s*Display\s+(\d+)", line)
        if m:
            current = {"display": int(m.group(1)), "bus": None, "model": None}
            displays.append(current)
            continue
        if current is None:
            continue
        m = re.match(r"\s*I2C bus:\s*(?:/dev/)?i2c-(\d+)", line)
        if m:
            current["bus"] = int(m.group(1))
            continue
        m = re.match(r"\s*Monitor:\s*(.*)", line)
        if m:
            current["model"] = m.group(1).strip()
            continue
        m = re.match(r"\s*((?:/dev/)?i2c-(\d+))", line)
        if m and current["bus"] is None:
            current["bus"] = int(m.group(2))
    return displays


def ddcutil_detect():
    """Run `ddcutil detect --terse` -> [{display, bus, connector, model}]."""
    if not DDCUTIL:
        return []
    rc, out, _ = run([DDCUTIL, "detect", "--terse"], timeout=25)
    if rc != 0:
        return []
    displays = parse_detect_output(out)
    for d in displays:
        d["connector"] = i2c_bus_connector(d["bus"]) if d["bus"] is not None else None
    return displays


def load_cache():
    try:
        with open(CACHE) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def save_cache(displays, signature):
    try:
        with open(CACHE, "w") as fh:
            json.dump({"ts": time.time(), "sig": signature, "displays": displays}, fh)
    except OSError:
        pass


def get_displays(monitors):
    """Return the ddcutil display list, refreshing from disk when stale."""
    signature = "|".join(sorted(m["name"] for m in monitors))
    cache = load_cache()
    displays = None
    if cache and time.time() - cache.get("ts", 0) < CACHE_TTL and cache.get("sig") == signature:
        displays = cache.get("displays")
    if displays is None:
        displays = ddcutil_detect()
        save_cache(displays, signature)
    return displays


# ---------------------------------------------------------------------------
# reads
# ---------------------------------------------------------------------------

def read_backlight(device):
    if not BRIGHTNESSCTL:
        return -1
    _, cur, _ = run([BRIGHTNESSCTL, "-d", device, "get"], timeout=3)
    _, mx, _ = run([BRIGHTNESSCTL, "-d", device, "max"], timeout=3)
    try:
        cur = int(cur.strip())
        mx = int(mx.strip())
    except (AttributeError, ValueError):
        return -1
    return round(cur * 100 / mx) if mx > 0 else -1


def read_ddc(bus):
    if not DDCUTIL:
        return -1
    rc, out, _ = run([DDCUTIL, "--nodetect", "--bus", str(bus), "getvcp", "10", "--terse"], timeout=6)
    if rc != 0:
        return -1
    m = re.search(r"\bVCP\s+10\s+C\s+(\d+)\s+(\d+)", out)
    if not m:
        return -1
    cur, mx = int(m.group(1)), int(m.group(2))
    return round(cur * 100 / mx) if mx > 0 else -1


def read_gamma():
    if not HYPRCTL:
        return -1
    rc, out, _ = run([HYPRCTL, "hyprsunset", "gamma"], timeout=3)
    if rc != 0:
        return -1
    try:
        return clamp(int(float(out.strip())))
    except (AttributeError, ValueError):
        return -1


# ---------------------------------------------------------------------------
# writes
# ---------------------------------------------------------------------------

def set_backlight(device, pct):
    if not BRIGHTNESSCTL:
        return False
    rc, _, _ = run([BRIGHTNESSCTL, "-d", device, "set", f"{clamp(pct)}%"], timeout=5)
    return rc == 0


def set_ddc(bus, pct):
    """Set DDC brightness, mapping the percentage onto the monitor's VCP max."""
    if not DDCUTIL:
        return False
    rc, out, _ = run([DDCUTIL, "--nodetect", "--bus", str(bus), "getvcp", "10", "--terse"], timeout=6)
    if rc != 0:
        return False
    m = re.search(r"\bVCP\s+10\s+C\s+(\d+)\s+(\d+)", out)
    if not m:
        return False
    mx = int(m.group(2))
    if mx <= 0:
        return False
    raw = round(clamp(pct) * mx / 100)
    rc, _, _ = run([DDCUTIL, "--nodetect", "--bus", str(bus), "setvcp", "10", str(raw)], timeout=6)
    return rc == 0


def set_gamma(pct):
    """Set the global gamma, starting hyprsunset first if it is not running."""
    pct = clamp(pct)
    if HYPRCTL:
        rc, _, _ = run([HYPRCTL, "hyprsunset", "gamma", str(pct)], timeout=5)
        if rc == 0:
            return True
    if not HYPRSUNSET:
        return False
    try:
        subprocess.Popen(
            [HYPRSUNSET, "-g", str(pct)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(0.6)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------------------
# poll
# ---------------------------------------------------------------------------

def poll():
    monitors = hypr_monitors()
    bmap = backlight_map()
    displays = get_displays(monitors)

    by_conn = {}
    for d in displays:
        c = conn_name(d.get("connector"))
        if c:
            by_conn.setdefault(c, d)

    used_buses = set()
    entries = []
    unmatched = []
    for m in monitors:
        conn = conn_name(m.get("path")) or m.get("name")
        control = None
        if conn in bmap:
            control = {"type": "backlight", "device": bmap[conn]}
        elif conn in by_conn and by_conn[conn].get("bus") is not None:
            control = {"type": "ddcutil", "bus": by_conn[conn]["bus"]}
            used_buses.add(control["bus"])
        if control:
            entries.append((m, control))
        else:
            unmatched.append(m)

    leftover = [d for d in displays if d.get("bus") is not None and d["bus"] not in used_buses]
    for m in unmatched:
        if leftover:
            d = leftover.pop(0)
            control = {"type": "ddcutil", "bus": d["bus"]}
        else:
            control = None
        entries.append((m, control))

    gamma = read_gamma()
    doc = {
        "gamma": {
            "value": gamma if gamma >= 0 else 100,
            "available": gamma >= 0 or HYPRSUNSET is not None,
        },
        "monitors": [],
    }
    for m, control in entries:
        entry = {
            "name": m["name"],
            "model": m["model"],
            "label": m["name"] + (f" · {m['model']}" if m.get("model") else ""),
            "control": control["type"] if control else "unsupported",
            "device": control.get("device", "") if control else "",
            "bus": control.get("bus", 0) if control else 0,
            "value": -1,
            "supported": control is not None,
        }
        if control and control["type"] == "backlight":
            entry["value"] = read_backlight(control["device"])
        elif control and control["type"] == "ddcutil":
            entry["value"] = read_ddc(control["bus"])
        doc["monitors"].append(entry)
    return doc


# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if not args:
        print("usage: brightness-control.py <poll|get|set> ...", file=sys.stderr)
        return 2
    cmd = args[0]
    try:
        if cmd == "poll":
            print(json.dumps(poll()))
            return 0
        if cmd == "get":
            kind = args[1] if len(args) > 1 else ""
            if kind == "gamma":
                print(read_gamma())
                return 0
            if kind == "backlight" and len(args) > 2:
                print(read_backlight(args[2]))
                return 0
            if kind == "ddcutil" and len(args) > 2:
                print(read_ddc(int(args[2])))
                return 0
            return 2
        if cmd == "set":
            kind = args[1] if len(args) > 1 else ""
            if kind == "gamma" and len(args) > 2:
                return 0 if set_gamma(int(args[2])) else 1
            if kind == "backlight" and len(args) > 3:
                return 0 if set_backlight(args[2], int(args[3])) else 1
            if kind == "ddcutil" and len(args) > 3:
                return 0 if set_ddc(int(args[2]), int(args[3])) else 1
            return 2
        return 2
    except (IndexError, ValueError):
        return 2


if __name__ == "__main__":
    sys.exit(main())
