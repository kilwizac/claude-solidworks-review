# Changelog

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
