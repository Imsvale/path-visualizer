# To do

In order (user, 2026-10-24):

1. ~~Through-station test~~: done 2026-10-24, see MOVE_PATH.md (Station stop).
1b. ~~Trains whose route continues through a station~~: done 2026-10-24, see MOVE_PATH.md
   (Station stop).
2. On/off button in the HUD's mod button area.
3. Highlight the selected train's reservation over the others.
4. The `[pathvis]` reservation logger (game script) behind a dev switch, off in a release.
5. A small indicator of each train's braking distance, v² / 2a ahead of its front. `a` is per
   vehicle model, not one game setting: `landVehicle.brakeDeceleration` in the model metadata
   (`base/model_metadata_util.lua` defaults it to 2.5 for rail, 5 for road, where a model
   doesn't set it). Per train from `api.engine.system.carriageListSystem.getVehicleData(train)`
   `.brakeDeceleration` (the game's debug panel reads it there; also has `length` and
   `bounds.front` / `bounds.back`, which may give the front's position). Check what it returns
   for a train first.

Parked:

- Start the line at the train's front instead of at the start of its front edge (the first
  edge would be redrawn as the train moves). Not sure it's needed.
