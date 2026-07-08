# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in SwiftSlate Desktop, please report it privately:

**Email:** me@musheer360.com

**Subject line:** `[SwiftSlate Desktop Security] Brief description`

Please include:
- Description of the vulnerability
- Steps to reproduce
- Affected component (e.g., keystroke handling, clipboard operations, API calls)
- Potential impact

I'll acknowledge your report within 48 hours and provide a fix timeline.

## Scope

Security issues I'm particularly interested in:

| Area | Examples |
|:-----|:--------|
| **Keystroke handling** | Buffer leakage, unintended capture outside trigger detection |
| **Clipboard operations** | Data exposure, failing to exclude from clipboard history |
| **API communication** | Credential exposure in logs or error messages, insecure transmission |
| **Configuration** | API keys stored insecurely, path traversal in config loading |
| **Shell commands** | Command injection via replacer-shell commands |

## Out of Scope

- Vulnerabilities in upstream AI providers (Gemini, Groq, etc.)
- Issues requiring physical access to an unlocked machine
- Social engineering attacks
- Denial of service against the app itself

## Disclosure

Please do **not** open a public GitHub issue for security vulnerabilities. I'll coordinate disclosure with you once a fix is available.
