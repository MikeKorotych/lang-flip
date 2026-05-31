# LangFlip plan.html workflow

`docs/plan.html` is the visual operating manual for LangFlip. It complements:

- `README.md` for user-facing product explanation.
- `ROADMAP.md` for long-form planning.
- `CHANGELOG.md` for release history.

## When to update it

Update `docs/plan.html` whenever a change affects one of these:

- architecture or component boundaries;
- user-facing workflows, hotkeys, onboarding, preferences, AI, voice;
- roadmap order, release strategy, backlog priority;
- notable decisions that future work should remember;
- release narrative after a changelog entry.

## How to update it

1. Read the relevant source docs and code before editing.
2. Keep the style system inside the page reusable: CSS variables, cards, metrics, phase rows, decisions, flow diagrams.
3. Prefer updating an existing tab over adding a new tab. The page should stay scan-friendly.
4. Add a short Chronicle entry for meaningful project shifts.
5. Open the page with `make plan` and check tabs, diagrams, and mobile width.

## Codex prompt

Use this when asking Codex to keep the plan current:

```text
Обнови docs/plan.html как living plan для текущих изменений. Сначала прочитай README.md, ROADMAP.md, CHANGELOG.md и затронутый код, затем обнови только релевантные tabs, decisions, release notes и chronicle. Проверь, что make plan открывает страницу.
```

