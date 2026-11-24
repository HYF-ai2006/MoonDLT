#!/usr/bin/env python3
"""Reproduce local checks and save evidence, without publishing or network writes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "work" / "validation"


def run(name: str, command: list[str]) -> dict:
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, encoding="utf-8",
                                errors="replace", timeout=240)
        output = result.stdout + result.stderr
        exit_code = result.returncode
        error = None
    except (OSError, subprocess.TimeoutExpired) as exception:
        output = str(exception)
        exit_code = None
        error = output
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / f"{name}.log").write_text(output, encoding="utf-8")
    check = {"name": name, "command": command, "exit_code": exit_code,
             "status": "PASS" if exit_code == 0 else "FAIL"}
    if error:
        check["error"] = error
    match = re.search(r"Total tests: (\d+), passed: (\d+), failed: (\d+)", output)
    if match:
        check["tests"] = dict(zip(("total", "passed", "failed"), map(int, match.groups())))
    if name.startswith("test_") and (not match or int(match[1]) == 0 or match[1] != match[2] or int(match[3])):
        check["status"] = "FAIL"
        check["error"] = "Expected a nonempty test run with every test passing"
    print(f"{check['status']}: {name}", flush=True)
    if check["status"] == "FAIL":
        print(output[-6000:], flush=True)
    return check


def write_summary(report: dict) -> None:
    rows = []
    for check in report["checks"]:
        result = check["status"]
        if "tests" in check:
            result += f" ({check['tests']['passed']}/{check['tests']['total']})"
        if check.get("reason"):
            result += ": " + check["reason"]
        rows.append(f"| `{check['name']}` | {result} |")
    core = report.get("source_scale", {}).get("totals", {}).get("core", {})
    text = "\n".join([
        "# 本地验证记录", "", f"记录时间：{report['recorded_at']}。结果：**{report['result']}**。",
        "", "本文件由 `scripts/validate.py` 按实际执行结果生成。未进行远程推送、报名或发布。",
        "", "| 检查 | 结果 |", "| --- | --- |", *rows, "",
        f"核心源码：{core.get('physical', '未知')} 物理行，去除注释和空行后 {core.get('code_nonblank', '未知')} 行，"
        f"进一步去除纯结构符号后 **{core.get('effective_strict', '未知')} 严格有效行**。测试、示例、生成文件和依赖均未计入核心。",
        "", "复现：`python scripts/validate.py --release-tests`。机器记录见 `LOCAL_VALIDATION.json`，完整日志在忽略目录 `work/validation/`。",
        "", "局限：高级 VARI/FIXP/数组未获得独立 pydlt 互操作证明；没有实车或量产日志语料；云端 CI 尚未执行。",
        "Windows 原生运行需要 MSVC C++ 编译环境与 SDK，未运行项不能视为通过。", "",
    ])
    (ROOT / "docs" / "LOCAL_VALIDATION.md").write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="Require a native runtime test")
    parser.add_argument("--release-tests", action="store_true", help="Also execute optimized Wasm and JS tests")
    arguments = parser.parse_args()
    checks = []
    commands = [
        ("format", ["moon", "fmt", "--check"]),
        ("compile_all", ["moon", "check", "--target", "all", "--deny-warn"]),
        ("test_wasm", ["moon", "test", "--target", "wasm", "--deny-warn"]),
        ("test_wasm_gc", ["moon", "test", "--target", "wasm-gc", "--deny-warn"]),
        ("test_js", ["moon", "test", "--target", "js", "--deny-warn"]),
        ("demo", ["moon", "run", "cmd/demo", "--target", "js", "--deny-warn"]),
        ("interfaces", ["moon", "info"]),
        ("source_scale", [sys.executable, "scripts/count_loc.py", "--minimum", "4000"]),
        ("independent_interop", [sys.executable, "scripts/interop.py"]),
        ("seeded_interop", [sys.executable, "scripts/test_interop_random.py"]),
        ("file_cli", [sys.executable, "scripts/test_file_cli.py"]),
    ]
    if arguments.release_tests:
        commands.extend([
            ("test_release_wasm", ["moon", "test", "--target", "wasm", "--release", "--deny-warn"]),
            ("test_release_js", ["moon", "test", "--target", "js", "--release", "--deny-warn"]),
        ])
    for name, command in commands:
        checks.append(run(name, command))
    if arguments.native or platform.system() != "Windows" or shutil.which("cl") or shutil.which("clang-cl"):
        checks.append(run("test_native", ["moon", "test", "--target", "native", "--deny-warn"]))
    else:
        checks.append({"name": "test_native", "status": "NOT_RUN",
                       "reason": "Windows MSVC C++ compiler/linker and SDK are unavailable in this environment"})
    scale = subprocess.run([sys.executable, "scripts/count_loc.py", "--json"],
                           cwd=ROOT, capture_output=True, encoding="utf-8", check=True)
    toolchain = subprocess.run(["moon", "version", "--all"], cwd=ROOT,
                              capture_output=True, encoding="utf-8", check=True)
    node = subprocess.run(["node", "--version"], cwd=ROOT,
                         capture_output=True, encoding="utf-8", check=True)
    report = {
        "recorded_at": datetime.now(timezone(timedelta(hours=8))).isoformat(),
        "scope": "Local validation only; no remote repository, contest submission or Mooncakes publication",
        "platform": platform.system(), "node": node.stdout.strip(),
        "toolchain": toolchain.stdout.strip(), "checks": checks,
        "source_scale": json.loads(scale.stdout),
        "limitations": [
            "Advanced VARI/FIXP/array types have standard-derived unit tests, not independent pydlt interoperability evidence",
            "The 54 external vectors cover the common v1 scalar profile, not complete AUTOSAR certification",
            "No real vehicle hardware or production fleet log corpus was used",
            "Remote CI configuration has not been executed on a hosting service",
        ],
    }
    report["result"] = "FAIL" if any(check["status"] == "FAIL" for check in checks) else "PASS_WITH_LIMITATIONS"
    target = ROOT / "docs" / "LOCAL_VALIDATION.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_summary(report)
    print(f"{report['result']}: evidence saved to docs/LOCAL_VALIDATION.json")
    if report["result"] == "FAIL":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
