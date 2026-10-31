Show the currently reserved path of trains.

### Features

* Normal path in blue.
* Orange when stopping to wait for clear path ahead.
* A bar across the track where the current reservation ends.
  * White: Path ahead is clear.
  * Red: Path ahead is occupied.
  * Gray: End of leg.
* Toggle overlay with mod button in the top left.
* Right-click the button for settings:
  * Braking distance for selected trains
  * Manual stop distance (3x braking)

### Limitations

* Currently draws the path for all trains in the save. This could get expensive on larger saves.

### Mod compatibility

The overlay is drawn through the game's tool overlay (`builtin.ActionDescriptor`). Each overlay can only hold one set of lines (`builtin.EdgeRenderable`), so mods that draw their own lines have to share it.

* Compatible: Mods that draw overlay lines the normal way, through `builtin.EdgeRenderable`. Their lines and the paths are drawn together.
* Compatible: Mods that wrap `builtin.ActionDescriptor` by chaining to whatever replacement is already there. This is the compatibility friendly way.
* Conflict: Mods that wrap `builtin.ActionDescriptor` by calling the game's original directly (`_react.originalRecipeFn` or `react.CallOriginalRecipe`). That knocks out every other mod wrapping it. The paths stop showing or updating. No crash.
* Possible crash: Mods that add lines to the overlay without going through `builtin.EdgeRenderable`. Two sets of lines in one overlay crashes the game. None known.

### Removing the mod

Safe to add and remove at any time. Nothing is stored in your save.

### Contact
* Reddit: [u/Imsvale](https://www.reddit.com/user/Imsvale)
* Discord: `imsvale`

**AI Disclaimer**

This mod was made with the help of Anthropic's Claude. It's been tested and verified by myself. There may still be flaws.
