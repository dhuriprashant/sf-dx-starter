#!/usr/bin/env python3
"""
apex_test_finder.py
-------------------
Find all Salesforce Apex test classes that cover a given Apex class.

Two modes:
  1. --static   Offline static analysis — scans local source files for references.
  2. --org      Live query — uses the Salesforce Tooling API via `sf` CLI for
                coverage data produced by actual test runs.
  3. (default)  Both modes, results merged and de-duplicated.

Usage
-----
  python apex_test_finder.py MyApexClass
  python apex_test_finder.py MyApexClass --static
  python apex_test_finder.py MyApexClass --org
  python apex_test_finder.py MyApexClass --project-dir ./force-app
  python apex_test_finder.py MyApexClass --org --target-org myAlias
  python apex_test_finder.py MyApexClass --json
"""

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class TestClassResult:
    name: str
    source: str                      # "static" | "org"
    file_path: Optional[str] = None  # local path (static only)
    lines_covered: Optional[int] = None   # org only
    lines_uncovered: Optional[int] = None # org only
    coverage_pct: Optional[float] = None  # org only

    def coverage_label(self) -> str:
        if self.coverage_pct is not None:
            return f"{self.coverage_pct:.1f}%"
        return "n/a"


# ---------------------------------------------------------------------------
# Static analysis
# ---------------------------------------------------------------------------

# Patterns that indicate a test class
_ISTEST_RE = re.compile(r'@isTest', re.IGNORECASE)
_TEST_METHOD_RE = re.compile(r'\btestMethod\b', re.IGNORECASE)

def _is_test_class(content: str) -> bool:
    return bool(_ISTEST_RE.search(content) or _TEST_METHOD_RE.search(content))


def _references_class(content: str, class_name: str) -> bool:
    """
    Return True if the file content contains a meaningful reference to
    class_name.  We look for:
      - Direct instantiation:  new ClassName(
      - Static call:            ClassName.someMethod(
      - Type declaration:       ClassName varName
      - Cast:                   (ClassName)
      - SObject DML:            insert new ClassName(
    A simple word-boundary match covers all these cases without needing a
    full parser, while avoiding false positives from substrings.
    """
    pattern = re.compile(r'\b' + re.escape(class_name) + r'\b', re.IGNORECASE)
    return bool(pattern.search(content))


def find_by_static_analysis(
    class_name: str,
    project_dir: Path,
) -> list[TestClassResult]:
    """
    Walk the project directory, collect all .cls files marked @isTest that
    reference class_name.
    """
    results: list[TestClassResult] = []

    cls_files = list(project_dir.rglob("*.cls"))
    if not cls_files:
        print(f"[static] No .cls files found under {project_dir}", file=sys.stderr)
        return results

    for cls_file in cls_files:
        try:
            content = cls_file.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"[static] Could not read {cls_file}: {exc}", file=sys.stderr)
            continue

        if not _is_test_class(content):
            continue

        # Skip the class itself if it somehow carries @isTest
        stem = cls_file.stem
        if stem.lower() == class_name.lower():
            continue

        if _references_class(content, class_name):
            results.append(
                TestClassResult(
                    name=stem,
                    source="static",
                    file_path=str(cls_file),
                )
            )

    return results


# ---------------------------------------------------------------------------
# Org query via Salesforce CLI
# ---------------------------------------------------------------------------

def _run_sf(args: list[str], target_org: Optional[str], exit_on_error: bool = True) -> dict:
    """Run `sf <args> --json` and return parsed JSON output."""
    cmd = ["sf"] + args + ["--json"]
    if target_org:
        cmd += ["--target-org", target_org]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,
            shell=(sys.platform == "win32"),
        )
    except FileNotFoundError:
        sys.exit(
            "[org] ERROR: `sf` CLI not found. Install Salesforce CLI: "
            "https://developer.salesforce.com/tools/salesforcecli"
        )
    except subprocess.TimeoutExpired:
        sys.exit("[org] ERROR: sf CLI timed out after 300 s.")

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.exit(
            f"[org] ERROR: Could not parse sf output.\n"
            f"STDOUT: {proc.stdout[:500]}\nSTDERR: {proc.stderr[:500]}"
        )

    if exit_on_error and data.get("status", 0) != 0:
        msg = data.get("message") or proc.stderr or "unknown error"
        sys.exit(f"[org] ERROR from sf CLI: {msg}")

    return data


def run_tests_in_org(
    test_class_names: list[str],
    target_org: Optional[str],
) -> None:
    """Run the given test classes synchronously in the org to populate coverage data."""
    print(
        f"[org]    Running {len(test_class_names)} test class(es) to generate coverage: "
        f"{', '.join(test_class_names)}",
        file=sys.stderr,
    )

    args = ["apex", "test", "run", "--wait", "10", "--code-coverage"]
    for name in test_class_names:
        args += ["--class-names", name]

    # exit_on_error=False: some tests may fail but coverage is still recorded
    data = _run_sf(args, target_org, exit_on_error=False)

    summary = data.get("result", {}).get("summary", {})
    passed = summary.get("passing", 0) or 0
    failed = summary.get("failing", 0) or 0
    print(f"[org]    Test run complete — {passed} passed, {failed} failed.", file=sys.stderr)


def find_by_org_coverage(
    class_name: str,
    target_org: Optional[str],
) -> list[TestClassResult]:
    """
    Query ApexCodeCoverageAggregate via the Tooling API to find test classes
    that produced coverage for class_name.
    """
    soql = (
        "SELECT ApexTestClass.Name, NumLinesCovered, NumLinesUncovered "
        "FROM ApexCodeCoverage "
        f"WHERE ApexClassOrTrigger.Name = '{class_name}'"
    )

    print(f"[org]    Querying Tooling API for coverage of '{class_name}'…", file=sys.stderr)

    data = _run_sf(
        ["data", "query", "--query", soql, "--use-tooling-api"],
        target_org,
    )

    records = data.get("result", {}).get("records", [])
    if not records:
        print(
            f"[org]    No coverage records found. Have tests been run in this org?",
            file=sys.stderr,
        )
        return []

    # Aggregate per-method rows into one entry per test class
    totals: dict[str, list[int]] = {}  # name -> [covered, uncovered]
    for rec in records:
        test_class = rec.get("ApexTestClass") or {}
        name = test_class.get("Name", "<unknown>")
        covered = rec.get("NumLinesCovered", 0) or 0
        uncovered = rec.get("NumLinesUncovered", 0) or 0
        if name in totals:
            totals[name][0] += covered
            totals[name][1] += uncovered
        else:
            totals[name] = [covered, uncovered]

    results: list[TestClassResult] = []
    for name, (covered, uncovered) in totals.items():
        total = covered + uncovered
        pct = (covered / total * 100) if total > 0 else 0.0
        results.append(
            TestClassResult(
                name=name,
                source="org",
                lines_covered=covered,
                lines_uncovered=uncovered,
                coverage_pct=pct,
            )
        )

    return results


# ---------------------------------------------------------------------------
# Merge & output
# ---------------------------------------------------------------------------

def merge_results(
    static: list[TestClassResult],
    org: list[TestClassResult],
) -> list[TestClassResult]:
    """
    Combine results from both sources. Where both found the same class,
    keep the org record (has coverage numbers) and annotate source as "both".
    """
    org_names = {r.name.lower(): r for r in org}
    merged: list[TestClassResult] = []

    seen: set[str] = set()

    for r in org:
        key = r.name.lower()
        seen.add(key)
        # Check if static analysis also found it
        for s in static:
            if s.name.lower() == key:
                r.source = "both"
                r.file_path = s.file_path
                break
        merged.append(r)

    for r in static:
        if r.name.lower() not in seen:
            merged.append(r)

    merged.sort(key=lambda x: x.name.lower())
    return merged


def print_table(class_name: str, results: list[TestClassResult]) -> None:
    if not results:
        print(f"\nNo test classes found that cover '{class_name}'.\n")
        return

    col_name  = max(len(r.name) for r in results)
    col_name  = max(col_name, len("Test Class"))
    col_src   = max(len(r.source) for r in results)
    col_src   = max(col_src, len("Source"))
    col_cov   = len("Coverage")
    col_path  = max((len(r.file_path or "") for r in results), default=0)
    col_path  = max(col_path, len("File"))

    sep = (
        f"+{'-'*(col_name+2)}+{'-'*(col_src+2)}+"
        f"{'-'*(col_cov+2)}+{'-'*(col_path+2)}+"
    )
    header = (
        f"| {'Test Class':<{col_name}} | {'Source':<{col_src}} | "
        f"{'Coverage':^{col_cov}} | {'File':<{col_path}} |"
    )

    print(f"\nTest classes covering '{class_name}' ({len(results)} found):\n")
    print(sep)
    print(header)
    print(sep)
    for r in results:
        print(
            f"| {r.name:<{col_name}} | {r.source:<{col_src}} | "
            f"{r.coverage_label():^{col_cov}} | {(r.file_path or ''):<{col_path}} |"
        )
    print(sep)
    print()


def print_json(class_name: str, results: list[TestClassResult]) -> None:
    output = {
        "targetClass": class_name,
        "count": len(results),
        "testClasses": [
            {
                "name": r.name,
                "source": r.source,
                "filePath": r.file_path,
                "linesCovered": r.lines_covered,
                "linesUncovered": r.lines_uncovered,
                "coveragePct": r.coverage_pct,
            }
            for r in results
        ],
    }
    print(json.dumps(output, indent=2))


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="apex_test_finder",
        description="Find Apex test classes that cover a given Apex class.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("class_name", help="The Apex class to find test coverage for.")

    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--static",
        action="store_true",
        help="Only use static source analysis (no org required).",
    )
    mode.add_argument(
        "--org",
        action="store_true",
        help="Only query the Salesforce org for coverage data.",
    )

    p.add_argument(
        "--project-dir",
        default=".",
        metavar="DIR",
        help="Root of the SFDX project to scan. Default: current directory.",
    )
    p.add_argument(
        "--target-org",
        metavar="ALIAS",
        help="Salesforce org alias or username for --org queries.",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON.",
    )
    return p


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    class_name: str = args.class_name
    project_dir: Path = Path(args.project_dir).resolve()
    use_static: bool = args.static or not args.org
    use_org: bool = args.org or not args.static

    static_results: list[TestClassResult] = []
    org_results: list[TestClassResult] = []

    if use_static:
        print(f"[static] Scanning '{project_dir}' for test classes referencing '{class_name}'…", file=sys.stderr)
        static_results = find_by_static_analysis(class_name, project_dir)
        print(f"[static] Found {len(static_results)} candidate(s).", file=sys.stderr)

    if use_org:
        org_results = find_by_org_coverage(class_name, args.target_org)
        print(f"[org]    Found {len(org_results)} coverage record(s).", file=sys.stderr)

        if not org_results:
            # No stored coverage — find test candidates via static analysis and run them
            candidates = static_results or find_by_static_analysis(class_name, project_dir)
            if candidates:
                run_tests_in_org([r.name for r in candidates], args.target_org)
                org_results = find_by_org_coverage(class_name, args.target_org)
                print(f"[org]    Found {len(org_results)} coverage record(s) after test run.", file=sys.stderr)
            else:
                print(
                    "[org]    No test candidates found by static analysis — cannot auto-run tests.",
                    file=sys.stderr,
                )

    if use_static and use_org:
        results = merge_results(static_results, org_results)
    elif use_org:
        results = sorted(org_results, key=lambda x: x.name.lower())
    else:
        results = sorted(static_results, key=lambda x: x.name.lower())

    if args.json:
        print_json(class_name, results)
    else:
        print_table(class_name, results)


if __name__ == "__main__":
    main()
