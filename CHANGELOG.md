# Changelog

## Unreleased

### Added
- Clicking a finding puts `#finding-N` in the address, and a link with it opens the report on that finding, also when pasted into a page that's already open.
- The drawing keeps its zoom when the window is resized or the drawing is shown again, and balloons change size much less while it zooms.
- A background review that runs past 30 minutes is stopped with a message (`-TimeoutMinutes` changes the limit).
- Dimensions of a component in an assembly view are flagged, since their value may come from another configuration than the view shows.
- Automated tests (`tests\Run-Tests.ps1`), run by GitHub Actions on every push and pull request. Locally they can also drive SOLIDWORKS end to end on the demo drawing, and have Claude review it. See [CONTRIBUTING.md](CONTRIBUTING.md#tests).
- `run-review.ps1 -NoDialog` reports errors only in `claude-log.txt` and the exit code (now 1 on failure), for scripts.
- `tools\verify-release.ps1` checks a release zip, and a **Verify release** workflow runs it on every published release.

### Changed
- `tools\make-release.ps1`:
  - checks the code inside each built macro against its `.bas`, instead of comparing file dates;
  - always saves the release notes to `dist\`;
  - with `-Upload` or the new `-DryRun`, refuses a release without a CHANGELOG section, with uncommitted or unpushed changes, or with its tag on another commit;
  - runs the tests and `verify-release.ps1` before uploading, and creates the release on the tested commit.

### Fixed
- Release zips use `/` in their paths. 0.2.0's used `\`, which only Windows reads.
- A Pin written with percent signs (`62%, 41%`) puts a balloon on the drawing; before, the finding had none.
- A finding with Sheet `0` gets a dashed balloon instead of one that does nothing when clicked.
- An answer without a findings table no longer shows its Verdict line twice.
- An error in a background review is written to `claude-log.txt` before the message box appears, not after it's closed.
- Hidden annotations, annotations on hidden layers and hidden views are left out of `drawing-data.md`, so Claude doesn't flag what never prints.
- When Claude Code fails (e.g. not signed in), its message is shown and logged instead of being saved as `review.md`.
- A summary on the line after the Verdict line is no longer dropped from the report.
- A Sheet column of "Sheet 2" puts the balloon on sheet 2, not sheet 1.
- `-RenderOnly` with a relative folder keeps its balloons. A failed sheet render no longer leaves images for the next run to reuse, and its log line gives the real error.
- Report page: a malformed `#finding-` address no longer breaks the header buttons, a link to a finding on sheet 2 isn't undone when sheet 1 loads, a click that wobbles a pixel no longer counts as a pan, and balloon colour fades keep working after an animated zoom.
- Installer:
  - no longer stops at the start when the Documents folder doesn't exist (e.g. a broken folder redirection);
  - unblocks only the files it installs, not everything in the chosen folder;
  - replaces a `review-instructions.md` you never edited with the new default (only a customised one is kept), and always saves the default beside it as `review-instructions.default.md`;
  - Install.cmd explains when Group Policy blocks PowerShell scripts (the old check inside Install.ps1 could never run);
  - refuses to install over a clone of the repository.
- The installed README's links to files that aren't installed go to GitHub.

## 0.2.0 - 2026-10-10

### Added
- **One-step install.** The release zip includes prebuilt macros and an **Install.cmd** installer. The installer:
  - checks for SOLIDWORKS 2025+, Claude Code and Claude Desktop, and whether Group Policy blocks scripts;
  - offers to install Claude Code with Anthropic's official installer, and opens a sign-in window;
  - unblocks the downloaded files and copies everything to a folder you pick;
  - keeps a customised `review-instructions.md` on upgrade.
- **Light/dark switch** in the report header; `?theme=light|dark` in the page's address forces either one.
- `tools/make-release.ps1` builds and publishes the release zip. It refuses `.swp` files older than their source.

## 0.1.0 - 2026-10-10

First public release.

### Macro
- A SOLIDWORKS 2025 VBA macro exports the active drawing to PDF and writes `drawing-data.md` from the API:
  - dimensions with tolerances and flags;
  - notes, GD&T (including frames created in 2022 or later), datum tags and tables;
  - custom properties, and sheet and view setup;
  - sheet positions for views, dimensions and notes.
- Pre-flags: overridden and dangling dimensions, datums referenced but never tagged, blank title-block properties.

### Review
- The default background mode runs the Claude Code CLI read-only, confined to the run folder.
- Four other ways to open the review in Claude Desktop (Code tab, Cowork, chat, or just the folder).

### Report
- `review.html` lists the findings beside the drawing, with a numbered balloon on the sheet for each finding.
- Severity filters, a Fixed checkbox for each finding, zoom and pan, and light and dark modes.

### Repo
- The review checklist is an editable `review-instructions.md`.
- `demo/BuildDemoDrawing.bas` builds a demo drawing with planted mistakes to try it on.
