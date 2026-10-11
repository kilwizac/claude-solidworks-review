# Contributing

Issues and pull requests are welcome, especially:
- improvements to [`review-instructions.md`](review-instructions.md) (drafting rules worth checking);
- reports from SOLIDWORKS versions, drawing types and locales the project hasn't been tried on.

## Working on it

- **The macro:**
  - `src/ClaudeReviewDrawing.bas` is the source. Import it into a `.swp` (see [Build the macro](README.md#build-the-macro)).
  - If you edit in the VBA editor, export the module back over the `.bas` before committing.
  - `.swp` files aren't committed.
- **The background review and report:**
  - `run-review.ps1` must stay **ASCII-only**, because Windows PowerShell 5.1 reads scripts without a BOM in the ANSI code page.
  - To iterate on the page without calling Claude:

    ```
    powershell -ExecutionPolicy Bypass -File run-review.ps1 -Folder "<run folder>" -RenderOnly
    ```

- **SOLIDWORKS API:** check member and enum names against the [API help](https://help.solidworks.com/2025/english/api/sldworksapi/welcome.htm) for the version you target. VBA only reports a wrong name when the macro compiles. Call members that vary between versions late-bound, through `TryValue`.
- **Testing:** build the demo drawing (`demo/BuildDemoDrawing.bas`), run the review on it, and check that every planted mistake is found and pinned. Mention which SOLIDWORKS version you tested on.

## Line endings

`.gitattributes` keeps `.bas` and `.ps1` files in CRLF, which the VBA editor's **Import File** expects. Keep it that way.
