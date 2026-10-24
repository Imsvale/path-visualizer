# What a train's MOVE_PATH tells us

Findings from `tools/probe_train_path.lua`. "Confirmed" means seen in probe output; the rest are working guesses.

Terms (user, 2026-10-24; also in the README and code): a **leg** is a train's way to its next stop. Its **path** is the game's `path.edges` for that leg, one track edge after another (it tells parallel tracks apart). The **reservation** is the part of the path the train has claimed. "Route" is avoided: players use it for whole lines.

The script-doc's `MovePath` record is out of date: it lists `servedFrom`, `servedTo` and `reverse`, which are nil, and lacks `reservedFrom` / `reservedTo`, which exist (the doc's `Ship` record has fields of those names). The console's echo of `api.engine.getComponent(543, api.type.ComponentType.MOVE_PATH)` lists every field (2026-10-24), so this is the full set:

```
path = { edges = { {edgeId = {entity, index}, dir}, ... }, endOffset, earlyArrivalIndices, terminalDecisionOffset }
endParam, endPos, state, blocked, allowEarlyArrival
dyn, dyn0 = { pathPos = {edgeIndex, pos01, pos}, pathPos0 (nil), speed, speed0 (nil), brakeDecel, accel,
              timeUntilAccel, timeStanding, timeToIgnore, approachingStation }
reservedFrom, reservedTo, occupiedBackIndex, occupiedFrontIndex
```

## Which vehicles

`landVehicleMoveSystem.forEach` goes over every land vehicle, not only trains as its doc says: in an organic save it gave 379 vehicles, most of them road vehicles (MOVE_PATH too, reservation `[0, 0)`). Trains: `TRANSPORT_VEHICLE.carrier == api.type.enum.Carrier.RAIL` (2026-10-24).

## Reservation

- `reservedFrom` .. `reservedTo`: a half-open range of indices into `path.edges`, `[reservedFrom, reservedTo)`. Confirmed (2026-10-24), train 543, path of 83 edges:
  - Standing at red signal 850 (on path edge 43, at the edge's start in the direction of travel), occupying 40..42: reserved 40..43, i.e. edges 40..42, up to the signal.
  - Signal turned green, train starting off: reserved 40..83, i.e. through the last edge of the path (the far end of the destination station's track pieces). Signal 551 on the way, facing the other direction, didn't limit it.
- Released behind the train edge by edge: `reservedFrom` equalled `occupiedBackIndex` in every sample (10 samples over a whole leg, station stop and departure). Confirmed.
- Extended signal to signal: leaving the terminal on a fresh path (86 edges), train 543 reserved 0..29, up to the first signal facing it (551 on edge 29). Approaching 551 (it turned green while the train was within about 100..200 m), the reservation jumped to 45, the next signal facing it (856 on edge 45, 1.1 km further on). Not seen extending early while the train was still about 400 m out. Whether that is a lookahead distance or the block beyond 551 being occupied by another train is unknown. Confirmed (2026-10-24).
- Braking distance is the minimum (user's principle), confirmed with two signals 3 m apart (503, then 318), train 591 at 22.7 m/s, logger output 2026-10-24:
  - t=1437.8: reservation extended past 503 to 318 (one section), the front still 37..134 m before 503 (braking distance at 2.5 m/s²: about 103 m).
  - t=1438.6: extended past 318 to the next signal (850), the front still on the same edge, before 503.
  - The second extension came 0.8 s (18 m) after the first, though 318 is only 3 m past 503; a fixed lookahead distance would have taken it after 3 m. Game time moves in 0.2 s steps. Not understood yet.
- Departing a terminal, the reservation went straight to the first signal (503, several hundred metres on) at walking pace: at least one whole section, however far.
- `isTrainWaitingForFreePath` is true for a train at full speed (543, 31 m/s) whose reservation can't be extended past the next signal (856, red): it marks a failed extension, not a stopped train.
- A train held at a red signal with no further signal ahead reserved all the way to the end of its path when the signal cleared (419, at 0.6 m/s).
- After loading a save, each train starts with a new path from its position (index 0) and a reservation over just the edges it occupies plus the next; 0.2 s later it was extended as normal.
- The end of the path also ends a reservation: arriving at a terminal station, the reservation ran to the last edge of the path, the end of the platform track (user: both stations here are terminals).
- To draw the reserved path ahead: edges `occupiedFrontIndex` .. `reservedTo - 1` (or start at the train's front position).

## Station stop (terminal station)

- Arriving: path of 83 edges, the train braking with `occupied` 60..81 and reserved 60..83.
- At the platform: `TRANSPORT_VEHICLE.state` 2 (1 en route), `MovePath.state` 3 (0 en route), `approachingStation` false, and a new short path of 20 edges (the platform track) with reserved 0..20, all of it.
- Departing: a new path of 86 edges starting at the platform, `stopIndex` advanced, reserved 0..29 before the train had moved.
- Through station shared by two lines, confirmed (2026-10-24). Stations A, B, C from west to east, no signals anywhere; train 1328 runs A–B and back, train 1329 C–B and back, so they overlap only at B. 1328, turning at A, got a new path through to the eastern end of B's platform track. Without signals that whole path is one section: while 1329 stood at B, 1328 held only its own edges plus the next (waiting for a free path, reservation ending at an edge with no signal). It got the entire path, to its end, at once, 15.8 s after 1329 left B eastward: when 1329's rear passed the eastern end of B (seen in the overlay, user). So a reservation that ends at the end of the path needs the leading train only to clear that platform, not to pass a signal beyond it.
- Where the path of a leg ends, confirmed 2026-10-24 (stations A, B, C west to east, now with signals and trains running through B):
  - Where the train reverses after the stop (terminal, or a line turning there): at the far end of the platform track. A train heading there needs that platform clear to its far end, and no further.
  - Where its route carries on in the same direction: past the platform, up to the edge before the next signal facing it, though the train stops at the platform on the way. Train 1328 (C → B → onward), path of 70 edges: C's platform 0..22, the line 23..37, B's platform 38..61, then 8 more edges (about 770 m) ending just before signal 1508. Held at signal 1176 before B until train 433, far past B, cleared 1508; then reserved to its path end at once.
  - A train leaving a depot for its line gets such a path too: train 537, from the depot exit through C's platform (6..29) to the edge before signal 1176. It stood at the depot exit until 1328's rear left that edge (15.8 s after 1328 set off from 1176), then reserved its whole path.
  - So a station without a signal at its platform end holds a stopping train's successor until the train has cleared the next signal beyond (user's TF3 observation; TF2 had built-in platform-end signals for stopping trains).
- `endOffset` was 21 in both paths above (70 and 38 edges); its meaning is still unknown.
- A reservation can end at an edge with no signal: a train that can't reserve its next section holds what it occupies plus one edge.

## Path

- `path.edges` is a Lua table of `EdgeIdDir` userdata with `.edgeId` (`EdgeId`: `entity`, `index`) and `.dir` (boolean). Not indexable as `[1]`/`[2]`. Confirmed.
- The path covers the whole leg from the previous stop to the next: edges already passed stay in it (train at index 41 of 83, indices 0..22 are the departure station's track pieces). Confirmed (2026-10-24).
- Indices into `path.edges` are 0-based (`edgeIndex`, `occupied*`, `reserved*`, `blocked` line up with `path.edges[i + 1]`). Consistent so far.
- A new path is made for each leg, and another while the train stands at a terminal (see Station stop).
- `endOffset` (2 inbound, 13 outbound, 30 in another save), `terminalDecisionOffset` (-1, 39, 40) and `earlyArrivalIndices` (-1 so far): meaning unknown. Neither marks where the reservation ends.

## Position

- `dyn.pathPos.edgeIndex` / `pos` (metres into the edge) / `pos01` (fraction): the middle of the train. Confirmed 2026-10-24 (drawn in the overlay, user). `carriageListSystem.getVehicleData(train)` gives `length` and `bounds.front` / `bounds.back`, the nose and tail relative to it (train 1328: length 130.69, bounds +65.345 / -65.345), and `brakeDeceleration` (2.5).
- `pathPos` changes once per game time step (0.2 s); the overlay extrapolates its bars in between.
- Braking: at red signals and arriving at stations the logger saw `dyn.brakeDecel` 2.50..2.60, the train's `brakeDeceleration` (2.5). Once, train 1328 at 28.4 m/s got a new short path in the middle of the line (n=30, then n=2 once stopped) and braked at 7.50, three times that, stopping in about 54 m (user saw 60 m) instead of 160 m. It was a manual stop (the user, 2026-10-24): stopping a train by hand brakes at three times its brake deceleration.
- Per-step log of a train stopping at a station (433, 2026-10-24): braking at a steady `dyn.accel` −2.510 (`brakeDecel` 2.510), speed down 0.502 per 0.2 s step; at the platform `MovePath.state` 3, a new platform path, speed 0 and `dyn.accel` +1.53 for the whole stop (not −7.5 as in TF2), `timeStanding` 0; departing, `state` 0 again. At a faster game speed the overlay saw steps 0.8 s of game time apart.
- The braking point (nose + v² / 2 × `brakeDeceleration`) matched where trains stopped at a station exactly, and a train held by a signal started braking, and turned "waiting for a free path", when its braking point reached the signal (user, 2026-10-24, within error). So a train tries to extend its reservation when its braking distance reaches the reservation's end.
- `occupiedBackIndex` .. `occupiedFrontIndex`: edges the train covers, both inclusive (front went from 42 to 43 as the train's front passed signal 850 at the start of edge 43). Consistent so far.

## blocked

Integer. Seen 0 and 1 for a train waiting at a station (changed between two samples while it stood still), 0 for a train waiting at a signal and 0 after it got the green. Not a boolean; meaning unknown.

## Signals

- `signalSystem.getSignal(edgeId, reversed)` returns a `SignalId` with `entity = -1` when there is none. Confirmed.
- A signal splits its track segment: the edge carrying it is e.g. `852:0` next to `852:1`.
- `SIGNAL_LIST` of the signal entity, `signals[index + 1]` (0-based `index` assumed): `type` 0 for the signals seen so far (likely `PATH_SIGNAL`), `state` 0 for all of them. All signals in the game are path signals; red is their resting state, and one turns green only when an approaching train reserves the path beyond it (user). `state` 0 = red, 1 = green: signal 850 went from 0 to 1 when train 543 got its path. Confirmed.
- `stateTime` is the game time of the last state change × 1000: signal 850 read 1236800000 when `GAME_TIME.gameTime` (ms) was 1239400, 2.6 s after it turned green. Confirmed.
- Which direction applies to the train: on edges with `dir = false`, the signal that held the train (850) is `getSignal(edgeId, false)`, and the one facing the other way (551) is `getSignal(edgeId, true)`. On the way back (edges with `dir = true`), signal 551 held and then cleared the train as `getSignal(edgeId, true)`. So the signal facing the train on a path edge is `getSignal(edgeId, dir)`. Confirmed (2026-10-24).
- A signal's edge (the one `getSignal` finds it on) is the edge just past it: the train stops with its front on the previous edge, and the reservation while waiting ends before the signal's edge.
- No API gives per-edge train reservations (`isReserved` exists only on the aircraft move system). `signalSystem` has only `getSignal`.
