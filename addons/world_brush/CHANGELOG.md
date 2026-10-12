# Changelog

All notable changes to World Brush are documented here.

## 0.4.0 - 2026-10-12

- Added **multi-scene random placement** as a native feature: every scene row has
  a `Variants` button that takes a multi-select list of extra `.tscn`; each
  stamped instance then picks one at random from `[active scene] + that list`.
  The pool is stored per source scene in the existing per-scene brush profile,
  so it persists and follows the brush.
- Weights are **your data, not guesses**: a second `Weights` button sets a
  relative weight (1..999) per scene in the pool, stored as
  `random_variant_weights`; the default is 1 for every scene (= uniform). The
  pool module reads no file names and contains no keyword tables, so nothing in
  the plugin is tied to a particular model set.
  `tests/test_world_brush_scene_pool.gd` guards this genericity explicitly.
- Removed the external variant tool (`addons/variant_tools`) together with the
  `world_brush_restoring` cooperation channel, the `node_added` hook and the
  extra undo actions it pushed. Random placement now happens **before** the
  instance is created (one node per stamp, no swapping) — nothing left to fight
  the undo system over.
- The legacy `variant_tools/sets` project setting is imported once into the
  matching per-scene profiles, so existing variant lists keep working without
  re-picking them.
- Instance source metadata (`world_brush_source_scene_path`) now records the
  variant actually used, and the LOD / Auto LOD passes match the whole pool
  instead of only the active scene.
- Pool logic lives in `world_brush_scene_pool.gd`, covered by
  `tests/test_world_brush_scene_pool.gd` (dedupe, pool order, weight
  sanitizing, weighted/uniform pick, genericity sentinels, wiring).
- Root cause, diagnostics and remaining limits:
  `docs/世界笔刷擦除-已修问题与排障.md`.

## 0.3.5 - 2026-10-11

- Fixed the erase brush ignoring scene instances that were regrouped under a plain
  `Node` inside `WorldBrushInstances`, or that lack the
  `world_brush_instance` metadata. The scan now walks the container's **whole
  subtree** and treats any scene instance as a brush instance (the old
  direct-children + metadata check could see 0 of them).
- Erase snapshots now record each instance's real parent, index and global
  transform, so undo/redo puts nested instances back exactly where they were
  (previously everything was re-parented to the container). A grouping that
  was deleted in the meantime falls back to the container instead of aborting
  the undo.
- One drag-erase stroke now carries every stamped batch in a single undo
  action (previously only the last stamp survived).
- Painted instances now respect spacing against nested instances as well
  (same blind spot, same fix).
- The instance predicate/scan moved to `world_brush_instance_scan.gd` so it
  is testable outside the editor; covered by
  `tests/test_world_brush_erase.gd`.

## 0.3.4 - 2026-08-14

- Added per-palette-entry Godot automatic mesh LOD controls.
- Added one-click `Generate LODs` import configuration and reimport for only
  the active model source.
- Added optional distance culling per model.
- Added persistent Auto LOD controllers for painted instances.
- Added a centralized, batched runtime distance manager.
- Far instances now suspend rendering, shadows, GI, collision, areas, and child
  processing, then restore their original state when the camera returns.
- Added `LOD Bias = 0` support for forcing the lightest generated LOD in tests.
- Improved Arabic and English Auto LOD guidance.

## 0.3.0

- Added independent manual near, medium, and distant LOD scenes per palette
  entry.
- Added configurable transition and culling distances.
- Added editor preview and runtime camera switching.

## 0.2.0

- Added scene palette persistence and independent per-scene brush profiles.
- Added undo/redo for painting and erasing.

## 0.1.0

- Initial 3D paint and erase workflow.
