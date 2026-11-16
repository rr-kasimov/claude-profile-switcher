import json, os, sqlite3, subprocess, sys, tempfile, unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "claude_profiles.py"


def creds(token):
    return {"claudeAiOauth": {"accessToken": "a-" + token, "refreshToken": token, "expiresAt": 1}}


class ProfilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.creds = self.tmp / "home/.claude/.credentials.json"
        self.cjson = self.tmp / "home/.claude.json"
        self.desk = self.tmp / "desk"
        (self.desk / "Network").mkdir(parents=True)
        self.creds.parent.mkdir(parents=True)
        self.env = dict(os.environ, CLAUDE_PROFILES_HOME=str(self.tmp / "store"),
                        CLAUDE_CREDENTIALS=str(self.creds), CLAUDE_JSON=str(self.cjson),
                        CLAUDE_DESKTOP_DIR=str(self.desk), CLAUDE_DESKTOP_RUNNING="0",
                        LOCALAPPDATA=str(self.tmp / "win/local"), APPDATA=str(self.tmp / "win/roaming"))

    def run_cli(self, *args, running="0", **env_overrides):
        env = dict(self.env, CLAUDE_DESKTOP_RUNNING=running, **env_overrides)
        p = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True)
        return json.loads(p.stdout)

    @staticmethod
    def target(status, tid):
        return next((t for t in status["targets"] if t["id"] == tid), None)

    def login_cli(self, email, uuid, token):
        self.creds.write_text(json.dumps(creds(token)))
        data = json.loads(self.cjson.read_text()) if self.cjson.exists() else {"projects": {"x": 1}}
        data["oauthAccount"] = {"emailAddress": email, "accountUuid": uuid}
        self.cjson.write_text(json.dumps(data, indent=2))

    def login_desktop(self, uuid, token, cookie):
        cfg = {"locale": "ru", "oauth:tokenCacheV2": token, "lastKnownAccountUuid": uuid}
        (self.desk / "config.json").write_text(json.dumps(cfg, indent="\t"))
        (self.desk / "Network/Cookies").write_bytes(cookie)

    def test_cli_switch_keeps_refreshed_token_and_other_keys(self):
        self.login_cli("a@x.ru", "u-a", "tok-a1")
        self.run_cli("status")
        self.login_cli("b@x.ru", "u-b", "tok-b1")
        self.run_cli("status")
        self.creds.write_text(json.dumps(creds("tok-b2")))  # CLI refreshed b's token
        r = self.run_cli("switch", "a@x.ru", "--target", "code")
        self.assertEqual(r["code"], {"saved_previous": "b@x.ru", "active": "a@x.ru"})
        self.assertEqual(json.loads(self.creds.read_text())["claudeAiOauth"]["refreshToken"], "tok-a1")
        data = json.loads(self.cjson.read_text())
        self.assertEqual((data["oauthAccount"]["emailAddress"], data["projects"]), ("a@x.ru", {"x": 1}))
        self.run_cli("switch", "b@x.ru", "--target", "code")
        self.assertEqual(json.loads(self.creds.read_text())["claudeAiOauth"]["refreshToken"], "tok-b2")

    def test_signed_out_cli_is_not_saved_over_profile(self):
        self.login_cli("a@x.ru", "u-a", "tok-a1")
        self.run_cli("status")
        self.creds.write_text(json.dumps(creds("")))  # logged out, email still in .claude.json
        self.assertFalse(self.target(self.run_cli("status"), "code")["signed_in"])
        saved = json.loads((self.tmp / "store/a@x.ru/code/credentials.json").read_text())
        self.assertEqual(saved["claudeAiOauth"]["refreshToken"], "tok-a1")

    def test_desktop_switch_and_pending_new_login(self):
        self.login_cli("a@x.ru", "u-a", "tok-a1")
        self.login_desktop("u-a", "dt-a", b"cookie-a")
        r = self.run_cli("logout", "--target", "desktop", "--email", "B@x.ru")
        self.assertEqual(r["saved_previous"], "a@x.ru")
        cfg = json.loads((self.desk / "config.json").read_text())
        self.assertEqual((cfg, (self.desk / "Network/Cookies").exists()), ({"locale": "ru"}, False))
        self.login_desktop("u-b", "dt-b", b"cookie-b")  # user signed in as b in the app
        self.assertEqual(self.target(self.run_cli("status"), "desktop")["email"], "b@x.ru")
        r = self.run_cli("switch", "a@x.ru", "--target", "desktop")
        self.assertEqual(r["desktop"], {"saved_previous": "b@x.ru", "active": "a@x.ru", "sessions_synced": 0})
        self.assertEqual((self.desk / "Network/Cookies").read_bytes(), b"cookie-a")
        text = (self.desk / "config.json").read_text()
        self.assertIn('\n\t"', text)
        self.assertEqual(json.loads(text)["oauth:tokenCacheV2"], "dt-a")
        self.run_cli("switch", "b@x.ru", "--target", "desktop")
        self.assertEqual((self.desk / "Network/Cookies").read_bytes(), b"cookie-b")

    def cookie_db(self, path, names):
        db = sqlite3.connect(str(path))
        db.execute("create table cookies (host_key text, name text, encrypted_value blob)")
        db.executemany("insert into cookies values ('.claude.ai', ?, x'00')", [(n,) for n in names])
        db.commit(); db.close()

    def test_fresh_desktop_sign_in_held_only_in_cookie_is_saved_before_switch(self):
        self.login_desktop("u-a", "dt-a", b"")
        self.cookie_db(self.desk / "Network/Cookies.a", ["sessionKey"])
        (self.desk / "Network/Cookies").unlink()
        (self.desk / "Network/Cookies.a").rename(self.desk / "Network/Cookies")
        self.run_cli("save", "--target", "desktop", "--email", "a@x.ru")
        self.run_cli("logout", "--target", "desktop", "--email", "new@x.ru")
        # signed in as new@x.ru: only the session cookie exists yet, no token caches
        (self.desk / "config.json").write_text(json.dumps({"locale": "ru"}))
        for names, saved in ((["routingHint"], False), (["sessionKey", "routingHint"], True)):
            with self.subTest(cookies=names):
                (self.desk / "Network/Cookies").unlink(missing_ok=True)
                self.cookie_db(self.desk / "Network/Cookies", names)
                r = self.run_cli("save", "--target", "desktop")
                self.assertEqual(r["saved"], "new@x.ru" if saved else None)
        self.assertTrue((self.tmp / "store/new@x.ru/desktop/Cookies").exists())

    def test_desktop_refuses_while_running_and_unknown_email(self):
        self.login_desktop("u-z", "dt-z", b"z")
        r = self.run_cli("save", "--target", "desktop", running="1")
        self.assertEqual(r, {"ok": False, "error": "Claude Desktop is running; close it first"})
        r = self.run_cli("save", "--target", "desktop")
        self.assertFalse(r["ok"])
        self.assertTrue(r["error"].startswith("unknown e-mail"))
        self.assertEqual(self.run_cli("save", "--target", "desktop", "--email", "z@x.ru")["saved"], "z@x.ru")

    def test_switch_to_missing_profile_fails_without_changes(self):
        self.login_cli("a@x.ru", "u-a", "tok-a1")
        before = self.creds.read_text()
        for target in ("code", "desktop"):
            with self.subTest(target=target):
                r = self.run_cli("switch", "nobody@x.ru", "--target", target)
                self.assertFalse(r["ok"])
        self.assertEqual(self.creds.read_text(), before)

    def test_desktop_dir_is_found_from_windows_folders(self):
        for name, sub in (("msix", "win/local/Claude-Data/claude_abc"),
                          ("classic", "win/roaming/Claude")):
            with self.subTest(install=name):
                found = self.tmp / name / sub
                found.mkdir(parents=True)
                (found / "config.json").write_text(json.dumps({"oauth:tokenCacheV2": "t", "lastKnownAccountUuid": "u"}))
                r = self.run_cli("status", CLAUDE_DESKTOP_DIR="",
                                 LOCALAPPDATA=str(self.tmp / name / "win/local"),
                                 APPDATA=str(self.tmp / name / "win/roaming"))
                self.assertTrue(self.target(r, "desktop")["signed_in"])

    def test_without_desktop_app_cli_still_works(self):
        self.login_cli("a@x.ru", "u-a", "tok-a1")
        r = self.run_cli("status", CLAUDE_DESKTOP_DIR="")
        self.assertEqual([t["id"] for t in r["targets"]], ["code"])
        self.assertEqual(self.target(r, "code")["email"], "a@x.ru")
        r = self.run_cli("switch", "a@x.ru", "--target", "desktop", CLAUDE_DESKTOP_DIR="")
        self.assertEqual(r["ok"], False)
        self.assertIn("unknown target: desktop", r["error"])

    def test_claude_config_dir_is_respected(self):
        cfg = self.tmp / "custom"
        cfg.mkdir()
        (cfg / ".credentials.json").write_text(json.dumps(creds("tok-c")))
        (cfg / ".claude.json").write_text(json.dumps({"oauthAccount": {"emailAddress": "c@x.ru", "accountUuid": "u-c"}}))
        env = {k: v for k, v in self.env.items() if k not in ("CLAUDE_CREDENTIALS", "CLAUDE_JSON")}
        env["CLAUDE_CONFIG_DIR"] = str(cfg)
        p = subprocess.run([sys.executable, str(SCRIPT), "status"], env=env, capture_output=True, text=True)
        self.assertEqual(self.target(json.loads(p.stdout), "code")["email"], "c@x.ru")

    def session(self, account, org, sid, activity, title):
        d = self.desk / "claude-code-sessions" / account / org
        d.mkdir(parents=True, exist_ok=True)
        (d / f"local_{sid}.json").write_text(json.dumps({"sessionId": f"local_{sid}", "lastActivityAt": activity, "title": title}))
        return d

    def test_desktop_switch_merges_sessions_of_saved_accounts(self):
        self.login_cli("a@x.ru", "u-a", "tok-a")
        self.login_desktop("u-a", "dt-a", b"cookie-a")
        a = self.session("u-a", "org-a", "s1", 100, "old title")
        self.session("u-a", "org-a", "only-a", 50, "a")
        self.session("u-a", "org-a", "gone", 10, "deleted in b")
        (a / "archived-sessions.idx").write_text(json.dumps({"v": 1, "archived": ["local_x"]}))
        (a / "scheduled-tasks.json").write_text("{}")
        self.run_cli("save", "--target", "desktop")
        self.login_desktop("u-b", "dt-b", b"cookie-b")
        b = self.session("u-b", "org-b", "s1", 200, "new title")
        self.session("u-b", "org-b", "only-b", 60, "b")
        (b / "deleted_gone").write_text("1794732676773")
        (b / "archived-sessions.idx").write_text(json.dumps({"v": 1, "archived": ["local_y"]}))
        other = self.session("u-stranger", "org-z", "private", 70, "not a saved profile")
        self.run_cli("save", "--target", "desktop", "--email", "b@x.ru")

        r = self.run_cli("switch", "a@x.ru", "--target", "desktop")

        self.assertGreater(r["desktop"]["sessions_synced"], 0)
        for d in (a, b):
            with self.subTest(folder=d.parent.name):
                names = sorted(f.name for f in d.iterdir() if f.name.startswith(("local_", "deleted_")))
                self.assertEqual(names, ["deleted_gone", "local_only-a.json", "local_only-b.json", "local_s1.json"])
                self.assertEqual(json.loads((d / "local_s1.json").read_text())["title"], "new title")
                self.assertEqual(json.loads((d / "archived-sessions.idx").read_text())["archived"], ["local_x", "local_y"])
        self.assertFalse((b / "scheduled-tasks.json").exists())
        self.assertEqual(sorted(f.name for f in other.iterdir()), ["local_private.json"])

    def test_session_sync_setting_off_leaves_folders_alone(self):
        self.assertEqual(self.run_cli("status")["settings"], {"sync_sessions": True, "language": "auto"})
        self.assertEqual(self.run_cli("set", "sync-sessions", "off")["settings"], {"sync_sessions": False, "language": "auto"})
        self.login_desktop("u-a", "dt-a", b"cookie-a")
        a = self.session("u-a", "org-a", "only-a", 50, "a")
        self.run_cli("save", "--target", "desktop", "--email", "a@x.ru")
        self.login_desktop("u-b", "dt-b", b"cookie-b")
        b = self.session("u-b", "org-b", "only-b", 60, "b")
        self.run_cli("save", "--target", "desktop", "--email", "b@x.ru")

        r = self.run_cli("switch", "a@x.ru", "--target", "desktop")

        self.assertIsNone(r["desktop"]["sessions_synced"])
        self.assertEqual([f.name for f in a.iterdir()], ["local_only-a.json"])
        self.assertEqual([f.name for f in b.iterdir()], ["local_only-b.json"])
        self.assertEqual(self.run_cli("status")["settings"], {"sync_sessions": False, "language": "auto"})

    def test_language_setting(self):
        self.assertEqual(self.run_cli("set", "language", "en")["settings"]["language"], "en")
        self.assertEqual(self.run_cli("status")["settings"]["language"], "en")
        r = self.run_cli("set", "language", "on")
        self.assertEqual((r["ok"], r["error"]), (False, "language takes one of: auto, en, ru"))
        self.assertEqual(self.run_cli("set", "sync-sessions", "ru")["ok"], False)
        self.assertEqual(self.run_cli("status")["settings"], {"sync_sessions": True, "language": "en"})

    def test_settings_file_with_bom_is_read(self):
        store = self.tmp / "store"
        store.mkdir()
        (store / ".settings.json").write_bytes('\ufeff{"language": "ru"}'.encode("utf-8"))
        self.assertEqual(self.run_cli("status")["settings"], {"sync_sessions": True, "language": "ru"})

    def test_unknown_setting_is_rejected(self):
        for args in (("set", "colour", "on"), ("set", "sync-sessions", "maybe")):
            with self.subTest(args=args):
                p = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env, capture_output=True, text=True)
                self.assertEqual(p.returncode, 2)

    def test_sync_sessions_command_needs_desktop_closed(self):
        r = self.run_cli("sync-sessions", running="1")
        self.assertEqual(r, {"ok": False, "error": "Claude Desktop is running; close it first"})
        self.assertEqual(self.run_cli("sync-sessions"), {"ok": True, "sessions_synced": 0})

    def test_wsl_install_keeps_its_own_copy_of_each_sign_in(self):
        wsl = self.tmp / "wsl-home"
        (wsl / ".claude").mkdir(parents=True)
        (self.tmp / "no-claude").mkdir()
        homes = json.dumps({"Ubuntu-22.04": str(wsl), "Debian": str(self.tmp / "no-claude")})
        def login_wsl(email, token):
            (wsl / ".claude/.credentials.json").write_text(json.dumps(creds(token)))
            (wsl / ".claude.json").write_text(json.dumps({"oauthAccount": {"emailAddress": email, "accountUuid": "u-" + email[0]}}))
        self.login_cli("a@x.ru", "u-a", "win-a")
        login_wsl("a@x.ru", "wsl-a")
        status = self.run_cli("status", CLAUDE_PROFILES_WSL_HOMES=homes)
        self.assertEqual([t["id"] for t in status["targets"]], ["desktop", "code", "code-wsl-ubuntu-22-04"])
        self.assertEqual([t["used"] for t in status["targets"]], [False, True, True])
        self.login_cli("b@x.ru", "u-b", "win-b")
        login_wsl("b@x.ru", "wsl-b")
        self.run_cli("status", CLAUDE_PROFILES_WSL_HOMES=homes)

        r = self.run_cli("switch", "a@x.ru", "--target", "code-wsl-ubuntu-22-04", CLAUDE_PROFILES_WSL_HOMES=homes)

        self.assertEqual(r["code-wsl-ubuntu-22-04"], {"saved_previous": "b@x.ru", "active": "a@x.ru"})
        self.assertEqual(json.loads((wsl / ".claude/.credentials.json").read_text())["claudeAiOauth"]["refreshToken"], "wsl-a")
        self.assertEqual(json.loads(self.creds.read_text())["claudeAiOauth"]["refreshToken"], "win-b")
        r = self.run_cli("switch", "a@x.ru", "--target", "all", CLAUDE_PROFILES_WSL_HOMES=homes)
        self.assertEqual((r["skipped"], r["code"]["active"]), (["desktop"], "a@x.ru"))
        self.assertEqual(self.run_cli("switch", "z@x.ru", "--target", "all")["error"], "no saved sign-ins for z@x.ru")
        profile = self.run_cli("status", CLAUDE_PROFILES_WSL_HOMES=homes)["profiles"]
        self.assertEqual([p["saved"] for p in profile], [["code", "code-wsl-ubuntu-22-04"]] * 2)

    def test_stopped_wsl_distribution_is_not_touched_by_status(self):
        wsl = self.tmp / "wsl-home"
        (wsl / ".claude").mkdir(parents=True)
        (wsl / ".claude/.credentials.json").write_text(json.dumps(creds("wsl-a")))
        (wsl / ".claude.json").write_text(json.dumps({"oauthAccount": {"emailAddress": "a@x.ru", "accountUuid": "u-a"}}))
        homes = json.dumps({"Ubuntu": str(wsl)})
        # Never seen running: unknown, so it is skipped rather than started.
        status = self.run_cli("status", CLAUDE_PROFILES_WSL_HOMES=homes, CLAUDE_PROFILES_WSL_RUNNING="")
        self.assertIsNone(self.target(status, "code-wsl-ubuntu"))
        self.run_cli("status", CLAUDE_PROFILES_WSL_HOMES=homes, CLAUDE_PROFILES_WSL_RUNNING="Ubuntu")
        (wsl / ".claude/.credentials.json").write_text(json.dumps(creds("wsl-a2")))
        # Stopped now: shown from the cache, its files are neither read nor saved.
        status = self.run_cli("status", CLAUDE_PROFILES_WSL_HOMES=homes, CLAUDE_PROFILES_WSL_RUNNING="")
        t = self.target(status, "code-wsl-ubuntu")
        self.assertEqual((t["asleep"], t["signed_in"], t["used"]), (True, False, True))
        saved = json.loads((self.tmp / "store/a@x.ru/code-wsl-ubuntu/credentials.json").read_text())
        self.assertEqual(saved["claudeAiOauth"]["refreshToken"], "wsl-a")
        # A switch is asked for by the user: it reads (and saves) the current sign-in first.
        r = self.run_cli("switch", "a@x.ru", "--target", "code-wsl-ubuntu",
                         CLAUDE_PROFILES_WSL_HOMES=homes, CLAUDE_PROFILES_WSL_RUNNING="")
        self.assertEqual(r["code-wsl-ubuntu"]["saved_previous"], "a@x.ru")
        saved = json.loads((self.tmp / "store/a@x.ru/code-wsl-ubuntu/credentials.json").read_text())
        self.assertEqual(saved["claudeAiOauth"]["refreshToken"], "wsl-a2")

    def test_signed_in_account_cannot_be_removed(self):
        self.login_cli("a@x.ru", "u-a", "tok-a1")
        self.run_cli("status")
        self.login_cli("b@x.ru", "u-b", "tok-b1")
        self.run_cli("status")
        r = self.run_cli("remove", "B@x.ru")
        self.assertEqual((r["ok"], "switch to another account" in r["error"]), (False, True))
        self.assertEqual(self.run_cli("remove", "a@x.ru"), {"ok": True, "removed": "a@x.ru"})
        self.assertEqual([p["email"] for p in self.run_cli("status")["profiles"]], ["b@x.ru"])

    def test_invalid_emails_are_rejected(self):
        for bad in ("a@b:c", "no-at-sign", "a b@x.ru", "a@x.ru.", '"a"@x.ru', "../a@x.ru", "a@x?.ru"):
            with self.subTest(email=bad):
                r = self.run_cli("logout", "--target", "desktop", "--email", bad)
                self.assertEqual((r["ok"], r["error"].startswith("invalid e-mail")), (False, True))

    def test_unreadable_json_is_reported_as_json(self):
        self.cjson.write_text('{"oauthAccount": ')  # caught mid-write by Claude Code
        self.creds.write_text(json.dumps(creds("tok")))
        r = self.run_cli("status")
        self.assertEqual(r["ok"], False)
        self.assertIn("cannot read", r["error"])

    def test_unknown_target_is_rejected(self):
        r = self.run_cli("switch", "a@x.ru", "--target", "code-wsl-nope")
        self.assertEqual(r["ok"], False)
        self.assertIn("available: desktop, code", r["error"])


if __name__ == "__main__":
    unittest.main()
