# Changelog

All notable changes to World Brush are documented here.

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
