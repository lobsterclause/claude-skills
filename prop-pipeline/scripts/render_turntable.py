"""Render a GLB from 4 turntable angles plus the top for mesh QA (headless Blender workbench).

Usage:
  blender --background --python render_turntable.py -- <model.glb> <out_prefix>
Writes <out_prefix>_0.png .. _3.png at azimuths ~25/115/205/295 deg (the ~205
frame catches the back, where reconstruction artifacts usually hide) and
<out_prefix>_top.png looking straight down. Prints one MESH line with the
triangle count, the number of open edges and the size in metres.

Workbench engine + studio light shows geometry clearly without depending on the
render-engine enum name across Blender versions; color_type=TEXTURE keeps the
material so doubled/melted features are visible. Workbench does not show how
the asset reacts to light: check that in the engine.
"""
import math
import sys

import bmesh
import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
if len(argv) < 2:
    print("usage: blender --background --python render_turntable.py -- <model.glb> <out_prefix>",
          file=sys.stderr)
    sys.exit(1)
src, out_prefix = argv[0], argv[1]
N = 4

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

objs = [o for o in bpy.data.objects if o.type == "MESH"]
if not objs:
    print("render_turntable: no meshes in", src, file=sys.stderr)
    sys.exit(1)
mn = Vector((1e9,) * 3)
mx = Vector((-1e9,) * 3)
triangles = 0
open_edges = 0
for o in objs:
    for c in o.bound_box:
        wco = o.matrix_world @ Vector(c)
        mn = Vector((min(mn[i], wco[i]) for i in range(3)))
        mx = Vector((max(mx[i], wco[i]) for i in range(3)))
    bm = bmesh.new()
    bm.from_mesh(o.data)
    # Weld a copy first: glTF splits vertices at texture seams, and those are not real holes.
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    triangles += sum(len(f.verts) - 2 for f in bm.faces)
    open_edges += sum(1 for e in bm.edges if len(e.link_faces) == 1)
    bm.free()
center = (mn + mx) / 2.0
size = mx - mn
extent = max(size)
print("MESH", src.split("/")[-1], "objects", len(objs), "triangles", triangles,
      "open edges after welding seams", open_edges,
      "size m (x, y, z in Blender axes) %.3f %.3f %.3f" % (size.x, size.y, size.z))

cam_data = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_data)
bpy.context.collection.objects.link(cam)
bpy.context.scene.camera = cam
cam_data.type = "ORTHO"
cam_data.ortho_scale = extent * 1.25

scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "TEXTURE"
scene.render.resolution_x = 480
scene.render.resolution_y = 480

elev = math.radians(12)
dist = extent * 3
for i in range(N):
    az = math.radians(i * 90 + 25)
    cam.location = center + Vector((
        dist * math.cos(elev) * math.cos(az),
        dist * math.cos(elev) * math.sin(az),
        dist * math.sin(elev),
    ))
    cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = f"{out_prefix}_{i}.png"
    bpy.ops.render.render(write_still=True)

cam.location = center + Vector((0.0, 0.0, dist))
cam.rotation_euler = (0.0, 0.0, 0.0)
scene.render.filepath = f"{out_prefix}_top.png"
bpy.ops.render.render(write_still=True)
print("render_turntable: wrote", N, "side angles and the top for", src)
