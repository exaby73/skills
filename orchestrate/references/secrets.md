# Secrets

A secret that enters an agent's context can end up in a log, a transcript, or a brief. Keep every value out of context: move it from the owner to the command that needs it without it ever being printed.

## Keep Values Out of Sight

- Never print the environment or a secret: no `env`, `printenv`, `set -x`, `echo $SECRET`, or `cat` of an env file. Check a variable is set with `[ -n "$NAME" ] && echo set`.
- Keep secrets out of briefs, pull requests, issues, commit messages, and the checkpoint log. Name the file that holds one instead.

## Take a Secret From the Owner

- Ask through the host's private input, one that writes the value to a file readable only by you (mode 0600), never through chat.
- Without one, ask the owner to write the file themselves: `umask 077; read -rs v; printf %s "$v" > <path>; unset v`.
- Or, when the value is on their clipboard, pipe it straight in, then clear the clipboard: `pbpaste | gh secret set NAME` and `pbcopy < /dev/null` on macOS; `wl-paste` or `xclip -o -selection clipboard` on Linux.

## Pass It

Pass a secret on stdin, from its file: `gh secret set NAME < <path>`, `docker login --password-stdin < <path>`, or `sudo -S -p '' <cmd> < <path>`. Never put one in a command's arguments, where `ps` and the shell history show it.

## Remove It

When the work is done, ask the owner before deleting the file, then shred it: `shred -u <path>` on Linux, `rm -P <path>` on macOS.
