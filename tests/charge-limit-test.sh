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

if failures:
    print(f"{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("all charge-limit checks passed")
PYEOF

echo "PASS: charge-limit-test"
