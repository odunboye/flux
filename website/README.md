# Flux landing page

A native **Idris + Flux HTTP server**, serving its own landing page. There is
no Node production server, React application, remote font or analytics service.
The page is useful without JavaScript; the small optional script adds keyboard
code tabs, a mobile menu and clipboard feedback.

## Run

From the repository root:

```sh
pack --no-prompt build website/landing.ipkg
(cd website && ./build/exec/flux-landing 8080 128)
```

Open **http://127.0.0.1:8080**. Run from `website` so the server can locate
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
clear positioning, server/client examples, prominent feature showcases followed
by a scannable capability grid, and an immediate getting-started path. The copy, geometric Flux mark, CSS illustration
and implementation are original; no Serverpod logos, screenshots, testimonials
or proprietary assets are reused.

The hero and feature diagrams are illustrations, not live dashboards. Four large
feature cards explain PostgreSQL/migrations, accounts/private tasks, Flux UI and
generated contracts. Eight compact cards cover runtime ownership, verified PG TLS,
native RPC, health, tracing, the local CLI, integration checks and working examples.
Feature jump links work with or without JavaScript; mobile cards become a single
column with compact icon-and-text rows for the smaller capabilities.

Product claims distinguish implemented capabilities from future application
caching, managed jobs, uploads, realtime, SDK packaging and production deployment.
Authentication and verified PG TLS are implemented; ownership is demonstrated by
the private starter, not automatically granted to arbitrary application SQL.
There are no invented customer counts, performance numbers, managed cloud or
production parity claims. The code panel now shows a real principal-scoped query.
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
python3 website/test_site.py
```

The test starts the actual native server and checks HTTP status/MIME/security,
source-path rejection, code tabs with arrow/Home keyboard navigation, clipboard
success/failure, native FAQs, mobile menu/Escape behavior, reduced motion,
320–1440px page widths and a JavaScript-disabled browser. It checks clean
shutdown, the four showcases/eight capabilities, feature anchors and explicit
future-work labeling. It writes desktop, full-page, mobile and feature-section
screenshots to `.workspace/landing/` (failure screenshots are retained there too).

This is also part of `python3 tools/workspace.py test`, including `--without-db`,
so the root platform CI job protects the site. These are functional browser
checks, not a claim of a comprehensive accessibility audit or pixel-identical
rendering across browser engines.
