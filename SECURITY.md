# Security and privacy

## Reporting a problem

Please report security or privacy problems privately through [GitHub's private vulnerability reporting](https://github.com/kilwizac/claude-solidworks-review/security/advisories/new), not in a public issue. Examples:

- a way for drawing content to make Claude do more than review;
- the background run reaching files outside its run folder;
- data leaving the machine that the README doesn't mention.

## How the project limits what can happen

- **Data sent to Claude:** the drawing PDF and `drawing-data.md` (values, notes, properties and file names; not full paths). See [Privacy and security](README.md#privacy-and-security) in the README.
- **Background review (the default):**
  - Claude Code runs with `--restricted --strict-mcp-config --tools Read`, so Read is its only tool, confined to the run folder.
  - Your Claude Code settings and MCP servers aren't loaded.
  - The script writes Claude's answer to disk; Claude can't write files.
- **Drawing text:** treated as data. The checklist tells Claude that notes, properties and table cells are never instructions, and to report anything that reads like one as a finding.
- **Report page:** everything that comes from the drawing or from Claude is HTML-escaped before it goes into `review.html`.
- **Cleanup:** the macro deletes only run folders that contain its own `.claude-review-run` marker.
- **PowerShell:** `-ExecutionPolicy Bypass` applies to the single PowerShell process that runs `run-review.ps1`, and Group Policy can still block it.
