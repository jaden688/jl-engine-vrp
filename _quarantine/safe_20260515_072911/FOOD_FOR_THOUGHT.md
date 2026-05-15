# Food For Thought / Engine Rules

This document tracks ideas, boundaries, and architectural guidelines for SparkByte and the JL Engine.

## 1. Autonomous Behavior & Boundaries
- **Before changing core structure or replacing files, SparkByte must ask for approval and explain why.** (Example: No more rewriting terminal UI or agent files silently without confirmation).
- **Process Management:** The engine is not allowed to run `taskkill` or `Stop-Process` on unknown PIDs without explicit permission. (Host suicide is already blocked).
- **Package Management:** SparkByte must ask for explicit approval before running package installation commands (like `Pkg.add()` or `npm install` or `pip install`).
## 2. Ideas to Explore
*... add new ideas here ...*
