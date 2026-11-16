# Changelog

## 0.1.0

First public version.

- Switches Claude Desktop (Microsoft Store and classic installer) and Claude Code (Windows and every WSL distribution) between saved accounts without signing in again.
- Each app keeps its own copy of every account's sign-in; the current sign-in is saved before every switch, so refreshed tokens are kept.
- Adding an account signs the selected apps out and opens the normal Claude sign-in.
- Optional sync of Claude Desktop Code sessions between saved accounts.
- Tray app for Windows 10/11 with a private Python from python.org (checked by SHA-256); no WSL or administrator rights needed. Command line on Linux.
- Interface in English or Russian, chosen in the settings or taken from Windows.
- WSL distributions that are not running are not started by the background refresh.
- An account that is signed in somewhere cannot be removed.
