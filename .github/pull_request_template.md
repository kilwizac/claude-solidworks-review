## What and why

<!-- What this changes, and why. Link the issue if there is one. -->

## Tested

- [ ] `powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1` passes (GitHub runs it too)
- [ ] Changed a `.bas`: rebuilt the `.swp` and ran `tests\Run-Tests.ps1 -SolidWorks` on SOLIDWORKS <!-- version and SP, e.g. 2025 SP5.0 -->
- [ ] Changed `review-instructions.md` or the prompt: ran `tests\Run-Tests.ps1 -Live`
- [ ] Changed the macro's output: refreshed the fixtures with `-UpdateFixtures`
- [ ] Added a line to `CHANGELOG.md` under **Unreleased** for anything a user would notice
