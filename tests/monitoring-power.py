#!/usr/bin/env python3
"""Test evaluated monitoring rules: monitoring-power.py EVAL_JSON [PROMTOOL]."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


def series(metric, values):
    return {"series": metric, "values": values}


def assertion(metric, value, time="1m"):
    samples = [] if value is None else [{
        "labels": (f'{{__name__="{metric}",instance="test",model="no-battery"}}'
                   if metric.startswith("pc:energy_") else
                   f'{{__name__="{metric}",instance="test"}}'),
        "value": value,
    }]
    return {"expr": metric, "eval_time": time, "exp_samples": samples}


def case(name, inputs, *assertions):
    return {
        "name": name,
        "interval": "1s",
        "input_series": inputs,
        "promql_expr_test": list(assertions),
    }


def fixtures(extra=(), online=1):
    values = {
        "pc:cpu_power_watts": 20,
        "pc:gpu_power_watts": 30,
        "pc_power_supply_rated_watts": 100,
        "pc_power_supply_idle_watts": 2,
        "pc_power_supply_peak_efficiency": 0.8,
        "pc_power_supply_curvature": 0,
        "pc_power_supply_peak_load_ratio": 0.5,
        "node_power_supply_online": online,
    }
    return [
        series(f'{metric}{{instance="test"}}', f"{value}+0x60")
        for metric, value in values.items()
    ] + [series('up{instance="test",job="node"}', "1+0x60")] + list(extra)


def energy_cases():
    tests = []
    for name, values, joules, seconds in [
        ("full minute", "100+0x60", 6000, 60),
        ("started halfway", "_x30 100+0x29", 3000, 30),
        ("gap remains missing", "100+0x15 stale _x29 100+0x14", 3000, 30),
        ("observed zero consumption", "0+0x60", 0, 60),
    ]:
        tests.append(case(
            name, [series('pc:equivalent_power_watts{instance="test"}', values)],
            assertion("pc:energy_joules:1m", joules),
            assertion("pc:energy_observed_seconds:1m", seconds),
        ))
    tests.append(case("absent host not invented", [], assertion("pc:energy_joules:1m", None)))
    for name, values, uptime, observed in [
        ("full minute of uptime", "1+0x60", 60, 60),
        ("late telemetry does not claim the whole minute", "_x30 1+0x29", 30, 30),
        ("recorded downtime stays distinct from missing telemetry", "1+0x15 0+0x14 stale _x30", 15, 30),
    ]:
        tests.append(case(
            name, [series('host:up{instance="test"}', values)],
            assertion("host:uptime_seconds:1m", uptime),
            assertion("host:up_observed_seconds:1m", observed),
        ))
    return tests


def model_cases():
    tests = [
        case("disjoint CPU and GPU plus supply losses", fixtures(),
             assertion("pc:power_dc_watts", 50),
             assertion("pc:power_watts", 62.5),
             assertion("pc:equivalent_power_watts", 62.5)),
        case("platform replaces overlapping CPU and GPU", fixtures([
            series('pc:platform_power_watts{instance="test"}', "40+0x60")]),
            assertion("pc:power_dc_watts", 40), assertion("pc:power_watts", 50)),
        case("named fixed component is included once", fixtures([
            series('pc_power_fixed_component_watts{instance="test",component="SATA controller"}',
                   "5+0x60")]),
            assertion("pc:power_dc_watts", 55), assertion("pc:power_watts", 68.75)),
        case("selected and modelled power share one component snapshot", [
            series('pc:cpu_power_watts{instance="test"}', "20+1x60"),
            *[s for s in fixtures() if not s["series"].startswith("pc:cpu_power_watts{")]],
            assertion("pc:power_model_watts", 137.5),
            assertion("pc:power_watts", 137.5),
            assertion("pc:equivalent_power_watts", 137.5)),
        case("unplugged laptop uses the same supply-loss model", fixtures(online=0),
             assertion("pc:power_dc_watts", 50), assertion("pc:power_watts", 62.5),
             assertion("pc:equivalent_power_watts", 62.5)),
        case("meter overrides model and residual compares model", fixtures([
            series('pc_power_meter_watts{instance="test"}', "70+0x60")]),
            assertion("pc:power_model_watts", 62.5), assertion("pc:power_watts", 70),
            assertion("pc:equivalent_power_watts", 70),
            assertion("pc:power_model_error_watts", 7.5)),
        case("battery charging telemetry does not alter modelled power", fixtures([
            series('laptop_battery_power_watts{instance="test",battery="BAT0"}', "9+0x60"),
            series('laptop_battery_status_info{instance="test",battery="BAT0",status="Charging"}', "1+0x60")]),
            assertion("pc:power_watts", 62.5), assertion("pc:equivalent_power_watts", 62.5)),
        case("negative meter is clamped to zero", [
            series('pc_power_meter_watts{instance="test"}', "-10+0x60")],
            assertion("pc:power_watts", 0), assertion("pc:equivalent_power_watts", 0)),
    ]
    stale = [
        series(s["series"], "1+0x10 _x50") if s["series"].startswith("up{") else s
        for s in fixtures()
    ]
    tests.append(case("node freshness prevents phantom mains and usage", stale,
                      assertion("pc:power_watts", None), assertion("pc:equivalent_power_watts", None)))
    tests.append(case("stale meter expires", [
        series('pc_power_meter_watts{instance="test"}', "70+0x10 _x50")],
        assertion("pc:power_watts", None), assertion("pc:equivalent_power_watts", None)))
    tests.append(case("missing CPU cannot produce a partial DC total", [
        s for s in fixtures() if not s["series"].startswith("pc:cpu_power_watts{")],
        assertion("pc:power_dc_watts", None), assertion("pc:equivalent_power_watts", None)))
    return tests


def main():
    if not 2 <= len(sys.argv) <= 3:
        raise SystemExit(__doc__)
    evaluated = json.loads(Path(sys.argv[1]).read_text())
    rules = evaluated["rules"]
    for folder in evaluated["dashboards"].values():
        for dashboard in folder.values():
            for panel in dashboard["panels"]:
                energy_targets = [
                    target for target in panel.get("targets", [])
                    if "pc:energy_joules:1m" in target.get("expr", "")
                ]
                if energy_targets:
                    assert panel["datasource"]["uid"] == "prometheus-archive", panel["title"]
                    assert all(target["datasource"]["uid"] == "prometheus-archive"
                               for target in energy_targets), panel["title"]
    uptime_panel = next(panel for panel in evaluated["dashboards"]["overview"]["home.json"]["panels"]
                        if panel["title"] == "System session summary")
    assert uptime_panel["fieldConfig"]["defaults"]["unit"] == "dtdurations"
    assert uptime_panel["datasource"]["uid"] == "prometheus-lt"
    assert all(target["datasource"]["uid"] == "prometheus-lt"
               for target in uptime_panel["targets"])
    overview_panels = evaluated["dashboards"]["overview"]["home.json"]["panels"]
    mean_panel = next(panel for panel in overview_panels
                      if panel["title"] == "Equivalent wall power while awake (24h)")
    peak_panel = next(panel for panel in overview_panels
                      if panel["title"] == "Peak equivalent wall power (24h)")
    assert mean_panel["type"] == "timeseries" and mean_panel["timeFrom"] == "24h"
    assert mean_panel["targets"][0]["expr"].startswith("avg_over_time(pc:equivalent_power_watts")
    assert mean_panel["fieldConfig"]["defaults"]["custom"]["spanNulls"] is False
    assert peak_panel["type"] == "bargauge"
    assert peak_panel["datasource"]["uid"] == "prometheus-lt"
    assert peak_panel["targets"][0]["expr"].startswith("max_over_time(pc:equivalent_power_watts")
    promtool = sys.argv[2] if len(sys.argv) == 3 else "promtool"
    sensor_rules = rules["hires"][0]["rules"]
    assert all("laptop_battery" not in rule["expr"]
               and "node_power_supply_online" not in rule["expr"]
               for rule in sensor_rules if rule["record"].startswith("pc:"))
    start = next(i for i, rule in enumerate(sensor_rules)
                 if rule["record"] == "pc:power_dc_component_watts")
    end = next(i for i, rule in enumerate(sensor_rules)
               if rule["record"] == "pc:equivalent_power_watts")
    # Isolate downstream rules so upstream recordings cannot overwrite fixtures.
    groups = [{"name": "model", "interval": "1s", "rules": sensor_rules[start:end + 1]}]
    cpu_groups = [{"name": "cpu", "interval": "1s", "rules": [
        rule for rule in sensor_rules if rule["record"] == "pc:cpu_power_watts"
    ]}]
    cpu_tests = [
        case("valid package energy rate", [
            series('node_rapl_package_joules_total{instance="test",path="package-0"}', "0+20x60")],
            assertion("pc:cpu_power_watts", 20)),
        case("corrupt package counter cannot become fabricated 400 watts", [
            series('node_rapl_package_joules_total{instance="test",path="package-0"}', "0+1000x60")],
            assertion("pc:cpu_power_watts", None)),
    ]
    suites = [
        ("energy", rules["energy"], energy_cases()),
        ("model", groups, model_cases()),
        ("cpu", cpu_groups, cpu_tests),
    ]
    with tempfile.TemporaryDirectory(prefix="monitoring-power-") as directory:
        root = Path(directory)
        for name, group, tests in suites:
            rule_path = root / f"{name}-rules.json"
            rule_path.write_text(json.dumps({"groups": group}))
            test_path = root / f"{name}-tests.json"
            test_path.write_text(json.dumps({
                "rule_files": [str(rule_path)],
                "evaluation_interval": "1s",
                "fuzzy_compare": True,
                "tests": tests,
            }))
            subprocess.run([promtool, "test", "rules", str(test_path)], check=True)
        for name, group in rules.items():
            rule_path = root / f"{name}-all.json"
            rule_path.write_text(json.dumps({"groups": group}))
            subprocess.run([promtool, "check", "rules", str(rule_path)], check=True)
    print(f"{sum(len(tests) for _, _, tests in suites)} power, energy and uptime regression cases passed")


if __name__ == "__main__":
    main()
