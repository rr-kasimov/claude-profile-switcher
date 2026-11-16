# Security

## What this tool stores

Claude Profile Switcher copies sign-ins of Claude Desktop and Claude Code into
`%USERPROFILE%\.claude-profiles` (`~/.claude-profiles` on Linux), one folder per e-mail:

- Claude Code: `.credentials.json` (OAuth access and refresh tokens) and the `oauthAccount` entry of `.claude.json`.
- Claude Desktop: the `oauth:*` entries of its `config.json` and its `Network/Cookies` database.

These are the same secrets the Claude apps keep in their own folders, stored the same way: plain files
readable by your user account (on Linux the folder is `0700` and files are `0600`). Claude Desktop
encrypts its tokens and cookies with Windows DPAPI, so they work only for the same Windows user.

Anyone who can read this folder can use the saved accounts. Do not sync it to cloud storage, do not
copy it to other machines, and do not commit it anywhere (`.gitignore` already excludes it).

## Network

The tool itself makes no network requests. The installer downloads the official embeddable Python
from python.org once and checks it against a pinned SHA-256 sum.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub: Security → Report a vulnerability
(https://github.com/Ioprst/claude-profile-switcher/security/advisories/new), with steps to reproduce.
You will get an answer within a week.
