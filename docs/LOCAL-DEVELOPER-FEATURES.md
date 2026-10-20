# Developer features in 0.0.3 Beta

Cursor and Grok integrations are opt-in through Settings → Panels & Features → Developer features (Cursor / Grok beta). Ordinary mode hides their accounts, platform links, provider controls, and panel content, and does not start subsequent usage refreshes for them. Existing data and per-provider choices are retained.

The remaining/used display switch is in the same Panels & Features group.

Availability, persistence, menu grouping, stable-provider behavior, and refresh gating are covered by DeveloperFeatures.Tests.ps1. Tests use fixtures and do not require provider credentials.

A local read-only usage probe found no usable sign-in for either experimental provider. Live API availability still requires a signed-in installation to verify.
