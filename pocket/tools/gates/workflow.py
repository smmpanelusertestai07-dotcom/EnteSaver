#!/usr/bin/env python3
"""PocketIDE's own workflow, .github/workflows/pocket.yml, held to the rules it enforces.

  - only allow-listed actions (allowed-actions.txt), each pinned by full commit SHA with its
    tag in a comment, so Dependabot and a reader both see what the SHA is;
  - `permissions: contents: read` at the top; the only write grant is contents: write on the
    release job;
  - every checkout sets persist-credentials: false;
  - no pull_request_target, and no ${{ github.event.* }} or head_ref pasted into a run: script,
    where a crafted branch name or commit message would become shell code (pass it through env);
  - the release build tells the app where its updates come from: the repository this workflow
    runs in and publishes to (-PPOCKETIDE_RELEASES_REPO="$GITHUB_REPOSITORY"), so a phone never
    keeps reading a place the project has moved away from.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import actions_rules
import common
import yaml_lite

WORKFLOW = ".github/workflows/pocket.yml"
ALLOWED = Path(__file__).with_name("allowed-actions.txt")
RELEASES_REPO = re.compile(r'-PPOCKETIDE_RELEASES_REPO=\$\{?GITHUB_REPOSITORY\}?\b')
UNTRUSTED = re.compile(r"\$\{\{[^}]*\b(github\.event\.|github\.head_ref|inputs\.)[^}]*\}\}")


def allowed_actions(path: Path = ALLOWED) -> set[str]:
    return {l.strip() for l in path.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.lstrip().startswith("#")}


def check_text(text: str, allowed: set[str]) -> list[str]:
    problems = []
    try:
        workflow = yaml_lite.load(text)
    except yaml_lite.YamlError as error:
        return [f"{WORKFLOW} cannot be read: {error}"]

    for line, reference, comment in actions_rules.uses_lines(text):
        why = actions_rules.pin_problem(reference)
        if why:
            problems.append(f"{WORKFLOW}:{line}: {reference} {why}")
        elif not actions_rules.TAG_COMMENT.search(comment):
            problems.append(f"{WORKFLOW}:{line}: {reference} needs its tag in a comment, e.g. '# v5.0.0'")
        if actions_rules.action_name(reference) not in allowed:
            problems.append(f"{WORKFLOW}:{line}: {actions_rules.action_name(reference)} is not in allowed-actions.txt")

    triggers = workflow.get("on") or {}
    if "pull_request_target" in (triggers if isinstance(triggers, (dict, list)) else [triggers]):
        problems.append(f"{WORKFLOW}: pull_request_target runs fork code with this repository's secrets")

    top = workflow.get("permissions")
    if not (isinstance(top, dict) and set(top.items()) == {("contents", "read")}):
        problems.append(f"{WORKFLOW}: top-level permissions must be exactly 'contents: read'")

    for job_name, job in (workflow.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for grant in actions_rules.write_grants(job.get("permissions")):
            if not (job_name == "release" and grant == "contents"):
                problems.append(f"{WORKFLOW}: job {job_name} grants write to {grant}; only release may write contents")
        for index, step in enumerate(job.get("steps") or []):
            if not isinstance(step, dict):
                continue
            label = f"job {job_name}, step {step.get('name') or index + 1}"
            uses = str(step.get("uses") or "")
            if uses.startswith("actions/checkout@"):
                if str((step.get("with") or {}).get("persist-credentials")) != "false":
                    problems.append(f"{WORKFLOW}: {label}: checkout must set persist-credentials: false")
            run = step.get("run")
            if isinstance(run, str) and UNTRUSTED.search(run):
                problems.append(f"{WORKFLOW}: {label}: '{UNTRUSTED.search(run).group(0)}' is pasted into the "
                                "script; pass it through env: instead")
            if isinstance(run, str) and "assembleRelease" in run and not RELEASES_REPO.search(run):
                problems.append(f"{WORKFLOW}: {label}: the release build must pass "
                                '-PPOCKETIDE_RELEASES_REPO="$GITHUB_REPOSITORY", or the app looks for its updates '
                                "somewhere this workflow does not publish them")
    return problems


def check(root: Path = common.POCKET, allowed_path: Path = ALLOWED) -> common.Report:
    report = common.Report()
    path = root.parent / WORKFLOW
    if not path.is_file():
        report.fail(f"{WORKFLOW} is missing")
        return report
    for problem in check_text(path.read_text(encoding="utf-8"), allowed_actions(allowed_path)):
        report.fail(problem)
    return report


if __name__ == "__main__":
    sys.exit(common.run_standalone("workflow", check))
