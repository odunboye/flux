# Security policy

## Reporting

Report suspected vulnerabilities privately to the repository owner. Do not
include credentials, access tokens, or private user data in public issues.

## Browser deployment

Iris-generated controls do not use inline JavaScript handlers. Applications
should serve assets over HTTPS and start with this Content Security Policy,
then narrow `connect-src` to their actual APIs:

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; connect-src 'self' https:; img-src 'self' data:; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'
```

The web renderers materialize generated declarations through a constructed
stylesheet and emit neither `style` elements nor `style` attributes. This
requires browser support for `CSSStyleSheet` and `document.adoptedStyleSheets`.
Do not place untrusted values in custom CSS or URLs. Widget text and attributes
are escaped by the renderer.

Use `FetchOptions` to set request timeouts and response limits. Keep secrets
out of browser bundles and WebView source; browser API keys are visible to the
user. Native applications should store credentials through platform secure
storage rather than localStorage.

## Dependency checks

CI runs `npm audit` for browser-test and Capacitor JavaScript dependencies.
Native dependency scanning belongs in the platform-specific Xcode/Gradle
pipeline.
