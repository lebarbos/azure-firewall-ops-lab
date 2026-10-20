"""Consistência do lab.contract.json com Bicep, scripts, queries e documentação.

O contrato é a fonte única de nomes, endereços e prioridades. Estes testes
garantem que ele é coerente por dentro, que os números sustentam a lição de
cada experimento e que nenhum consumidor diverge dele.
"""

from __future__ import annotations

import collections
import fnmatch
import ipaddress
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((ROOT / "lab.contract.json").read_text(encoding="utf-8"))
NAMES = CONTRACT["names"]
NETWORK = CONTRACT["network"]
RCG = CONTRACT["rcg"]
RC = CONTRACT["rc"]
RULES = CONTRACT["rules"]
TARGETS = CONTRACT["targets"]

PRIORITY_MIN, PRIORITY_MAX = 100, 65000
ACTIONS_BY_TYPE = {"DNAT": {"DNAT"}, "Network": {"Allow", "Deny"}, "Application": {"Allow", "Deny"}}
POLICIES = {"polNs", "polEw", "polParent"}
EXPECTED_OUTPUTS = [
    "resourceGroupName", "location", "fwNsName", "fwNsPrivateIp", "fwNsPublicIp",
    "fwEwName", "fwEwPrivateIp", "polNsId", "polEwId", "lawId", "lawCustomerId",
    "vhubId", "vmAName", "vmBName",
]
# 443 é a porta da regra temporária allow-https-any (E3); as demais vêm de targets.
HTTPS_PORT = 443
SCANNED_GLOBS = (
    "README.md", "NOTICE.md", "guide/README.md",
    "scripts/**/*.sh", "queries/*.kql", "infra/**/*.bicep", "infra/**/*.bicepparam",
    "guest/*.ps1", "guide/src/**/*.html", "guide/src/**/*.css", "guide/src/**/*.js",
    "guide/src/**/*.svg", ".github/workflows/*.yml", "tests/fixtures/*.sh",
)
KQL_GLOBS = ("queries/*.kql", "scripts/**/*.sh", "guide/src/*.html", "README.md")

FWLAB_TOKEN = re.compile(r"(?<![\w-])(?:[a-z0-9]+-)*fwlab(?:-[a-z0-9]+)*(?![\w-])")
RCG_TOKEN = re.compile(r"(?<![\w-])rcg-[a-z0-9]+(?:-[a-z0-9]+)*(?![\w-])")
RC_TOKEN = re.compile(r"(?<![\w-])(?:app|net|dnat)-(?:infra|wl|baseline|corp|tls)(?:-[a-z0-9]+)*(?![\w-])")
RULE_TOKEN = re.compile(r"(?<![\w-])(?:allow|deny|dnat)-[a-z0-9]+(?:-[a-z0-9]+)*(?![\w-])")
MKTEMP_TEMPLATE = re.compile(r"[\w.-]*X{6,}[\w.]*")
PATH_STEP = re.compile(r"\.([A-Za-z_][A-Za-z0-9_]*)|\[(\d+)\]")
QUOTE = r"""(?:["']|&quot;|&#39;|&#x27;)"""
PORT_COLUMN = r"\b(?:DestinationPort|SourcePort|TranslatedPort)"
KQL_TYPE_ERRORS = {
    "porta (int) comparada com string": re.compile(
        PORT_COLUMN + r"\s*(?:==|!=|=~|!~|!?in~?|!?has|!?contains|!?startswith)\s*\(?\s*" + QUOTE
    ),
    "SignatureId (string) comparado com número": re.compile(
        r"\bSignatureId\s*(?:==|!=|!?in|[<>]=?)\s*\(?\s*(?:\d|\$\()"
    ),
    "IsTlsInspected (bool) comparado com string": re.compile(
        r"\bIsTlsInspected\s*(?:==|!=|=~|!~)\s*" + QUOTE
    ),
}
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?![\w.])")
PORT_COMPARISON = re.compile(PORT_COLUMN + r"\s*(?:==|!=|!?in)\s*\(?\s*([0-9][0-9,\s]*)\)?")


def leaves(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from leaves(item)
    elif isinstance(value, list):
        for item in value:
            yield from leaves(item)
    else:
        yield value


def resolve(path: str):
    node, pos = CONTRACT, 0
    while pos < len(path):
        step = PATH_STEP.match(path, pos)
        if not step:
            raise KeyError(path)
        key, index = step.groups()
        node = node[key] if key is not None else node[int(index)]
        pos = step.end()
    return node


def files(*patterns: str) -> list[Path]:
    found: list[Path] = []
    for pattern in patterns:
        for path in sorted(ROOT.glob(pattern)):
            if path.is_file() and path not in found:
                found.append(path)
    return found


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def bicep_code(text: str) -> str:
    """Remove comentários do Bicep sem tocar no conteúdo das strings."""
    out: list[str] = []
    i, size = 0, len(text)
    while i < size:
        if text.startswith("'''", i):
            end = text.find("'''", i + 3)
            end = size if end < 0 else end + 3
            out.append(text[i:end])
            i = end
        elif text[i] == "'":
            end = i + 1
            while end < size and text[end] != "'":
                end += 2 if text[end] == "\\" else 1
            out.append(text[i:end + 1])
            i = end + 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = size if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = size if end < 0 else end + 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def rc_of(key: str) -> dict:
    return RC[key]


def network(key: str) -> ipaddress.IPv4Network:
    return ipaddress.ip_network(NETWORK[key])


class ContractStructureTests(unittest.TestCase):
    def test_rcg_points_to_known_policy_with_valid_priority(self) -> None:
        for key, rcg in RCG.items():
            with self.subTest(rcg=key):
                self.assertIn(rcg["policy"], POLICIES)
                for field in ("priority", "e2Priority"):
                    if field in rcg:
                        self.assertGreaterEqual(rcg[field], PRIORITY_MIN)
                        self.assertLessEqual(rcg[field], PRIORITY_MAX)

    def test_rcg_priorities_and_names_unique_per_policy(self) -> None:
        states = {"base": {}, "E2": {key: rcg["e2Priority"] for key, rcg in RCG.items() if "e2Priority" in rcg}}
        for state, overrides in states.items():
            by_policy: dict[str, list[int]] = collections.defaultdict(list)
            for key, rcg in RCG.items():
                by_policy[rcg["policy"]].append(overrides.get(key, rcg["priority"]))
            for policy, priorities in by_policy.items():
                with self.subTest(state=state, policy=policy):
                    self.assertEqual(len(priorities), len(set(priorities)), priorities)
        names: dict[str, list[str]] = collections.defaultdict(list)
        for rcg in RCG.values():
            names[rcg["policy"]].append(rcg["name"])
        for policy, values in names.items():
            with self.subTest(policy=policy):
                self.assertEqual(len(values), len(set(values)), values)

    def test_rc_type_action_and_priority_are_coherent(self) -> None:
        for key, rc in RC.items():
            with self.subTest(rc=key):
                self.assertIn(rc["rcg"], RCG)
                self.assertIn(rc["type"], ACTIONS_BY_TYPE)
                self.assertIn(rc["action"], ACTIONS_BY_TYPE[rc["type"]])
                self.assertGreaterEqual(rc["priority"], PRIORITY_MIN)
                self.assertLessEqual(rc["priority"], PRIORITY_MAX)

    def test_rc_priorities_and_names_unique_per_rcg(self) -> None:
        by_rcg: dict[str, list[dict]] = collections.defaultdict(list)
        for rc in RC.values():
            by_rcg[rc["rcg"]].append(rc)
        for rcg, collections_in_group in by_rcg.items():
            with self.subTest(rcg=rcg):
                priorities = [rc["priority"] for rc in collections_in_group]
                names = [rc["name"] for rc in collections_in_group]
                self.assertEqual(len(priorities), len(set(priorities)), priorities)
                self.assertEqual(len(names), len(set(names)), names)

    def test_resource_names_are_not_reused_by_mistake(self) -> None:
        by_value: dict[str, list[str]] = collections.defaultdict(list)
        for key, value in NAMES.items():
            by_value[value].append(key)
        repeated = {value: keys for value, keys in by_value.items() if len(keys) > 1}
        self.assertEqual(repeated, {CONTRACT["prefix"]: ["agShort", "deploymentPrefix"]})

    def test_checkpoints_match_checkpoint_script(self) -> None:
        script = (ROOT / "scripts" / "checkpoint.sh").read_text(encoding="utf-8")
        labels = re.findall(r"^\s+(C[0-9X])\)\s*$", script, re.M)
        self.assertEqual(labels, CONTRACT["checkpoints"])


class ExperimentInvariantTests(unittest.TestCase):
    """Cada lição depende de uma relação entre números; mudar o contrato não pode quebrá-la."""

    def test_ex1_baseline_allows_microsoft_and_not_bing(self) -> None:
        pattern = TARGETS["baselineFqdn"]
        self.assertTrue(fnmatch.fnmatch(TARGETS["learn"], pattern))
        self.assertTrue(fnmatch.fnmatch(TARGETS["allowedProbe"], pattern))
        self.assertFalse(fnmatch.fnmatch(TARGETS["bing"], pattern))
        self.assertEqual((RCG["baselineNs"]["policy"], RCG["baselineEw"]["policy"]), ("polNs", "polEw"))
        self.assertEqual((rc_of("appBaseline")["rcg"], rc_of("appBaseline")["type"], rc_of("appBaseline")["action"]),
                         ("baselineNs", "Application", "Allow"))
        self.assertEqual((rc_of("netBaselineEw")["rcg"], rc_of("netBaselineEw")["type"], rc_of("netBaselineEw")["action"]),
                         ("baselineEw", "Network", "Allow"))

    def test_e1_workload_deny_is_evaluated_before_baseline(self) -> None:
        self.assertLess(RCG["wlA"]["priority"], RCG["baselineNs"]["priority"])
        self.assertEqual((rc_of("appWlA")["rcg"], rc_of("appWlA")["type"], rc_of("appWlA")["action"]),
                         ("wlA", "Application", "Deny"))

    def test_e2_rcg_decides_before_rc_number(self) -> None:
        allow, deny = rc_of("appWlBAllow"), rc_of("appWlA")
        self.assertEqual((allow["rcg"], allow["type"], allow["action"]), ("wlB", "Application", "Allow"))
        self.assertEqual((deny["rcg"], deny["type"], deny["action"]), ("wlA", "Application", "Deny"))
        self.assertLess(allow["priority"], deny["priority"], "a pegadinha exige RC do Allow com número melhor")
        self.assertLess(RCG["wlA"]["priority"], RCG["wlB"]["priority"], "A continua negado antes da troca")
        self.assertLess(RCG["wlB"]["e2Priority"], RCG["wlA"]["priority"], "A passa depois da troca")

    def test_e3_network_type_beats_application_deny_in_better_rcg(self) -> None:
        # A lição do slide: o tipo vence a prioridade do RCG. O Deny está no RCG de número melhor.
        allow, deny = rc_of("netWlBTemp"), rc_of("appWlA")
        self.assertEqual((allow["rcg"], allow["type"], allow["action"]), ("wlB", "Network", "Allow"))
        self.assertEqual((deny["rcg"], deny["type"], deny["action"]), ("wlA", "Application", "Deny"))
        self.assertLess(RCG[deny["rcg"]]["priority"], RCG[allow["rcg"]]["priority"], "o número do RCG sugere o Deny; o tipo decide")

    def test_e4_rc_number_breaks_the_tie_inside_the_rcg(self) -> None:
        allow, deny = rc_of("appWlBAllow"), rc_of("appWlBDeny")
        self.assertEqual((allow["rcg"], allow["type"], allow["action"]), ("wlB", "Application", "Allow"))
        self.assertEqual((deny["rcg"], deny["type"], deny["action"]), ("wlB", "Application", "Deny"))
        self.assertLess(allow["priority"], deny["priority"], "antes da troca, o Allow decide para B")
        self.assertLess(deny["e4Priority"], allow["priority"], "depois da troca, o Deny decide para B")

    def test_every_rcg_is_accepted_by_the_portal(self) -> None:
        # Evidência do piloto (06/10): o Portal recusa, dentro de um mesmo RCG, números fora da ordem
        # DNAT < Network < Application ("Invalid rule priority"). A API aceita; o lab precisa funcionar nos dois.
        # Inclui as prioridades temporárias dos experimentos (e4Priority).
        order = {"DNAT": 0, "Network": 1, "Application": 2}
        variants = [{}]
        for key, rc in CONTRACT["rc"].items():
            if "e4Priority" in rc:
                variants.append({key: rc["e4Priority"]})
        for variant in variants:
            by_rcg: dict[str, list[tuple[str, str, int]]] = {}
            for key, rc in CONTRACT["rc"].items():
                by_rcg.setdefault(rc["rcg"], []).append((rc["name"], rc["type"], variant.get(key, rc["priority"])))
            for rcg, collections in by_rcg.items():
                with self.subTest(rcg=rcg, variant=variant):
                    priorities = [prio for _, _, prio in collections]
                    self.assertEqual(len(priorities), len(set(priorities)), "prioridade de RC repetida no RCG")
                    ranked = sorted(collections, key=lambda rc: rc[2])
                    types = [order[kind] for _, kind, _ in ranked]
                    self.assertEqual(types, sorted(types), ranked)

    def test_ex3_parent_wins_with_worse_number(self) -> None:
        corp = RCG["corp"]
        self.assertEqual(corp["policy"], "polParent")
        children = [value for rcg in RCG.values() if rcg["policy"] != "polParent"
                    for field, value in rcg.items() if field in ("priority", "e2Priority")]
        self.assertGreater(corp["priority"], max(children))
        guardrail, corp_allow = rc_of("netCorpGuardrail"), rc_of("appCorp")
        self.assertEqual((guardrail["rcg"], guardrail["type"], guardrail["action"]), ("corp", "Network", "Deny"))
        self.assertEqual((corp_allow["rcg"], corp_allow["type"], corp_allow["action"]), ("corp", "Application", "Allow"))

    def test_ex5_loop_crosses_alert_threshold(self) -> None:
        alert = CONTRACT["alerts"]["appDeny"]
        self.assertGreater(TARGETS["denyLoopCount"], alert["threshold"])
        self.assertEqual(alert["target"], "fwNs")


class NetworkTests(unittest.TestCase):
    def test_subnets_inside_their_vnets(self) -> None:
        for subnet, vnet in (("snetA", "vnetA"), ("snetB", "vnetB"), ("snetFw", "vnetNs"), ("snetBastion", "vnetNs")):
            with self.subTest(subnet=subnet):
                self.assertTrue(network(subnet).subnet_of(network(vnet)))
        self.assertFalse(network("snetFw").overlaps(network("snetBastion")))

    def test_vm_ips_are_usable_hosts(self) -> None:
        for ip_key, subnet_key in (("vmAIp", "snetA"), ("vmBIp", "snetB")):
            with self.subTest(ip=ip_key):
                ip, subnet = ipaddress.ip_address(NETWORK[ip_key]), network(subnet_key)
                self.assertIn(ip, subnet)
                self.assertGreaterEqual(int(ip) - int(subnet.network_address), 4, "Azure reserva os 4 primeiros")
                self.assertNotEqual(ip, subnet.broadcast_address)

    def test_address_spaces_do_not_overlap(self) -> None:
        keys = ["vhub", "vnetA", "vnetB", "vnetNs"]
        for index, left in enumerate(keys):
            for right in keys[index + 1:]:
                with self.subTest(pair=(left, right)):
                    self.assertFalse(network(left).overlaps(network(right)))

    def test_routing_intent_covers_spokes_and_peering_stays_more_specific(self) -> None:
        private = [ipaddress.ip_network(cidr) for cidr in NETWORK["privateRanges"]]
        for key in ("vhub", "vnetA", "vnetB", "vnetNs"):
            with self.subTest(prefix=key):
                covering = [cidr for cidr in private if network(key).subnet_of(cidr)]
                self.assertTrue(covering)
                self.assertGreater(network(key).prefixlen, max(cidr.prefixlen for cidr in covering))

    def test_subnet_sizes_meet_service_minimums(self) -> None:
        self.assertEqual(network("snetFw").prefixlen, 26)
        self.assertLessEqual(network("snetBastion").prefixlen, 26)
        self.assertLessEqual(network("vhub").prefixlen, 24)

    def test_ip_group_cidrs_match_subnets(self) -> None:
        groups = CONTRACT["ipGroupCidrs"]
        self.assertEqual(groups["ipgWlA"], [NETWORK["snetA"]])
        self.assertEqual(groups["ipgWlB"], [NETWORK["snetB"]])
        self.assertEqual(sorted(groups["ipgSpokes"]), sorted([NETWORK["snetA"], NETWORK["snetB"]]))


class BicepTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sources = {rel(path): path.read_text(encoding="utf-8") for path in files("infra/**/*.bicep")}
        cls.code = {name: bicep_code(text) for name, text in cls.sources.items()}

    def test_outputs_match_brief(self) -> None:
        outputs = re.findall(r"^output\s+(\w+)\s", self.code["infra/main.bicep"], re.M)
        self.assertCountEqual(outputs, EXPECTED_OUTPUTS)

    def test_contract_references_resolve(self) -> None:
        for name, code in self.code.items():
            for match in re.finditer(r"(?<![\w.])contract((?:\.[A-Za-z_]\w*)+)", code):
                with self.subTest(file=name, reference=match.group(0)):
                    try:
                        resolve(match.group(1))
                    except (KeyError, IndexError, TypeError):
                        self.fail(f"{name}:{line_of(code, match.start())}: {match.group(0)} não existe no contrato")

    def test_bicep_reads_names_and_addresses_from_contract(self) -> None:
        literals = set(NAMES.values()) | set(leaves(NETWORK)) | set(RULES.values())
        literals |= {rcg["name"] for rcg in RCG.values()} | {rc["name"] for rc in RC.values()}
        for name, code in self.code.items():
            with self.subTest(file=name):
                tokens = FWLAB_TOKEN.findall(code)
                quoted = sorted(value for value in literals if f"'{value}'" in code)
                self.assertEqual(tokens, [], "nome com o prefixo do lab escrito à mão")
                self.assertEqual(quoted, [], "valor do contrato escrito à mão")

    def test_hub_firewall_leaves_threat_intel_to_the_policy(self) -> None:
        vwan = (ROOT / "infra" / "modules" / "vwan.bicep").read_text(encoding="utf-8")
        firewall = vwan[vwan.index("resource firewall "):]
        firewall = firewall[: firewall.index("\n}\n")]
        self.assertIn("AZFW_Hub", firewall)
        self.assertNotRegex(firewall, r"(?m)^\s*threatIntelMode:", "AZFW_Hub recusa threatIntelMode no recurso do firewall")

    def test_vm_size_defaults_match_contract(self) -> None:
        texts = list(self.code.values()) + [(ROOT / "infra" / "main.bicepparam").read_text(encoding="utf-8")]
        sizes = {size for text in texts for size in re.findall(r"'(Standard_B\w+)'", text)}
        self.assertEqual(sizes, {CONTRACT["vmSizes"][0]})

    def test_bicepparam_environment_is_set_by_deploy(self) -> None:
        params = (ROOT / "infra" / "main.bicepparam").read_text(encoding="utf-8")
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        variables = re.findall(r"readEnvironmentVariable\('([A-Z_]+)'", params)
        self.assertIn("LAB_ADMIN_PASSWORD", variables)
        for variable in variables:
            with self.subTest(variable=variable):
                self.assertRegex(deploy, rf"(?m)^\s*(?:export\s+)?{variable}=")


class ScriptContractTests(unittest.TestCase):
    def test_contract_accessors_resolve(self) -> None:
        checks = 0
        for path in files("scripts/**/*.sh"):
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"""contract_(get|array)\s+(?:'([^']+)'|"([^"$]+)")""", text):
                kind, path_expr = match.group(1), match.group(2) or match.group(3)
                where = f"{rel(path)}:{line_of(text, match.start())}"
                with self.subTest(at=where, path=path_expr):
                    try:
                        value = resolve(path_expr)
                    except (KeyError, IndexError, TypeError):
                        self.fail(f"{where}: {path_expr} não existe no contrato")
                    if kind == "array":
                        self.assertIsInstance(value, list)
                    else:
                        self.assertNotIsInstance(value, (dict, list))
                checks += 1
            for kind, section in (("name", NAMES), ("tag", CONTRACT["tags"])):
                for match in re.finditer(rf"contract_{kind}\s+([A-Za-z]\w*)", text):
                    with self.subTest(at=f"{rel(path)}:{line_of(text, match.start())}", key=match.group(1)):
                        self.assertIn(match.group(1), section)
                    checks += 1
        self.assertGreater(checks, 50)


class QueryConsistencyTests(unittest.TestCase):
    def test_kql_column_types(self) -> None:
        problems = []
        for path in files(*KQL_GLOBS):
            text = path.read_text(encoding="utf-8")
            for label, pattern in KQL_TYPE_ERRORS.items():
                for match in pattern.finditer(text):
                    problems.append(f"{rel(path)}:{line_of(text, match.start())}: {label}: {match.group(0)}")
        self.assertEqual(problems, [])

    def test_query_ip_literals_come_from_contract(self) -> None:
        allowed = set(leaves(NETWORK)) | {"0.0.0.0/0"}
        problems = []
        for path in files("queries/*.kql", "scripts/checkpoint.sh"):
            text = path.read_text(encoding="utf-8")
            for match in IPV4.finditer(text):
                if match.group(0) not in allowed:
                    problems.append(f"{rel(path)}:{line_of(text, match.start())}: {match.group(0)}")
        self.assertEqual(problems, [])

    def test_query_ports_come_from_contract(self) -> None:
        allowed = {TARGETS[key] for key in ("httpPort", "rdpPort")} | {HTTPS_PORT}
        seen = set()
        for path in files("queries/*.kql"):
            text = path.read_text(encoding="utf-8")
            for match in PORT_COMPARISON.finditer(text):
                for port in re.findall(r"\d+", match.group(1)):
                    seen.add(int(port))
                    with self.subTest(at=f"{rel(path)}:{line_of(text, match.start())}", port=port):
                        self.assertIn(int(port), allowed)
        self.assertTrue({TARGETS["rdpPort"], HTTPS_PORT} <= seen)

    def test_idps_signature_literal_matches_contract(self) -> None:
        found = []
        for path in files("queries/*.kql"):
            found += re.findall(r"""\bSignatureId\s*==\s*["'](\d+)["']""", path.read_text(encoding="utf-8"))
        self.assertTrue(found)
        self.assertEqual(set(found), {str(TARGETS["idpsSignatureId"])})

    def test_rule_hits_reference_matches_contract(self) -> None:
        text = (ROOT / "queries" / "ref-rule-hits.kql").read_text(encoding="utf-8")
        rows = re.findall(r'^\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)"', text, re.M)
        policy_key = {NAMES[key]: key for key in POLICIES}
        rc_by_name = {rc["name"]: (key, rc) for key, rc in RC.items()}
        for policy, rcg_name, rc_name, rule in rows:
            with self.subTest(row=(policy, rcg_name, rc_name, rule)):
                self.assertIn(policy, policy_key)
                self.assertIn(rc_name, rc_by_name)
                rcg_key = rc_by_name[rc_name][1]["rcg"]
                self.assertEqual(RCG[rcg_key]["name"], rcg_name)
                self.assertEqual(RCG[rcg_key]["policy"], policy_key[policy])
                self.assertIn(rule, RULES.values())
        self.assertEqual({row[2] for row in rows}, {rc["name"] for rc in RC.values()})
        self.assertEqual({row[3] for row in rows}, set(RULES.values()))


class NameTokenTests(unittest.TestCase):
    def test_lab_names_in_files_exist_in_contract(self) -> None:
        known = {value for value in leaves(CONTRACT) if isinstance(value, str)}
        checks = {
            "recurso": (FWLAB_TOKEN, known),
            "RCG": (RCG_TOKEN, {rcg["name"] for rcg in RCG.values()}),
            "RC": (RC_TOKEN, {rc["name"] for rc in RC.values()}),
            "regra": (RULE_TOKEN, set(RULES.values()) | {rc["name"] for rc in RC.values()}),
        }
        problems = []
        for path in files(*SCANNED_GLOBS):
            text = MKTEMP_TEMPLATE.sub(lambda match: " " * len(match.group(0)), path.read_text(encoding="utf-8"))
            for label, (pattern, allowed) in checks.items():
                for match in pattern.finditer(text):
                    if match.group(0) not in allowed:
                        problems.append(f"{rel(path)}:{line_of(text, match.start())}: {label} desconhecido {match.group(0)}")
        self.assertEqual(problems, [])
        for doc in ("README.md", "NOTICE.md", "guide/README.md"):
            self.assertTrue((ROOT / doc).is_file(), f"{doc} precisa existir para ser verificado")


if __name__ == "__main__":
    unittest.main()
