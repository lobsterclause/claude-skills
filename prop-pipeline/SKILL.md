---
name: prop-pipeline
description: >-
  End-to-end pipeline for turning a text idea (or a reference image) into a
  game-ready 3D prop using AI image generation (codex / GPT Image / Tripo) and
  the tripo-mcp tools (Tripo image-to-3D plus local Blender finishing), with a
  MANDATORY review gate — including a visual-logic / geometric-consistency
  check — before any credit-spending generation, and a local finishing pass
  (scale, welded reduction, normal bake, colour grade) after it. Use this
  whenever the user wants to generate, create, or make a 3D model / prop /
  asset from a description, add props to a game, turn an image into 3D, or run
  the "Tripo pipeline" — even casual phrasings like "make me a 3D crate" or
  "generate a model of a busted vending machine". Always reach for this BEFORE
  calling tripo_* generation tools directly, so the reference image is
  reviewed for geometric consistency first and a contradictory image never
  burns credits. Not for tileable ground or wall surfaces (see the last
  section) and not for assets a free scan or a procedural generator already
  covers (step 0).
---

# Prop pipeline: idea → reviewed reference → 3D → game-ready

Turn a description into a usable 3D prop. The spine is simple. Two parts earn
their keep: a **review gate before every credit-spending step**, because the
cheapest place to catch a bad asset is upstream, and a **local finishing pass
after reconstruction**, because a raw generated model is not a game asset.

## Why the gate exists (read this first)

Concept images are cheap and fast (free on a codex subscription; regenerate in
seconds). Tripo reconstruction is paid and slow (60 credits and a few minutes
at the quality worth using, see the cost table). A flawed reference image
passes straight through Tripo and corrupts the mesh, and you only notice after
paying.

The canonical failure: a steampunk-owl contact sheet drew the single wind-up
key in *both* side views. That is geometrically impossible for one key, but
nothing checked it, so Tripo faithfully fused **two** keys and the credits
bought a broken model. A ten-second look at the image would have caught it.

So: **generate cheap → review → only then spend.** Never call a `tripo_*`
generation tool on an image you have not looked at.

## Step 0 — Should this be generated at all, and may you spend?

Generation is one of three sources. Pick the cheapest one that fits:

| Source | Use it for | Why |
| --- | --- | --- |
| Free scan library (Poly Haven and similar CC0 sources) | Real-world rock, wood, debris, furniture that already exists as a scan | Real surface detail, real scale, no credits. Check first. |
| Procedural (`gp_build_model`, a Blender script, an SDF generator) | Parametric or repeating shapes: crates, pipes, fences, layered rock faces, anything needing many variants | Exact dimensions, unlimited variants, no credits. |
| AI generation (this pipeline) | One-off organic or characterful props a library will not have | Fast, but costs credits and needs the finishing pass below. |

Generated models suit compact, irregular, free-standing objects (boulders,
props, characters). They suit large flat-sided pieces badly: in one rock
pilot, free-standing rectangular cliff blocks read as boxes at 10 m however
they were graded and embedded.

Before the first paid call:

- Confirm the user has authorised credit spending for this task. Authorisation
  for one service does not cover another: `openai_generate_image` bills an
  OpenAI API key, which is a different account from Tripo credits.
- Call `tripo_balance` and note the figure. Call it again after each paid step.
  The difference is the real price; the numbers in this file are measurements
  from one date and one plan, not a contract.

## The pipeline

```
0. Source     → scan library? procedural? only then generate. Spend authorised?
1. Strategy   → single image | Tripo multi-view (default when the back matters)
                 | contact sheet (last resort)
2. Concept    → one concept image: codex image tool            [free on subscription]
                 or openai_generate_image / tripo_text_to_image [paid]
2b. Views     → tripo_generate_multiview_image expands ONE reviewed concept
                 into front/left/back/right                     [paid, 10 credits]
3. REVIEW     → vision gate: framing · 3D-suitability · VISUAL LOGIC · lighting
                 pass → continue | one bad view → tripo_edit_multiview_image
                 (5 credits) or leave that view out | revise → 2 | reject → 1
4. Reconstruct→ tripo_image_to_model OR tripo_multiview_to_model [paid, 60 credits]
5. Finish     → local and free: scale + orient · weld + reduce · bake normals
                 from the dense mesh · grade colour
                 paid options: tripo_smart_lowpoly · tripo_segment_parts ·
                 tripo_texture_model · tripo_stylize_model
5b. Animate   → characters: scripted Blender rig (free) → tripo_rig_model →
                 tripo_retarget_animation (paid, last resort)
5c. Bridge    → tripo_import_model gives a locally edited file a task id
6. QA + record→ turntable · open-edge count · in-engine look under two lights ·
                 provenance record (task ids, prompts, settings, cost)
```

## Step 1 — Reference strategy

| Strategy | When | Cost before reconstruction |
| --- | --- | --- |
| **Single image** | The object is symmetric or near-symmetric (drum, tyre, barrel, crate) or its far side does not matter | 0 |
| **Tripo multi-view** from one reviewed concept (step 2b) | The far side will be seen, or it carries features the front cannot imply. This is the default for rocks and anything walked around. | 10 credits, plus 5 per edit |
| **Contact sheet** (one image holding four views, split locally) | Only when Tripo's multi-view keeps failing on a feature you can describe exactly | 0, but the most likely to contradict itself |

Why multi-view is the default when the back matters: a single-image model has
to invent the far side, and it invents badly. In a rock pilot the single-image
boulder came back as a ring-stacked drum and the cliff piece as a crate; the
multi-view versions of the same concepts held up from every side. Tripo's own
multi-view also removes most of the cross-view contradictions that a
general-purpose image generator introduces, which is the failure the gate
exists for. Still run the gate on all four views.

Three views are enough. A model built from three good views cost the same as
one built from four, so leave a bad view out rather than feeding it in.

## Step 2 — Generate the concept image

Free route: codex's built-in image tool on a subscription, driven
non-interactively:

```bash
printf '%s' "<image prompt>" | codex exec --skip-git-repo-check \
  --sandbox workspace-write -C /tmp [-i /tmp/reference.png] 2>&1 | tail -5
# Output lands in ~/.codex/generated_images/<session>/ig_*.png; codex copies it
# to the path you name in the prompt. Pass -i to condition on an existing image.
```

Paid routes, only with authorisation for that account: `openai_generate_image`
(OpenAI API key) and `tripo_text_to_image` (Tripo credits).

**Concept prompt** — describe ONE object on a plain background, lit flat:
> a single weathered red oil drum, flat even studio lighting, no cast shadows,
> plain pure-white seamless background, centred, three-quarter view, no other
> objects, no text.

Ask for flat lighting on purpose. Shadows and highlights in the concept end up
painted into the model's colour map, and an asset with baked-in lighting looks
wrong as soon as the scene's light moves.

**Step 2b — views.** `tripo_generate_multiview_image(image_path, output_dir,
stem)` writes `<stem>_front/left/back/right`. Fix one bad view with
`tripo_edit_multiview_image(original_task_id, prompts=[{view, prompt}])`.
Edits only partly obey: state the camera height and the outline you want in
plain words, look at the result, and if it is still wrong leave that view out.

**Contact-sheet prompt** (last resort) — all four views in ONE image so the
generator conditions on itself, then split with `scripts/split_contact_sheet.py`:
> 2×2 grid, four orthographic views of the SAME <object>: top-left FRONT,
> top-right LEFT, bottom-left BACK, bottom-right RIGHT. Identical object in
> every cell — same proportions, materials, wear; only the camera angle
> changes. Each asymmetric feature appears ONLY in the views it is actually
> visible from (e.g. a key on the left appears in LEFT and BACK, NEVER in
> RIGHT). Flat studio lighting, plain white background, centred, identical
> scale, no perspective distortion, no shadows.

## Step 3 — REVIEW GATE (the point of this skill)

Before touching a paid tool, **look at the generated image(s)** and run the
rubric. You have vision; use it. Give one verdict:

- **pass** — proceed.
- **revise** — fixable defect; regenerate or edit with a specific corrective
  instruction naming the flaw ("the key must appear only on the left; remove
  it from the right-side view").
- **reject** — wrong subject or unusable; go back to step 1.

Loop up to about three times, then put the problem to the user rather than
burning more attempts. Write the verdict and its reason into the provenance
record (step 6).

### Rubric

**A. Framing and subject**
- Exactly one subject, centred, fully in frame.
- Plain background; no second object, no text, no watermark.

**B. 3D-suitability**
- The subject has real volume (a thing you could walk around), not a logo,
  icon, sticker, or scene.
- Materials read clearly enough to texture.

**C. Visual logic — geometric and spatial consistency (the critical one)**

This is reasoning, not aesthetics. **Mentally rotate the object** and ask
whether what is drawn could exist as one solid, and whether every view is a
valid projection of the *same* object.

- **Feature count is conserved.** A single key, spout, handle or chimney must
  not appear twice, nor vanish where it should be visible. (The owl failure.)
- **Feature placement agrees across views.** A feature on the left side shows
  in LEFT and BACK and is absent or edge-on in RIGHT. Walk each feature around
  the turntable in your head.
- **Silhouette continuity.** The outline changes sensibly between adjacent
  views; proportions, height and scale hold.
- **No impossible geometry.** No parts fused in ways one solid cannot be.
- **View assignment is correct.** The back view shows the back, not a second
  front.

**D. Lighting, for assets that must work under changing light**
- Lighting is flat and the same in every view. No hard cast shadow, no strong
  highlight, no dark side. Whatever is drawn here is painted into the colour
  map.

Any failure in C or D is a **revise**, not a pass. For a single image the
check is lighter (one view cannot contradict itself), but still confirm the
object is a coherent solid and nothing is clipped or doubled.

## Step 4 — Reconstruct

- Single: `tripo_image_to_model(image_path, output_path, …)`.
- Multi-view: `tripo_multiview_to_model(front_path, left_path?, back_path?,
  right_path?, output_path, …)`. Front is required.

Settings that worked for relightable, close-range assets (measured 2026-11-13;
re-check when Tripo ships new versions):

```
model_version    "v3.1-20260211"   # the "H3" alias passed local validation
                                   # but the API answered HTTP 400
geometry_quality "detailed"
texture_version  "v3.5-20260815"
texture_quality  "detailed"
delight          true              # removes lighting from the colour map
pbr              true
```

What comes back at those settings:

- About 1.9 M triangles and 70 MB, with 4K colour and occlusion-roughness-metal
  maps. It is a source mesh, not a game mesh.
- Unit-sized: about 1 m across with the origin at the centre, whatever the
  object is. It must be scaled.
- In the pilot the concept's front faced the model's **+X** axis. Check with a
  turntable instead of assuming a forward axis.
- De-lit colour is more saturated than most game palettes. Plan a grade.

Keep the returned `task_id`. Every paid post-processing tool takes it.

## Step 5 — Finish (local and free first)

A raw model fails in a game in four ways: wrong size, too dense, cracks after
reduction, and colour that does not sit in the scene. Fix them in this order.

1. **Scale and orient.** Scale to the object's real size, rotate so its front
   faces the project's forward axis, and put the origin where the engine wants
   it (usually bottom centre). `tripo_convert_model` can do this server-side
   (paid); a few lines of Blender do it free.
2. **Reduce with the seams welded.** glTF stores a separate vertex on each
   side of every texture seam. Reducing that mesh as it stands lets the two
   sides drift apart and leaves cracks that show as bright dots and light
   leaking into shadows. `tripo_decimate_model` does exactly this (it applies
   a collapse per object without welding): on the pilot boulder it left 176
   loose pieces and 11,274 open edges. Use the bundled script instead:

   ```bash
   blender --factory-startup --background --python scripts/reduce_welded.py -- \
     <in.glb> <out.glb> <target_triangles>
   ```

   It welds, reduces, and prints the open-edge count (2 on the same boulder at
   20 k triangles). A count in the thousands means the weld did not take.
3. **Bake the dense mesh's detail into a normal map** for the reduced mesh
   (high to low, 4K). A mesh-tools MCP with `mesh_bake_normals` does this in
   one call; otherwise a Cycles selected-to-active bake in Blender. Without
   this step the reduced model looks smooth and cheap at close range.
4. **Grade the colour** against the scene. Compare the model with neighbouring
   surfaces in a lit engine capture, not against a palette constant, because
   the scene's light and tone mapping shift both.

Paid server-side alternatives, when the local route fails or the task needs
them:

- `tripo_smart_lowpoly(task_id, out, quad?, face_limit?)` — clean game topology
  with baked textures.
- `tripo_segment_parts(task_id, out)` — semantic parts for rigging;
  `tripo_segment_model(in, out, num_chunks)` — breakable debris shards (local);
  `tripo_mesh_completion(task_id, out, part_names)` — rebuilds the surface
  under a deleted part.
- `tripo_texture_model(task_id, out, text_prompt)` — re-texture without
  touching geometry. `tripo_stylize_model(task_id, out, style)` — lego, voxel,
  voronoi or minecraft rebuild.

## Step 5b — Rig and animate (every character, turret, or creature)

Rigging without cycle animations is half a deliverable. A unit is done when
its .glb carries a **clip set**, not just a skeleton. A workable default
contract (adapt the names per project, but keep one convention):

| Body plan | Required clips |
| --- | --- |
| Biped / quadruped | `idle`, `walk`, `attack`, `death` (+ optional `hurt`, `land`) |
| Turret / static emplacement | `idle`, `attack` (recoil), `death` (tip-over) |

Rules: every clip keys every bone so switching clips resets the pose; clips
animate in place (gameplay owns movement); one agreed forward and up axis with
feet at height 0; loop `idle` and `walk`, one-shot the rest. Godot import:
keep `animation/remove_immutable_tracks=false` or constant tracks vanish.

Default path (free, Blender): a scripted armature per body plan with region or
heat weights and hand-keyed cycles pushed to NLA tracks, exported with
`export_animation_mode="NLA_TRACKS"`. Keep one such script per project as the
template and reuse it. It costs no credits and the clips fit the character
instead of a generic preset.

Paid escalations, only when the free path fails. The prices below are the
listed ones and were not re-measured; check the balance around each call.

1. `tripo_check_riggable(task_id)` — free; stop if it says no.
2. `tripo_rig_model(task_id, out, rig_type, spec="mixamo")` — listed at 25
   credits. Use when automatic weights melt (thin limbs, disconnected parts).
   rig_type: biped, quadruped, hexapod, octopod, avian, serpentine, aquatic.
3. `tripo_retarget_animation(rig_task_id, out, animations)` — listed at 10
   credits PER CLIP, last resort. Presets: idle, walk, run, slash, shoot, hurt,
   fall, jump, dive, climb, turn. Always `animate_in_place`. A four-clip unit
   can cost more than its mesh; price it and get approval first.

Either way, render a frame strip per clip and parse the GLB to confirm every
clip drives every joint before committing.

## Step 5c — Bridge from Blender back into Tripo

Anything edited in Blender, reduced locally, or built with `gp_build_model`
has no task id. `tripo_import_model(file_path)` uploads the .glb / .obj / .fbx
/ .stl and returns one, so the paid tools in steps 5 and 5b can run on it.

## Step 6 — QA and record

Render a turntable and look at it the way you reviewed the concept:

```bash
blender --background --python scripts/render_turntable.py -- <model.glb> /tmp/qa
```

It writes four side views (`/tmp/qa_0..3.png`), a top view (`/tmp/qa_top.png`)
and one `MESH` line with triangle count, open edges and size in metres. Check:

- **Back and top**, where reconstruction artefacts hide. A doubled feature or a
  melted back nearly always traces to a visual-logic miss in step 3; fix the
  reference and regenerate rather than accepting the mesh.
- **Open edges** near zero, **size** equal to the real object.
- **In the engine, under two different light directions** (for example noon
  and low sun). Shadows or highlights that do not move with the light are
  baked into the colour map; the asset fails for any scene whose lighting
  changes. A Blender turntable cannot show this.
- **At the distances the player will see it**, next to its neighbours.

Then write a provenance record beside the asset: concept prompt, review
verdicts, every task id, the generation settings, the measured credit cost,
and the defects still outstanding. An automated check passing is not a
statement that the asset looks right; say what you saw.

## Costs

Measured on 2026-11-13 from balance checks between calls. Treat as a starting
estimate and re-measure.

| Step | Credits |
| --- | --- |
| Concept image through codex | 0 (subscription) |
| `tripo_generate_multiview_image` | 10 |
| `tripo_edit_multiview_image` | 5 |
| `tripo_image_to_model` or `tripo_multiview_to_model` (3 or 4 views), detailed geometry and texture | 60 |
| Local finishing (reduce, bake, grade) | 0 |
| A finished multi-view asset | about 70–80 |

Not measured: `tripo_text_to_image`, `tripo_smart_lowpoly`,
`tripo_convert_model`, segmentation, texturing, stylising, rigging and
retargeting. `openai_generate_image` bills OpenAI, not Tripo.

## Bundled scripts

- `scripts/split_contact_sheet.py` — split a 2×2 contact sheet into
  front/left/back/right. `python split_contact_sheet.py <sheet.png> <outdir>`
- `scripts/reduce_welded.py` — weld seam vertices, reduce to a triangle budget,
  report open edges.
  `blender --factory-startup --background --python reduce_welded.py -- <in.glb> <out.glb> <triangles>`
- `scripts/render_turntable.py` — four side views, a top view and a mesh
  report. `blender --background --python render_turntable.py -- <model.glb> <out_prefix>`

The two Blender scripts were last run on Blender 5.3.

## Tools this skill orchestrates

`tripo-mcp` server, 33 tools.

- Account: `tripo_balance`.
- Concept: `openai_generate_image`, `tripo_text_to_image`,
  `tripo_generate_multiview_image`, `tripo_edit_multiview_image`.
- Generation: `tripo_image_to_model`, `tripo_multiview_to_model`,
  `tripo_generate` (text straight to GLB), `tripo_generate_via_image` (concept
  and model in one call: it skips the review gate, so do not use it here).
- Finish: `tripo_smart_lowpoly`, `tripo_decimate_model` (no weld, see step 5),
  `tripo_segment_parts`, `tripo_segment_model`, `tripo_mesh_completion`,
  `tripo_texture_model`, `tripo_stylize_model`.
- Animate: `tripo_check_riggable`, `tripo_rig_model`,
  `tripo_retarget_animation`.
- Bridge and export: `tripo_import_model`, `tripo_convert_model`.
- Local procedural: `gp_build_model`, `gp_preview_model`.
- Surfaces: `generate_pbr_material`, `make_detile_material`.
- Low-level, for long jobs or retries after a timeout: `tripo_create_text_task`,
  `tripo_create_image_task`, `tripo_create_texture_task`, `tripo_get_task`,
  `tripo_wait_for_task`, `tripo_download_model`, `tripo_upload_image`,
  `tripo_upload_model_file`.

Optional, if a mesh-tools MCP is connected: `mesh_inspect` (triangles, open
edges, bounds) and `mesh_bake_normals` (high-to-low bake).

## Surfaces (ground / terrain / walls), not just props

For a tileable SURFACE rather than a discrete prop the flow is different:
`generate_pbr_material` (local StableMaterials, on-device PBR maps, no Tripo
credits) makes the texture, then `make_detile_material` wires it into a
drop-in Godot `ShaderMaterial` that removes visible tiling on a large plane
with stochastic hex-tiling. This is the answer to "the ground looks
copy-pasted": never put a plain UV-tiled texture on a big ground plane. The
tone target calibrates itself from the texture, so there is no per-texture
tuning (run the Godot import and flag the normal map as the tool's
`next_steps` say).
