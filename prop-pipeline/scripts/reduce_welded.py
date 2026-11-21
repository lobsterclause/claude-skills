"""Reduce a dense GLB to a triangle budget without opening gaps along texture seams.

Usage:
  blender --factory-startup --background --python reduce_welded.py -- <in.glb> <out.glb> <target_triangles>

glTF stores a separate vertex on each side of every texture seam. Reducing that
mesh as it stands lets the two sides drift apart, which leaves cracks that show
as bright dots and leak light into shadows. This joins the meshes, welds the
seam vertices (texture coordinates stay per face corner), reduces the closed
surface, and prints how many open edges remain. Expect a handful; thousands
mean the weld did not take.
"""
import sys

import bmesh
import bpy

args = sys.argv[sys.argv.index("--") + 1:]
if len(args) != 3:
    sys.exit("usage: blender --factory-startup --background --python reduce_welded.py -- "
             "<in.glb> <out.glb> <target_triangles>")
src, dst, target = args[0], args[1], int(args[2])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
if not meshes:
    sys.exit("REDUCE failed: no mesh in " + src)
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active


def open_edge_count(mesh):
    bm = bmesh.new()
    bm.from_mesh(mesh)
    count = sum(1 for e in bm.edges if len(e.link_faces) == 1)
    faces = len(bm.faces)
    bm.free()
    return count, faces


bm = bmesh.new()
bm.from_mesh(obj.data)
bmesh.ops.triangulate(bm, faces=bm.faces)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
bm.to_mesh(obj.data)
before = len(bm.faces)
bm.free()
open_before, _ = open_edge_count(obj.data)

mod = obj.modifiers.new("reduce", "DECIMATE")
mod.ratio = min(1.0, target / max(before, 1))
bpy.ops.object.modifier_apply(modifier=mod.name)
bpy.ops.object.shade_smooth()

open_after, after = open_edge_count(obj.data)
print("REDUCE", src.split("/")[-1], "triangles", before, "->", after,
      "open edges", open_before, "->", open_after)

bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", export_apply=False)
print("REDUCE wrote", dst)
