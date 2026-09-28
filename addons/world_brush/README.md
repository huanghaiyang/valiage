# World Brush

World Brush is a Godot 4 editor plugin for painting and erasing 3D scenes directly in the 3D viewport.

## Features

- Paint reusable 3D scenes directly in the editor viewport.
- Erase previously painted instances.
- Manage multiple scenes through a scene palette.
- Keep an independent profile for every scene, including its medium/distant models and all LOD distances.
- Enable Godot's automatic mesh LOD independently for any single active palette model.
- Configure native LOD bias and an optional culling distance per model.
- Apply `Generate LODs` and reimport only the active model source with one click.
- Optionally assign medium and distant scenes to an active scene.
- Keep only one LOD scene visible and switch it by camera distance at runtime.
- Configure medium, distant, and optional culling distances per scene.
- Adjust brush radius, instance count, and minimum spacing.
- Randomize Y rotation and scale.
- Rotate instances with the surface.
- Limit placement by maximum slope.
- Apply height offset along World Y or the surface normal.
- Undo and redo painting and erasing actions.
- Save palette and brush settings.
- Arabic and English interface support.

## Installation

1. Copy the `addons/world_brush` folder into your Godot project.
2. Open the project in Godot.
3. Go to `Project > Project Settings > Plugins`.
4. Enable `World Brush`.

## Distance LOD workflow

### Automatic LOD from one model

1. Add and activate a model or scene in the scene palette.
2. Enable `Godot Auto LOD — Single Model` for that palette entry.
3. Adjust `Transition Detail` (`LOD Bias`) and the optional `Hide After` distance.
4. Click `Apply & Reimport This Model` if the source needs to be regenerated.

The import action updates `Meshes > Generate LODs` only for the active model
source (GLB, GLTF, FBX, OBJ, or Blend). It never changes every palette model.
Every palette scene stores its own automatic LOD enabled state, bias, and cull
distance. Turning the option off restores the original GeometryInstance3D
values on painted instances managed by World Brush.
Set LOD bias to `0` to force the lightest generated mesh for visual testing;
use a higher value for normal gameplay quality.

World Brush stores a lightweight controller beside every painted Auto LOD
instance. This keeps native LOD bias and culling active after saving, reopening,
or running the edited scene without modifying the reusable source scene.
At runtime, culled instances also disable their collision shapes, collision
layers, area monitoring, shadows, global illumination, rendering, and child
processing. They are restored slightly
before the camera returns to the culling boundary to avoid visible or physical
popping.
A single runtime manager updates all painted instances in small batches. This
avoids per-instance timers and keeps distance checks smooth with hundreds of
props.

### Manual LOD from authored models

1. Add and activate the original high-detail scene in the scene palette.
2. Enable `Add Distant Scene`.
3. Assign the medium and distant versions of the same model.
4. Set the distances where the medium and distant scenes begin.
5. Optionally set `Hide After`; leave it at `0` to disable distance culling.

Newly painted instances show one LOD scene at a time. The editor preview follows
the 3D editor camera while painting and navigating, and the saved runtime
controller follows the active game camera. Older World Brush LOD groups are
upgraded automatically when their scene is opened.

Switching the active palette scene restores only that scene's LOD profile.
New scenes start with LOD disabled and empty medium/distant slots; settings are
never inherited from the previously active scene. Changing a profile updates
only painted instances whose original scene matches that profile.

## Compatibility

- Godot 4.6 or newer (tested with 4.6.3 and 4.7.1)
- 3D projects
- Editor plugin

## Support and known behavior

- Automatic mesh LOD depends on Godot's generated import LODs. Use `Apply &
  Reimport This Model` for imported GLB, GLTF, FBX, OBJ, or Blend sources.
- Native LOD changes mesh detail; `Hide After` additionally disables rendering,
  shadows, GI, collision, area monitoring, and child processing at long range.
- World Brush never changes the import settings of every palette entry at once.
  Each scene keeps an independent Auto LOD profile.
- If an issue occurs, include the Godot version, renderer, reproduction steps,
  and the editor Output log in the report.

## License

World Brush is released under the MIT License.
