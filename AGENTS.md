# Agent Instructions

## NEVER Write Outside the Project

**The first and strongest default rule: agents and every subprocess they launch must keep every controllable write inside `/Users/richard/code/BicTerm`.** Changing the working directory, invoking another tool, or delegating work does not weaken or relocate this boundary. The only exception is the narrow Apple tooling exception below.

- Never select `/tmp`, `/private/tmp`, `$HOME`, home-directory caches, Downloads, Desktop, or any other external scratch, build, test, log, result, cache, or evidence path.
- Treat DerivedData, result bundles, logs, screenshots, temporary files, package/cache overrides, evidence, generated artifacts, downloads, and tool metadata as agent-controlled outputs subject to this rule.
- Before running any command that can write, inspect every explicit and implicit output, cache, temporary, build, result, screenshot, log, and evidence path and confirm it resolves within `/Users/richard/code/BicTerm`.
- Override tools whose defaults write externally. Use repository-local destinations such as `.build-artifacts/DerivedData/<task>`, `.build-artifacts/xcresults/`, `.sisyphus/evidence/`, and `.scratch/`.
- Apple Xcode and CoreSimulator tooling may perform incidental system-managed writes outside the repository only when those writes are inherent, cannot be redirected, and the tooling is required for build, test, or simulator QA. This permits only Apple-created simulator/device state and unavoidable Apple tool metadata; it does not permit agents to choose external output, cache, log, screenshot, result, temporary, package, evidence, or scratch paths.
- Outside that narrow exception, do not run a command when all of its writes cannot be redirected into the project or when containment cannot be guaranteed. The exception does not apply to non-Apple tools.
- Ensure scripts, child processes, build systems, test runners, simulators, package managers, and other delegated tools obey the same boundary.

No convenience, default behavior, debugging need, or evidence requirement permits any exception beyond the unavoidable Apple tooling writes defined above.
