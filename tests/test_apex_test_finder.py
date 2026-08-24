"""Unit tests for apex_test_finder.py."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import apex_test_finder as atf  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def write_cls(directory: Path, name: str, body: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{name}.cls"
    path.write_text(body, encoding="utf-8")
    return path


class FakeProc:
    def __init__(self, stdout="", stderr=""):
        self.stdout = stdout
        self.stderr = stderr


def sf_stub(payload, capture=None, stderr=""):
    """Build a subprocess.run replacement returning `payload` as JSON."""

    def _run(cmd, **kwargs):
        if capture is not None:
            capture.append((cmd, kwargs))
        text = payload if isinstance(payload, str) else json.dumps(payload)
        return FakeProc(stdout=text, stderr=stderr)

    return _run


# ---------------------------------------------------------------------------
# TestClassResult
# ---------------------------------------------------------------------------


def test_coverage_label_formats_percentage_to_one_decimal():
    result = atf.TestClassResult(name="A", source="org", coverage_pct=87.65)
    assert result.coverage_label() == "87.7%"


def test_coverage_label_is_na_without_percentage():
    assert atf.TestClassResult(name="A", source="static").coverage_label() == "n/a"


def test_coverage_label_handles_zero_percent():
    result = atf.TestClassResult(name="A", source="org", coverage_pct=0.0)
    assert result.coverage_label() == "0.0%"


# ---------------------------------------------------------------------------
# _is_test_class / _references_class
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "content",
    [
        "@isTest\npublic class Foo {}",
        "@ISTEST public class Foo {}",
        "public class Foo { static testMethod void t() {} }",
        "public class Foo { static TESTMETHOD void t() {} }",
    ],
)
def test_is_test_class_detects_test_markers(content):
    assert atf._is_test_class(content) is True


@pytest.mark.parametrize(
    "content",
    [
        "public class Foo {}",
        "// isTesting helper without annotation",
        "",
    ],
)
def test_is_test_class_rejects_non_test_content(content):
    assert atf._is_test_class(content) is False


@pytest.mark.parametrize(
    "content",
    [
        "AccountService s = new AccountService();",
        "AccountService.doWork();",
        "Object o = (AccountService) raw;",
        "accountservice.doWork();",
    ],
)
def test_references_class_matches_usages(content):
    assert atf._references_class(content, "AccountService") is True


@pytest.mark.parametrize(
    "content",
    [
        "MyAccountServiceHelper.doWork();",
        "AccountServiceExtra s;",
        "OtherClass.doWork();",
    ],
)
def test_references_class_ignores_substring_matches(content):
    assert atf._references_class(content, "AccountService") is False


def test_references_class_escapes_regex_metacharacters():
    assert atf._references_class("a.b.c", "a.b") is True
    assert atf._references_class("axb", "a.b") is False


# ---------------------------------------------------------------------------
# find_by_static_analysis
# ---------------------------------------------------------------------------


def test_find_by_static_analysis_returns_referencing_test_classes(tmp_path):
    classes = tmp_path / "force-app" / "main" / "default" / "classes"
    write_cls(classes, "AccountService", "public class AccountService {}")
    write_cls(
        classes,
        "AccountServiceTest",
        "@isTest\nprivate class AccountServiceTest { AccountService s; }",
    )
    write_cls(
        classes,
        "UnrelatedTest",
        "@isTest\nprivate class UnrelatedTest { ContactService s; }",
    )

    results = atf.find_by_static_analysis("AccountService", tmp_path)

    assert [r.name for r in results] == ["AccountServiceTest"]
    assert results[0].source == "static"
    assert results[0].file_path.endswith("AccountServiceTest.cls")


def test_find_by_static_analysis_skips_target_class_even_when_marked_istest(tmp_path):
    classes = tmp_path / "classes"
    write_cls(classes, "AccountService", "@isTest\npublic class AccountService {}")

    assert atf.find_by_static_analysis("accountservice", tmp_path) == []


def test_find_by_static_analysis_warns_when_no_cls_files(tmp_path, capsys):
    assert atf.find_by_static_analysis("AccountService", tmp_path) == []
    assert "No .cls files found" in capsys.readouterr().err


def test_find_by_static_analysis_reports_unreadable_files(tmp_path, capsys, monkeypatch):
    classes = tmp_path / "classes"
    write_cls(classes, "BrokenTest", "@isTest private class BrokenTest {}")

    def boom(*_args, **_kwargs):
        raise OSError("permission denied")

    monkeypatch.setattr(Path, "read_text", boom)

    assert atf.find_by_static_analysis("AccountService", tmp_path) == []
    assert "Could not read" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# _run_sf
# ---------------------------------------------------------------------------


def test_run_sf_builds_command_with_json_and_target_org(monkeypatch):
    calls = []
    monkeypatch.setattr(
        subprocess, "run", sf_stub({"status": 0, "result": {"ok": True}}, calls)
    )

    data = atf._run_sf(["data", "query"], "myAlias")

    assert data["result"] == {"ok": True}
    assert calls[0][0] == ["sf", "data", "query", "--json", "--target-org", "myAlias"]


def test_run_sf_omits_target_org_when_not_provided(monkeypatch):
    calls = []
    monkeypatch.setattr(subprocess, "run", sf_stub({"status": 0}, calls))

    atf._run_sf(["apex", "test", "run"], None)

    assert calls[0][0] == ["sf", "apex", "test", "run", "--json"]


def test_run_sf_exits_when_cli_missing(monkeypatch):
    def missing(*_args, **_kwargs):
        raise FileNotFoundError

    monkeypatch.setattr(subprocess, "run", missing)

    with pytest.raises(SystemExit) as exc:
        atf._run_sf(["org", "list"], None)
    assert "`sf` CLI not found" in str(exc.value)


def test_run_sf_exits_on_timeout(monkeypatch):
    def timeout(*_args, **_kwargs):
        raise subprocess.TimeoutExpired(cmd="sf", timeout=300)

    monkeypatch.setattr(subprocess, "run", timeout)

    with pytest.raises(SystemExit) as exc:
        atf._run_sf(["org", "list"], None)
    assert "timed out" in str(exc.value)


def test_run_sf_exits_on_unparseable_output(monkeypatch):
    monkeypatch.setattr(subprocess, "run", sf_stub("not json", stderr="boom"))

    with pytest.raises(SystemExit) as exc:
        atf._run_sf(["org", "list"], None)
    assert "Could not parse sf output" in str(exc.value)


def test_run_sf_exits_on_error_status(monkeypatch):
    monkeypatch.setattr(subprocess, "run", sf_stub({"status": 1, "message": "no org"}))

    with pytest.raises(SystemExit) as exc:
        atf._run_sf(["org", "list"], None)
    assert "no org" in str(exc.value)


def test_run_sf_tolerates_error_status_when_exit_on_error_false(monkeypatch):
    monkeypatch.setattr(subprocess, "run", sf_stub({"status": 1, "message": "failed"}))

    assert atf._run_sf(["org", "list"], None, exit_on_error=False)["status"] == 1


# ---------------------------------------------------------------------------
# run_tests_in_org
# ---------------------------------------------------------------------------


def test_run_tests_in_org_passes_each_class_name(monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(
        subprocess,
        "run",
        sf_stub({"status": 0, "result": {"summary": {"passing": 3, "failing": 1}}}, calls),
    )

    atf.run_tests_in_org(["ATest", "BTest"], "myAlias")

    cmd = calls[0][0]
    assert cmd[:7] == ["sf", "apex", "test", "run", "--wait", "10", "--code-coverage"]
    assert cmd.count("--class-names") == 2
    assert "ATest" in cmd and "BTest" in cmd
    assert "3 passed, 1 failed" in capsys.readouterr().err


def test_run_tests_in_org_defaults_missing_summary_counts(monkeypatch, capsys):
    monkeypatch.setattr(subprocess, "run", sf_stub({"status": 0, "result": {}}))

    atf.run_tests_in_org(["ATest"], None)

    assert "0 passed, 0 failed" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# find_by_org_coverage
# ---------------------------------------------------------------------------


def test_find_by_org_coverage_aggregates_rows_per_test_class(monkeypatch):
    calls = []
    payload = {
        "status": 0,
        "result": {
            "records": [
                {
                    "ApexTestClass": {"Name": "AccountServiceTest"},
                    "NumLinesCovered": 8,
                    "NumLinesUncovered": 2,
                },
                {
                    "ApexTestClass": {"Name": "AccountServiceTest"},
                    "NumLinesCovered": 2,
                    "NumLinesUncovered": 0,
                },
                {
                    "ApexTestClass": None,
                    "NumLinesCovered": None,
                    "NumLinesUncovered": None,
                },
            ]
        },
    }
    monkeypatch.setattr(subprocess, "run", sf_stub(payload, calls))

    results = {r.name: r for r in atf.find_by_org_coverage("AccountService", "alias")}

    aggregated = results["AccountServiceTest"]
    assert (aggregated.lines_covered, aggregated.lines_uncovered) == (10, 2)
    assert aggregated.coverage_pct == pytest.approx(83.3333, rel=1e-3)
    assert aggregated.source == "org"

    unknown = results["<unknown>"]
    assert (unknown.lines_covered, unknown.lines_uncovered) == (0, 0)
    assert unknown.coverage_pct == 0.0

    cmd = calls[0][0]
    assert "--use-tooling-api" in cmd
    assert "ApexClassOrTrigger.Name = 'AccountService'" in cmd[cmd.index("--query") + 1]


def test_find_by_org_coverage_returns_empty_when_no_records(monkeypatch, capsys):
    monkeypatch.setattr(
        subprocess, "run", sf_stub({"status": 0, "result": {"records": []}})
    )

    assert atf.find_by_org_coverage("AccountService", None) == []
    assert "No coverage records found" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# merge_results
# ---------------------------------------------------------------------------


def test_merge_results_marks_classes_found_by_both_sources():
    static = [
        atf.TestClassResult(name="AccountServiceTest", source="static", file_path="/a.cls"),
        atf.TestClassResult(name="StaticOnlyTest", source="static", file_path="/b.cls"),
    ]
    org = [
        atf.TestClassResult(
            name="accountservicetest", source="org", coverage_pct=90.0
        ),
        atf.TestClassResult(name="OrgOnlyTest", source="org", coverage_pct=50.0),
    ]

    merged = atf.merge_results(static, org)

    assert [r.name for r in merged] == [
        "accountservicetest",
        "OrgOnlyTest",
        "StaticOnlyTest",
    ]
    both = merged[0]
    assert both.source == "both"
    assert both.file_path == "/a.cls"
    assert merged[1].source == "org"
    assert merged[2].source == "static"


def test_merge_results_handles_empty_inputs():
    assert atf.merge_results([], []) == []


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def test_print_table_renders_rows(capsys):
    results = [
        atf.TestClassResult(
            name="AccountServiceTest",
            source="both",
            file_path="/classes/AccountServiceTest.cls",
            coverage_pct=75.0,
        ),
        atf.TestClassResult(name="StaticOnlyTest", source="static"),
    ]

    atf.print_table("AccountService", results)

    out = capsys.readouterr().out
    assert "Test classes covering 'AccountService' (2 found):" in out
    assert "AccountServiceTest" in out
    assert "75.0%" in out
    assert "n/a" in out


def test_print_table_reports_no_results(capsys):
    atf.print_table("AccountService", [])
    assert "No test classes found that cover 'AccountService'." in capsys.readouterr().out


def test_print_json_emits_full_records(capsys):
    results = [
        atf.TestClassResult(
            name="AccountServiceTest",
            source="org",
            lines_covered=9,
            lines_uncovered=1,
            coverage_pct=90.0,
        )
    ]

    atf.print_json("AccountService", results)

    payload = json.loads(capsys.readouterr().out)
    assert payload == {
        "targetClass": "AccountService",
        "count": 1,
        "testClasses": [
            {
                "name": "AccountServiceTest",
                "source": "org",
                "filePath": None,
                "linesCovered": 9,
                "linesUncovered": 1,
                "coveragePct": 90.0,
            }
        ],
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def test_build_parser_defaults():
    args = atf.build_parser().parse_args(["MyClass"])
    assert (args.class_name, args.project_dir) == ("MyClass", ".")
    assert not args.static and not args.org and not args.json
    assert args.target_org is None


def test_build_parser_rejects_static_and_org_together():
    with pytest.raises(SystemExit):
        atf.build_parser().parse_args(["MyClass", "--static", "--org"])


def test_main_static_only_prints_table(monkeypatch, capsys, tmp_path):
    static_hit = atf.TestClassResult(
        name="AccountServiceTest", source="static", file_path="/a.cls"
    )
    monkeypatch.setattr(atf, "find_by_static_analysis", lambda *_a: [static_hit])

    def fail(*_a, **_k):
        raise AssertionError("org path must not run in --static mode")

    monkeypatch.setattr(atf, "find_by_org_coverage", fail)
    monkeypatch.setattr(
        sys,
        "argv",
        ["apex_test_finder", "AccountService", "--static", "--project-dir", str(tmp_path)],
    )

    atf.main()

    assert "AccountServiceTest" in capsys.readouterr().out


def test_main_org_only_outputs_json(monkeypatch, capsys):
    org_hit = atf.TestClassResult(name="OrgTest", source="org", coverage_pct=100.0)
    monkeypatch.setattr(atf, "find_by_org_coverage", lambda *_a: [org_hit])
    monkeypatch.setattr(sys, "argv", ["apex_test_finder", "MyClass", "--org", "--json"])

    atf.main()

    payload = json.loads(capsys.readouterr().out)
    assert payload["count"] == 1
    assert payload["testClasses"][0]["name"] == "OrgTest"


def test_main_default_mode_merges_and_runs_tests_when_org_has_no_coverage(
    monkeypatch, capsys
):
    static_hit = atf.TestClassResult(
        name="AccountServiceTest", source="static", file_path="/a.cls"
    )
    org_hit = atf.TestClassResult(
        name="AccountServiceTest", source="org", coverage_pct=42.0
    )
    coverage_calls = []
    ran = []

    def fake_coverage(class_name, target_org):
        coverage_calls.append((class_name, target_org))
        return [] if len(coverage_calls) == 1 else [org_hit]

    monkeypatch.setattr(atf, "find_by_static_analysis", lambda *_a: [static_hit])
    monkeypatch.setattr(atf, "find_by_org_coverage", fake_coverage)
    monkeypatch.setattr(atf, "run_tests_in_org", lambda names, org: ran.append((names, org)))
    monkeypatch.setattr(sys, "argv", ["apex_test_finder", "AccountService"])

    atf.main()

    assert ran == [(["AccountServiceTest"], None)]
    assert len(coverage_calls) == 2
    out = capsys.readouterr().out
    assert "both" in out
    assert "42.0%" in out


def test_main_org_mode_reports_when_no_static_candidates(monkeypatch, capsys):
    monkeypatch.setattr(atf, "find_by_static_analysis", lambda *_a: [])
    monkeypatch.setattr(atf, "find_by_org_coverage", lambda *_a: [])

    def fail(*_a, **_k):
        raise AssertionError("no candidates: tests must not be run")

    monkeypatch.setattr(atf, "run_tests_in_org", fail)
    monkeypatch.setattr(sys, "argv", ["apex_test_finder", "MyClass", "--org"])

    atf.main()

    captured = capsys.readouterr()
    assert "No test candidates found by static analysis" in captured.err
    assert "No test classes found that cover 'MyClass'." in captured.out
