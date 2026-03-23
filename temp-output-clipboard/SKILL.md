---
name: temp-output-clipboard
description: Generate user-requested text into a temporary file and copy it to the system clipboard. Use when the user asks to draft, write, or generate text and wants quick copy/paste. Default to a Markdown temp file (`.md`) unless the user explicitly asks for another format.
---

# Temp Output Clipboard

Follow this workflow whenever generating text output.

## Workflow

1. Determine format.

- Use Markdown (`md`) by default.
- If the user explicitly requests another format, use that format.

2. Generate the final text content.

3. Save the content to `/tmp`, copy to clipboard, and get the file path:

```bash
cat <<'EOF' | <skill-dir>/scripts/save_output_and_copy.sh --format <format>
<generated text>
EOF
```

- Omit `--format` to keep default Markdown.
- The script prints the created file path to stdout.

4. Return the result.

- Include the generated text unless the user asks for path-only output.
- Include the file path returned by the script.
- If clipboard copy is unavailable, mention the warning and still provide the file path.

## Format Rules

- Default format: `md`.
- Map common requests to extensions:
    - `markdown` -> `md`
    - `text` or `plain` -> `txt`
    - `yaml` -> `yml`
    - `bash` or `shell` -> `sh`
- If the user provides a specific extension, use it directly.

## Script

- Resolve the skill directory from the loaded skill path, then
  call [scripts/save_output_and_copy.sh](scripts/save_output_and_copy.sh) with an absolute path.
- Clipboard command priority:
    1. `pbcopy`
    2. `wl-copy`
    3. `xclip`
    4. `xsel`
    5. `clip.exe`
    6. `powershell.exe` with `Set-Clipboard`
