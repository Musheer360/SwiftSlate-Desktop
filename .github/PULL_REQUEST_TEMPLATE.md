## What does this PR do?

<!-- Brief description of the change -->

## Type of change

- [ ] Bug fix (trigger detection, clipboard, API handling)
- [ ] New command (built-in AI or text replacer)
- [ ] New provider integration
- [ ] Installer improvement
- [ ] Refactor (no behavior change)
- [ ] Documentation

## Testing

- [ ] Tested trigger detection in Notepad / browser / messaging app
- [ ] Text replacer commands execute instantly (no regressions)
- [ ] AI commands return proper responses with configured provider
- [ ] Spinner animation works correctly during API calls
- [ ] Clipboard is restored after operations
- [ ] Hot reload picks up config/command changes
- [ ] No new external dependencies added

## Checklist

- [ ] Python syntax check passes (`python -c "import py_compile; py_compile.compile('SwiftSlate.pyw', doraise=True)"`)
- [ ] No hardcoded API keys or secrets
- [ ] Works with both system Python and embedded runtime
- [ ] Follows existing code style
