"""PowerShell variable names are case-insensitive: $S and $s, or $Tray and $tray, are one variable.

Both bugs happened here (a local silently overwrote a strings table / a switch parameter),
so every script is checked for names that differ only in case.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = sorted([*(ROOT / "windows").glob("*.ps1"), ROOT / "install.ps1"])
VAR = re.compile(r"\$(?:script:|global:|local:)?([A-Za-z_][A-Za-z0-9_]*)")


def case_clashes(text):
    seen = {}
    for name in VAR.findall(text):
        seen.setdefault(name.lower(), set()).add(name)
    return {k: v for k, v in seen.items() if len(v) > 1}


class PowerShellNamesTest(unittest.TestCase):
    def test_scripts_exist(self):
        self.assertEqual([p.name for p in SCRIPTS], ["install.ps1", "ClaudeProfileSwitcher.ps1", "setup.ps1"])

    def test_no_variables_differing_only_in_case(self):
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                self.assertEqual(case_clashes(script.read_text(encoding="utf-8-sig")), {})

    def test_detects_a_clash(self):
        self.assertEqual(case_clashes("param([switch]$Tray)\n$tray = 1"), {"tray": {"Tray", "tray"}})


if __name__ == "__main__":
    unittest.main()
