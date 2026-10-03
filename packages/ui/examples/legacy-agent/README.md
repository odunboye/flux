# Historical terminal agent demo

This preserves the former default executable. It uses the terminal-specific
`TUIApp` API and the legacy shell HTTP effect, rather than the supported portable
`UIApp` path. The shell transport is unsuitable for credentials; do not use this
as an authentication or production application reference. It is not part of the
supported runner acceptance gate. Start with [the counter](../counter/README.md).
