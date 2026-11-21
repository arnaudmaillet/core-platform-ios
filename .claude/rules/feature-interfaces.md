---
paths:
  - "Packages/FeatureInterfaces/**"
---
# Working in a feature interface

- **An interface holds value types, builder protocols and routes**, and nothing heavier than those values need. No views, no implementations.
- **Every type here is a promise** to every feature that imports it. Keep it small, `public` on purpose, documented.
- **Depend only on Kit and other interfaces** (`LayeringGuardTests`).
