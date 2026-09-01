from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import render_codex_config  # noqa: E402
import secret_guard  # noqa: E402


class ConfigRenderingTests(unittest.TestCase):
    def test_codex_profile_is_valid_toml(self) -> None:
        rendered = render_codex_config.render(
            "gpt-test/model", "https://cpa.example.com/v1", "/home/suyi/bin/token"
        )
        data = tomllib.loads(rendered)
        self.assertEqual(data["model"], "gpt-test/model")
        self.assertEqual(data["model_provider"], "cpa")
        self.assertEqual(data["model_providers"]["cpa"]["wire_api"], "responses")
        self.assertEqual(
            data["model_providers"]["cpa"]["auth"]["command"],
            "/home/suyi/bin/token",
        )
        self.assertNotIn("experimental_bearer_token", rendered)

    def test_toml_strings_are_escaped(self) -> None:
        rendered = render_codex_config.render(
            'model"quoted', "https://example.com/v1", "/tmp/a\\b"
        )
        data = tomllib.loads(rendered)
        self.assertEqual(data["model"], 'model"quoted')
        self.assertEqual(
            data["model_providers"]["cpa"]["auth"]["command"], "/tmp/a\\b"
        )

    def test_shell_files_are_forced_to_lf(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn("*.sh text eol=lf", attributes)

    def test_interactive_ui_contract(self) -> None:
        install_script = (ROOT / "install.sh").read_text(encoding="utf-8")
        shell_library = (ROOT / "scripts" / "00-lib.sh").read_text(encoding="utf-8")
        self.assertIn("clear_screen", install_script)
        self.assertIn("banner_row 'VMware Ubuntu Bootstrap'", install_script)
        self.assertIn("ui_info", install_script)
        self.assertIn('ui_section "基础信息"', install_script)
        self.assertIn('read_default "CPA /v1 地址，公网必须 HTTPS"', install_script)
        self.assertLess(
            install_script.index('key_input="$(read_secret "CPA API key"'),
            install_script.index('choose_cpa_model "$CPA_BASE_URL"'),
        )
        self.assertIn('read_default "CPA 模型编号"', install_script)
        self.assertIn('CPA_BYPASS_PROXY="true"', install_script)
        self.assertIn("当前唯一可选安装组件：Docker Engine", install_script)
        self.assertIn('CONFIRM_SSH_KEY_LOGIN="$DISABLE_SSH_PASSWORD"', install_script)
        self.assertNotIn("Windows 公钥已在另一终端登录成功", install_script)
        self.assertIn(
            'read -e -i "$default_value" -r -p "${prompt}："', shell_library
        )
        self.assertIn(
            'read -e -i "$default_input" -r -p "${prompt}："', shell_library
        )
        self.assertIn("printf '*'", shell_library)
        self.assertNotIn("[默认:", shell_library)

    def test_runtime_and_secret_files_are_ignored(self) -> None:
        for relative in ("config.env", "secrets/cpa-api-key", "run.log", "state/x"):
            result = subprocess.run(
                ["git", "-C", str(ROOT), "check-ignore", "--no-index", "--quiet", relative],
                check=False,
            )
            self.assertEqual(result.returncode, 0, relative)

    def test_secret_guard_detects_only_external_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            secret_file = root / "secret"
            secret_file.write_text("fixture-secret-value\n", encoding="utf-8")
            safe_file = root / "safe.txt"
            safe_file.write_text("nothing sensitive\n", encoding="utf-8")
            self.assertEqual(secret_guard.scan(secret_file, [root]), [])
            leaked_file = root / "leaked.txt"
            leaked_file.write_text("prefix fixture-secret-value suffix", encoding="utf-8")
            self.assertEqual(secret_guard.scan(secret_file, [root]), [leaked_file])


if __name__ == "__main__":
    unittest.main()
