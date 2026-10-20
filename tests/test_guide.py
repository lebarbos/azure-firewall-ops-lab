"""Integridade do guia do aluno: build, navegação, uso offline e pedagogia."""

from __future__ import annotations

import collections
import contextlib
import importlib.util
import io
import json
import re
import shutil
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs" / "index.html"
QUERIES = ROOT / "queries"
CONTRACT = json.loads((ROOT / "lab.contract.json").read_text(encoding="utf-8"))

CHAPTERS = [
    "inicio", "arquitetura", "conceitos",
    "ex0", "ex1", "ex2", "ex3", "ex4", "ex5", "ex6", "cleanup",
    "kql", "troubleshooting", "creditos",
]
REFERENCE_CHAPTERS = {"inicio", "arquitetura", "conceitos", "kql", "troubleshooting", "creditos"}
CHECKPOINT_ANCHORS = {
    "C0": ("ex0", "ex0-c0"),
    "C1": ("ex1", "ex1-c1"),
    "C2": ("ex2", "ex2-c2"),
    "C3": ("ex3", "ex3-c3"),
    "C4": ("ex4", "ex4-c4"),
    "C5": ("ex5", "ex5-c5"),
    "C6": ("ex6", "ex6-c6"),
    "CX": ("cleanup", "cleanup-cx"),
}
EX2_EXPERIMENTS = ["ex2-e2", "ex2-e3", "ex2-e4"]
EXPERIMENT_FLOW = ["predict", "portal", "cli", "verify", "answer"]
MARKDOWN_DOCS = ["README.md", "NOTICE.md", "guide/README.md"]
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
OFFLINE_FORBIDDEN_TAGS = {
    "link", "iframe", "frame", "frameset", "object", "embed", "applet",
    "audio", "video", "source", "track", "portal", "base", "form",
}


class Node:
    def __init__(self, tag: str, attrs: dict[str, str], parent: Node | None) -> None:
        self.tag = tag
        self.attrs = attrs
        self.parent = parent
        self.children: list[Node | str] = []

    @property
    def classes(self) -> set[str]:
        return set(self.attrs.get("class", "").split())

    @property
    def id(self) -> str:
        return self.attrs.get("id", "")

    def walk(self):
        for child in self.children:
            if isinstance(child, Node):
                yield child
                yield from child.walk()

    def find_all(self, tag: str | None = None, cls: str | None = None) -> list[Node]:
        return [
            node for node in self.walk()
            if (tag is None or node.tag == tag) and (cls is None or cls in node.classes)
        ]

    def text(self) -> str:
        return "".join(child if isinstance(child, str) else child.text() for child in self.children)

    def ancestors(self):
        node = self.parent
        while node is not None:
            yield node
            node = node.parent

    def element_children(self) -> list[Node]:
        return [child for child in self.children if isinstance(child, Node)]


class TreeBuilder(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = Node("#document", {}, None)
        self.stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        node = Node(tag, {name: value or "" for name, value in attrs}, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.stack[-1].children.append(Node(tag, {name: value or "" for name, value in attrs}, self.stack[-1]))

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        self.stack[-1].children.append(data)


def parse(page: str) -> Node:
    builder = TreeBuilder()
    builder.feed(page)
    builder.close()
    return builder.root


def text_nodes(node: Node):
    for child in node.children:
        if isinstance(child, str):
            yield node, child
        else:
            yield from text_nodes(child)


def visible_text(node: Node) -> str:
    """Texto que o aluno vê sem abrir um <details class="answer">."""
    parts = []
    for child in node.children:
        if isinstance(child, str):
            parts.append(child)
        elif not (child.tag == "details" and "answer" in child.classes):
            parts.append(visible_text(child))
    return "".join(parts)


def roles(article: Node) -> list[str]:
    """Blocos da anatomia de um passo, na ordem do documento, sem repetição."""
    found: list[str] = []
    for node in article.walk():
        role = None
        if node.tag == "details" and "cli" in node.classes:
            role = "cli"
        elif node.tag == "details" and "answer" in node.classes:
            role = "answer"
        else:
            for name in ("what", "why", "portal", "verify", "predict", "no-cli"):
                if name in node.classes:
                    role = name
                    break
        if role and role not in found:
            found.append(role)
    return found


def load_build(root: Path = ROOT):
    spec = importlib.util.spec_from_file_location(f"guide_build_{abs(hash(root))}", root / "guide" / "build.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GuideBuildTests(unittest.TestCase):
    def test_docs_index_matches_a_fresh_build(self) -> None:
        build = load_build()
        rendered = build.render(build.SRC / "_layout.html", build.DEFAULT_OUT)
        self.assertTrue(
            DOCS.read_text(encoding="utf-8") == rendered,
            "docs/index.html está desatualizado: rode python3 guide/build.py",
        )

    def _copy_sources(self, target: Path) -> None:
        for name in ("guide", "queries", "docs"):
            shutil.copytree(ROOT / name, target / name, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copy2(ROOT / "lab.contract.json", target / "lab.contract.json")

    def test_broken_sources_fail_with_file_and_line(self) -> None:
        cases = [
            ("05-ex2.html", "{{c.rc.appWlA.name}}", "{{c.rc.inexistente.name}}", "c.rc.inexistente.name"),
            ("05-ex2.html", "{{kql:ex2-tipo}}", "{{kql:nao-existe}}", "query ausente"),
            ("06-ex3.html", "<h3>3.4 ·", '<p id="ex2-e1"></p><h3>3.4 ·', "id duplicado: ex2-e1"),
        ]
        for partial, old, new, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self._copy_sources(root)
                source = root / "guide" / "src" / partial
                text = source.read_text(encoding="utf-8")
                self.assertIn(old, text)
                source.write_text(text.replace(old, new, 1), encoding="utf-8")
                build = load_build(root)
                with self.assertRaises(build.BuildError) as raised:
                    build.render(build.SRC / "_layout.html", build.DEFAULT_OUT)
                self.assertIn(message, str(raised.exception))
                self.assertRegex(str(raised.exception), r"^[\w./-]+:\d+: ")

    def test_check_flag_detects_stale_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._copy_sources(root)
            build = load_build(root)
            output = root / "docs" / "index.html"
            output.write_text(output.read_text(encoding="utf-8") + "<!-- editado à mão -->", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(build.main(["--check"]), 1)
                self.assertEqual(build.main([]), 0)
                self.assertEqual(build.main(["--check"]), 0)


class GuidePageTests(unittest.TestCase):
    page: str
    root: Node
    ids: set[str]
    chapters: dict[str, Node]

    @classmethod
    def setUpClass(cls) -> None:
        cls.page = DOCS.read_text(encoding="utf-8")
        cls.root = parse(cls.page)
        cls.ids = {node.id for node in cls.root.walk() if node.id}
        cls.chapters = {node.id: node for node in cls.root.find_all("section", "chapter")}

    def test_no_placeholder_survives_the_build(self) -> None:
        self.assertNotIn("{{", self.page)

    def test_chapters_follow_the_course_order(self) -> None:
        self.assertEqual([node.id for node in self.root.find_all("section", "chapter")], CHAPTERS)

    def test_sidebar_lists_every_chapter_in_order(self) -> None:
        navs = self.root.find_all("nav", "toc")
        self.assertEqual(len(navs), 1)
        top_level = navs[0].find_all("ol")[0].element_children()
        hrefs = [item.find_all("a")[0].attrs["href"] for item in top_level]
        self.assertEqual(hrefs, ["#" + chapter for chapter in CHAPTERS])

    def test_ids_are_unique(self) -> None:
        counts = collections.Counter(node.id for node in self.root.walk() if node.id)
        self.assertEqual(sorted(name for name, count in counts.items() if count > 1), [])

    def test_every_internal_link_and_aria_reference_resolves(self) -> None:
        missing = set()
        for node in self.root.walk():
            href = node.attrs.get("href", "") if node.tag == "a" else ""
            if href.startswith("#") and href[1:] not in self.ids:
                missing.add(href)
            for attr in ("aria-controls", "aria-labelledby", "aria-describedby", "for"):
                missing.update(f"{attr}={ref}" for ref in node.attrs.get(attr, "").split() if ref not in self.ids)
        self.assertEqual(sorted(missing), [])

    def test_required_anchors_exist(self) -> None:
        self.assertEqual(set(CHECKPOINT_ANCHORS), set(CONTRACT["checkpoints"]))
        required = set(CHAPTERS) | set(EX2_EXPERIMENTS) | {"ex2-e1"} | {anchor for _, anchor in CHECKPOINT_ANCHORS.values()}
        self.assertEqual(sorted(required - self.ids), [])

    def test_page_works_offline(self) -> None:
        self.assertEqual(sorted({node.tag for node in self.root.walk() if node.tag in OFFLINE_FORBIDDEN_TAGS}), [])
        for node in self.root.walk():
            for attr in ("src", "srcset", "data", "poster", "action", "formaction", "background"):
                value = node.attrs.get(attr)
                if value is not None:
                    self.assertTrue(value.startswith("data:"), f"<{node.tag} {attr}={value}>")
            if node.tag in {"image", "use", "feimage"}:
                for attr in ("href", "xlink:href"):
                    value = node.attrs.get(attr, "#")
                    self.assertTrue(value.startswith(("#", "data:")), f"<{node.tag} {attr}={value}>")
            if node.tag == "meta":
                self.assertNotEqual(node.attrs.get("http-equiv", "").lower(), "refresh")
        css = "\n".join(node.text() for node in self.root.find_all("style"))
        css += "\n".join(node.attrs["style"] for node in self.root.walk() if "style" in node.attrs)
        self.assertNotRegex(css, r"@import|url\(\s*['\"]?(?!#|data:)")
        js = "\n".join(node.text() for node in self.root.find_all("script"))
        self.assertNotRegex(js, r"\bfetch\s*\(|XMLHttpRequest|\bimport\s*\(|sendBeacon|WebSocket|EventSource|\.src\s*=")

    def test_external_links_are_https_and_open_safely(self) -> None:
        for anchor in self.root.find_all("a"):
            href = anchor.attrs.get("href", "")
            with self.subTest(href=href):
                if href.startswith(("http:", "https:", "//")):
                    self.assertTrue(href.startswith("https://"))
                if anchor.attrs.get("target") == "_blank":
                    self.assertIn("noopener", anchor.attrs.get("rel", "").split())

    def test_every_query_is_embedded_verbatim(self) -> None:
        embedded: dict[str, set[str]] = collections.defaultdict(set)
        for figure in self.root.find_all("figure", "code-figure"):
            caption = figure.find_all("figcaption")[0].text().strip()
            embedded[caption].add(figure.find_all("code")[0].text())
        queries = sorted(QUERIES.glob("*.kql"))
        self.assertTrue(queries)
        for path in queries:
            with self.subTest(query=path.name):
                key = f"queries/{path.name}"
                self.assertIn(key, embedded, "query não embutida em nenhum capítulo")
                self.assertEqual(embedded[key], {path.read_text(encoding="utf-8")})

    def test_prose_has_no_markdown_leftovers(self) -> None:
        offenders = []
        for parent, text in text_nodes(self.root):
            tags = {parent.tag, *(node.tag for node in parent.ancestors())}
            if tags & {"pre", "script", "style"}:
                continue
            if "`" in text or re.search(r"\*\*\S", text) or re.search(r"\[[^\]]+\]\([^)\s]+\)", text):
                offenders.append(" ".join(text.split())[:100])
        self.assertEqual(offenders, [])

    def test_copy_paste_blocks_keep_the_cloud_shell_alive(self) -> None:
        blocks = self.root.find_all("pre")
        self.assertTrue(blocks)
        for block in blocks:
            lang = block.attrs.get("data-lang")
            body = block.text()
            with self.subTest(lang=lang, start=body[:60]):
                self.assertIn(lang, {"bash", "powershell", "kql"})
                if lang == "bash":
                    self.assertNotRegex(body, r"(?m)^\s*set\s+(-\w*e|-o\s+errexit)")
                    self.assertNotRegex(body, r"(?m)(^|[;&|({]|\b(?:then|else|do))\s*(exit|exec)\b")
                if lang == "powershell":
                    self.assertNotRegex(body, r"(?im)(^|[;{])\s*exit\b")

    def test_progress_tracking_is_off_only_in_reference_chapters(self) -> None:
        off = {chapter_id for chapter_id, node in self.chapters.items() if node.attrs.get("data-progress") == "off"}
        self.assertEqual(off, REFERENCE_CHAPTERS)

    def test_exercise_steps_follow_the_guide_anatomy(self) -> None:
        for chapter_id in CHAPTERS:
            if chapter_id in REFERENCE_CHAPTERS:
                continue
            steps = self.chapters[chapter_id].find_all("article", "step")
            self.assertTrue(steps, chapter_id)
            for step in steps:
                with self.subTest(step=step.id):
                    found = roles(step)
                    for role in ("what", "why", "portal", "verify"):
                        self.assertIn(role, found)
                    self.assertTrue({"cli", "no-cli"} & set(found))
                    self.assertTrue(step.attrs.get("data-nav"))

    def test_each_exercise_closes_with_its_checkpoint(self) -> None:
        for checkpoint, (chapter_id, anchor) in CHECKPOINT_ANCHORS.items():
            with self.subTest(checkpoint=checkpoint):
                chapter = self.chapters[chapter_id]
                blocks = chapter.find_all(cls="checkpoint")
                self.assertEqual([block.id for block in blocks], [anchor])
                children = chapter.element_children()
                after = children[children.index(blocks[0]) + 1:]
                self.assertEqual([node.id for node in after if node.tag == "article"], [], "passo depois do checkpoint")
                self.assertIn(f"./scripts/checkpoint.sh {checkpoint}", blocks[0].text())

    def test_predictions_keep_the_result_hidden_until_the_answer(self) -> None:
        articles = [node for node in self.root.find_all("article") if node.find_all(cls="predict")]
        self.assertTrue(articles)
        for article in articles:
            with self.subTest(article=article.id):
                found = roles(article)
                self.assertIn("answer", found)
                self.assertLess(found.index("predict"), found.index("answer"))
                if "verify" in found:
                    self.assertLess(found.index("verify"), found.index("answer"))
                self.assertNotIn("Resultado esperado", visible_text(article))

    def test_experiments_follow_predict_test_record_reveal(self) -> None:
        self.assertEqual([node.id for node in self.chapters["ex2"].find_all("article", "experiment")], EX2_EXPERIMENTS)
        for experiment in self.root.find_all("article", "experiment"):
            with self.subTest(experiment=experiment.id):
                self.assertEqual([role for role in roles(experiment) if role in EXPERIMENT_FLOW], EXPERIMENT_FLOW)

    def test_version_comes_from_the_contract(self) -> None:
        self.assertEqual(self.root.find_all("title")[0].text(), CONTRACT["title"])
        footer = self.root.find_all("footer")[0].text()
        self.assertIn(f"versão {CONTRACT['version']}", footer)
        self.assertNotIn("piloto", self.root.text().lower())

    def test_diagrams_are_accessible(self) -> None:
        svgs = [node for node in self.root.find_all("svg") if not any(a.tag == "svg" for a in node.ancestors())]
        self.assertGreaterEqual(len(svgs), 2)
        for svg in svgs:
            with self.subTest(svg=svg.attrs.get("aria-labelledby")):
                self.assertEqual(svg.attrs.get("role"), "img")
                labelled = svg.attrs.get("aria-labelledby", "").split()
                self.assertTrue(labelled or svg.attrs.get("aria-label"))
                inner = {node.id: node for node in svg.walk() if node.id}
                for ref in labelled:
                    self.assertIn(ref, inner)
                    self.assertTrue(inner[ref].text().strip())

    def test_copy_button_copies_only_the_code(self) -> None:
        blocks = [node for node in self.root.walk() if node.tag == "pre" and "code" in node.attrs.get("class", "").split()]
        self.assertGreater(len(blocks), 0)
        for pre in blocks:
            self.assertEqual([child.tag for child in pre.element_children()], ["code"])
        js = "\n".join(node.text() for node in self.root.find_all("script"))
        self.assertNotIn("pre.innerText", js)
        self.assertIn('pre.querySelector("code")', js)

    def test_theme_switch_offers_auto_light_dark_and_prints_light(self) -> None:
        switches = [node for node in self.root.walk() if "theme-switch" in node.attrs.get("class", "").split()]
        self.assertEqual(len(switches), 1)
        buttons = [node for node in switches[0].walk() if node.tag == "button"]
        self.assertEqual([b.attrs.get("data-theme-choice") for b in buttons], ["auto", "light", "dark"])
        for button in buttons:
            self.assertEqual(button.attrs.get("type"), "button")
            self.assertIn("aria-pressed", button.attrs)
        head_js = "\n".join(node.text() for node in self.root.find_all("script"))
        self.assertIn('"fwlab:v3:theme"', head_js)
        css = "\n".join(node.text() for node in self.root.find_all("style"))
        self.assertNotIn("prefers-color-scheme: dark) {\n  :root", css)
        self.assertRegex(css, r"@media screen \{\s*html\[data-theme=\"dark\"\]")
        print_block = css[css.index("@media print"):]
        self.assertIn(".theme-switch", print_block)


class TroubleshootingToolsTests(unittest.TestCase):
    """Flow trace, change tracking, métricas de saúde e playbook (pós-análise dos vídeos, 06/10)."""

    FLOW = CONTRACT["diagnostics"]["flowTrace"]
    root: Node
    chapters: dict[str, Node]

    @classmethod
    def setUpClass(cls) -> None:
        cls.root = parse(DOCS.read_text(encoding="utf-8"))
        cls.chapters = {node.id: node for node in cls.root.find_all("section", "chapter")}

    def step(self, step_id: str) -> Node:
        found = [node for node in self.root.find_all("article") if node.id == step_id]
        self.assertEqual(len(found), 1, step_id)
        return found[0]

    def test_ex1_does_not_send_students_to_an_empty_flow_trace(self) -> None:
        diag = self.step("ex1-1")
        text = " ".join(diag.text().split())
        self.assertNotIn("como DNS, flow trace ou agregações", text)
        self.assertIn(f"Não marque agora a categoria de flow trace ({self.FLOW['category']})", text)
        self.assertIn("2.3", text)

    def test_flow_trace_bonus_registers_enables_queries_and_undoes(self) -> None:
        bonus = self.step("ex2-3")
        text = bonus.text()
        for needed in (
            f"az feature register --namespace {self.FLOW['namespace']} --name {self.FLOW['feature']}",
            f"az feature unregister --namespace {self.FLOW['namespace']} --name {self.FLOW['feature']}",
            '"category":"AZFWFlowTrace","enabled":true',
            "Enable TCP Connection Logging",
            "queries/ex2-flow-trace.kql",
            "L3/L4",
        ):
            self.assertIn(needed, text)
        ids = [node.id for node in self.chapters["ex2"].element_children()]
        self.assertEqual(ids.index("ex2-3"), ids.index("ex2-2") + 1, "o bônus vem depois de 2.2 e antes do C2")

    def test_flow_trace_query_reads_the_flow_trace_table(self) -> None:
        query = (QUERIES / "ex2-flow-trace.kql").read_text(encoding="utf-8")
        self.assertRegex(query, r"(?m)^AZFWFlowTrace$")
        self.assertIn("Flag", query)
        self.assertFalse((QUERIES / "ref-flow-trace.kql").exists())
        multi = (QUERIES / "ref-rastreio-fluxo.kql").read_text(encoding="utf-8")
        self.assertNotRegex(multi, r"(?m)^\s*AZFWFlowTrace\b")
        self.assertIn("Não é o log Flow trace", multi)

    def test_change_tracking_runs_in_resource_graph(self) -> None:
        step = self.step("ex3-6")
        text = step.text()
        self.assertIn("Resource Graph Explorer", text)
        self.assertIn("preview", text)
        self.assertIn("queries/ex3-change-tracking.kql", text)
        query = (QUERIES / "ex3-change-tracking.kql").read_text(encoding="utf-8")
        self.assertRegex(query, r"(?m)^networkresourcechanges$")
        self.assertIn("microsoft.network/firewallpolicies/rulecollectiongroups", query)
        self.assertIn(f'resourceGroup =~ "{CONTRACT["names"]["rg"]}"', query)

    def test_health_latency_and_capacity_step(self) -> None:
        text = self.step("ex5-5").text()
        for metric in ("FirewallHealth", "FirewallLatencyPng", "ObservedCapacity", "Latency Probe", "Reason"):
            self.assertIn(metric, text)
        self.assertIn("do próprio firewall", text)
        metrics = (QUERIES / "ex5-metricas.kql").read_text(encoding="utf-8")
        for metric in ("FirewallLatencyPng", "ObservedCapacity"):
            self.assertIn(f'"{metric}"', metrics)

    def test_troubleshooting_playbook_comes_first_and_links_resolve(self) -> None:
        chapter = self.chapters["troubleshooting"]
        steps = chapter.find_all("article", "step")
        self.assertEqual(steps[0].id, "ts-playbook")
        hrefs = {node.attrs.get("href") for node in steps[0].find_all("a")}
        self.assertTrue({"#ex2-3", "#ex3-6", "#kql-reference", "#arquitetura-rotas"} <= hrefs)
        self.assertIn("Top flows", steps[0].text())


class MarkdownLinkTests(unittest.TestCase):
    LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
    FENCE = re.compile(r"^```.*?^```", re.MULTILINE | re.DOTALL)

    def test_relative_links_resolve(self) -> None:
        guide_ids = {node.id for node in parse(DOCS.read_text(encoding="utf-8")).walk() if node.id}
        for doc in MARKDOWN_DOCS:
            path = ROOT / doc
            self.assertTrue(path.is_file(), doc)
            text = self.FENCE.sub("", path.read_text(encoding="utf-8"))
            for target in self.LINK.findall(text):
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                with self.subTest(doc=doc, target=target):
                    file_part, _, anchor = target.partition("#")
                    resolved = (path.parent / file_part).resolve()
                    self.assertTrue(resolved.exists())
                    if anchor and resolved == DOCS.resolve():
                        self.assertIn(anchor, guide_ids)


if __name__ == "__main__":
    unittest.main()
