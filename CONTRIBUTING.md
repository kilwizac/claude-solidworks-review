# Contributing

Issues and pull requests are welcome, especially:
- improvements to [`review-instructions.md`](review-instructions.md) (drafting rules worth checking);
- reports from SOLIDWORKS versions, drawing types and locales the project hasn't been tried on.

## Working on it

- **The macro:**
  - `src/ClaudeReviewDrawing.bas` is the source. Import it into a `.swp` (see [Or build from source](README.md#or-build-from-source)).
  - If you edit in the VBA editor, export the module back over the `.bas` before committing.
  - `.swp` files aren't committed.
- **The background review and report:**
  - `run-review.ps1` must stay **ASCII-only**, because Windows PowerShell 5.1 reads scripts without a BOM in the ANSI code page.
  - To iterate on the page without calling Claude:

    ```
    powershell -ExecutionPolicy Bypass -File run-review.ps1 -Folder "<run folder>" -RenderOnly
    ```

- **SOLIDWORKS API:** check member and enum names against the [API help](https://help.solidworks.com/2025/english/api/sldworksapi/welcome.htm) for the version you target. VBA only reports a wrong name when the macro compiles. Call members that vary between versions late-bound, through `TryValue`. The tests check every `sw...` constant and API member name against SOLIDWORKS's own type libraries, including the names passed to `TryValue` as strings, which VBA never checks.

## Tests

One command runs them, in Windows PowerShell like the macro:

```
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

Pester 5 is used; if you don't have it, a copy is downloaded once into `tests\.tools`. The report page tests need [Node.js](https://nodejs.org) and run in Microsoft Edge.

| What | When it runs | What it covers |
| --- | --- | --- |
| Repo checks | every run, and on GitHub | ASCII and line endings, scripts parse in PowerShell 5.1 and 7, VBA import limits, the checklist's answer format matches what the report reads, README settings match the macro |
| `run-review.ps1` | every run, and on GitHub | reading Claude's answer (pins, sheets, verdicts, odd tables), the report it writes, sheet images, and a stand-in `claude.exe` that answers, fails, returns nothing or hangs |
| Report page | every run, and on GitHub | the page in Edge: balloons, zoom and pan, `#finding-N` links, filters, Fixed boxes, light and dark, narrow windows, printing, escaping of drawing text |
| Installer and release | every run, and on GitHub | fresh installs and upgrades, the release zip, and its README links and notes |
| API names | every run on a PC with SOLIDWORKS 2025 | SOLIDWORKS constants and members in both `.bas` files |
| SOLIDWORKS end to end | `-SolidWorks` | builds the demo drawing, runs the review macro on it as a user would, and checks the PDF, `drawing-data.md` (every planted mistake pre-flagged), the report, and the messages it shows |
| Live review | `-Live` | a real review by Claude Code of the demo drawing, which must find the planted mistakes and pin them; takes a few minutes and counts toward your Claude plan |

- **Before a pull request:** run the tests. If you changed the macro, rebuild the `.swp` and add `-SolidWorks`; mention your SOLIDWORKS version. If you changed `review-instructions.md`, add `-Live`.
- **The end-to-end test** starts SOLIDWORKS 2025, or uses the running one, and closes only the documents it opened. It refuses to run if a `.swp` doesn't hold the code in its `.bas`: the tests read the VBA source out of the `.swp` (`tools\SwpSource.psm1`) and compare.
- **`-UpdateFixtures`** with `-SolidWorks` saves the demo drawing's export as `tests\fixtures\demo`, and with `-Live` also Claude's review. Do it when the macro's output changes.
- `-Path tests\RunReview.Tests.ps1` runs one file; `-SkipBrowser` leaves out the page tests and `-BrowserOnly` runs only them.

## Releasing

1. Rebuild both macros in SOLIDWORKS: open the `.swp`, remove its module, **File → Import File** the `.bas`, **Debug → Compile**, and save. `ClaudeReviewDrawing.swp` comes from `src\ClaudeReviewDrawing.bas`, `demo\BuildDemoDrawing.swp` from `demo\BuildDemoDrawing.bas`.
2. Run `tests\Run-Tests.ps1 -SolidWorks`, and `-Live` if the checklist or prompt changed.
3. In `CHANGELOG.md`, rename `## Unreleased` to `## <version> - <date>`, then commit and push.
4. Check everything without publishing:

   ```
   powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -Version <version> -DryRun
   ```

   This builds `dist\ClaudeSolidWorksReview-<version>.zip` and the notes `dist\release-notes-<version>.md`. It refuses to go on if:
   - a `.swp` doesn't hold the code in its `.bas` (it reads the code out of the `.swp`);
   - the CHANGELOG has no section for the version;
   - the tree has uncommitted changes, or HEAD isn't pushed;
   - tag `v<version>` points at another commit.

   It then runs the tests, and `tools\verify-release.ps1` on the zip: layout, line endings, the macros' code, README links, a quiet install, and a report rendered by the installed scripts.
5. The same command with `-Upload` publishes. The release is created on the commit that was tested. On GitHub, the **Verify release** workflow then checks the published zip again, including that the README's links answer.

To check any release zip: `tools\verify-release.ps1 -Zip <zip> [-CheckLinks]`.

## Line endings

`.gitattributes` keeps `.bas`, `.ps1`, `.psm1`, `.cs` and `.cmd` files in CRLF, which the VBA editor's **Import File** and `cmd.exe` expect, and Markdown, JavaScript and YAML in LF. The tests check the files on disk, since the release zip is built from them.
