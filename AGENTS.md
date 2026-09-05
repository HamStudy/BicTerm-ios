# Agent Instructions

## NEVER Write Outside the Project

**The first and strongest rule: agents and every subprocess they launch must never write outside `/Users/richard/code/BicTerm`. This boundary is absolute and non-negotiable.** Changing the working directory, invoking another tool, or delegating work does not weaken or relocate this boundary.

- Never write to `/tmp`, `/private/tmp`, `$HOME`, home-directory caches, or any other external scratch, build, test, log, result, or evidence path.
- Treat caches, DerivedData, result bundles, screenshots, logs, generated artifacts, downloads, temporary files, and tool metadata as writes subject to this rule.
- Before running any command that can write, inspect every explicit and implicit output, cache, temporary, build, result, screenshot, log, and evidence path and confirm it resolves within `/Users/richard/code/BicTerm`.
- Override tools whose defaults write externally. Use repository-local destinations such as `.build-artifacts/DerivedData/<task>`, `.build-artifacts/xcresults/`, `.sisyphus/evidence/`, and `.scratch/`.
- Do not run a command when all of its writes cannot be redirected into the project or when containment cannot be guaranteed.
- Ensure scripts, child processes, build systems, test runners, simulators, package managers, and other delegated tools obey the same boundary.

No convenience, default behavior, debugging need, or evidence requirement permits an exception.
