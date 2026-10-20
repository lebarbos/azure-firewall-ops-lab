"""Testes offline dos scripts Bash com um Azure CLI falso (tests/fixtures/fake-az.sh).

Cada teste roda numa cópia temporária de scripts/ + lab.contract.json, então nada
é gravado na raiz do repositório (.lab/, arquivos temporários).
"""

import datetime as dt
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAKE_AZ = ROOT / "tests" / "fixtures" / "fake-az.sh"
CONTRACT = json.loads((ROOT / "lab.contract.json").read_text(encoding="utf-8"))
NAMES = CONTRACT["names"]


def find_bash5():
    for candidate in (shutil.which("bash"), "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
        if not candidate or not os.path.exists(candidate):
            continue
        try:
            probe = subprocess.run(
                [candidate, "-c", "echo ${BASH_VERSINFO[0]}"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        major = probe.stdout.strip()
        if probe.returncode == 0 and major.isdigit() and int(major) >= 5:
            return candidate
    return None


BASH5 = find_bash5()
HAS_JQ = shutil.which("jq") is not None


def strong_password():
    # Gerada a cada execução: nenhum literal com cara de senha entra no repositório.
    return "Fw" + secrets.token_hex(6) + "a9!"


@unittest.skipUnless(BASH5 and HAS_JQ, "requer bash 5+ e jq")
class FakeAzTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fwlab-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        shutil.copytree(ROOT / "scripts", self.repo / "scripts")
        shutil.copy2(ROOT / "lab.contract.json", self.repo / "lab.contract.json")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        shutil.copy2(FAKE_AZ, self.bin / "az")
        (self.bin / "az").chmod(0o755)
        self.state = self.tmp / "state"
        self.state.mkdir()

    def run_script(self, script, *args, stdin="", **env):
        environment = {k: v for k, v in os.environ.items() if not k.startswith(("LAB_", "FAKE_"))}
        environment.update({
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "FAKE_STATE": str(self.state),
            "FAKE_CONTRACT": str(self.repo / "lab.contract.json"),
            "FAKE_SCENARIO": "good",
            "TMPDIR": str(self.tmp),
        })
        environment.update(env)
        return subprocess.run(
            [BASH5, str(self.repo / "scripts" / script), *args],
            input=stdin, capture_output=True, text=True, timeout=180,
            env=environment, cwd=self.tmp, check=False,
        )

    def state_text(self, name):
        path = self.state / name
        return path.read_text(encoding="utf-8") if path.exists() else ""

    @staticmethod
    def failed_labels(output):
        return [line.split("❌", 1)[1].strip() for line in output.splitlines() if "❌" in line]


class DeployScriptTests(FakeAzTestCase):
    def deploy(self, *args, stdin, **env):
        base = {
            "FAKE_RG_EXISTS": "false",
            "LAB_REGION": "westus3",
            "LAB_VM_SIZE": CONTRACT["vmSizes"][0],
            "LAB_TRUSTED_LAUNCH": "true",
        }
        base.update(env)
        return self.run_script("deploy.sh", *args, stdin=stdin, **base)

    def test_password_reaches_az_exactly_and_never_argv_or_output(self):
        password = strong_password()
        before = dt.datetime.now(dt.timezone.utc).date()
        result = self.deploy(stdin=f"{password}\n{password}\n")
        after = dt.datetime.now(dt.timezone.utc).date()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Regressão: a senha já chegou ao az com "\n\n" na frente.
        self.assertEqual(self.state_text("password"), password)
        self.assertNotIn(password, self.state_text("argv.log"))
        self.assertNotIn(password, result.stdout + result.stderr)
        tomorrow = {(day + dt.timedelta(days=1)).isoformat() for day in (before, after)}
        self.assertIn(self.state_text("expires"), tomorrow)
        self.assertEqual(self.state_text("deploy-env").strip(), f"westus3|{CONTRACT['vmSizes'][0]}|true")

    def test_deployment_is_async_at_subscription_scope(self):
        password = strong_password()
        result = self.deploy(stdin=f"{password}\n{password}\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        create = [line for line in self.state_text("argv.log").splitlines() if line.startswith("deployment sub create")]
        self.assertEqual(len(create), 1)
        for fragment in ("--no-wait", "--parameters infra/main.bicepparam", "--location westus3",
                         f"--name {NAMES['deploymentPrefix']}-"):
            self.assertIn(fragment, create[0])
        self.assertFalse((self.repo / ".lab").exists(), "deploy.sh não deve gravar estado local")

    def test_existing_resource_group_requires_force(self):
        password = strong_password()
        refused = self.deploy(stdin=f"{password}\n{password}\n", FAKE_RG_EXISTS="true")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("já existe", refused.stderr)
        self.assertNotIn("deployment sub create", self.state_text("argv.log"))

        forced = self.deploy("--force", stdin=f"{password}\n{password}\n", FAKE_RG_EXISTS="true")
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertIn("deployment sub create", self.state_text("argv.log"))

    def test_az_error_on_resource_group_query_blocks_deploy(self):
        password = strong_password()
        result = self.deploy(stdin=f"{password}\n{password}\n", FAKE_FAIL="group exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("deployment sub create", self.state_text("argv.log"))

    def test_mismatched_passwords_are_rejected(self):
        result = self.deploy(stdin=f"{strong_password()}\n{strong_password()}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("não conferem", result.stderr)
        self.assertNotIn("deployment sub create", self.state_text("argv.log"))

    def test_weak_passwords_are_rejected_locally(self):
        user = CONTRACT["vm"]["adminUsername"]
        weak = {
            "curta": "Ab1!" + secrets.token_hex(2),
            "arroba inicial": "@" + strong_password(),
            "contém o usuário": user.capitalize() + "9!" + secrets.token_hex(4),
            "duas classes": secrets.token_hex(8).lower() + "abcd",
        }
        for reason, candidate in weak.items():
            with self.subTest(reason=reason):
                result = self.deploy(stdin=f"{candidate}\n{candidate}\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Senha rejeitada", result.stderr)
        self.assertNotIn("deployment sub create", self.state_text("argv.log"))

    def test_missing_region_points_to_preflight(self):
        result = self.run_script("deploy.sh", stdin="", FAKE_RG_EXISTS="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preflight", result.stderr)

    def test_failed_create_reports_without_leaking_password(self):
        password = strong_password()
        result = self.deploy(stdin=f"{password}\n{password}\n", FAKE_FAIL="deployment sub create")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Falha ao iniciar o deployment", result.stderr)
        self.assertNotIn(password, result.stdout + result.stderr)

    def test_explicit_environment_wins_over_preflight_file(self):
        lab = self.repo / ".lab"
        lab.mkdir()
        (lab / "env").write_text("LAB_REGION=centralus\nLAB_VM_SIZE=Standard_B2s\nLAB_TRUSTED_LAUNCH=false\n", encoding="utf-8")
        password = strong_password()
        result = self.run_script(
            "deploy.sh", stdin=f"{password}\n{password}\n",
            FAKE_RG_EXISTS="false", LAB_REGION="southcentralus",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state_text("deploy-env").strip(), "southcentralus|Standard_B2s|false")


class PreflightScriptTests(FakeAzTestCase):
    def test_picks_first_contract_region_and_writes_env_without_secrets(self):
        result = self.run_script("preflight.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        env_file = self.repo / ".lab" / "env"
        content = env_file.read_text(encoding="utf-8")
        self.assertIn(f"LAB_REGION={CONTRACT['regions'][0]}", content)
        self.assertIn(f"LAB_VM_SIZE={CONTRACT['vmSizes'][0]}", content)
        self.assertNotIn("PASSWORD", content.upper())
        self.assertEqual(env_file.stat().st_mode & 0o077, 0, "o env do preflight deve ser privado")

    def test_zone_only_restriction_does_not_block_non_zonal_vms(self):
        result = self.run_script("preflight.sh", FAKE_SKU_RESTRICTION="zone")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = (self.repo / ".lab" / "env").read_text(encoding="utf-8")
        self.assertIn(f"LAB_REGION={CONTRACT['regions'][0]}", env)
        self.assertIn(f"LAB_VM_SIZE={CONTRACT['vmSizes'][0]}", env)

    def test_region_restriction_reports_every_rejected_sku(self):
        result = self.run_script("preflight.sh", FAKE_SKU_RESTRICTION="location")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"LAB_REGION={CONTRACT['regions'][1]}", (self.repo / ".lab" / "env").read_text(encoding="utf-8"))
        output = result.stdout + result.stderr
        for sku in CONTRACT["vmSizes"]:
            self.assertIn(f"{sku}: restrita (NotAvailableForSubscription)", output)

    def test_ineligible_region_is_skipped_after_arm_validate(self):
        first, second = CONTRACT["regions"][0], CONTRACT["regions"][1]
        result = self.run_script("preflight.sh", FAKE_INELIGIBLE_REGIONS=first)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"LAB_REGION={second}", (self.repo / ".lab" / "env").read_text(encoding="utf-8"))
        self.assertIn("locationineligible", result.stdout + result.stderr)
        self.assertEqual(self.state_text("validated").split(), [first, second])
        self.assertFalse((self.state / "password").exists(), "o preflight não pode criar o deployment")

    def test_all_regions_ineligible_fails(self):
        result = self.run_script("preflight.sh", FAKE_INELIGIBLE_REGIONS=" ".join(CONTRACT["regions"]))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repo / ".lab" / "env").exists())

    def test_invalid_region_fails_with_clear_message(self):
        result = self.run_script("preflight.sh", LAB_REGION="marsnorth")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nenhuma combinação região × SKU", result.stderr)
        self.assertIn("marsnorth", result.stdout)
        self.assertFalse((self.repo / ".lab" / "env").exists())

    def test_existing_resource_group_region_wins(self):
        result = self.run_script("preflight.sh", FAKE_RG_EXISTS="true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("LAB_REGION=centralus", (self.repo / ".lab" / "env").read_text(encoding="utf-8"))
        self.assertNotIn("Microsoft.Compute/skus", self.state_text("argv.log"))

    def test_az_error_on_resource_group_query_stops_preflight(self):
        result = self.run_script("preflight.sh", FAKE_FAIL="group exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repo / ".lab" / "env").exists())


class CheckpointScriptTests(FakeAzTestCase):
    def checkpoint(self, name, scenario="good", **env):
        result = self.run_script("checkpoint.sh", name, FAKE_SCENARIO=scenario, **env)
        return result, result.stdout + result.stderr

    def test_good_environment_passes_every_checkpoint(self):
        for name in CONTRACT["checkpoints"]:
            with self.subTest(checkpoint=name):
                result, output = self.checkpoint(name)
                self.assertEqual(result.returncode, 0, output)
                self.assertNotIn("❌", output)
                self.assertNotIn("FAKE-AZ unhandled", output)

    def test_bad_environment_fails_every_checkpoint(self):
        for name in CONTRACT["checkpoints"]:
            with self.subTest(checkpoint=name):
                result, output = self.checkpoint(name, scenario="bad")
                self.assertNotEqual(result.returncode, 0, output)
                self.assertTrue(self.failed_labels(output), output)
                self.assertNotIn("FAKE-AZ unhandled", output)

    def test_c0_requires_active_private_route_to_hub_firewall(self):
        # A rota 10/8 só prova o E-W se estiver Active e apontar para o IP do FW do hub.
        _, output = self.checkpoint("C0", scenario="bad")
        self.assertEqual(self.failed_labels(output), ["Rotas efetivas da NIC A coerentes"])

    def test_az_failure_is_not_success(self):
        # Regressão: retry_az devolvia 0 para qualquer falha do az.
        _, output = self.checkpoint("C3", scenario="bad")
        self.assertIn("Policy pai existe", self.failed_labels(output))

    def test_c5_counts_only_the_app_deny_rule_and_accepts_resolved(self):
        _, good = self.checkpoint("C5")
        self.assertNotIn("❌", good)
        _, bad = self.checkpoint("C5", scenario="bad")
        self.assertEqual(self.failed_labels(bad), [f"{NAMES['alertAppDeny']} teve ≥ 1 disparo"])

    def test_c6_requires_idps_deny_mode(self):
        _, output = self.checkpoint("C6", scenario="bad")
        self.assertIn("IDPS em Alert and Deny", self.failed_labels(output))

    def test_c4_requires_policy_analytics_on_the_lab_workspace(self):
        _, output = self.checkpoint("C4", scenario="bad")
        self.assertIn("Policy Analytics habilitado na policy N-S", self.failed_labels(output))
        self.assertIn("KQL tem dados agregados do Policy Analytics", self.failed_labels(output))

    def test_kql_uses_correct_column_types(self):
        for name in ("C1", "C2", "C6"):
            self.checkpoint(name)
        kql = self.state_text("kql.log")
        signature = CONTRACT["targets"]["idpsSignatureId"]
        self.assertIn("union isfuzzy=true AZFWNetworkRule, AZFWApplicationRule", kql)
        self.assertNotRegex(kql, r"DestinationPort == ['\"]")
        self.assertIn(f"SignatureId == '{signature}'", kql)

    def test_cx_fails_closed_when_az_errors(self):
        result, output = self.checkpoint("CX", FAKE_FAIL="group exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"Resource group {NAMES['rg']} inexistente", self.failed_labels(output))

    def test_absence_checks_fail_closed_when_rcg_is_unreadable(self):
        unreadable = "network firewall policy rule-collection-group show"
        _, c2 = self.checkpoint("C2", FAKE_FAIL=unreadable)
        self.assertTrue(any(CONTRACT["rc"]["netWlBTemp"]["name"] in label for label in self.failed_labels(c2)), c2)
        self.assertTrue(any(CONTRACT["rc"]["appWlBDeny"]["name"] in label for label in self.failed_labels(c2)), c2)
        _, c3 = self.checkpoint("C3", FAKE_FAIL=unreadable)
        self.assertTrue(any(CONTRACT["rules"]["allowMicrosoft"] in label for label in self.failed_labels(c3)), c3)

    def test_removed_baseline_rcg_counts_as_absent(self):
        result, output = self.checkpoint("C3", FAKE_MISSING_RCG=CONTRACT["rcg"]["baselineNs"]["name"])
        self.assertEqual(result.returncode, 0, output)

    def test_transient_retry_does_not_corrupt_captured_json(self):
        result, output = self.checkpoint("C1", FAKE_TRANSIENT_ONCE="network ip-group show")
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("condição transitória", result.stderr)
        self.assertNotIn("condição transitória", result.stdout)

    def test_ip_groups_check_does_not_depend_on_list_output(self):
        # Piloto 06/10: a lista chegou ao jq como texto e o C1 falhou com os grupos criados.
        result, output = self.checkpoint("C1", FAKE_FAIL="network ip-group list")
        self.assertEqual(result.returncode, 0, output)

    def test_missing_ip_group_is_named(self):
        result, output = self.checkpoint("C1", "bad")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("3 IP Groups principais existem", self.failed_labels(output))
        self.assertIn(CONTRACT["names"]["ipgSpokes"], result.stderr)

    def test_unknown_checkpoint_is_rejected(self):
        result, output = self.checkpoint("C9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checkpoint inválido", output)


class CleanupScriptTests(FakeAzTestCase):
    def test_deletes_waits_and_sweeps(self):
        result = self.run_script("cleanup.sh", "--yes", FAKE_RG_EXISTS="true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = self.state_text("argv.log")
        self.assertIn(f"group delete --name {NAMES['rg']} --yes --no-wait", argv)
        self.assertIn("keyvault list-deleted", argv)
        self.assertIn("resource list --tag", argv)

    def test_keyvault_purge_finishes_after_the_resource_group_is_gone(self):
        # O cenário bad deixa um vault do lab em soft-delete (e um recurso sobrando, que reprova a varredura).
        self.run_script("cleanup.sh", "--yes", FAKE_SCENARIO="bad", FAKE_RG_EXISTS="true")
        calls = self.state_text("argv.log").splitlines()
        purges = [i for i, call in enumerate(calls) if call.startswith("keyvault purge")]
        self.assertEqual(len(purges), 1, calls)
        purge = calls[purges[0]]
        self.assertIn(f"--name {NAMES['kvPrefix']}abc --location {CONTRACT['regions'][0]}", purge)
        # Purge com --no-wait deixaria o CX logo em seguida ver o vault ainda em soft-delete.
        self.assertNotIn("--no-wait", purge)
        last_exists = max(i for i, call in enumerate(calls) if call.startswith("group exists"))
        self.assertGreater(purges[0], last_exists, "purge antes de confirmar a exclusão do RG")

    def test_resumes_a_deletion_already_in_progress(self):
        # O Cloud Shell encerra sessões sem interação após 20 min: o aluno reabre e roda o cleanup de novo, sem --yes.
        result = self.run_script("cleanup.sh", FAKE_RG_STATE="Deleting")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = self.state_text("argv.log")
        self.assertNotIn("group delete", argv)
        self.assertIn("retomando a espera", result.stdout)
        self.assertIn("keyvault list-deleted", argv)
        self.assertIn("resource list --tag", argv)

    def test_requires_typed_confirmation(self):
        result = self.run_script("cleanup.sh", stdin="nao\n", FAKE_RG_EXISTS="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("group delete", self.state_text("argv.log"))

    def test_leftover_tagged_resources_fail_the_cleanup(self):
        result = self.run_script("cleanup.sh", "--yes", FAKE_SCENARIO="bad", FAKE_RG_EXISTS="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ainda há recursos com a tag", result.stdout)

    def test_az_error_never_reports_resource_group_as_gone(self):
        result = self.run_script("cleanup.sh", "--yes", FAKE_FAIL="group exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("já não existe", result.stdout)
        self.assertNotIn("group delete", self.state_text("argv.log"))

    def test_az_error_while_polling_is_not_deletion(self):
        result = self.run_script("cleanup.sh", "--yes", FAKE_RG_EXISTS="true", FAKE_FAIL_AFTER_DELETE="group exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("group delete", self.state_text("argv.log"))
        self.assertNotIn("Resource group removido", result.stdout)


class CheckNeutralScriptTests(FakeAzTestCase):
    # Montado em partes: o próprio gate varre este arquivo e acusaria a atribuição escrita por inteiro.
    ASSIGN = "pass" + "word = "

    def setUp(self):
        super().setUp()
        self.copy = self.tmp / "copia"
        (self.copy / "tests").mkdir(parents=True)
        (self.copy / "README.md").write_text("Lab neutro.\n", encoding="utf-8")
        self.patterns = self.tmp / "patterns.txt"

    def neutral(self, *args, **env):
        env.setdefault("HOME", str(self.tmp))
        return self.run_script("check-neutral.sh", *args, **env)

    def test_original_license_copyright_exception_is_exact_and_auditable(self):
        copyright_line = (ROOT / "LICENSE").read_text(encoding="utf-8").splitlines()[2]
        self.assertEqual(
            hashlib.sha256(copyright_line.encode()).hexdigest(),
            "a0b0f2326787d57866f4a6a9677c2c3773ba4cd3cae2c9d0d64d21f27c95039c",
        )
        shutil.copy2(ROOT / "LICENSE", self.copy / "LICENSE")
        self.patterns.write_text("Copyright\n", encoding="utf-8")
        result = self.neutral(str(self.copy), FWLAB_NEUTRAL_PATTERNS=str(self.patterns))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("LICENSE:3: atribuição legal original permitida (16bfee8)", result.stdout)
        self.assertIn("nenhum achado", result.stdout)

    def test_copyright_exception_rejects_other_paths_lines_and_content(self):
        copyright_line = (ROOT / "LICENSE").read_text(encoding="utf-8").splitlines()[2]
        self.patterns.write_text("Copyright\n", encoding="utf-8")
        for path, number, content in (
            ("README.md", 3, copyright_line),
            ("nested/LICENSE", 3, copyright_line),
            ("LICENSE", 1, copyright_line),
            ("LICENSE", 4, copyright_line),
            ("LICENSE", 3, copyright_line.rstrip()),
            ("LICENSE", 3, copyright_line + "Contoso"),
            ("LICENSE", 3, copyright_line + ":"),
            ("LICENSE", 3, copyright_line + "\r"),
        ):
            with self.subTest(path=path, number=number, content=content):
                target = self.copy / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(("\n" * (number - 1) + content + "\n").encode())
                try:
                    result = self.neutral(str(self.copy), FWLAB_NEUTRAL_PATTERNS=str(self.patterns))
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(f"{path}:{number}: padrão de cliente:", result.stdout)
                    self.assertNotIn("nenhum achado", result.stdout)
                finally:
                    target.unlink()

    def test_copyright_exception_never_skips_secrets_in_license(self):
        copyright_line = (ROOT / "LICENSE").read_text(encoding="utf-8").splitlines()[2]
        self.patterns.write_text("Copyright\n", encoding="utf-8")
        candidates = (
            (self.ASSIGN + strong_password(), "password= com valor"),
            ("Account" + "Key=" + secrets.token_hex(16), "AccountKey em texto"),
            ("?" + "sig=" + secrets.token_hex(16), "token SAS em query string"),
            ("ghp_" + secrets.token_hex(20), "token GitHub"),
            ("-----BEGIN " + "PRIVATE KEY-----", "chave privada"),
            ("-".join(secrets.token_hex(n) for n in (4, 2, 2, 2, 6)), "GUID real"),
        )
        for candidate, reason in candidates:
            for separator, number in (("\n", 4), ("", 3)):
                with self.subTest(reason=reason, number=number):
                    (self.copy / "LICENSE").write_text(
                        "MIT License\n\n" + copyright_line + separator + candidate + "\n",
                        encoding="utf-8",
                    )
                    result = self.neutral(str(self.copy), FWLAB_NEUTRAL_PATTERNS=str(self.patterns))
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(f"LICENSE:{number}: {reason}", result.stdout)
                    self.assertNotIn("nenhum achado", result.stdout)

    def test_publication_copy_uses_the_same_allowlist(self):
        # A cópia de publicação fica fora do repositório de origem: os caminhos são relativos à raiz verificada.
        (self.copy / ".gitignore").write_text(".lab/\n", encoding="utf-8")
        (self.copy / "tests" / "test_scripts.py").write_text(f"        {self.ASSIGN}strong_password()\n", encoding="utf-8")
        result = self.neutral("--generic-only", str(self.copy))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nenhum achado", result.stdout)

    def test_literal_password_is_reported_even_in_an_allowlisted_file(self):
        lines = [f"        {self.ASSIGN}strong_password()", f'        {self.ASSIGN}"{strong_password()}"']
        (self.copy / "tests" / "test_scripts.py").write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = self.neutral("--generic-only", str(self.copy))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tests/test_scripts.py:2: password= com valor", result.stdout)
        self.assertNotIn("tests/test_scripts.py:1:", result.stdout)

    def test_unreadable_file_fails_the_gate(self):
        # Reproduz um grep morto pelo sistema (Killed: 9): arquivo não lido não pode contar como limpo.
        wrapper = self.tmp / "grep-bin"
        wrapper.mkdir()
        (wrapper / "grep").write_text(
            '#!/bin/sh\ncase "$*" in $KILL_WHEN) kill -9 $$ ;; esac\nexec "$REAL_GREP" "$@"\n',
            encoding="utf-8",
        )
        (wrapper / "grep").chmod(0o755)
        (self.copy / "victim.txt").write_text("conteúdo\n", encoding="utf-8")
        self.patterns.write_text("Contoso\n", encoding="utf-8")
        for case, kill_when, mode in (
            ("leitura do arquivo", "*victim*", "--generic-only"),
            ("padrão de cliente", "*-nE*victim*", "--full"),
        ):
            with self.subTest(case=case):
                args = [str(self.copy)] if mode == "--full" else [mode, str(self.copy)]
                result = self.neutral(
                    *args,
                    PATH=f"{wrapper}{os.pathsep}{os.environ.get('PATH', '')}", REAL_GREP=shutil.which("grep"),
                    KILL_WHEN=kill_when, FWLAB_NEUTRAL_PATTERNS=str(self.patterns),
                )
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("victim.txt: leitura falhou", result.stdout)
                self.assertNotIn("nenhum achado", result.stdout)

    @unittest.skipIf(os.geteuid() == 0, "root lê diretórios sem permissão")
    def test_unlistable_directory_fails_the_gate(self):
        private = self.copy / "privado"
        private.mkdir()
        (private / "nota.md").write_text("texto\n", encoding="utf-8")
        private.chmod(0)
        self.addCleanup(private.chmod, 0o755)
        result = self.neutral("--generic-only", str(self.copy))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Não foi possível listar", result.stdout)
        self.assertNotIn("nenhum achado", result.stdout)

    def test_missing_or_empty_path_is_not_a_pass(self):
        (self.tmp / "vazia").mkdir()
        for target, message in (("nao-existe", "Diretório não encontrado"), ("vazia", "Nenhum arquivo de texto verificado")):
            with self.subTest(target=target):
                result = self.neutral("--generic-only", str(self.tmp / target))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stdout)
                self.assertNotIn("nenhum achado", result.stdout)

    def test_pattern_list_must_exist_be_valid_and_not_be_empty(self):
        for case, content, message in (
            ("ausente", None, "Arquivo de padrões de cliente ausente"),
            ("vazia", "# só comentário\n\n", "Nenhum padrão em"),
            ("inválida", "Contoso\n[sem-fechar\n", "Padrão inválido na linha 2"),
        ):
            with self.subTest(case=case):
                self.patterns.unlink(missing_ok=True)
                if content is not None:
                    self.patterns.write_text(content, encoding="utf-8")
                result = self.neutral(str(self.copy), FWLAB_NEUTRAL_PATTERNS=str(self.patterns))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stdout)
                self.assertNotIn("nenhum achado", result.stdout)

    def test_client_patterns_are_reported_even_when_they_start_with_a_dash(self):
        self.patterns.write_text("# padrões de exemplo\nContoso\n-fabrikam\n", encoding="utf-8")
        (self.copy / "notas.md").write_text("Lab da Contoso\nhost web-fabrikam\n", encoding="utf-8")
        result = self.neutral(str(self.copy), FWLAB_NEUTRAL_PATTERNS=str(self.patterns))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("notas.md:1: padrão de cliente: Contoso", result.stdout)
        self.assertIn("notas.md:2: padrão de cliente: -fabrikam", result.stdout)


if __name__ == "__main__":
    unittest.main()
