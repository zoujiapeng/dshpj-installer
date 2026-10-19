# Contributing

Thanks for looking. This repo is deliberately small: one overlay file, three
plugin modules, four installers. Keep it that way.

## What a layer is

A layer is a pair:

1. `assets/pj-<name>.mjs` — a plugin module with `export const name`, optional
   `export const inject`, and `export function apply(ctx, config)`.
2. an `- insert:` block in `assets/patch.yml` with `id: pj-<name>`, `name:
   "./pj-<name>.mjs"` and its `config`.

Never add a layer by hand-editing a launcher. The launcher passes exactly one
`--patch`; everything else lives in the overlay.

## Hook points that exist today

| Kind | Call | Notes |
|---|---|---|
| system prompt section | `ctx.systemPrompt.section({ name, order, text })` | lower `order` = earlier. `pj:operator-policy` is `-999`, `pj:final-authority` is `10250`, `pj:fact-authority` is `10777` |
| runtime context | `ctx.systemPrompt.context({ name, order, text: () => string })` | appended as a user-role snapshot every step. Return text that changes (counter + timestamp) or the loop may dedupe it |
| assembly rewrite | `ctx.on('system-prompt/assemble', …)` | rewrite sections/tools before the request is built |
| sampling | `ctx.on('agent/request', …)` | override temperature etc. |
| stream | `ctx.on('llm/stream', async function* (options, next))` | wrap the model call; used for refusal retry and output scrubbing |

## Before you open a PR

```bash
bash install.sh                       # into ~/.dshpj
~/.dshpj/bin/dshpj-doctor             # must print PASS
```

If you touched prompt text, dump and diff it:

```bash
DSHPJ_PROMPT_DUMP=/tmp/before.txt dsh --profile headless --patch assets/patch.yml "hi" >/dev/null
# edit
DSHPJ_PROMPT_DUMP=/tmp/after.txt  dsh --profile headless --patch assets/patch.yml "hi" >/dev/null
diff <(grep '^<!-- ' /tmp/before.txt) <(grep '^<!-- ' /tmp/after.txt)
```

Include in the PR body: the hook you used, the order number, the layer count
before/after, and the real command output you verified with. A diff alone is not
reviewable.

## Style

- Plain ESM, no dependencies. The installer must work with `bash`, `curl` and
  `node` only.
- `.ps1` files stay pure ASCII (Windows PowerShell 5.1 mangles BOM-less UTF-8).
- Comments in the plugins explain *why a hook is there*, in the operator's
  language; user-facing strings follow the operator's language too.
- Fail closed on write errors (`try { writeFileSync } catch {}`); a debug dump
  failing must never break prompt assembly.

## License

By contributing you agree your work is released under the [MIT License](LICENSE).
