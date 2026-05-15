# Script Lanes

Use this folder to keep language tooling organized and out of project root.

- `@jl-scripts` Julia ops and engine utilities
- `@py-scripts` Python automation and data tasks
- `@node-scripts` Node/TS adapters and web automations
- `@rust-scripts` performance/security helpers
- `@ps-scripts` Windows operational scripts
- `@bat-scripts` lightweight launcher wrappers
- `@go-scripts` network/service tools
- `@cs-scripts` .NET utilities
- `@java-scripts` JVM integrations
- `@sql-scripts` DB maintenance/query packs
- `@tests` cross-language smoke/integration scripts

Output policy:
- Generated files go to `runtime/dropzone/*`
- Do not write generated artifacts to repo root
