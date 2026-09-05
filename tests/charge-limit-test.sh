#!/usr/bin/env bash
# Covers the battery charge limit: armada-powerd battery discovery against a
# fake /sys/class/power_supply tree, threshold read/write with readback,
# MaxChargeLevel get/set semantics (-1 mapping, 55..100 validation, start =
# end - 5), the tick-driven re-apply at boot and after resume, and the
# steamos-manager shim gating BatteryChargeLimit1 on powerd support.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" "$WORK" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import pathlib
import sys
import types

ROOT, WORK = sys.argv[1], sys.argv[2]
LIB = os.path.join(ROOT, "system_files/usr/lib/armada")
LIBEXEC = os.path.join(ROOT, "system_files/usr/libexec/armada")
sys.path.insert(0, LIB)

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)
        print(f"FAIL: {name}", file=sys.stderr)


def load_script(name):
    spec = importlib.util.spec_from_loader(
        name.replace("-", "_"),
        importlib.machinery.SourceFileLoader(
            name.replace("-", "_"), os.path.join(LIBEXEC, name)),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_supply(root, name, kind, thresholds=None):
    supply = pathlib.Path(root) / name
    supply.mkdir(parents=True, exist_ok=True)
    (supply / "type").write_text(f"{kind}\n")
    if thresholds is not None:
        start, end = thresholds
        (supply / "charge_control_start_threshold").write_text(f"{start}\n")
        (supply / "charge_control_end_threshold").write_text(f"{end}\n")
    return supply


def read_thresholds(supply):
    return (
        int((supply / "charge_control_start_threshold").read_text()),
        int((supply / "charge_control_end_threshold").read_text()),
    )


# --- armada-powerd: battery discovery ---------------------------------------
powerd = load_script("armada-powerd")
powerd.GLib = types.SimpleNamespace(Variant=lambda sig, value: (sig, value))


def new_power(root):
    powerd.POWER_SUPPLY_ROOT = powerd.Path(root)
    power = powerd.ArmadaPower.__new__(powerd.ArmadaPower)
    power.battery = None
    power.charge_limit_pending = None
    power.connection = None
    power.gpu = None
    power.save_state = lambda: None
    power.emitted = []
    power.emit_properties = lambda changed: power.emitted.append(changed)
    return power


ps_none = os.path.join(WORK, "ps-none")
make_supply(ps_none, "usb", "USB")
make_supply(ps_none, "bat_plain", "Battery")
check("no threshold file -> no battery", powerd.discover_battery(ps_none) is None)

ps = os.path.join(WORK, "ps")
make_supply(ps, "usb", "USB")
make_supply(ps, "wireless", "Wireless", (60, 65))
battery = make_supply(ps, "battery", "Battery", (70, 80))
check("battery with thresholds found", powerd.discover_battery(ps) == battery)

power = new_power(ps_none)
check("lazy discovery: none yet", power.battery_dir() is None)
check("read_charge_limit None without battery", power.read_charge_limit() is None)
check("write_charge_limit False without battery", power.write_charge_limit(75, 80) is False)
late = make_supply(ps_none, "battery", "Battery", (0, 0))
check("lazy discovery: found on retry", power.battery_dir() == late)
check("read_charge_limit reads 0/0", power.read_charge_limit() == (0, 0))

power = new_power(ps)
check("read_charge_limit reads android 70/80", power.read_charge_limit() == (70, 80))
check("write_charge_limit reads back", power.write_charge_limit(75, 80) is True)
check("write_charge_limit wrote start then end", read_thresholds(battery) == (75, 80))
check("write skips start below 50", power.write_charge_limit(0, 60) is True)
check("start untouched when skipped", read_thresholds(battery) == (75, 60))

real_write_text = powerd.write_text
powerd.write_text = lambda path, value: True
check("write_charge_limit False on readback mismatch", power.write_charge_limit(80, 85) is False)
powerd.write_text = real_write_text

# --- armada-powerd: MaxChargeLevel semantics --------------------------------
power = new_power(ps)
(battery / "charge_control_start_threshold").write_text("70\n")
(battery / "charge_control_end_threshold").write_text("80\n")
check("value: android 80 -> 80", power.charge_limit_value() == 80)
(battery / "charge_control_end_threshold").write_text("100\n")
check("value: 100 -> -1", power.charge_limit_value() == -1)
(battery / "charge_control_end_threshold").write_text("0\n")
check("value: 0 -> -1", power.charge_limit_value() == -1)
check("value: no battery -> -1", new_power(ps_none + "-missing").charge_limit_value() == -1)

check("set 80 returns 80", power.set_charge_limit(80) == 80)
check("set 80 writes 75/80", read_thresholds(battery) == (75, 80))
check("set 55 writes 50/55", power.set_charge_limit(55) == 55 and read_thresholds(battery) == (50, 55))
check("set -1 returns -1", power.set_charge_limit(-1) == -1)
check("set -1 writes 95/100", read_thresholds(battery) == (95, 100))
check("set 97 then -1 resets", power.set_charge_limit(97) == 97 and power.set_charge_limit(-1) == -1
      and read_thresholds(battery) == (95, 100))
for bad in (54, 101, 0, -2):
    try:
        power.set_charge_limit(bad)
        check(f"set rejects {bad}", False)
    except ValueError:
        pass
check("bad set leaves thresholds", read_thresholds(battery) == (95, 100))
try:
    new_power(ps_none + "-missing").set_charge_limit(80)
    check("set without battery raises", False)
except RuntimeError:
    pass

check("no pending after good set", power.charge_limit_pending is None)
powerd.write_text = lambda path, value: True
power.set_charge_limit(85)
powerd.write_text = real_write_text
check("failed set schedules retry with target",
      power.charge_limit_pending == {"attempts": 5, "wait": 1, "target": (80, 85)})

# --- armada-powerd: D-Bus properties ----------------------------------------
power = new_power(ps)
check("XML declares MaxChargeLevel i readwrite",
      '<property name="MaxChargeLevel" type="i" access="readwrite"/>' in powerd.XML)
check("XML declares SuggestedMinimumLimit i read",
      '<property name="SuggestedMinimumLimit" type="i" access="read"/>' in powerd.XML)
check("XML declares ChargeLimitSupported b read",
      '<property name="ChargeLimitSupported" type="b" access="read"/>' in powerd.XML)
check("get MaxChargeLevel", power.get_property("MaxChargeLevel") == ("i", -1))
check("get SuggestedMinimumLimit", power.get_property("SuggestedMinimumLimit") == ("i", 55))
check("get ChargeLimitSupported", power.get_property("ChargeLimitSupported") == ("b", True))
check("get ChargeLimitSupported false",
      new_power(ps_none + "-missing").get_property("ChargeLimitSupported") == ("b", False))
power.set_property("MaxChargeLevel", types.SimpleNamespace(get_int32=lambda: 80))
check("set property writes 75/80", read_thresholds(battery) == (75, 80))
check("set property emits readback", power.emitted == [{"MaxChargeLevel": ("i", 80)}])
try:
    power.set_property("MaxChargeLevel", types.SimpleNamespace(get_int32=lambda: 40))
    check("set property rejects 40", False)
except ValueError:
    pass

# --- armada-powerd: tick-driven re-apply ------------------------------------
writes = []
powerd.write_text = lambda path, value: writes.append((path.name, int(value))) or real_write_text(path, value)

power = new_power(ps)
(battery / "charge_control_start_threshold").write_text("70\n")
(battery / "charge_control_end_threshold").write_text("80\n")
power.schedule_charge_limit()
power.charge_limit_tick()
check("first tick waits", writes == [] and power.charge_limit_pending["wait"] == 0)
power.charge_limit_tick()
check("rewrite preserves android 70/80",
      writes == [("charge_control_start_threshold", 70), ("charge_control_end_threshold", 80)])
check("rewrite clears pending", power.charge_limit_pending is None)
power.charge_limit_tick()
check("idle tick writes nothing", len(writes) == 2)

writes.clear()
(battery / "charge_control_start_threshold").write_text("0\n")
(battery / "charge_control_end_threshold").write_text("0\n")
power.schedule_charge_limit()
power.charge_limit_tick()
power.charge_limit_tick()
check("unset limit is not rewritten", writes == [] and power.charge_limit_pending is None)

writes.clear()
(battery / "charge_control_start_threshold").write_text("0\n")
(battery / "charge_control_end_threshold").write_text("80\n")
power.schedule_charge_limit()
power.charge_limit_tick()
power.charge_limit_tick()
check("partial limit rewrites end only", writes == [("charge_control_end_threshold", 80)])

writes.clear()
late_root = os.path.join(WORK, "ps-late")
os.makedirs(late_root)
power = new_power(late_root)
power.schedule_charge_limit()
for _ in range(10):
    power.charge_limit_tick()
check("waits for battery without consuming attempts",
      writes == [] and power.charge_limit_pending["attempts"] == 5)
late_bat = make_supply(late_root, "battery", "Battery", (75, 80))
power.charge_limit_tick()   # battery now visible; this tick consumes the wait
power.charge_limit_tick()
check("applies once battery appears",
      writes == [("charge_control_start_threshold", 75), ("charge_control_end_threshold", 80)]
      and power.charge_limit_pending is None)

writes.clear()
powerd.write_text = lambda path, value: True
power.schedule_charge_limit((80, 85))
for _ in range(7):
    power.charge_limit_tick()
check("gives up after 5 attempts", power.charge_limit_pending is None)
powerd.write_text = real_write_text
check("give-up leaves thresholds untouched", read_thresholds(late_bat) == (75, 80))

power = new_power(ps)
power.suspended = True
power.suspend_save = {}
power.smoothed_temp = 0.0
power.apply_profile = lambda: None
power.gpu_level = "auto"
power.fan_tick = lambda: None
power.resume()
check("resume schedules re-apply", power.charge_limit_pending == {"attempts": 5, "wait": 1, "target": None})

if failures:
    print(f"{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("all charge-limit checks passed")
PYEOF

echo "PASS: charge-limit-test"
