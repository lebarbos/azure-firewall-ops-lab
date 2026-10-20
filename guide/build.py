#!/usr/bin/env python3
"""Build the self-contained student guide."""

from __future__ import annotations

import argparse
import difflib
import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
GUIDE = ROOT / "guide"
SRC = GUIDE / "src"
ASSETS = SRC / "assets"
CONTRACT = ROOT / "lab.contract.json"
DEFAULT_OUT = ROOT / "docs" / "index.html"

C_PLACEHOLDER = re.compile(r"\{\{c\.([A-Za-z0-9_.-]+)\}\}")
KQL_PLACEHOLDER = re.compile(r"^\s*\{\{kql:([A-Za-z0-9_.-]+)\}\}\s*$", re.MULTILINE)
SVG_PLACEHOLDER = re.compile(r"\{\{svg:([A-Za-z0-9_.-]+)\}\}")


class BuildError(Exception):
    """Build error with source location."""


def fail(path: Path, line: int, message: str) -> None:
    raise BuildError(f"{display(path)}:{line}: {message}")


def display(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def line_for(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise BuildError(f"{display(path)}:1: {error}") from error


def load_contract() -> dict[str, Any]:
    try:
        return json.loads(read_text(CONTRACT))
    except json.JSONDecodeError as error:
        fail(CONTRACT, error.lineno, error.msg)


def contract_value(contract: dict[str, Any], path_expr: str, source: Path, line: int) -> str:
    current: Any = contract
    for part in path_expr.split("."):
        if isinstance(current, dict):
            if part not in current:
                fail(source, line, f"contrato não contém c.{path_expr}")
            current = current[part]
        elif isinstance(current, list):
            if not part.isdigit():
                fail(source, line, f"índice de lista inválido em c.{path_expr}")
            index = int(part)
            if index >= len(current):
                fail(source, line, f"índice fora do intervalo em c.{path_expr}")
            current = current[index]
        else:
            fail(source, line, f"caminho continua após valor escalar em c.{path_expr}")

    if isinstance(current, (dict, list)):
        if isinstance(current, list) and all(isinstance(item, (str, int, float, bool)) for item in current):
            return html.escape(", ".join(str(item) for item in current), quote=True)
        fail(source, line, f"c.{path_expr} resolve para objeto ou lista não escalar")
    if current is None:
        fail(source, line, f"c.{path_expr} resolve para nulo")
    return html.escape(str(current), quote=True)


def replace_contract(text: str, contract: dict[str, Any], source: Path) -> str:
    def repl(match: re.Match[str]) -> str:
        return contract_value(contract, match.group(1), source, line_for(text, match.start()))

    return C_PLACEHOLDER.sub(repl, text)


def render_kql(text: str, source: Path) -> str:
    def repl(match: re.Match[str]) -> str:
        stem = match.group(1)
        path = ROOT / "queries" / f"{stem}.kql"
        if not path.is_file():
            fail(source, line_for(text, match.start()), f"query ausente: queries/{stem}.kql")
        body = html.escape(read_text(path), quote=False)
        caption = html.escape(f"queries/{stem}.kql")
        return (
            f'<figure class="code-figure">'
            f'<figcaption>{caption}</figcaption>'
            f'<pre class="code" data-lang="kql"><code>{body}</code></pre>'
            f"</figure>"
        )

    return KQL_PLACEHOLDER.sub(repl, text)


def render_svg(text: str, contract: dict[str, Any], source: Path) -> str:
    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        path = ASSETS / f"{name}.svg"
        if not path.is_file():
            fail(source, line_for(text, match.start()), f"svg ausente: assets/{name}.svg")
        return replace_contract(read_text(path), contract, path)

    return SVG_PLACEHOLDER.sub(repl, text)


class PartialParser(HTMLParser):
    def __init__(self, path: Path) -> None:
        super().__init__(convert_charrefs=False)
        self.path = path
        self.sections: list[tuple[str, str, int]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "section":
            return
        data = {name: value or "" for name, value in attrs}
        classes = set(data.get("class", "").split())
        if "chapter" in classes:
            section_id = data.get("id", "")
            title = data.get("data-title", "")
            line, _ = self.getpos()
            self.sections.append((section_id, title, line))


class NavParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.current_section: dict[str, Any] | None = None
        self.nav: list[dict[str, Any]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        data = {name: value or "" for name, value in attrs}
        classes = set(data.get("class", "").split())
        if tag == "section" and "chapter" in classes:
            self.depth = 1
            self.current_section = {
                "id": data["id"],
                "title": data["data-title"],
                "children": [],
            }
            self.nav.append(self.current_section)
            return
        if self.current_section:
            self.depth += 1
            if self.depth > 1 and data.get("id") and data.get("data-nav"):
                self.current_section["children"].append((data["id"], data["data-nav"]))

    def handle_endtag(self, tag: str) -> None:
        if self.current_section:
            self.depth -= 1
            if self.depth == 0:
                self.current_section = None


class IdParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: dict[str, int] = {}
        self.duplicates: list[tuple[str, int]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        data = {name: value or "" for name, value in attrs}
        element_id = data.get("id")
        if not element_id:
            return
        line, _ = self.getpos()
        if element_id in self.ids:
            self.duplicates.append((element_id, line))
        self.ids[element_id] = line


class HrefParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.hrefs: list[tuple[str, int]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        data = {name: value or "" for name, value in attrs}
        href = data.get("href", "")
        if href.startswith("#") and len(href) > 1:
            line, _ = self.getpos()
            self.hrefs.append((href[1:], line))


def validate_partial(path: Path, raw: str) -> tuple[str, str]:
    parser = PartialParser(path)
    try:
        parser.feed(raw)
    except Exception as error:
        fail(path, 1, f"HTML inválido: {error}")
    if len(parser.sections) != 1:
        fail(path, 1, "partial deve conter exatamente uma <section class=\"chapter\" id data-title>")
    section_id, title, line = parser.sections[0]
    if not section_id or not title:
        fail(path, line, "section.chapter precisa de id e data-title")
    return section_id, title


def build_nav(content: str) -> str:
    parser = NavParser()
    parser.feed(content)
    items: list[str] = []
    for section in parser.nav:
        children = "\n".join(
            f'<li><a href="#{html.escape(child_id, quote=True)}">{html.escape(label)}</a></li>'
            for child_id, label in section["children"]
        )
        child_list = f"\n<ul>{children}</ul>" if children else ""
        items.append(
            f'<li><a href="#{html.escape(section["id"], quote=True)}">'
            f'{html.escape(section["title"])}</a>{child_list}</li>'
        )
    return '<nav class="toc" aria-label="Sumário"><ol>' + "\n".join(items) + "</ol></nav>"


def render_partial(path: Path, contract: dict[str, Any]) -> str:
    raw = read_text(path)
    validate_partial(path, raw)
    rendered = replace_contract(raw, contract, path)
    rendered = render_svg(rendered, contract, path)
    rendered = render_kql(rendered, path)
    return rendered


def render(layout: Path, output: Path) -> str:
    contract = load_contract()
    partials = sorted(SRC.glob("[0-9][0-9]-*.html"))
    content = "\n".join(render_partial(path, contract) for path in partials)
    nav = build_nav(content)
    css = read_text(ASSETS / "styles.css")
    js = read_text(ASSETS / "app.js")
    page = read_text(layout)

    replacements = {
        "{{nav}}": nav,
        "{{content}}": content,
        "{{css}}": css,
        "{{js}}": js,
    }
    for token, value in replacements.items():
        if token not in page:
            fail(layout, 1, f"layout sem placeholder {token}")
        page = page.replace(token, value)
    page = replace_contract(page, contract, layout)

    if "{{" in page:
        offset = page.index("{{")
        fail(output, line_for(page, offset), "placeholder não resolvido")

    ids = IdParser()
    ids.feed(page)
    if ids.duplicates:
        duplicate, line = ids.duplicates[0]
        fail(output, line, f"id duplicado: {duplicate}")

    hrefs = HrefParser()
    hrefs.feed(nav)
    for target, line in hrefs.hrefs:
        if target not in ids.ids:
            fail(output, line, f"href do menu aponta para id inexistente: #{target}")

    return page


def short_diff(expected: str, actual: str, output: Path) -> str:
    diff = difflib.unified_diff(
        actual.splitlines(),
        expected.splitlines(),
        fromfile=display(output),
        tofile="generated",
        lineterm="",
        n=3,
    )
    lines = list(diff)
    if len(lines) > 80:
        lines = lines[:80] + ["... diff truncado ..."]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare with docs/index.html")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output file")
    args = parser.parse_args(argv)

    try:
        layout = SRC / "_layout.html"
        output = args.out if args.out.is_absolute() else ROOT / args.out
        rendered = render(layout, output)
        if args.check:
            if not output.is_file():
                print(f"{display(output)}:1: arquivo ausente", file=sys.stderr)
                return 1
            current = read_text(output)
            if current != rendered:
                print(short_diff(rendered, current, output), file=sys.stderr)
                return 1
            print(f"{display(output)} está atualizado.")
            return 0
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8", newline="")
        print(f"Gerado {display(output)}.")
        return 0
    except BuildError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
