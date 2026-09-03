#!/usr/bin/env python3
"""Render and validate the managed Fcitx5/Rime configuration."""

from __future__ import annotations

import argparse
import configparser
import pathlib
import re
import sys


SECTION_RE = re.compile(r"^\s*\[([^]]+)]\s*$")
ACTIVE_RE = re.compile(r"^\s*ActiveByDefault\s*=", re.IGNORECASE)


def render_global_config(original: str) -> str:
    """Set Behavior/ActiveByDefault without replacing unrelated Fcitx settings."""
    if "\x00" in original:
        raise ValueError("Fcitx5 config contains a NUL byte")

    lines = original.splitlines()
    rendered: list[str] = []
    current_section = ""
    behavior_seen = False
    active_written = False

    for line in lines:
        section_match = SECTION_RE.match(line)
        if section_match:
            if current_section.casefold() == "behavior" and not active_written:
                rendered.append("ActiveByDefault=True")
                active_written = True
            current_section = section_match.group(1).strip()
            if current_section.casefold() == "behavior":
                behavior_seen = True
            rendered.append(line)
            continue

        if current_section.casefold() == "behavior" and ACTIVE_RE.match(line):
            if not active_written:
                rendered.append("ActiveByDefault=True")
                active_written = True
            continue
        rendered.append(line)

    if behavior_seen:
        if not active_written:
            rendered.append("ActiveByDefault=True")
    else:
        if rendered and rendered[-1].strip():
            rendered.append("")
        if not rendered:
            rendered.append("# Managed by vmware-ubuntu-bootstrap.")
        rendered.extend(("[Behavior]", "ActiveByDefault=True"))

    while rendered and not rendered[-1].strip():
        rendered.pop()
    return "\n".join(rendered) + "\n"


def _read(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc


def _parse_ini(path: pathlib.Path) -> configparser.ConfigParser:
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.optionxform = str  # type: ignore[method-assign]
    try:
        parser.read_string(_read(path))
    except configparser.Error as exc:
        raise ValueError(f"invalid INI file {path}: {exc}") from exc
    return parser


def _top_level_block(text: str, key: str) -> list[str]:
    lines = text.splitlines()
    start = next(
        (
            index
            for index, line in enumerate(lines)
            if re.fullmatch(rf"{re.escape(key)}:\s*", line)
        ),
        None,
    )
    if start is None:
        raise ValueError(f"compiled Rime config is missing {key}:")

    block: list[str] = []
    for line in lines[start + 1 :]:
        if line and not line[0].isspace() and not line.lstrip().startswith("#"):
            break
        block.append(line)
    return block


def _has_mapping(text: str, **expected: str) -> bool:
    for line in text.splitlines():
        if "{" not in line or "}" not in line:
            continue
        body = line.split("{", 1)[1].rsplit("}", 1)[0]
        values: dict[str, str] = {}
        for item in body.split(","):
            key, separator, value = item.partition(":")
            if separator:
                values[key.strip()] = value.strip().strip('"\'')
        if all(values.get(key) == value for key, value in expected.items()):
            return True
    return False


def validate_configuration(
    profile_path: pathlib.Path,
    global_config_path: pathlib.Path,
    custom_path: pathlib.Path,
    compiled_path: pathlib.Path,
) -> None:
    profile = _parse_ini(profile_path)
    try:
        default_im = profile.get("Groups/0", "DefaultIM")
        default_layout = profile.get("Groups/0", "Default Layout")
    except (configparser.Error, KeyError) as exc:
        raise ValueError("Fcitx5 profile is missing the default group") from exc
    if default_im != "rime":
        raise ValueError("Fcitx5 default input method is not rime")
    if default_layout != "us":
        raise ValueError("Fcitx5 fallback keyboard layout is not us")

    item_sections = sorted(
        (
            section
            for section in profile.sections()
            if re.fullmatch(r"Groups/0/Items/[0-9]+", section)
        ),
        key=lambda section: int(section.rsplit("/", 1)[1]),
    )
    item_names = [
        profile.get(section, "Name", fallback="") for section in item_sections
    ]
    if item_names != ["keyboard-us", "rime"]:
        raise ValueError("Fcitx5 input list must contain only keyboard-us and rime")

    global_config = _parse_ini(global_config_path)
    active_by_default = global_config.get(
        "Behavior", "ActiveByDefault", fallback=""
    )
    if active_by_default.casefold() != "true":
        raise ValueError("Fcitx5 is not active by default")

    custom = _read(custom_path)
    if "__include" in custom or "rime_ice_suggestion" in custom:
        raise ValueError("Rime custom config contains the unsupported suggestion include")
    custom_schemas = re.findall(
        r"^\s*-\s*schema:\s*([A-Za-z0-9_.-]+)\s*$", custom, re.MULTILINE
    )
    if custom_schemas != ["rime_ice"]:
        raise ValueError("Rime custom config must enable only rime_ice")
    if not re.search(r'^\s*"menu/page_size":\s*9\s*$', custom, re.MULTILINE):
        raise ValueError("Rime custom page size is not 9")
    if not _has_mapping(custom, when="paging", accept="minus", send="Page_Up"):
        raise ValueError("Rime custom config is missing the minus/Page_Up binding")
    if not _has_mapping(custom, when="has_menu", accept="equal", send="Page_Down"):
        raise ValueError("Rime custom config is missing the equal/Page_Down binding")

    compiled = _read(compiled_path)
    menu_block = "\n".join(_top_level_block(compiled, "menu"))
    if not re.search(r"^\s+page_size:\s*9\s*$", menu_block, re.MULTILINE):
        raise ValueError("compiled Rime page size is not 9")

    schema_block = "\n".join(_top_level_block(compiled, "schema_list"))
    compiled_schemas = re.findall(
        r"^\s*-\s*schema:\s*([A-Za-z0-9_.-]+)\s*$",
        schema_block,
        re.MULTILINE,
    )
    if compiled_schemas != ["rime_ice"]:
        raise ValueError("compiled Rime config must enable only rime_ice")
    if not _has_mapping(compiled, when="paging", accept="minus", send="Page_Up"):
        raise ValueError("compiled Rime config is missing the minus/Page_Up binding")
    if not _has_mapping(
        compiled, when="has_menu", accept="equal", send="Page_Down"
    ):
        raise ValueError("compiled Rime config is missing the equal/Page_Down binding")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    render_parser = subparsers.add_parser("render-global")
    render_parser.add_argument("--input", type=pathlib.Path, required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--profile", type=pathlib.Path, required=True)
    validate_parser.add_argument("--global-config", type=pathlib.Path, required=True)
    validate_parser.add_argument("--custom", type=pathlib.Path, required=True)
    validate_parser.add_argument("--compiled", type=pathlib.Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "render-global":
            original = _read(args.input) if args.input.exists() else ""
            sys.stdout.write(render_global_config(original))
        else:
            validate_configuration(
                args.profile,
                args.global_config,
                args.custom,
                args.compiled,
            )
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
