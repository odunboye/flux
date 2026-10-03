# Landing feature layout

A Serverpod-inspired information hierarchy with original Flux visuals and copy:
four illustrated feature showcases, eight compact capability cards, feature jump
links and an explicit future-work boundary. The server/client example now includes
a real principal-scoped query and session-aware client command.

## Verified

`python3 apps/landing/test_site.py` passed against the actual native Flux landing
server with the updated assets, in local macOS Chromium:

- Four showcases and eight capability cards; implemented/future scope labels.
- Keyboard feature navigation and native fragment links with JavaScript disabled.
- Whole-page and individual card bounds at 1440, 1024, 768, 390 and 320 pixels.
  Tablet showcases use equal columns to prevent diagram overflow.
- Existing HTTP/MIME/CSP, asset allowlisting, error security headers, code-tab
  keyboard controls, mobile menu, clipboard success/failure, reduced motion,
  no-JS fallback and clean native server shutdown checks.

See `browser.log`, `features-desktop.png` and `features-mobile.png`. These are
local Chromium checks, not a comprehensive accessibility audit, hosted Linux
result or production deployment. Server logic and JavaScript behavior were not
changed; no full workspace gate was run for this presentation-only change.

Reference: https://serverpod.dev/ — feature-first structure only. No Serverpod
copy, brand assets, testimonials or customer claims are reused. No third-party
fonts, scripts, tracking or image requests were introduced. Unrelated ongoing
CLI/dev-reload changes were left untouched.
