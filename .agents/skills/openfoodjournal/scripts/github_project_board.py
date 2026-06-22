#!/usr/bin/env python3
"""Manage the OpenFoodJournal GitHub Projects v2 board with gh.

This mirrors the CodeGym project-board helper pattern, but defaults to this
repository and shells out to `gh project` because GitHub's CLI now exposes the
Project v2 operations needed for a lightweight kanban workflow.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

DEFAULT_OWNER = "kvn8888"
DEFAULT_REPO = "OpenFoodJournal"
DEFAULT_PROJECT_TITLE = "OpenFoodJournal"


class BoardError(RuntimeError):
    pass


@dataclass(frozen=True)
class Project:
    id: str
    number: int
    title: str
    url: str


def run_gh(*args: str, json_output: bool = False) -> Any:
    command = ["gh", *args]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise BoardError(f"{' '.join(command)} failed: {message}")
    output = result.stdout.strip()
    if json_output:
        return json.loads(output or "{}")
    return output


def list_projects(owner: str) -> list[Project]:
    data = run_gh("project", "list", "--owner", owner, "--format", "json", "--limit", "100", json_output=True)
    return [
        Project(
            id=item["id"],
            number=int(item["number"]),
            title=item["title"],
            url=item["url"],
        )
        for item in data.get("projects", [])
    ]


def resolve_project(owner: str, title: str, number: int | None) -> Project:
    projects = list_projects(owner)
    if number is not None:
        for project in projects:
            if project.number == number:
                return project
        raise BoardError(f"No project #{number} found for {owner}.")

    lowered = title.lower()
    for project in projects:
        if project.title.lower() == lowered:
            return project
    for project in projects:
        if lowered in project.title.lower():
            return project

    available = ", ".join(f"#{project.number} {project.title}" for project in projects)
    raise BoardError(f"No project matching {title!r}. Available: {available or 'none'}")


def project_view(owner: str, project: Project) -> dict[str, Any]:
    return run_gh("project", "view", str(project.number), "--owner", owner, "--format", "json", json_output=True)


def field_list(owner: str, project: Project) -> list[dict[str, Any]]:
    data = run_gh("project", "field-list", str(project.number), "--owner", owner, "--format", "json", json_output=True)
    return data.get("fields", [])


def item_list(owner: str, project: Project, limit: str = "100") -> list[dict[str, Any]]:
    data = run_gh(
        "project",
        "item-list",
        str(project.number),
        "--owner",
        owner,
        "--format",
        "json",
        "--limit",
        limit,
        json_output=True,
    )
    return data.get("items", [])


def status_field(fields: list[dict[str, Any]]) -> dict[str, Any]:
    return single_select_field(fields, "Status")


def single_select_field(fields: list[dict[str, Any]], name: str) -> dict[str, Any]:
    for field in fields:
        if field.get("name", "").lower() == name.lower() and field.get("options"):
            return field
    raise BoardError(f"Project has no single-select {name} field.")


def option_id(field: dict[str, Any], value: str) -> str:
    lowered = value.lower()
    for option in field.get("options", []):
        if option["name"].lower() == lowered:
            return option["id"]
    for option in field.get("options", []):
        if lowered in option["name"].lower():
            return option["id"]
    names = ", ".join(option["name"] for option in field.get("options", []))
    raise BoardError(f"No {field.get('name', 'field')} option matching {value!r}. Available: {names}")


def resolve_item(items: list[dict[str, Any]], ref: str) -> dict[str, Any]:
    clean = ref.strip()
    if clean.startswith("PVTI_"):
        for item in items:
            if item.get("id") == clean:
                return item
    if clean.startswith("#"):
        clean = clean[1:]
    if clean.isdigit():
        for item in items:
            content = item.get("content") or {}
            if str(content.get("number", "")) == clean:
                return item
    for item in items:
        content = item.get("content") or {}
        values = {item.get("id"), content.get("url"), item.get("title"), content.get("title")}
        if clean in values:
            return item
        if clean.lower() in {str(value).lower() for value in values if value}:
            return item
    raise BoardError(f"No project item matched {ref!r}.")


def markdown_escape(value: Any) -> str:
    return str(value or "").replace("|", "\\|").replace("\n", " ")


def print_projects(projects: list[Project]) -> None:
    print("| Number | Title | URL |")
    print("| --- | --- | --- |")
    for project in projects:
        print(f"| {project.number} | {markdown_escape(project.title)} | {project.url} |")


def print_columns(fields: list[dict[str, Any]]) -> None:
    field = status_field(fields)
    print("# Status")
    print()
    for option in field.get("options", []):
        print(f"- {option['name']} (`{option['id']}`)")


def print_items(items: list[dict[str, Any]]) -> None:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for item in items:
        grouped.setdefault(item.get("status") or "No Status", []).append(item)

    for status, status_items in grouped.items():
        print(f"## {status}")
        print()
        print("| Item | Title | Type | URL |")
        print("| --- | --- | --- | --- |")
        for item in status_items:
            content = item.get("content") or {}
            number = content.get("number")
            item_number = f"#{number}" if number else "draft"
            title = item.get("title") or content.get("title") or "(untitled)"
            print(
                f"| {item_number} | {markdown_escape(title)} | "
                f"{markdown_escape(content.get('type'))} | {content.get('url', '')} |"
            )
        print()


def move_item(owner: str, project: Project, item_id: str, status: str) -> None:
    set_single_select(owner, project, item_id, "Status", status)


def set_single_select(owner: str, project: Project, item_id: str, field_name: str, value: str) -> None:
    view = project_view(owner, project)
    field = single_select_field(field_list(owner, project), field_name)
    run_gh(
        "project",
        "item-edit",
        "--id",
        item_id,
        "--project-id",
        view["id"],
        "--field-id",
        field["id"],
        "--single-select-option-id",
        option_id(field, value),
    )


def repo_slug(args: argparse.Namespace) -> str:
    return f"{args.repo_owner}/{args.repo}"


def issue_url(args: argparse.Namespace, number: int) -> str:
    return f"https://github.com/{repo_slug(args)}/issues/{number}"


def issue_body(body: str | None, body_file: str | None) -> str:
    if body_file:
        if body_file == "-":
            return sys.stdin.read()
        return Path(body_file).read_text()
    if body == "-":
        return sys.stdin.read()
    return body or ""


def split_labels(labels: list[str] | None) -> list[str]:
    if not labels:
        return []
    values: list[str] = []
    for label in labels:
        values.extend(part.strip() for part in label.split(",") if part.strip())
    return values


def issue_number_from_url(url: str) -> int:
    try:
        return int(url.rstrip("/").split("/")[-1])
    except ValueError as err:
        raise BoardError(f"Could not parse issue number from {url!r}.") from err


def project_item_for_issue(owner: str, project: Project, number: int) -> dict[str, Any] | None:
    for item in item_list(owner, project):
        content = item.get("content") or {}
        if str(content.get("number", "")) == str(number):
            return item
    return None


def ensure_issue_on_project(args: argparse.Namespace, project: Project, number: int) -> str:
    existing = project_item_for_issue(args.owner, project, number)
    if existing:
        return existing["id"]

    data = run_gh(
        "project",
        "item-add",
        str(project.number),
        "--owner",
        args.owner,
        "--url",
        issue_url(args, number),
        "--format",
        "json",
        json_output=True,
    )
    return data["id"]


def apply_project_fields(args: argparse.Namespace, project: Project, item_id: str) -> None:
    field_values = {
        "Status": getattr(args, "status", None),
        "Priority": getattr(args, "priority", None),
        "Size": getattr(args, "size", None),
    }
    for field_name, value in field_values.items():
        if value:
            set_single_select(args.owner, project, item_id, field_name, value)


def cmd_projects(args: argparse.Namespace) -> None:
    print_projects(list_projects(args.owner))


def cmd_create(args: argparse.Namespace) -> None:
    for project in list_projects(args.owner):
        if project.title.lower() == args.project_title.lower():
            print(f"Project already exists: #{project.number} {project.url}")
            return
    data = run_gh(
        "project",
        "create",
        "--owner",
        args.owner,
        "--title",
        args.project_title,
        "--format",
        "json",
        json_output=True,
    )
    number = str(data["number"])
    run_gh("project", "link", number, "--owner", args.owner, "--repo", args.repo)
    print(f"Created project #{number}: {data['url']}")


def cmd_columns(args: argparse.Namespace) -> None:
    project = resolve_project(args.owner, args.project_title, args.project_number)
    print_columns(field_list(args.owner, project))


def cmd_list(args: argparse.Namespace) -> None:
    project = resolve_project(args.owner, args.project_title, args.project_number)
    items = item_list(args.owner, project, args.limit)
    if args.status:
        items = [item for item in items if (item.get("status") or "").lower() == args.status.lower()]
    print_items(items)


def cmd_add_issue(args: argparse.Namespace) -> None:
    project = resolve_project(args.owner, args.project_title, args.project_number)
    item_id = ensure_issue_on_project(args, project, args.number)
    apply_project_fields(args, project, item_id)
    print(f"Added/updated issue #{args.number}: `{item_id}`")


def cmd_move(args: argparse.Namespace) -> None:
    project = resolve_project(args.owner, args.project_title, args.project_number)
    item = resolve_item(item_list(args.owner, project), args.item)
    move_item(args.owner, project, item["id"], args.status)
    print(f"Moved `{item['id']}` to {args.status}.")


def cmd_create_issue(args: argparse.Namespace) -> None:
    labels = split_labels(args.label)
    command = [
        "issue",
        "create",
        "--repo",
        repo_slug(args),
        "--title",
        args.title,
        "--body",
        issue_body(args.body, args.body_file),
    ]
    if labels:
        command.extend(["--label", ",".join(labels)])
    url = run_gh(*command).splitlines()[-1]
    number = issue_number_from_url(url)
    print(f"Created issue #{number}: {url}")

    if not args.no_project:
        project = resolve_project(args.owner, args.project_title, args.project_number)
        item_id = ensure_issue_on_project(args, project, number)
        apply_project_fields(args, project, item_id)
        print(f"Added/updated project item: `{item_id}`")


def cmd_edit_issue(args: argparse.Namespace) -> None:
    command = [
        "issue",
        "edit",
        str(args.number),
        "--repo",
        repo_slug(args),
    ]
    if args.title:
        command.extend(["--title", args.title])
    if args.body is not None or args.body_file:
        command.extend(["--body", issue_body(args.body, args.body_file)])
    labels = split_labels(args.add_label)
    if labels:
        command.extend(["--add-label", ",".join(labels)])
    run_gh(*command)
    print(f"Edited issue #{args.number}: {issue_url(args, args.number)}")

    if args.status or args.priority or args.size:
        project = resolve_project(args.owner, args.project_title, args.project_number)
        item_id = ensure_issue_on_project(args, project, args.number)
        apply_project_fields(args, project, item_id)
        print(f"Updated project item: `{item_id}`")


def cmd_set_fields(args: argparse.Namespace) -> None:
    project = resolve_project(args.owner, args.project_title, args.project_number)
    item = resolve_item(item_list(args.owner, project), args.item)
    apply_project_fields(args, project, item["id"])
    print(f"Updated project item: `{item['id']}`")


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--owner", default=os.environ.get("OFJ_GITHUB_OWNER", DEFAULT_OWNER))
    parser.add_argument("--repo-owner", default=os.environ.get("OFJ_GITHUB_REPO_OWNER", DEFAULT_OWNER))
    parser.add_argument("--repo", default=os.environ.get("OFJ_GITHUB_REPO", DEFAULT_REPO))
    parser.add_argument("--project-title", default=os.environ.get("OFJ_GITHUB_PROJECT_TITLE", DEFAULT_PROJECT_TITLE))
    parser.add_argument("--project-number", type=int, default=env_int("OFJ_GITHUB_PROJECT_NUMBER"))


def env_int(name: str) -> int | None:
    value = os.environ.get(name)
    return int(value) if value else None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage the OpenFoodJournal GitHub Projects v2 board.")
    add_common_args(parser)
    sub = parser.add_subparsers(dest="command", required=True)

    projects = sub.add_parser("projects", help="List owner projects.")
    add_common_args(projects)
    projects.set_defaults(func=cmd_projects)

    create = sub.add_parser("create", help="Create/link the default project if missing.")
    add_common_args(create)
    create.set_defaults(func=cmd_create)

    columns = sub.add_parser("columns", help="List Status options.")
    add_common_args(columns)
    columns.set_defaults(func=cmd_columns)

    list_parser = sub.add_parser("list", help="Render project items as Markdown.")
    add_common_args(list_parser)
    list_parser.add_argument("--status")
    list_parser.add_argument("--limit", default="100")
    list_parser.set_defaults(func=cmd_list)

    add_issue = sub.add_parser("add-issue", help="Add a repository issue to the board.")
    add_common_args(add_issue)
    add_issue.add_argument("number", type=int)
    add_issue.add_argument("--status")
    add_issue.add_argument("--priority")
    add_issue.add_argument("--size")
    add_issue.set_defaults(func=cmd_add_issue)

    move = sub.add_parser("move", help="Move an item to a Status column.")
    add_common_args(move)
    move.add_argument("item")
    move.add_argument("status")
    move.set_defaults(func=cmd_move)

    create_issue = sub.add_parser("create-issue", help="Create an issue and optionally add it to the board.")
    add_common_args(create_issue)
    create_issue.add_argument("--title", required=True)
    create_issue.add_argument("--body", default="")
    create_issue.add_argument("--body-file")
    create_issue.add_argument("--label", action="append", help="Comma-separated label list. May be repeated.")
    create_issue.add_argument("--status")
    create_issue.add_argument("--priority")
    create_issue.add_argument("--size")
    create_issue.add_argument("--no-project", action="store_true")
    create_issue.set_defaults(func=cmd_create_issue)

    edit_issue = sub.add_parser("edit-issue", help="Edit an issue and optionally update board fields.")
    add_common_args(edit_issue)
    edit_issue.add_argument("number", type=int)
    edit_issue.add_argument("--title")
    edit_issue.add_argument("--body")
    edit_issue.add_argument("--body-file")
    edit_issue.add_argument("--add-label", action="append", help="Comma-separated label list. May be repeated.")
    edit_issue.add_argument("--status")
    edit_issue.add_argument("--priority")
    edit_issue.add_argument("--size")
    edit_issue.set_defaults(func=cmd_edit_issue)

    set_fields = sub.add_parser("set-fields", help="Set project single-select fields for an item.")
    add_common_args(set_fields)
    set_fields.add_argument("item", help="Issue number, item ID, URL, or title.")
    set_fields.add_argument("--status")
    set_fields.add_argument("--priority")
    set_fields.add_argument("--size")
    set_fields.set_defaults(func=cmd_set_fields)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except BoardError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
