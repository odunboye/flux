# Use-case examples verification

2026-09-12, local macOS, pinned pack collection `nightly-260903` / Idris2
`74b33730b6fea649b15e8d01ab099df9effcc7a0`.

- The new `flux-use-cases` package compiled and passed actual HTTP tests for
  greetings, localization, typed quote computation, domain/body limits, JSON
  errors, error-path request IDs/security headers, health routes and clean shutdown.
- All **39/39** combined workspace steps passed, including the existing real
  PostgreSQL, account/session, native transport, generated-client and browser UI
  integration tests. Full source logs: `.workspace/reports/20260912-185639/`.
  The manifest now contains 24 canonical packages.
- All 29 tool unit tests passed separately; relative links in `examples/README.md`
  were checked against the repository.

The focused recipes are stateless public examples, not persistence/payment/auth
implementations. Advanced walkthroughs point to the existing compiled private
application and platform examples rather than introducing duplicate substitutes.
This run is local macOS evidence, not hosted Linux CI or production deployment.
