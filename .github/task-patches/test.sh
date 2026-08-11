#!/usr/bin/env bash
# Compact verifier entrypoint — SELF-CONTAINED (generic; shipped per task).
#
# Resolves the workspace, applies the eval tests (tests/tests.patch) at verify
# time, runs the configured test command(s), then grades via an EMBEDDED copy of
# grade.py (inlined at materialize time at the grader marker below — no sibling
# grade.py ships). Reads tests/config.json = {execution, grading, artifacts}.
# A fallback trap guarantees reward.txt exists.
set -uo pipefail

CONFIG="/tests/config.json"
LOG_DIR="/logs/verifier"
STDOUT_LOG="$LOG_DIR/test-stdout.txt"
STDERR_LOG="$LOG_DIR/test-stderr.txt"
REPORT="$LOG_DIR/report.json"
OUTPUT="$LOG_DIR/output.json"
REWARD="$LOG_DIR/reward.txt"

mkdir -p "$LOG_DIR"

# Safety net: if we crash before the grader writes the reward, write 0.
write_zero_reward_if_missing() {
  if [ ! -f "$REWARD" ]; then echo "0" > "$REWARD"; fi
}
trap write_zero_reward_if_missing EXIT

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: missing $CONFIG" | tee "$STDERR_LOG"
  echo '{"success": false, "infrastructure_error": "missing config.json", "reward": 0.0}' > "$REPORT"
  echo "0" > "$REWARD"
  exit 2
fi

# Resolve the workspace from hardcoded fallbacks (config carries no workspace).
WORKSPACE=""
for p in /app /testbed /workspace; do
  if [ -d "$p" ]; then WORKSPACE="$p"; break; fi
done
if [ -z "$WORKSPACE" ]; then
  echo "ERROR: could not resolve workspace" | tee "$STDERR_LOG"
  echo '{"success": false, "infrastructure_error": "missing workspace", "reward": 0.0}' > "$REPORT"
  echo "0" > "$REWARD"
  exit 2
fi
cd "$WORKSPACE" || exit 2
export VERIFIER_WORKSPACE="$WORKSPACE"

# Export configured env vars (execution.env).
python3 - <<'PY' > /tmp/verifier_env.sh
import json, shlex
cfg = json.load(open("/tests/config.json"))
env = (cfg.get("execution") or {}).get("env", {})
if isinstance(env, dict):
    for k, v in env.items():
        if isinstance(k, str):
            print(f"export {k}={shlex.quote(str(v))}")
PY
# shellcheck disable=SC1091
source /tmp/verifier_env.sh

# Apply the eval tests at VERIFY time. They ship as tests/tests.patch (NOT in
# repo/), so the solving agent never saw them. git apply (plain, then 3-way for
# agent edits to neighbouring files) when git exists; otherwise fall back to
# patch(1), which patch_dockerfile injects into every task image — a slim/alpine
# base without git must not zero the reward. A hard failure means we cannot
# grade -> infra error, reward 0.
if [ -f /tests/tests.patch ]; then
  APPLIED=0
  if command -v git >/dev/null 2>&1; then
    if git apply /tests/tests.patch 2>>"$STDERR_LOG" \
       || git apply --3way /tests/tests.patch 2>>"$STDERR_LOG"; then
      APPLIED=1
    fi
  fi
  if [ "$APPLIED" != "1" ] && command -v patch >/dev/null 2>&1; then
    if patch -p1 --forward < /tests/tests.patch >>"$STDERR_LOG" 2>&1; then
      APPLIED=1
    fi
  fi
  if [ "$APPLIED" != "1" ]; then
    echo "ERROR: failed to apply tests/tests.patch" | tee -a "$STDERR_LOG"
    echo '{"success": false, "infrastructure_error": "tests.patch did not apply", "reward": 0.0}' > "$REPORT"
    echo "0" > "$REWARD"
    exit 2
  fi
fi

# Materialize task-owned verifier assets (not shipped as separate tests/ files).
cat > /tmp/verifier.init.gradle <<'VERIFIER_INIT_GRADLE_EOF'
// Verifier-owned init script — disables Gradle Test tasks so repository build
// logic cannot emit graded results.
gradle.projectsLoaded { g ->
    g.rootProject.allprojects { project ->
        project.tasks.withType(Test).configureEach {
            enabled = false
        }
    }
    g.rootProject.subprojects { sub ->
        sub.plugins.withId('java') {
            sub.tasks.register('verifierPrintTestClasspath') {
                group = 'verification'
                description = 'Prints the unit-test runtime classpath for the verifier JUnit launcher.'
                dependsOn sub.tasks.named('testClasses')
                doLast {
                    println sub.sourceSets.test.runtimeClasspath.asPath
                }
            }
        }
    }
}
VERIFIER_INIT_GRADLE_EOF

cat > /tmp/run_junit_verifier.py <<'RUN_JUNIT_VERIFIER_PY_EOF'
#!/usr/bin/env python3
"""Fail-closed hidden-test runner for lod-server-support task #101.

Source of truth: JUnit Platform Console Launcher invoked by this script with explicit
class/method selectors. Gradle is used ONLY for compilation and classpath resolution.
Results are read from launcher exit codes and verifier-owned report directories under
/tmp — never from workspace **/build/test-results/** XML.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

CONFIG_PATH = Path("/tests/config.json")
INIT_SCRIPT = Path("/tmp/verifier.init.gradle")
WORKSPACE = Path(os.environ.get("VERIFIER_WORKSPACE", os.getcwd()))

MODULE_TESTS: dict[str, list[str]] = {
    "fabric": [
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#viaClassesAbsentLegacyHandshakeProceedsThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#throwingGetApiLeavesLegacyHandshakeUnchangedThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#providerPresentNullApiLeavesLegacyHandshakeUnchangedThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#viaMismatchDeniesEveryLegacyDialectSilentlyThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#viaMismatchNeverTouchesACurrentClientThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#versionMismatchOutranksViaGuardThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#toggleOffIgnoresViaMismatchThroughProductionEntry",
        "dev.vox.lss.networking.server.LSSServerNetworkingHandshakeGlueTest#viaMismatchLogsBothMinecraftProtocolNumbers",
        "dev.vox.lss.config.ConfigValidationTest#viaMismatchGuardDefaultsOn",
        "dev.vox.lss.networking.server.HandshakeGateTest#happyPathRepliesAndRegisters",
        "dev.vox.lss.networking.server.HandshakeGateTest#v19WithCompatEnabledTakesTheNormalLadderWithTheV19Dialect",
    ],
    "paper": [
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#viaClassesAbsentPluginStartsNormally",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#viaClassesAbsentLegacyHandshakeProceedsThroughProductionEntry",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#viaMismatchOnALegacyHandshakeIsDeniedSilentlyThroughProductionEntry",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#viaMismatchNeverTouchesACurrentClientThroughProductionEntry",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#throwingGetApiLeavesLegacyHandshakeUnchangedThroughProductionEntry",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#providerPresentNullApiLeavesLegacyHandshakeUnchangedThroughProductionEntry",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#viaMismatchLogsBothMinecraftProtocolNumbers",
        "dev.vox.lss.paper.LSSPaperPluginViaProductionTest#toggleOffIgnoresViaMismatchThroughProductionEntry",
        "dev.vox.lss.paper.PaperConfigValidationTest#viaMismatchGuardDefaultsOn",
        "dev.vox.lss.paper.LSSPaperPluginGlueTest#noViaSignalLeavesLegacyHandshakeUnchangedThroughStaticGlue",
        "dev.vox.lss.paper.PluginYmlContractTest#viaVersionIsNotAHardDependency",
    ],
}


@dataclass
class TestExecution:
    fqcn: str
    method: str
    module: str
    discovered: int
    started: int
    finished: int
    passed: int
    failed: int
    skipped: int
    aborted: int

    @property
    def grade_name(self) -> str:
        return f"{self.fqcn}::{self.method}"

    @property
    def ok(self) -> bool:
        return (
            self.discovered == 1
            and self.started == 1
            and self.finished == 1
            and self.passed == 1
            and self.failed == 0
            and self.skipped == 0
            and self.aborted == 0
        )


def _parse_selector(selector: str) -> tuple[str, str]:
    cls, method = selector.split("#", 1)
    return cls, method


def _load_required_from_config() -> tuple[list[str], list[str]]:
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    grading = cfg.get("grading") or {}
    f2p = grading.get("fail_to_pass") or []
    p2p = grading.get("pass_to_pass") or []
    return [str(x) for x in f2p], [str(x) for x in p2p]


def _usable_gradle_home(path: str | None) -> bool:
    if not path:
        return False
    try:
        return Path(path).is_dir()
    except OSError:
        return False


def _gradle_env(report_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    # Prefer a verifier-owned Gradle home outside the agent workspace. Docker images
    # warm /root/.gradle at build time; do not use a fresh empty directory with
    # --offline or every verify run would need network access.
    gradle_home: str | None = env.get("VERIFIER_GRADLE_USER_HOME")
    if not gradle_home:
        for candidate in ("/root/.gradle", os.path.expanduser("~/.gradle")):
            if _usable_gradle_home(candidate):
                gradle_home = candidate
                break
    if gradle_home:
        env["GRADLE_USER_HOME"] = gradle_home
    else:
        fallback = report_dir / "gradle-home"
        fallback.mkdir(parents=True, exist_ok=True)
        env["GRADLE_USER_HOME"] = str(fallback)
    env["GRADLE_OPTS"] = "-Dorg.gradle.daemon=false -Dorg.gradle.parallel=false -Dorg.gradle.workers.max=1"
    return env


def _run(cmd: list[str], env: dict[str, str], cwd: Path) -> None:
    proc = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)


def _scrub_test_outputs() -> None:
    for rel in (
        "common/build/classes/java/test",
        "fabric/build/classes/java/test",
        "paper/build/classes/java/test",
    ):
        shutil.rmtree(WORKSPACE / rel, ignore_errors=True)


def _compile_modules(env: dict[str, str]) -> None:
    base = [
        "./gradlew",
        "--offline",
        "--no-daemon",
        "-Dorg.gradle.parallel=false",
        f"--init-script={INIT_SCRIPT}",
    ]
    _run(
        base + [":common:classes", ":fabric:testClasses"],
        env,
        WORKSPACE,
    )
    _run(base + [":paper:testClasses"], env, WORKSPACE)


def _classpath(module: str, env: dict[str, str]) -> str:
    cmd = [
        "./gradlew",
        "--offline",
        "--no-daemon",
        "--quiet",
        f"--init-script={INIT_SCRIPT}",
        f":{module}:verifierPrintTestClasspath",
    ]
    proc = subprocess.run(cmd, cwd=WORKSPACE, env=env, text=True, capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        print("ERROR: empty test classpath", file=sys.stderr)
        raise SystemExit(1)
    cp = lines[-1]
    extras: list[str] = []
    for rel in (
        "common/build/classes/java/main",
        "common/build/resources/main",
    ):
        path = WORKSPACE / rel
        if path.is_dir():
            extras.append(str(path))
    if extras:
        cp = cp + os.pathsep + os.pathsep.join(extras)
    return cp


def _parse_launcher_report(report_xml: Path) -> tuple[int, int, int, int, int, int]:
    if not report_xml.is_file():
        return 0, 0, 0, 0, 0, 0
    root = ET.parse(report_xml).getroot()
    if root.tag == "testsuite":
        suites = [root]
    else:
        suites = list(root.iter("testsuite"))
    if len(suites) != 1:
        return 0, 0, 0, 0, 0, 0
    suite = suites[0]
    cases = list(suite.iter("testcase"))
    if len(cases) != 1:
        return 0, len(cases), 0, 0, 0, 0
    tc = cases[0]
    skipped = 1 if tc.find("skipped") is not None else 0
    failure = 1 if tc.find("failure") is not None else 0
    error = 1 if tc.find("error") is not None else 0
    failed = max(failure, error)
    passed = 1 if not skipped and not failed else 0
    return 1, 1, 1, passed, failed, skipped


def _find_console_standalone(env: dict[str, str]) -> Path | None:
    gradle_home = Path(env.get("GRADLE_USER_HOME", "/root/.gradle"))
    base = gradle_home / "caches/modules-2/files-2.1/org.junit.platform/junit-platform-console-standalone"
    if not base.is_dir():
        return None
    jars = [
        p
        for p in base.rglob("junit-platform-console-standalone-*.jar")
        if "-sources" not in p.name and "-javadoc" not in p.name
    ]
    if not jars:
        return None
    return max(jars, key=lambda p: p.stat().st_mtime)


def _run_single_test(
    module: str,
    selector: str,
    classpath: str,
    reports_root: Path,
    env: dict[str, str],
) -> TestExecution:
    fqcn, method = _parse_selector(selector)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{fqcn}.{method}")
    report_dir = reports_root / module / safe
    if report_dir.exists():
        shutil.rmtree(report_dir)
    report_dir.mkdir(parents=True, exist_ok=True)

    run_env = dict(env)
    run_env["VERIFIER_TEST_CLASSPATH"] = classpath
    if env.get("VERIFIER_TEST_CLASSPATH_FILE"):
        run_env["VERIFIER_TEST_CLASSPATH_FILE"] = env["VERIFIER_TEST_CLASSPATH_FILE"]

    standalone = _find_console_standalone(env)
    launcher_cp = classpath
    if standalone is not None:
        launcher_cp = f"{standalone}{os.pathsep}{classpath}"
    launcher_cp_file = report_dir / "launcher-cp.txt"
    launcher_cp_file.write_text(launcher_cp, encoding="utf-8")
    cmd = [
        "java",
        "-cp",
        f"@{launcher_cp_file}",
        "org.junit.platform.console.ConsoleLauncher",
        f"--select-method={fqcn}#{method}",
        f"--reports-dir={report_dir}",
        "--disable-banner",
        "--details=tree",
    ]
    proc = subprocess.run(cmd, cwd=WORKSPACE, env=run_env, text=True, capture_output=True)
    if proc.returncode != 0 and (proc.stderr or proc.stdout):
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
    xml_files = sorted(report_dir.glob("**/TEST-*.xml"))
    if len(xml_files) != 1:
        return TestExecution(fqcn, method, module, 0, 0, 0, 0, 1, 0, 0)
    discovered, started, finished, passed, failed, skipped = _parse_launcher_report(xml_files[0])
    if proc.returncode != 0 and failed == 0 and passed == 0:
        failed = 1
    aborted = 1 if proc.returncode != 0 and passed == 0 and failed == 0 else 0
    return TestExecution(
        fqcn, method, module, discovered, started, finished, passed, failed, skipped, aborted
    )


def _scrub_workspace_xml() -> None:
    for path in WORKSPACE.glob("**/build/test-results"):
        shutil.rmtree(path, ignore_errors=True)


def _emit_results(
    token: str,
    executions: list[TestExecution],
    required_f2p: list[str],
    required_p2p: list[str],
) -> int:
    required = required_f2p + required_p2p
    by_name = {ex.grade_name: ex for ex in executions}

    print(f"VERIFIER_RUN_START token={token}")
    print("VERIFIER_SOURCE junit_platform_console_launcher")

    discovered = started = finished = passed = failed = skipped = aborted = 0
    for req in required:
        ex = by_name.get(req)
        if ex is None:
            print(f"TESTRESULT FAIL {req}")
            print(f"VERIFIER_DETAIL missing_execution {req}")
            continue
        discovered += ex.discovered
        started += ex.started
        finished += ex.finished
        passed += ex.passed
        failed += ex.failed
        skipped += ex.skipped
        aborted += ex.aborted
        status = "PASS" if ex.ok else "FAIL"
        print(f"TESTRESULT {status} {req}")
        if not ex.ok:
            print(
                f"VERIFIER_DETAIL counts {req} "
                f"discovered={ex.discovered} started={ex.started} finished={ex.finished} "
                f"passed={ex.passed} failed={ex.failed} skipped={ex.skipped} aborted={ex.aborted}"
            )

    print(
        "VERIFIER_EXECUTION_SUMMARY "
        f"discovered={discovered} started={started} finished={finished} "
        f"passed={passed} failed={failed} skipped={skipped} aborted={aborted} "
        f"required={len(required)}"
    )
    print(f"VERIFIER_RUN_COMPLETE token={token}")

    ok = (
        len(by_name) == len(required)
        and all(by_name[r].ok for r in required if r in by_name)
        and len(required) == len([r for r in required if r in by_name])
        and discovered == len(required)
        and started == len(required)
        and finished == len(required)
        and passed == len(required)
        and failed == 0
        and skipped == 0
        and aborted == 0
    )
    return 0 if ok else 1


def main() -> int:
    if not INIT_SCRIPT.is_file():
        print("ERROR: missing verifier init script", file=sys.stderr)
        return 2
    f2p, p2p = _load_required_from_config()

    configured = []
    for tests in MODULE_TESTS.values():
        for sel in tests:
            cls, method = _parse_selector(sel)
            configured.append(f"{cls}::{method}")
    required = f2p + p2p
    if sorted(configured) != sorted(required):
        print("ERROR: MODULE_TESTS drift from config.json", file=sys.stderr)
        return 2

    token = str(uuid.uuid4())
    reports_root = Path(tempfile.mkdtemp(prefix="verifier-junit-", dir="/tmp"))
    env = _gradle_env(reports_root)

    _scrub_workspace_xml()
    _scrub_test_outputs()
    _compile_modules(env)

    executions: list[TestExecution] = []
    for module, selectors in MODULE_TESTS.items():
        cp = _classpath(module, env)
        cp_file = reports_root / f"{module}-test-classpath.txt"
        cp_file.write_text(cp, encoding="utf-8")
        module_env = dict(env)
        module_env["VERIFIER_TEST_CLASSPATH_FILE"] = str(cp_file)
        for selector in selectors:
            executions.append(_run_single_test(module, selector, cp, reports_root, module_env))

    return _emit_results(token, executions, f2p, p2p)


if __name__ == "__main__":
    raise SystemExit(main())
RUN_JUNIT_VERIFIER_PY_EOF
chmod +x /tmp/run_junit_verifier.py

# Build the test command(s) from config (expands ${TEST_FILES}; language default
# from grading.parser.framework when execution.commands is empty).
python3 - <<'PY' > /tmp/run_tests.sh
import ast, json, shlex
cfg = json.load(open("/tests/config.json"))
execution = cfg.get("execution", {}) or {}

def parse_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, str) and value.strip():
        for p in (json.loads, ast.literal_eval):
            try:
                v = p(value)
                if isinstance(v, list):
                    return v
            except (json.JSONDecodeError, ValueError, SyntaxError, TypeError):
                continue
    return []

test_files = parse_list(execution.get("selected_test_files_to_run") or [])
commands = execution.get("commands", [])
if isinstance(commands, str):
    commands = [commands]
if not commands:
    fw = ((cfg.get("grading") or {}).get("parser") or {}).get("framework", "").lower()
    # Output MUST be parseable by grade.py: pytest -v (per-test lines),
    # jest/go JSON modes. `pytest -q` prints no per-test lines -> reward 0.
    if fw == "pytest":
        commands = ["python -m pytest -v ${TEST_FILES}"]
    elif fw == "jest":
        commands = ["npx jest --json ${TEST_FILES}"]
    elif fw == "go-test":
        commands = ["go test -json ./..."]
    else:
        raise SystemExit("No execution.commands configured and no framework default")

files_arg = " ".join(shlex.quote(str(x)) for x in test_files)
print("set -euo pipefail")
for cmd in commands:
    print(cmd.replace("${TEST_FILES}", files_arg))
PY
chmod +x /tmp/run_tests.sh

# Wrap with timeout(1) if available + configured.
TIMEOUT_SEC="$(python3 -c "import json;print((json.load(open('/tests/config.json')).get('execution') or {}).get('timeout_sec',''))" 2>/dev/null || true)"
RUNNER=(bash /tmp/run_tests.sh)
if [ -n "${TIMEOUT_SEC:-}" ] && command -v timeout >/dev/null 2>&1; then
  RUNNER=(timeout "${TIMEOUT_SEC}" bash /tmp/run_tests.sh)
fi

set +e
"${RUNNER[@]}" > "$STDOUT_LOG" 2> "$STDERR_LOG"
TEST_EXIT_CODE=$?
set -e

# Grade via the embedded grader (grade.py inlined at the marker below; written to
# /tmp at runtime and invoked with the same CLI it has always used).
cat > /tmp/grade.py <<'GRADE_PY_EOF'
#!/usr/bin/env python3
"""Compact SWE-bench/Harborized verifier — parser + evaluator (`grade.py`).

This is a **generic, task-agnostic** grader and the single source of grading
truth (see ``agents/difflection`` TEST_DESIGN.md). It is NOT shipped as its own
``tests/`` file: ``config_builder.assemble_test_sh`` embeds this file's source
into the self-contained ``test.sh`` at materialize time. It does NOT run the
tests — ``test.sh`` runs them + captures logs; this grader only parses those logs
against ``config.json``'s required-test lists and writes the reward.

Division of responsibility (compact = config.json + tests.patch + test.sh):
    config.json = declarative {execution, grading, artifacts} metadata (per-task)
    tests.patch = the eval tests, applied by test.sh at verify time (per-task)
    test.sh     = self-contained verifier (runs tests + this grader, embedded)

CLI (called by test.sh)::

    python3 /tests/grade.py \
      --config /tests/config.json \
      --stdout /logs/verifier/test-stdout.txt \
      --stderr /logs/verifier/test-stderr.txt \
      --raw-exit-code <int> \
      --output /logs/verifier/output.json \
      --report /logs/verifier/report.json \
      --reward /logs/verifier/reward.txt

Exit codes: 0 = success (reward 1), 1 = grading failure (reward 0),
2 = infrastructure/parser error (reward 0). reward.txt is ALWAYS written.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from typing import Any

# Normalized statuses; only exact PASSED counts as passed for grading.
PASSED, FAILED, ERROR, SKIPPED, UNKNOWN = (
    "PASSED",
    "FAILED",
    "ERROR",
    "SKIPPED",
    "UNKNOWN",
)


# ---------------------------------------------------------------------------
# Robust helpers
# ---------------------------------------------------------------------------
def parse_list(value: Any) -> list[str]:
    """Coerce a JSON array OR a string-encoded list into ``list[str]``.

    SWE-bench-style datasets often store list fields as strings, e.g.
    ``'["a", "b"]'`` or ``"['a', 'b']"``. All forms normalize to the same list.
    """
    if isinstance(value, list):
        return [str(x) for x in value]
    if isinstance(value, str):
        value = value.strip()
        if not value:
            return []
        for parser in (json.loads, ast.literal_eval):
            try:
                parsed = parser(value)
                if isinstance(parsed, list):
                    return [str(x) for x in parsed]
            except (json.JSONDecodeError, ValueError, SyntaxError, TypeError):
                continue
    return []


def normalize_name(name: str) -> str:
    """Backslash→slash, collapse duplicate slashes, strip leading ./ and space."""
    n = name.strip().replace("\\", "/")
    n = re.sub(r"/+", "/", n)
    if n.startswith("./"):
        n = n[2:]
    return n


def _read(path: str | None) -> str:
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# Framework parsers — text/JSON logs → [{name, status, raw_name, source}]
# ---------------------------------------------------------------------------
_PYTEST_RE = re.compile(
    r"^(?P<name>[\w./\-\[\]]+::[^\s]+)\s+(?P<status>PASSED|FAILED|ERROR|SKIPPED)",
    re.MULTILINE,
)
# unittest verbose: "test_name (module.TestClass) ... ok|FAIL|ERROR|skipped"
_UNITTEST_RE = re.compile(
    r"^(?P<test>\w+)\s+\((?P<cls>[\w.]+)\)\s+\.\.\.\s+"
    r"(?P<status>ok|FAIL|ERROR|skipped)",
    re.MULTILINE,
)
_STATUS_MAP = {
    "passed": PASSED,
    "pass": PASSED,
    "ok": PASSED,
    "failed": FAILED,
    "fail": FAILED,
    "error": ERROR,
    "skipped": SKIPPED,
    "skip": SKIPPED,
}


def _entry(name: str, status: str, source: str) -> dict[str, str]:
    return {
        "name": normalize_name(name),
        "status": status,
        "raw_name": name,
        "source": source,
    }


def parse_pytest(stdout: str, stderr: str) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for m in _PYTEST_RE.finditer(stdout + "\n" + stderr):
        out.append(_entry(m.group("name"), m.group("status").upper(), "pytest"))
    return out


def parse_unittest(stdout: str, stderr: str) -> list[dict[str, str]]:
    # unittest writes verbose results to stderr by default.
    out: list[dict[str, str]] = []
    for m in _UNITTEST_RE.finditer(stdout + "\n" + stderr):
        status = _STATUS_MAP.get(m.group("status").lower(), UNKNOWN)
        out.append(_entry(f"{m.group('cls')}.{m.group('test')}", status, "unittest"))
    return out


def _find_json(text: str) -> Any:
    """Best-effort: parse the largest JSON object/array embedded in *text*."""
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end > start:
        try:
            return json.loads(text[start : end + 1])
        except Exception:
            return None
    return None


def parse_jest(stdout: str, stderr: str) -> list[dict[str, str]]:
    data = _find_json(stdout) or _find_json(stderr)
    out: list[dict[str, str]] = []
    if not isinstance(data, dict):
        return out
    for suite in data.get("testResults", []):
        for a in suite.get("assertionResults", []):
            status = _STATUS_MAP.get(str(a.get("status", "")).lower(), UNKNOWN)
            title = a.get("fullName") or a.get("title") or ""
            out.append(_entry(title, status, "jest"))
    return out


def parse_mocha(stdout: str, stderr: str) -> list[dict[str, str]]:
    data = _find_json(stdout) or _find_json(stderr)
    out: list[dict[str, str]] = []
    if not isinstance(data, dict):
        return out
    for key, status in (("passes", PASSED), ("failures", FAILED), ("pending", SKIPPED)):
        for t in data.get(key, []):
            title = t.get("fullTitle") or t.get("title") or ""
            out.append(_entry(title, status, "mocha"))
    return out


def parse_go_test(stdout: str, stderr: str) -> list[dict[str, str]]:
    # `go test -json` emits one JSON object per line with Action/Test/Package.
    out: list[dict[str, str]] = []
    for line in (stdout + "\n" + stderr).splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        test = ev.get("Test")
        action = ev.get("Action")
        if not test or action not in ("pass", "fail", "skip"):
            continue
        status = {"pass": PASSED, "fail": FAILED, "skip": SKIPPED}[action]
        out.append(_entry(f"{ev.get('Package', '')}::{test}", status, "go-test"))
    return out


def parse_custom(stdout: str, stderr: str, parser_cfg: dict) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    text = stdout + "\n" + stderr
    start = text.find("VERIFIER_RUN_START")
    end = text.find("VERIFIER_RUN_COMPLETE")
    if start == -1 or end == -1 or end < start:
        return out
    text = text[start:end]
    pass_re = parser_cfg.get("pass_regex")
    fail_re = parser_cfg.get("fail_regex")
    for rx, status in ((pass_re, PASSED), (fail_re, FAILED)):
        if not rx:
            continue
        for m in re.finditer(rx, text, re.MULTILINE):
            name = m.groupdict().get("name") or (m.group(1) if m.groups() else "")
            if name:
                out.append(_entry(name, status, "custom"))
    return out


def _parse_verifier_summary(text: str) -> dict[str, int] | None:
    m = re.search(
        r"VERIFIER_EXECUTION_SUMMARY "
        r"discovered=(\d+) started=(\d+) finished=(\d+) passed=(\d+) "
        r"failed=(\d+) skipped=(\d+) aborted=(\d+) required=(\d+)",
        text,
    )
    if not m:
        return None
    keys = (
        "discovered",
        "started",
        "finished",
        "passed",
        "failed",
        "skipped",
        "aborted",
        "required",
    )
    return {k: int(m.group(i + 1)) for i, k in enumerate(keys)}


def _verifier_window_ok(text: str) -> bool:
    return (
        "VERIFIER_RUN_START" in text
        and "VERIFIER_RUN_COMPLETE" in text
        and "VERIFIER_SOURCE junit_platform_console_launcher" in text
    )


_PARSERS = {
    "pytest": parse_pytest,
    "unittest": parse_unittest,
    "jest": parse_jest,
    "mocha": parse_mocha,
    "go-test": parse_go_test,
}


def parse_results(
    framework: str, stdout: str, stderr: str, parser_cfg: dict
) -> list[dict[str, str]]:
    if framework == "custom":
        return parse_custom(stdout, stderr, parser_cfg)
    fn = _PARSERS.get(framework)
    return fn(stdout, stderr) if fn else []


# ---------------------------------------------------------------------------
# Matching: required name → parsed result (controlled, no broad fuzzy match)
# ---------------------------------------------------------------------------
def matched_passed(required: str, results: list[dict[str, str]]) -> bool:
    """True iff *required* maps to a parsed test whose status is exactly PASSED."""
    req = normalize_name(required)
    by_name: dict[str, str] = {}
    for r in results:
        # Last status wins; an exact PASSED is what we ultimately check.
        by_name[r["name"]] = r["status"]
    # 1) exact / whitespace / path-normalized (all folded into normalize_name).
    if req in by_name:
        return by_name[req] == PASSED
    # 2) unambiguous suffix match only.
    suffix_hits = [
        name
        for name in by_name
        if name.endswith("/" + req) or name.endswith("::" + req.split("::")[-1])
    ]
    if len(set(suffix_hits)) == 1:
        return by_name[suffix_hits[0]] == PASSED
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def _write(path: str, content: str) -> None:
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
    except OSError as exc:  # pragma: no cover - disk failure
        sys.stderr.write(f"grade.py: could not write {path}: {exc}\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Compact verifier grader")
    ap.add_argument("--config", required=True)
    ap.add_argument("--stdout", default="")
    ap.add_argument("--stderr", default="")
    ap.add_argument("--raw-exit-code", type=int, default=0)
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--reward", required=True)
    args = ap.parse_args(argv)

    def finish(reward: float, report: dict, exit_code: int) -> int:
        report.setdefault("reward", reward)
        _write(args.output, json.dumps({"tests": report.pop("_tests", [])}, indent=2))
        _write(args.report, json.dumps(report, indent=2))
        _write(args.reward, f"{1 if reward >= 1.0 else 0}\n")
        return exit_code

    # --- load config (infra error if unreadable) ---
    try:
        with open(args.config, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return finish(
            0.0,
            {
                "success": False,
                "infrastructure_error": f"could not read config.json: {exc}",
                "raw_exit_code": args.raw_exit_code,
            },
            2,
        )

    instance_id = (cfg.get("instance") or {}).get("instance_id", "")
    grading = cfg.get("grading") or {}
    parser_cfg = grading.get("parser") or {}
    framework = (parser_cfg.get("framework") or "").lower()

    # --- required tests: required_pass, else fail_to_pass ∪ pass_to_pass ---
    f2p = parse_list(grading.get("fail_to_pass"))
    p2p = parse_list(grading.get("pass_to_pass"))
    required_explicit = parse_list(grading.get("required_pass"))
    required = required_explicit if required_explicit else [*f2p, *p2p]
    # De-dup, preserve order.
    seen: set[str] = set()
    required = [r for r in required if not (r in seen or seen.add(r))]

    stdout, stderr = _read(args.stdout), _read(args.stderr)
    combined = stdout + "\n" + stderr
    results = parse_results(framework, stdout, stderr, parser_cfg)
    summary = _parse_verifier_summary(combined)
    verifier_ok = _verifier_window_ok(combined)

    base_report: dict[str, Any] = {
        "instance_id": instance_id,
        "raw_exit_code": args.raw_exit_code,
        "parser_framework": framework or "unknown",
        "infrastructure_error": None,
        "verifier_window_ok": verifier_ok,
        "verifier_execution_summary": summary,
        "_tests": results,
    }

    # Fail closed when no required tests are configured.
    if not required:
        return finish(
            0.0,
            {
                **base_report,
                "success": False,
                "infrastructure_error": "no required tests configured",
                "required_tests_count": 0,
                "passed_tests_count": 0,
                "required_tests": [],
                "passed_required_tests": [],
                "missing_required_tests": [],
                "unexpected_failures": [],
            },
            2,
        )

    passed_required = [r for r in required if matched_passed(r, results)]
    missing_required = [r for r in required if r not in passed_required]

    allow_extra = bool(grading.get("allow_extra_failures", True))
    unexpected: list[str] = []
    if not allow_extra:
        req_norm = {normalize_name(r) for r in required}
        unexpected = [
            r["name"]
            for r in results
            if r["status"] in (FAILED, ERROR) and r["name"] not in req_norm
        ]

    summary_ok = (
        summary is not None
        and summary.get("discovered") == len(required)
        and summary.get("started") == len(required)
        and summary.get("finished") == len(required)
        and summary.get("passed") == len(required)
        and summary.get("failed") == 0
        and summary.get("skipped") == 0
        and summary.get("aborted") == 0
        and summary.get("required") == len(required)
    )

    success = (
        args.raw_exit_code == 0
        and verifier_ok
        and summary_ok
        and not missing_required
        and not unexpected
    )
    reward = 1.0 if success else 0.0
    return finish(
        reward,
        {
            **base_report,
            "success": success,
            "raw_exit_code": args.raw_exit_code,
            "test_runner_exit_ok": args.raw_exit_code == 0,
            "required_tests_count": len(required),
            "passed_tests_count": len(passed_required),
            "required_tests": required,
            "passed_required_tests": passed_required,
            "missing_required_tests": missing_required,
            "unexpected_failures": unexpected,
        },
        0 if success else 1,
    )


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())

GRADE_PY_EOF

python3 /tmp/grade.py \
  --config "$CONFIG" \
  --stdout "$STDOUT_LOG" \
  --stderr "$STDERR_LOG" \
  --raw-exit-code "$TEST_EXIT_CODE" \
  --output "$OUTPUT" \
  --report "$REPORT" \
  --reward "$REWARD"
GRADE_EXIT_CODE=$?

write_zero_reward_if_missing
exit "$GRADE_EXIT_CODE"
