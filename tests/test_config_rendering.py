from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import fcitx5_rime_config  # noqa: E402
import render_codex_config  # noqa: E402
import secret_guard  # noqa: E402


class ConfigRenderingTests(unittest.TestCase):
    def test_fcitx5_rime_default_chinese_config(self) -> None:
        existing = """[Hotkey]
EnumerateWithTriggerKeys=True

[Behavior]
ActiveByDefault=False
ShareInputState=No
"""
        rendered = fcitx5_rime_config.render_global_config(existing)
        self.assertIn("EnumerateWithTriggerKeys=True", rendered)
        self.assertIn("ShareInputState=No", rendered)
        self.assertIn("ActiveByDefault=True", rendered)
        self.assertNotIn("ActiveByDefault=False", rendered)

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            profile = root / "profile"
            global_config = root / "config"
            custom = root / "default.custom.yaml"
            compiled = root / "default.yaml"
            profile.write_text(
                (ROOT / "templates" / "fcitx5-profile.conf.tpl").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            global_config.write_text(rendered, encoding="utf-8")
            custom.write_text(
                (ROOT / "templates" / "rime-default.custom.yaml.tpl").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            compiled.write_text(
                """key_binder:
  bindings:
    - {accept: minus, send: Page_Up, when: paging}
    - {accept: equal, send: Page_Down, when: has_menu}
menu:
  page_size: 9
schema_list:
  - schema: rime_ice
switcher:
  caption: test
""",
                encoding="utf-8",
            )
            fcitx5_rime_config.validate_configuration(
                profile, global_config, custom, compiled
            )

            custom.write_text(
                custom.read_text(encoding="utf-8")
                + "\n__include: rime_ice_suggestion:/\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "unsupported suggestion"):
                fcitx5_rime_config.validate_configuration(
                    profile, global_config, custom, compiled
                )

    def test_codex_default_config_is_valid_toml(self) -> None:
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

    def test_plain_codex_is_the_managed_entrypoint(self) -> None:
        codex_script = (ROOT / "scripts" / "07-codex.sh").read_text(
            encoding="utf-8"
        )
        validate_script = (ROOT / "scripts" / "08-validate.sh").read_text(
            encoding="utf-8"
        )
        status_script = (ROOT / "scripts" / "09-status.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('MAIN_CONFIG="$CODEX_DIR/config.toml"', codex_script)
        self.assertIn('write_user_file "$MAIN_CONFIG" 0600', codex_script)
        self.assertIn('run_as_user timeout 120 "$CODEX_BIN" exec', codex_script)
        self.assertIn("CODEX_SANDBOX_PACKAGES", codex_script)
        self.assertIn("bwrap-userns-restrict", codex_script)
        self.assertIn('"$CODEX_BIN" sandbox -- /bin/bash', codex_script)
        self.assertIn("请直接运行：codex", codex_script)
        self.assertNotIn("CODEX_WRAPPER", codex_script)
        self.assertNotIn('exec $(shell_quote "$CODEX_BIN") --profile', codex_script)
        self.assertIn('CODEX_CONFIG="$REAL_HOME/.codex/config.toml"', validate_script)
        self.assertIn('echo "command:  codex"', status_script)

    def test_ssh_network_is_staged_for_reboot(self) -> None:
        static_network = (ROOT / "scripts" / "04-static-network.sh").read_text(
            encoding="utf-8"
        )
        preflight = (ROOT / "scripts" / "01-preflight.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('if [[ -n "${SSH_CONNECTION:-}" ]]; then', static_network)
        self.assertIn("mark_phase pending-reboot", static_network)
        self.assertIn("netplan try --timeout 120", static_network)
        self.assertIn('write_managed_file "$path" 0600 root root', static_network)
        self.assertIn("network_cleanup", static_network)
        self.assertNotIn("固定网络将安全延后", preflight)
        # Execution, timeout rollback and unchanged unrelated YAML permissions are
        # checked by NetworkPhaseTests; global chmod/restart was the old contract.

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
        self.assertIn("Docker Engine 默认安装", install_script)
        self.assertIn("Fcitx5/Rime 默认安装雾凇拼音", install_script)
        self.assertIn('CONFIRM_SSH_KEY_LOGIN="$DISABLE_SSH_PASSWORD"', install_script)
        self.assertNotIn("Windows 公钥已在另一终端登录成功", install_script)
        self.assertIn(
            'read -e -i "$default_value" -r -p "${prompt}："', shell_library
        )
        self.assertIn(
            'read -e -i "$default_input" -r -p "${prompt}："', shell_library
        )
        self.assertIn('stty -echo <"$VUB_INPUT_TTY"', shell_library)
        self.assertNotIn("read -r -s -n 1", shell_library)
        self.assertIn("printf '*'", shell_library)
        self.assertNotIn("[默认:", shell_library)

    def test_dependency_and_proxy_contract(self) -> None:
        install_script = (ROOT / "install.sh").read_text(encoding="utf-8")
        bootstrap = (ROOT / "bootstrap.sh").read_text(encoding="utf-8")
        packages = (ROOT / "scripts" / "03-packages.sh").read_text(encoding="utf-8")
        input_method = (ROOT / "scripts" / "04-input-method.sh").read_text(
            encoding="utf-8"
        )
        input_method_helper = (
            ROOT / "scripts" / "fcitx5_rime_config.py"
        ).read_text(encoding="utf-8")
        repositories = (ROOT / "scripts" / "apt-repositories.sh").read_text(
            encoding="utf-8"
        )
        sudo_policy = (ROOT / "scripts" / "03-sudo-policy.sh").read_text(
            encoding="utf-8"
        )
        proxy = (ROOT / "scripts" / "02-proxy.sh").read_text(encoding="utf-8")
        shell_library = (ROOT / "scripts" / "00-lib.sh").read_text(encoding="utf-8")
        example = (ROOT / "config.example.env").read_text(encoding="utf-8")
        self.assertIn("ensure_startup_dependencies", bootstrap)
        self.assertIn("scripts/00-dependencies.sh", bootstrap)
        self.assertIn(': "${INSTALL_DOCKER:=true}"', shell_library)
        self.assertIn(': "${CONFIGURE_FCITX5_RIME:=true}"', shell_library)
        self.assertIn(': "${ENABLE_UPSTREAM_APT_SOURCES:=true}"', shell_library)
        self.assertIn(': "${UPGRADE_INSTALLED_PACKAGES:=true}"', shell_library)
        self.assertIn(': "${ENABLE_PASSWORDLESS_SUDO:=true}"', shell_library)
        self.assertIn(': "${TIMEZONE:=America/New_York}"', shell_library)
        self.assertIn('VUB_CONFIG_VERSION="5"', example)
        self.assertIn('TIMEZONE="America/New_York"', example)
        self.assertIn('INSTALL_DOCKER="true"', example)
        self.assertIn('CONFIGURE_FCITX5_RIME="true"', example)
        self.assertIn('ENABLE_PASSWORDLESS_SUDO="true"', example)
        self.assertIn(
            'if [[ "$VUB_CONFIG_VERSION" == "1" ]]',
            (ROOT / "install.sh").read_text(encoding="utf-8"),
        )
        for package in (
            "nodejs",
            "npm",
            "node-gyp",
            "meson",
            "ninja-build",
            "libpcsclite-dev",
            "libcurl4-openssl-dev",
            "vsmartcard-vpcd",
            "modemmanager",
            "bubblewrap",
            "apparmor-profiles",
            "apparmor-utils",
            "fcitx5-rime",
            "fcitx5-frontend-gtk4",
            "fcitx5-frontend-qt5",
            "librime-plugin-lua",
            "librime-plugin-octagram",
            "librime-bin",
            "im-config",
        ):
            self.assertIn(package, packages)
        for package in (
            "gh",
            "docker-ce",
            "docker-buildx-plugin",
            "docker-compose-plugin",
        ):
            self.assertIn(package, packages + shell_library)
        for source in (
            "https://cli.github.com/packages",
            "https://ppa.launchpadcontent.net/git-core/ppa/ubuntu",
            "https://packagecloud.io/github/git-lfs/ubuntu/",
            "https://apt.kitware.com/ubuntu/",
            "https://download.docker.com/linux/ubuntu",
        ):
            self.assertIn(source, repositories)
        self.assertNotIn("apt-key", repositories)
        self.assertIn("verify_openpgp_primary_fingerprints", repositories)
        self.assertIn("activate_docker_runtime", packages)
        self.assertIn("verify_docker_runtime", packages)
        self.assertIn("node --version", packages)
        self.assertIn("npm --version", packages)
        self.assertIn("npx --version", packages)
        self.assertIn("docker_start_existing", shell_library)
        self.assertIn("docker_local_healthy", shell_library)
        self.assertIn("NOPASSWD: ALL", shell_library)
        self.assertIn('visudo -cf "$sudoers_tmp"', sudo_policy)
        self.assertIn("sudo-policy", bootstrap)
        self.assertIn("input-method", bootstrap)
        self.assertIn(
            "DefaultIM=rime",
            (ROOT / "templates" / "fcitx5-profile.conf.tpl").read_text(
                encoding="utf-8"
            ),
        )
        self.assertIn("ActiveByDefault=True", input_method_helper)
        self.assertIn('rime_dir="$RIME_DIR"', input_method)
        self.assertIn("iDvel/rime-ice", input_method)
        self.assertNotIn("rime_ice_suggestion", input_method)
        self.assertIn("all_proxy", proxy)
        self.assertIn("host.docker.internal", proxy)
        self.assertIn(
            'VUB_TEMP_SECRET="$(make_private_temp_file ', install_script
        )
        self.assertNotIn("\n      umask 077\n", install_script)
        self.assertLess(
            proxy.index("normalize_system_config_permissions /etc/gitconfig"),
            proxy.index("git_as_user config --global --fixed-value"),
        )

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
