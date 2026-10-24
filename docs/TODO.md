# To do

Done (2026-10-24): through-station and through-running tests (MOVE_PATH.md), on/off button,
selected trains highlighted (wider line, white outline), dev switches (logs, pathPos mark,
timing), braking and emergency stop points, end bar by the next section, performance pass
(trains only, network caches, per-train state; see the overlay's header).

Open:

- For very large saves: track and draw only trains whose reservation is near the camera. A
  far train's reservation can run into view, so test the reservation's edges, not just the
  train: e.g. train position and reservation end against a circle around the camera
  (`api.gui.camera.getCameraData()`, radius following the zoom as in Parallelism's overlay),
  or the track edges in view from the octree (`api.engine.util.octree.findEntitiesInCircle(
  center, radius, BASE_EDGE)`, Parallelism; road-priority-yield's octree box trick) and the
  trains holding them.
- Crossings: the end bar's node check (a node inside the next section held by another train)
  is untested on a diamond crossing.
- Builds made by script (e.g. Parallelism) may not fire onProposalApply: the network caches
  then refresh only by the 5-minute fallback.

Parked:

- Start the line at the train's front instead of at the start of its front edge (the first
  edge would be redrawn as the train moves). Not sure it's needed.
- Teal instead of Lua: needs Lua and `tl` installed to type-check; not worth it for now
  (user, 2026-10-24).
