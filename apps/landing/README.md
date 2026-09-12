# Flux landing page

A native **Idris + Flux HTTP server**, serving its own landing page. There is
no Node production server, React application, remote font or analytics service.
The page is useful without JavaScript; the small optional script adds keyboard
code tabs, a mobile menu and clipboard feedback.

## Run

From the repository root:

```sh
pack --no-prompt build apps/landing/landing.ipkg
(cd apps/landing && ./build/exec/flux-landing 8080 128)
```

Open **http://127.0.0.1:8080**. Run from `apps/landing` so the server can locate
`public/`. Ctrl-C stops it. No PostgreSQL, Docker or frontend build is required
to serve this site. Edit HTML/CSS/JS and refresh; rebuild after Idris changes.

The application CLI's `dev` command targets generated-RPC applications, not
this independent, database-free Flux server package.

For environment-driven configuration, use `--from-env`, with the existing
`FLUX_SERVER_HOST`, `FLUX_SERVER_PORT` and other Flux server settings. Defaults
bind loopback. Put public deployments behind a TLS-terminating reverse proxy;
this server does not itself implement HTTPS. Keep the working directory and
`public/` alongside the native server bundle, and direct shutdown signals to
the native server process when using a process manager.

## Design and content

Inspired by [serverpod.dev](https://serverpod.dev)'s developer-facing sequence:
clear positioning, server/client examples, a modular feature grid and an
immediate getting-started path. The copy, geometric Flux mark, CSS illustration
and implementation are original; no Serverpod logos, screenshots, testimonials
or proprietary assets are reused.

The hero is an explicitly labeled illustration, not a pretend interactive app.
Product claims distinguish implemented features from unfinished authenticated
PostgreSQL TLS, identity/authorization, SDK packaging and deployment. No invented
customer counts, performance numbers, managed cloud or production parity claims.
The quickstart uses the real repository CLI and explains disposable cleanup.

External links point to the repository and issues. No deployment domain or
canonical URL is invented; configure those metadata values once a public host
has been selected and verify the published repository contains this preview.

## Boundaries

`src/Main.idr` exposes only `/`, `/site.css`, `/site.js`, `/mark.svg` and `/health`.
The repository and source tree are never mounted as static content. A strict
self-only CSP, no-sniff, referrer and permissions policies also cover errors.
There are no API, authentication, form submission or database routes here.

## Verify

With Playwright/Chromium installed from `packages/ui/package-lock.json`:

```sh
python3 apps/landing/test_site.py
```

The test starts the actual native server and checks HTTP status/MIME/security,
source-path rejection, code tabs with arrow/Home keyboard navigation, clipboard
success/failure, native FAQs, mobile menu/Escape behavior, reduced motion,
320–1440px page widths and a JavaScript-disabled browser. It checks clean
shutdown and writes desktop, full-page and mobile screenshots to
`.workspace/landing/` (failure screenshots are retained there too).

This is also part of `python3 tools/workspace.py test`, including `--without-db`,
so the root platform CI job protects the site. These are functional browser
checks, not a claim of a comprehensive accessibility audit or pixel-identical
rendering across browser engines.
