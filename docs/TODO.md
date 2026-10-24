# To do

In order (user, 2026-10-24):

1. Through-station test: two lines that overlap at one through station. Does a train of
   line B entering from the west get the platform as soon as a train of line A leaving east
   has cleared it, since both reservations end at the end of the path? Watch with the
   overlay and the `[pathvis]` log. (User sets up the save.)
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
