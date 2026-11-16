#!/usr/bin/env python3
"""Switch Claude sign-ins (one profile per e-mail) for Claude Desktop and Claude Code.

Targets are the places a sign-in lives:
  desktop          Claude Desktop (Windows)
  code             Claude Code of this system (Windows, Linux or WSL)
  code-wsl-<name>  Claude Code inside a WSL distribution, when running on Windows

A profile keeps its own copy of the sign-in for every target, because a refresh token
used by two installations would be invalidated by whichever refreshes first:
  <target>/credentials.json   .credentials.json of that Claude Code
  <target>/oauthAccount.json  the "oauthAccount" key of its .claude.json
  desktop/Cookies             <Claude Desktop data>/Network/Cookies (claude.ai session)
  desktop/auth.json           oauth:* token caches + lastKnownAccountUuid from config.json

Every switch first saves the current sign-in back into its own profile, so tokens
refreshed while a profile was active are not lost. All output is one JSON object.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WINDOWS = sys.platform == "win32"
HOME = Path.home()
STORE = Path(os.environ.get("CLAUDE_PROFILES_HOME", HOME / ".claude-profiles"))
DESKTOP_AUTH_KEYS = ("oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid")
PENDING_DESKTOP = STORE / ".desktop-pending"
SETTINGS = STORE / ".settings.json"
WSL_CACHE = STORE / ".wsl-homes.json"  # {distro: {"home": "/home/me", "code": true}}
DEFAULT_SETTINGS = {"sync_sessions": True, "language": "auto"}
# Values accepted by `set <key> <value>`, mapped to what is stored. Language "auto" follows Windows.
SETTING_VALUES = {
    "sync_sessions": {"on": True, "off": False},
    "language": {"auto": "auto", "en": "en", "ru": "ru"},
}
NO_WINDOW = 0x08000000 if WINDOWS else 0  # CREATE_NO_WINDOW: no console flashes from the tray
# A profile folder is named after the e-mail, so it must also be a valid Windows folder name.
EMAIL = re.compile(r'[^\s@/\\:*?"<>|]+@[^\s@/\\:*?"<>|]+')


class Fail(Exception):
    pass


def run(cmd, timeout=30):
    return subprocess.run(cmd, capture_output=True, timeout=timeout, creationflags=NO_WINDOW)


# ---------- small file helpers ----------

def read_json(path, default=None):
    for attempt in range(5):
        try:
            # utf-8-sig: Windows PowerShell and Notepad may save JSON with a byte order mark.
            with open(path, encoding="utf-8-sig") as fh:
                return json.load(fh)
        except FileNotFoundError:
            return default
        except ValueError as exc:
            # Claude Code may be rewriting the file at this very moment: try again shortly.
            if attempt == 4:
                raise Fail(f"cannot read {path}: {exc}")
            time.sleep(0.2)


def write_json(path, data, indent=None, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=indent, ensure_ascii=False)
            if indent is not None:
                fh.write("\n")
        try:
            os.chmod(tmp, mode)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def json_indent(path):
    """Keep the original indentation of a file we rewrite (tabs in Desktop config.json)."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return 2
    second = text.split("\n", 2)[1] if "\n" in text else ""
    if second.startswith("\t"):
        return "\t"
    stripped = len(second) - len(second.lstrip(" "))
    return stripped or None


def profile_dir(email):
    email = (email or "").strip().lower()
    if not EMAIL.fullmatch(email) or email.startswith(".") or email.endswith("."):
        raise Fail(f"invalid e-mail: {email!r}")
    return STORE / email


def ensure_store():
    STORE.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(STORE, 0o700)
    except OSError:
        pass


def get_settings():
    return {**DEFAULT_SETTINGS, **(read_json(SETTINGS, {}) or {})}


def set_setting(key, value):
    if key not in DEFAULT_SETTINGS:
        raise Fail(f"unknown setting: {key}")
    ensure_store()
    settings = get_settings()
    settings[key] = value
    write_json(SETTINGS, settings, indent=2)
    return settings


# ---------- Claude Code installations ----------

class Code:
    """One Claude Code installation: its credentials file and .claude.json."""
    kind = "code"

    def __init__(self, id, label, creds, account_json, login, distro=None, home=None, asleep=False):
        self.id, self.label, self.creds, self.account_json = id, label, Path(creds), Path(account_json)
        self.login, self.distro, self.home = login, distro, home
        # A WSL distribution that is not running: reading its files would start it, so status leaves
        # it alone. A switch or logout is asked for by the user and does start it.
        self.asleep = asleep

    def current(self):
        if self.asleep:
            return {"signed_in": False, "email": None, "uuid": None, "asleep": True}
        oauth = (read_json(self.creds, {}) or {}).get("claudeAiOauth") or {}
        account = (read_json(self.account_json, {}) or {}).get("oauthAccount") or {}
        return {
            "signed_in": bool(oauth.get("refreshToken")),
            "email": (account.get("emailAddress") or "").lower() or None,
            "uuid": account.get("accountUuid"),
            "asleep": False,
        }

    def save(self, email=None):
        """Save the current sign-in into its profile. Returns the e-mail or None."""
        cur = self.current()
        if not cur["signed_in"] or not cur["email"]:
            return None
        ensure_store()
        d = profile_dir(cur["email"]) / self.id
        write_json(d / "credentials.json", read_json(self.creds))
        write_json(d / "oauthAccount.json", read_json(self.account_json)["oauthAccount"], indent=2)
        return cur["email"]

    def has(self, email):
        return (profile_dir(email) / self.id / "credentials.json").exists()

    def _set_account(self, value):
        data = read_json(self.account_json, {}) or {}
        if value is None:
            data.pop("oauthAccount", None)
        else:
            data["oauthAccount"] = value
        write_json(self.account_json, data, indent=json_indent(self.account_json))

    def _protect(self):
        # Files written into WSL over \\wsl.localhost do not get Linux permissions.
        if self.distro and self.creds.exists() and not os.environ.get("CLAUDE_PROFILES_WSL_HOMES"):
            run(["wsl.exe", "-d", self.distro, "--", "chmod", "600", f"{self.home}/.claude/.credentials.json"])

    def switch(self, email):
        src = profile_dir(email) / self.id
        if not (src / "credentials.json").exists():
            raise Fail(f"no saved {self.label} sign-in for {email}")
        self.asleep = False
        saved = self.save()
        write_json(self.creds, read_json(src / "credentials.json"))
        self._protect()
        self._set_account(read_json(src / "oauthAccount.json"))
        return {"saved_previous": saved, "active": email}

    def logout(self, email=None):
        self.asleep = False
        saved = self.save()
        if self.creds.exists():
            self.creds.unlink()
        self._set_account(None)
        return {"saved_previous": saved}


def native_code():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(config_dir) if config_dir else HOME / ".claude"
    creds = os.environ.get("CLAUDE_CREDENTIALS") or base / ".credentials.json"
    account = os.environ.get("CLAUDE_JSON") or (base / ".claude.json" if config_dir else HOME / ".claude.json")
    if WINDOWS:
        exe = shutil.which("claude") or str(HOME / ".local" / "bin" / "claude.exe")
        return Code("code", "Claude Code (Windows)", creds, account, ["cmd.exe", "/k", exe, "auth", "login"])
    return Code("code", "Claude Code", creds, account, ["claude", "auth", "login"])


def wsl_distros():
    """Installed WSL distributions, read from the registry (does not start WSL)."""
    try:
        import winreg
    except ImportError:
        return []
    names = []
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Lxss") as root:
            for i in range(winreg.QueryInfoKey(root)[0]):
                with winreg.OpenKey(root, winreg.EnumKey(root, i)) as key:
                    name = winreg.QueryValueEx(key, "DistributionName")[0]
                    if not name.lower().startswith("docker-desktop"):
                        names.append(name)
    except OSError:
        return []
    return sorted(names)


def wsl_home(distro):
    """$HOME of the default user in a running distribution."""
    out = run(["wsl.exe", "-d", distro, "--", "sh", "-c", 'printf %s "$HOME"'], timeout=60)
    home = out.stdout.decode("utf-8", "ignore").strip()
    return home if not out.returncode and home.startswith("/") else None


def wsl_running():
    """Names of the running distributions. `wsl --list --running` does not start any."""
    if os.environ.get("CLAUDE_PROFILES_WSL_RUNNING") is not None:  # tests: comma-separated names
        return {n for n in os.environ["CLAUDE_PROFILES_WSL_RUNNING"].split(",") if n}
    try:
        out = run(["wsl.exe", "--list", "--running", "--quiet"], timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    if out.returncode:  # also "There are no running distributions"
        return set()
    raw = out.stdout
    text = raw.decode("utf-16-le", "ignore") if b"\x00" in raw else raw.decode("utf-8", "ignore")
    return {line.strip().lstrip("\ufeff") for line in text.splitlines() if line.strip()}


def wsl_codes():
    """Claude Code inside WSL distributions. What is known about each distribution (home folder,
    whether Claude Code is there) is cached, so a distribution that is not running is not started
    by polling: it is shown from the cache until it runs again."""
    override = os.environ.get("CLAUDE_PROFILES_WSL_HOMES")  # tests: {"Distro": "<local folder>"}
    if override:
        local = {d: Path(p) for d, p in json.loads(override).items()}
        distros = sorted(local)
    elif WINDOWS:
        local, distros = {}, wsl_distros()
    else:
        return []
    if not distros:
        return []
    running = set(distros) if override and "CLAUDE_PROFILES_WSL_RUNNING" not in os.environ else wsl_running()
    cache = read_json(WSL_CACHE, {}) or {}
    changed = False
    codes = []
    for distro in distros:
        entry = cache.get(distro)
        entry = {"home": entry} if isinstance(entry, str) else dict(entry or {})  # older format: just the home path
        awake = distro in running
        if awake:
            home = "/home/test" if override else (entry.get("home") or wsl_home(distro))
            if not home:
                continue
        elif entry.get("code") and entry.get("home"):
            home = entry["home"]
        else:
            continue  # unknown or without Claude Code; looking would start it
        root = local.get(distro) or Path(f"//wsl.localhost/{distro}") / home.lstrip("/")
        if awake:
            installed = (root / ".claude").exists() or (root / ".claude.json").exists()
            if entry != {"home": home, "code": installed}:
                cache[distro] = {"home": home, "code": installed}
                changed = True
            if not installed:
                continue
        tid = "code-wsl-" + "".join(ch if ch.isalnum() else "-" for ch in distro.lower())
        codes.append(Code(tid, f"Claude Code (WSL {distro})", root / ".claude" / ".credentials.json",
                          root / ".claude.json", ["wsl.exe", "-d", distro, "--", "bash", "-lic", "claude auth login"],
                          distro=distro, home=home, asleep=not awake))
    if changed:
        ensure_store()
        write_json(WSL_CACHE, cache, indent=2)
    return codes


# ---------- Claude Desktop ----------

def windows_dir(var):
    """A Windows folder such as LOCALAPPDATA: native on Windows, translated inside WSL."""
    value = os.environ.get(var, "")
    if WINDOWS or value.startswith("/"):  # tests and the old WSL tray pass WSL paths through WSLENV
        return Path(value) if value else None
    if not shutil.which("cmd.exe"):
        return None
    try:
        win = run(["cmd.exe", "/c", f"echo %{var}%"], timeout=10).stdout.decode("utf-8", "ignore").strip()
        if not win or "%" in win:
            return None
        return Path(run(["wslpath", "-u", win], timeout=10).stdout.decode().strip())
    except (OSError, subprocess.TimeoutExpired):
        return None


def find_desktop_dir():
    """Claude Desktop data folder: MSIX (Claude-Data or package cache) or classic installer."""
    if os.environ.get("CLAUDE_DESKTOP_DIR"):
        return Path(os.environ["CLAUDE_DESKTOP_DIR"])
    candidates = []
    local = windows_dir("LOCALAPPDATA")
    if local:
        candidates += local.glob("Claude-Data/claude_*")
        candidates += local.glob("Packages/Claude_*/LocalCache/Roaming/Claude")
    roaming = windows_dir("APPDATA")
    if roaming:
        candidates.append(roaming / "Claude")
    found = [c for c in candidates if (c / "config.json").exists()]
    if not found:
        return None
    return max(found, key=lambda c: (c / "config.json").stat().st_mtime)


class Desktop:
    kind = "desktop"
    id = "desktop"
    label = "Claude Desktop"
    login = None

    def __init__(self, folder):
        self.dir = folder

    def config(self):
        return read_json(self.dir / "config.json", {}) or {}

    def current(self):
        cfg = self.config()
        uuid = cfg.get("lastKnownAccountUuid")
        signed_in = bool(cfg.get("oauth:tokenCacheV2") or cfg.get("oauth:tokenCache"))
        email = None
        if signed_in:
            # A new account is not saved yet, so its uuid is unknown: it is the e-mail being added.
            pending = PENDING_DESKTOP.read_text().strip() if PENDING_DESKTOP.exists() else None
            email = email_for_uuid(uuid) or pending
        return {"signed_in": signed_in, "uuid": uuid, "email": email}

    def has(self, email):
        return (profile_dir(email) / "desktop" / "auth.json").exists()

    def require_stopped(self):
        if desktop_running():
            raise Fail("Claude Desktop is running; close it first")

    def save(self, email=None):
        """Save the current Desktop sign-in. The app must be closed (its cookie DB is live)."""
        self.require_stopped()
        self.settle_cookies()
        cur = self.current()
        # Right after signing in, Desktop keeps the session only in its claude.ai cookie; the token
        # caches in config.json appear later. Either one means there is a sign-in to keep.
        if not (cur["signed_in"] or self.has_session()):
            return None
        pending = PENDING_DESKTOP.read_text().strip() if PENDING_DESKTOP.exists() else None
        email = email or cur["email"] or pending
        if not email:
            raise Fail("unknown e-mail for the current Desktop sign-in; pass --email")
        ensure_store()
        d = profile_dir(email) / "desktop"
        cfg = self.config()
        write_json(d / "auth.json", {k: cfg[k] for k in DESKTOP_AUTH_KEYS if k in cfg}, indent=2)
        cookies = self.dir / "Network" / "Cookies"
        if cookies.exists():
            shutil.copy2(cookies, d / "Cookies")
        if pending and pending == email and PENDING_DESKTOP.exists():
            PENDING_DESKTOP.unlink()
        return email

    def settle_cookies(self):
        """After Desktop was stopped by force, its cookie database may have a hot journal next to it.
        Opening the database rolls that back, so the single file we copy is consistent."""
        cookies = self.dir / "Network" / "Cookies"
        if not (cookies.exists() and (self.dir / "Network" / "Cookies-journal").exists()):
            return
        import sqlite3
        try:
            db = sqlite3.connect(str(cookies))
            try:
                db.execute("select count(*) from sqlite_master").fetchone()
            finally:
                db.close()
        except sqlite3.Error:
            pass

    def has_session(self):
        """True if the cookie database holds a claude.ai session (readable only while Desktop is closed)."""
        cookies = self.dir / "Network" / "Cookies"
        if not cookies.exists():
            return False
        import sqlite3
        tmp = Path(tempfile.mkdtemp())
        try:
            shutil.copy2(cookies, tmp / "Cookies")
            db = sqlite3.connect(str(tmp / "Cookies"))
            try:
                found = db.execute("select count(*) from cookies where host_key like '%claude.ai' "
                                   "and name = 'sessionKey'").fetchone()[0]
            finally:
                db.close()
            return found > 0
        except (OSError, sqlite3.Error):
            return False
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def apply(self, auth, cookies_src):
        cfg_path = self.dir / "config.json"
        indent = json_indent(cfg_path)
        cfg = self.config()
        for k in DESKTOP_AUTH_KEYS:
            cfg.pop(k, None)
        cfg.update(auth)
        write_json(cfg_path, cfg, indent=indent, mode=0o644)
        net = self.dir / "Network"
        net.mkdir(parents=True, exist_ok=True)
        for name in ("Cookies", "Cookies-journal"):
            if (net / name).exists():
                (net / name).unlink()
        if cookies_src is not None and cookies_src.exists():
            shutil.copy2(cookies_src, net / "Cookies")

    def switch(self, email):
        src = profile_dir(email) / "desktop"
        if not (src / "auth.json").exists():
            raise Fail(f"no saved Desktop sign-in for {email}")
        saved = self.save()
        synced = self.sync_sessions() if get_settings()["sync_sessions"] else None
        self.apply(read_json(src / "auth.json"), src / "Cookies")
        return {"saved_previous": saved, "active": email, "sessions_synced": synced}

    def logout(self, email=None):
        """Sign Desktop out so the next start shows the login screen for `email`."""
        if not email:
            raise Fail("--email is required for Desktop")
        profile_dir(email)  # validates
        saved = self.save()
        self.apply({}, None)
        ensure_store()
        PENDING_DESKTOP.write_text(email.strip().lower())
        return {"saved_previous": saved, "pending": email}

    def session_dirs(self):
        """Desktop keeps Code sessions per account and organization:
        claude-code-sessions/<account uuid>/<organization uuid>/. Only saved accounts are synced."""
        root = self.dir / "claude-code-sessions"
        accounts = {p["uuid"] for p in all_profiles() if p["uuid"]}
        return sorted(d for a in accounts if (root / a).is_dir() for d in (root / a).iterdir() if d.is_dir())

    def sync_sessions(self):
        """Make every saved account see the same Desktop Code sessions. Desktop must be closed.

        local_<id>.json  the newest copy (lastActivityAt, then file time) goes everywhere
        deleted_<id>     a deletion in one account removes the session everywhere
        archived-sessions.idx  archived lists are merged
        Other files (e.g. scheduled-tasks.json) stay with their account. Transcripts are not touched:
        Claude Code keeps them in ~/.claude/projects, shared by all accounts already.
        Returns the number of files written or removed.
        """
        dirs = self.session_dirs()
        if len(dirs) < 2:
            return 0
        newest, tombstones, archived = {}, {}, set()
        for d in dirs:
            for f in d.glob("local_*.json"):
                if f.name not in newest or _session_rank(f) > _session_rank(newest[f.name]):
                    newest[f.name] = f
            for f in d.glob("deleted_*"):
                tombstones.setdefault(f.name, f)
            idx = read_json(d / "archived-sessions.idx", {}) or {}
            archived.update(idx.get("archived") or [])
        deleted = {name[len("deleted_"):] for name in tombstones}
        changed = 0
        for d in dirs:
            for name, src in tombstones.items():
                if not (d / name).exists():
                    shutil.copy2(src, d / name)
                    changed += 1
            for name, src in newest.items():
                dst = d / name
                if name[len("local_"):-len(".json")] in deleted:
                    if dst.exists():
                        dst.unlink()
                        changed += 1
                    continue
                if src != dst and (not dst.exists() or _session_rank(dst) < _session_rank(src)):
                    shutil.copy2(src, dst)
                    changed += 1
            idx_path = d / "archived-sessions.idx"
            idx = read_json(idx_path, {"v": 1}) or {"v": 1}
            if set(idx.get("archived") or []) != archived:
                idx["archived"] = sorted(archived)
                write_json(idx_path, idx, mode=0o644)
                changed += 1
        return changed


def _session_rank(path):
    data = read_json(path, {}) or {}
    return (data.get("lastActivityAt") or 0, path.stat().st_mtime)


def desktop_running():
    """True while the Desktop app runs (a Windows build of Claude Code is also claude.exe)."""
    if os.environ.get("CLAUDE_DESKTOP_RUNNING") is not None:  # test hook
        return os.environ["CLAUDE_DESKTOP_RUNNING"] == "1"
    script = ("@(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object "
              "{ $_.Path -like '*\\WindowsApps\\Claude_*' -or $_.Path -like '*\\AnthropicClaude\\*' }).Count")
    exe = "powershell.exe" if shutil.which("powershell.exe") else "powershell"
    try:
        out = run([exe, "-NoProfile", "-NonInteractive", "-Command", script]).stdout.decode("ascii", "ignore")
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.strip() not in ("", "0")


# ---------- targets and profiles ----------

_TARGETS = None


def targets():
    global _TARGETS
    if _TARGETS is None:
        found = []
        folder = find_desktop_dir()
        if folder:
            found.append(Desktop(folder))
        found.append(native_code())
        found += wsl_codes()
        _TARGETS = found
    return _TARGETS


def target(tid):
    for t in targets():
        if t.id == tid:
            return t
    raise Fail(f"unknown target: {tid} (available: {', '.join(t.id for t in targets())})")


def all_profiles():
    if not STORE.exists():
        return []
    out = []
    for d in sorted(STORE.iterdir()):
        if not d.is_dir() or d.name.startswith("."):
            continue
        uuid = None
        for sub in sorted(d.iterdir()):
            meta = read_json(sub / "oauthAccount.json", {}) or {}
            uuid = uuid or meta.get("accountUuid") or (read_json(sub / "auth.json", {}) or {}).get("lastKnownAccountUuid")
        saved = sorted(sub.name for sub in d.iterdir()
                       if (sub / "credentials.json").exists() or (sub / "auth.json").exists())
        out.append({"email": d.name, "uuid": uuid, "saved": saved})
    return out


def email_for_uuid(uuid):
    if not uuid:
        return None
    for p in all_profiles():
        if p["uuid"] == uuid:
            return p["email"]
    for t in targets():
        if t.kind == "code":
            cur = t.current()
            if cur["uuid"] == uuid and cur["email"]:
                return cur["email"]
    return None


# ---------- commands ----------

def cmd_status(_args):
    for t in targets():
        if t.kind == "code":
            t.save()  # keep refreshed tokens; harmless when already saved
    profiles = all_profiles()
    pending = PENDING_DESKTOP.read_text().strip() if PENDING_DESKTOP.exists() else None
    shown = []
    for t in targets():
        cur = t.current()
        # "used": signed in now or saved in some profile. Installed but unused targets are hidden by the app.
        used = cur["signed_in"] or any(t.id in p["saved"] for p in profiles) or (t.kind == "desktop" and bool(pending))
        shown.append({"id": t.id, "label": t.label, "kind": t.kind, "login": t.login, "used": used, **cur})
    return {"targets": shown, "pending_desktop": pending, "profiles": profiles, "settings": get_settings()}


def cmd_switch(args):
    if args.target != "all":
        t = target(args.target)
        return {t.id: t.switch(args.email)}
    ready = [t for t in targets() if t.has(args.email)]
    if not ready:
        raise Fail(f"no saved sign-ins for {args.email}")
    result = {t.id: t.switch(args.email) for t in ready}
    result["skipped"] = [t.id for t in targets() if t not in ready]
    return result


def cmd_save(args):
    return {"saved": target(args.target).save(args.email)}


def cmd_logout(args):
    return target(args.target).logout(args.email)


def cmd_sync_sessions(_args):
    desktop = target("desktop")
    desktop.require_stopped()
    return {"sessions_synced": desktop.sync_sessions()}


def cmd_set(args):
    key = args.key.replace("-", "_")
    values = SETTING_VALUES[key]
    if args.value not in values:
        raise Fail(f"{args.key} takes one of: {', '.join(values)}")
    return {"settings": set_setting(key, values[args.value])}


def cmd_remove(args):
    d = profile_dir(args.email)
    if not d.exists():
        raise Fail(f"no profile {args.email}")
    email = d.name
    # Status saves the current Claude Code sign-in into its profile, so a removed profile that is
    # signed in somewhere would come back on the next poll.
    active = [t.label for t in targets() if (cur := t.current())["signed_in"] and cur["email"] == email]
    if active:
        raise Fail(f"{email} is signed in to {', '.join(active)}; switch to another account first")
    shutil.rmtree(d)
    return {"removed": args.email}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    s = sub.add_parser("switch", help="sign a target (or all) in with a saved e-mail")
    s.add_argument("email")
    s.add_argument("--target", default="all", help="target id from status, or 'all'")
    s.set_defaults(fn=cmd_switch)
    s = sub.add_parser("save")
    s.add_argument("--target", required=True)
    s.add_argument("--email")
    s.set_defaults(fn=cmd_save)
    s = sub.add_parser("logout")
    s.add_argument("--target", required=True)
    s.add_argument("--email")
    s.set_defaults(fn=cmd_logout)
    s = sub.add_parser("remove")
    s.add_argument("email")
    s.set_defaults(fn=cmd_remove)
    sub.add_parser("sync-sessions").set_defaults(fn=cmd_sync_sessions)
    s = sub.add_parser("set", help="change a setting: sync-sessions on|off, language auto|en|ru")
    s.add_argument("key", choices=[k.replace("_", "-") for k in DEFAULT_SETTINGS])
    s.add_argument("value", choices=sorted({v for values in SETTING_VALUES.values() for v in values}))
    s.set_defaults(fn=cmd_set)
    args = p.parse_args(argv)
    try:
        out = {"ok": True, **args.fn(args)}
        code = 0
    except Fail as exc:
        out, code = {"ok": False, "error": str(exc)}, 1
    except Exception as exc:  # the tray shows this instead of "no reply from the backend"
        out, code = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}, 2
    print(json.dumps(out, ensure_ascii=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
