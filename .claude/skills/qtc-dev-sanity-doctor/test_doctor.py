# .claude/skills/qtc-dev-sanity-doctor/test_doctor.py
import json
import subprocess
import sys
from pathlib import Path

import pytest

DOCTOR = Path(__file__).parent / "doctor.py"


def run_doctor(*args, cwd):
    return subprocess.run(
        [sys.executable, str(DOCTOR), *args],
        capture_output=True, text=True, cwd=str(cwd),
    )


@pytest.fixture
def vault(tmp_path):
    p = tmp_path / "docs" / "project"
    for d in ("tasks", "epics", "features", "adr", "memory"):
        (p / d).mkdir(parents=True)

    (p / "memory" / "glossary.md").write_text(
        "# Glossary\n\n## Order Form\nA signed PDF.\n\n## Agent\nSales ops agent.\n"
    )
    # decisions.md holds real decisions; lifecycle breadcrumbs live in pipeline-log.md.
    # The doctor's map reads both, so rules 8/9/10 find EXECUTE/VERIFY in the log.
    (p / "memory" / "decisions.md").write_text(
        "# Decisions\n\n- 2026-05-14 [ADR] 001 use-sqlite — local dev. Rejected: postgres.\n"
    )
    (p / "memory" / "pipeline-log.md").write_text(
        "# Pipeline Log\n\n- 2026-05-14 [VERIFY] TASK-001 passed\n"
        "- 2026-05-14 [EXECUTE] TASK-002: built thing\n"
    )
    (p / "memory" / "failure-patterns.md").write_text(
        "# Failure Patterns\n\n## Shape: SfdcClient timeout\n"
        "`SfdcClient` fails when...\n"
    )
    (p / "000-base-use-cases.md").write_text(
        "# Use Cases\n\n## Renewal check\nAgent validates...\n"
        "## Customer identity\nAgent checks...\n"
    )

    (p / "tasks" / "TASK-001-test.md").write_text(
        "---\nid: TASK-001\ntitle: Test\ntype: task\nstatus: done\n"
        'epic: "[[epics/EPIC-001-test-epic]]"\ndepends_on: []\n---\n\n'
        "## Acceptance\n\n- [x] Thing A works correctly with all inputs\n- [x] Thing B works correctly with all inputs\n"
    )
    (p / "tasks" / "TASK-002-other.md").write_text(
        "---\nid: TASK-002\ntitle: Other\ntype: task\nstatus: in-progress\n"
        'epic: "[[epics/EPIC-001-test-epic]]"\ndepends_on: ["TASK-001"]\n---\n\n'
        "## Acceptance\n\n"
        "- [ ] Database connection is established before each request\n"
        "- [ ] Authentication token is validated on every endpoint\n"
    )
    (p / "epics" / "EPIC-001-test-epic.md").write_text(
        "---\nid: EPIC-001\ntitle: Test epic\ntype: epic\nstatus: done\n"
        'feature: "[[features/2026-05-14-test-feature]]"\n---\n\n'
        "## Tasks\n- [[TASK-001]]\n- [[TASK-002]]\n"
    )
    (p / "features" / "2026-05-14-test-feature.md").write_text(
        '---\ntitle: Test feature\nstatus: decomposed\n'
        'epics: ["[[epics/EPIC-001-test-epic]]"]\n---\n'
    )
    (p / "adr" / "001-test-adr.md").write_text(
        '---\nid: ADR-001\nstatus: accepted\nsupersedes: ""\nsuperseded_by: ""\n---\n# ADR 001\n'
    )
    return tmp_path


def test_map_tasks(vault):
    r = run_doctor("map", cwd=vault)
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    assert "TASK-001" in data["tasks"]
    t = data["tasks"]["TASK-001"]
    assert t["status"] == "done"
    assert t["parent_epic"] == "EPIC-001"
    assert t["depends_on"] == []


def test_map_epics(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert "EPIC-001" in data["epics"]
    e = data["epics"]["EPIC-001"]
    assert "TASK-001" in e["tasks"]
    assert "TASK-002" in e["tasks"]
    assert e["feature_slug"] == "2026-05-14-test-feature"


def test_map_features(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert "2026-05-14-test-feature" in data["features"]
    f = data["features"]["2026-05-14-test-feature"]
    assert "EPIC-001" in f["epic_ids"]


def test_map_adrs(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert "001" in data["adrs"]
    assert data["adrs"]["001"]["status"] == "accepted"


def test_map_glossary(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert "Order Form" in data["glossary_terms"]
    assert "Agent" in data["glossary_terms"]


def test_map_decisions(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    ids_all = [i for d in data["decisions"] for i in d["ids"]]
    assert "TASK-001" in ids_all
    assert "TASK-002" in ids_all


def test_map_failure_pattern_modules(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert "SfdcClient" in data["failure_pattern_module_refs"]


def test_map_acceptance_text_captured(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert "Thing A works correctly with all inputs" in data["tasks"]["TASK-001"]["acceptance_text"]


def test_map_task_depends_on(vault):
    r = run_doctor("map", cwd=vault)
    data = json.loads(r.stdout)
    assert data["tasks"]["TASK-002"]["depends_on"] == ["TASK-001"]


# ── git-check tests ──────────────────────────────────────────────────────────

@pytest.fixture
def git_repo(tmp_path):
    """Minimal git repo with one commit mentioning TASK-001."""
    subprocess.run(["git", "init"], cwd=tmp_path, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=tmp_path, check=True)
    (tmp_path / "f.txt").write_text("hello")
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(["git", "commit", "-m", "TASK-001: initial"], cwd=tmp_path, check=True, capture_output=True)
    return tmp_path


def test_git_check_found(git_repo):
    r = run_doctor("git-check", "TASK-001", cwd=git_repo)
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    assert data["found"] is True


def test_git_check_not_found(git_repo):
    r = run_doctor("git-check", "TASK-999", cwd=git_repo)
    assert r.returncode == 0
    data = json.loads(r.stdout)
    assert data["found"] is False


# ── similarity-all tests ─────────────────────────────────────────────────────

@pytest.fixture
def vault_with_similar_tasks(vault):
    """Add a TASK-003 with acceptance criteria nearly identical to TASK-001."""
    p = vault / "docs" / "project"
    (p / "tasks" / "TASK-003-copy.md").write_text(
        "---\nid: TASK-003\ntitle: Copy\ntype: task\nstatus: ready\n"
        'epic: "[[epics/EPIC-001-test-epic]]"\ndepends_on: []\n---\n\n'
        "## Acceptance\n\n- [ ] Thing A works correctly with all inputs\n- [ ] Thing B works correctly with all inputs\n"
    )
    return vault


def test_similarity_all_finds_similar_pair(vault_with_similar_tasks):
    r = run_doctor("similarity-all", cwd=vault_with_similar_tasks)
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    pairs = {(d["task_a"], d["task_b"]) for d in data["similar_pairs"]}
    assert ("TASK-001", "TASK-003") in pairs or ("TASK-003", "TASK-001") in pairs


def test_similarity_all_excludes_low_pairs(vault):
    """TASK-001 and TASK-002 have different acceptance criteria — should not appear."""
    r = run_doctor("similarity-all", cwd=vault)
    assert r.returncode == 0
    data = json.loads(r.stdout)
    pairs = {frozenset([d["task_a"], d["task_b"]]) for d in data["similar_pairs"]}
    assert frozenset(["TASK-001", "TASK-002"]) not in pairs


# ── autofix tests ────────────────────────────────────────────────────────────

def test_autofix_decisions_marks_stale(tmp_path):
    f = tmp_path / "decisions.md"
    f.write_text(
        "# Decisions\n\n"
        "- 2026-05-14 [VERIFY] TASK-999 passed\n"
        "- 2026-05-14 [VERIFY] TASK-001 passed\n"
    )
    r = run_doctor("autofix", "decisions", str(f), "--stale-ids", "TASK-999", cwd=tmp_path)
    assert r.returncode == 0, r.stderr
    result = json.loads(r.stdout)
    assert result["fixed"] == 1
    content = f.read_text()
    assert "TASK-999 passed [STALE]" in content
    assert "TASK-001 passed\n" in content  # untouched


def test_autofix_decisions_idempotent(tmp_path):
    """Running autofix twice does not double-append [STALE]."""
    f = tmp_path / "decisions.md"
    f.write_text("# Decisions\n\n- 2026-05-14 [VERIFY] TASK-999 passed\n")
    run_doctor("autofix", "decisions", str(f), "--stale-ids", "TASK-999", cwd=tmp_path)
    run_doctor("autofix", "decisions", str(f), "--stale-ids", "TASK-999", cwd=tmp_path)
    content = f.read_text()
    assert content.count("[STALE]") == 1


def test_autofix_failure_patterns_marks_stale(tmp_path):
    f = tmp_path / "failure-patterns.md"
    f.write_text(
        "# Failure Patterns\n\n"
        "## Shape: SfdcClientV1 timeout\n\n"
        "`SfdcClientV1` fails when auth token expires.\n"
    )
    r = run_doctor("autofix", "failure-patterns", str(f), "--stale-modules", "SfdcClientV1", cwd=tmp_path)
    assert r.returncode == 0
    result = json.loads(r.stdout)
    assert result["fixed"] == 1
    content = f.read_text()
    assert "[STALE]" in content


def test_autofix_failure_patterns_skips_live_modules(tmp_path):
    f = tmp_path / "failure-patterns.md"
    f.write_text(
        "# Failure Patterns\n\n"
        "## Shape: SfdcClient timeout\n\n"
        "`SfdcClient` fails when auth token expires.\n"
    )
    r = run_doctor("autofix", "failure-patterns", str(f), "--stale-modules", "OldModule", cwd=tmp_path)
    assert r.returncode == 0
    result = json.loads(r.stdout)
    assert result["fixed"] == 0
    content = f.read_text()
    assert "[STALE]" not in content
