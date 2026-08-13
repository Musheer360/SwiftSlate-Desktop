# Contributing to SwiftSlate Desktop

Thanks for wanting to contribute! Here's everything you need to know.

## Project Philosophy

- **Zero external dependencies** — uses only Python standard library and Windows APIs via ctypes
- **Single file** — the entire app is one `SwiftSlate.pyw` file, keep it that way
- **Lightweight** — blocking message loop with zero CPU when idle
- **Privacy first** — no analytics, no telemetry, no data leaves the machine except to the user's configured AI provider (and the built-in `?ip` command, which contacts ifconfig.me)

## Development Setup

```bash
git clone https://github.com/YOUR_USERNAME/SwiftSlate-Desktop.git
cd SwiftSlate-Desktop
```

Run directly on Windows with Python 3.10+:

```powershell
python SwiftSlate.pyw --debug
```

Debug mode runs in the foreground with full logging.

### Installer hash pins (one-time setup)

`install.ps1` pins the SHA-256 of `SwiftSlate.pyw` and `commands.json`, and CI fails
the build if a pin goes stale. A pre-commit hook keeps the pins in sync automatically,
so you never touch hashes manually:

```bash
git config core.hooksPath .githooks
```

After that, commits just work — the hook updates the pin in `install.ps1` and stages it
whenever either file changes.

## What You Can Contribute

| Area | What's needed |
|:-----|:-------------|
| **Commands** | New built-in AI commands with useful prompts |
| **Providers** | Integrations with additional OpenAI-compatible endpoints |
| **Bug fixes** | Especially around text replacement edge cases in specific apps |
| **Linux support** | Porting the keystroke detection and text replacement to Linux |
| **Installer** | Improvements to the PowerShell installer UX |

## Architecture Overview

Everything lives in `SwiftSlate.pyw`:

```
Win32 API declarations    → ctypes signatures for Raw Input, clipboard, SendInput
Keystroke processing      → Buffer management, trigger detection (longest match)
API clients               → Gemini + OpenAI-compatible with retry/key rotation
Text operations           → grab_field_text(), paste_text(), spinner animation
Command handlers          → AI transform, undo, clipboard, replacers
Main loop                 → Hidden window + GetMessageW (blocking, zero CPU idle)
```

Key behaviors to understand before touching core code:
- **Trigger detection** uses a fast-exit optimization (last character check) before full scan
- **Longest match** wins when multiple triggers could match
- **Buffer clears** on window change, navigation keys, Enter, Escape, Tab
- **Spinner animation** appends to original text (e.g., `how r u ◐`)
- **Clipboard operations** use exclusion flags to avoid polluting Windows clipboard history

## Testing Guidelines

There's a small pure-logic regression suite in `tests/` (run with
`python -m unittest discover -s tests -v`), plus CI (syntax check, pyflakes, ruff).
Most behavior is Windows-only, so manual testing is critical:

1. **Run in debug mode** — `python SwiftSlate.pyw --debug`
2. **Test trigger detection** — type triggers in Notepad, browser, VS Code, Teams
3. **Test both command types** — AI commands (need API key) and text replacer (offline)
4. **Check the undo command** — `?undo` should restore previous text
5. **Verify clipboard restoration** — after a transform, Ctrl+V should paste what was there before
6. **Test hot reload** — edit config.json or commands.json while running
7. **Test singleton** — try launching a second instance (it shows an "already running" message box and exits)

## Code Style

- Python, following the existing conventions in the codebase
- No auto-formatting tools — just match what's already there
- Keep functions focused and small
- Comments for Win32 API calls and non-obvious ctypes usage

## Submitting a PR

1. Fork and create a branch: `feature/your-thing` or `fix/the-bug`
2. Make your changes
3. Test on a real Windows machine (not WSL)
4. Verify syntax: `python -c "import py_compile; py_compile.compile('SwiftSlate.pyw', doraise=True)"`
5. Open a PR against `master` — fill in the template

## What I Won't Merge

- PRs that add third-party dependencies (pip packages, etc.)
- Changes that require admin/elevated privileges
- Features that collect user data or add telemetry
- Code that splits the app into multiple files unnecessarily
- Changes to ctypes/WNDPROC signatures that aren't verified on the Python version you target

## Questions?

Open an issue on the repo or reach out directly. Happy coding!
