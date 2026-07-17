# Image-gen prompts for line-art rasters

The tracer needs a **clean single-weight black line drawing on white** — no fills,
no shading, no double strokes. The prompt does most of the work.

## House-style template

```
A single continuous line-art drawing of <SUBJECT>, one consistent stroke weight,
smooth flowing hand-drawn line, black ink on a pure white background.
No shading, no fill, no cross-hatching, no color. Minimal and elegant, one
unbroken gesture where possible. Centered, generous margin, plenty of whitespace.
Flat, front-on, iconic. Think a single-line tattoo / continuous-line illustration.
```

Load-bearing phrases: **single continuous line · one stroke weight · black on white
· no shading/fill · centered · generous margin.** Drop them and you get filled or
shaded art the centerline tracer can't follow.

## Generation route

Proven route — **codex CLI** image tool (GPT Image; uses the ChatGPT subscription,
no `OPENAI_API_KEY`):

```bash
printf '%s' "PROMPT" | codex exec --skip-git-repo-check --sandbox workspace-write -C /tmp
# then collect the written PNG from the sandbox dir it reports
```

Any in-session image MCP tool with an `openai_generate_image`-style call works too.
(Note: a "tripo" MCP is for **3-D** models — not this; use the image tool.)

### Generating a batch — avoid image collisions

codex's `image_gen` writes into a shared `~/.codex/generated_images/` directory and
then copies **the most-recent PNG** out to the path you asked for. Run several
`codex exec` generations **concurrently** and two can finish near-simultaneously and
copy *each other's* image — you get the right filename with the wrong picture. The
stroke count still looks fine, so only a **visual check** catches it.

For a batch: **generate sequentially** (one `codex exec` at a time) — or give each call
its own working dir and confirm the PNG before the next starts. Either way, always
render a contact sheet of the finished set (load each motif's Lottie, `goToAndStop` its
last frame, screenshot the grid) and eyeball it for wrong-subject collisions and
lookalikes before building GIFs.

## The NEM motif set (reference prompts)

Subjects that traced cleanly into the shipped set — each is `<SUBJECT>` in the
template above. Tints are applied later at Stage 3 (`--tint`), not in the raster.

| motif       | subject phrase                                              | tint (Stage 3) | feeling        |
|-------------|-------------------------------------------------------------|----------------|----------------|
| heart-hand  | an open hand gently cradling a small heart                  | `#E07058`      | care / holding |
| leaf        | a single leaf on a curving stem                             | `#3D8A6B`      | growth         |
| moon        | a crescent moon with one small star                         | `#956BD6`      | rest / night   |
| waves       | three calm horizontal water waves                           | `#3BB8A2`      | calm           |
| candle      | a lit candle with a soft single-line flame                  | `#D99F60`      | light          |
| teacup      | a teacup on a saucer with a wisp of steam                   | `#415B4F`      | held space     |
| nest        | a small bird's nest with two eggs                           | `#8A6A4A`      | belonging      |
| thread      | a needle and a looping thread                               | `#E07058`      | connection     |
| sun         | a rising sun with simple rays over a horizon line           | `#D99F60`      | morning        |
| feather     | a single soft feather                                       | `#97B8CB`      | gentleness     |
| cat-curled  | a cat curled up asleep, one continuous outline              | warm neutral   | rest / quiet   |

For a coherent *set*, keep the subject descriptions parallel in complexity and
always end with the same style tail — that's what makes ten motifs feel like one
hand. Generate a couple of variations per subject and pick the cleanest single-line
one before tracing.

## Tint palette note

NEM tints double as persona accents (Rose `#E07058`, Vera `#3D8A6B`, Hazel
`#956BD6`, Betsy `#3BB8A2`). The empty-state heart ships **deep-green `#415B4F`**
(the DS ink), *not* a persona tint — persona colors are for persona-scoped marks.
Pick tint by context: brand/DS ink for neutral surfaces, persona accent when the
mark belongs to a persona.
