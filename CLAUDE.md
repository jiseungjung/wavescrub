# WaveScrub

An iPhone app for scrubbing through long surf videos, bookmarking waves, and
looping each wave zoomed in on the surfer.

## Working with the owner

The owner is vibe coding. Talk about what the app does and how it feels to
use, not about code, files, or function names. Make the changes, test them,
and report the result in plain language.

## How the app is laid out (agreed 2026-10-15)

- **Home is the loop screen.** Every video opens on it. Top bar: videos
  button and title, then compare, star, speed, and a ⋯ menu (who's surfing,
  track the surfer). Under the wave list: "Find waves".
- **Finding waves is a mode, not a screen.** It fades in place (like Edit in
  Photos) with Done top-left; Done fades back to the loop, on the wave marked
  last. It holds the scrubbing tapes and the flag / surfer buttons.
- A video with no waves still opens on home, showing "No waves marked yet"
  and a Find waves button.
- Compare opens from home's top bar; it has jog strips per clip, one shared
  strip when linked.
- **Zoom is per video** (agreed 2026-10-16): the camera doesn't move within a
  video, so every wave shows the same amount of the picture. Each video
  remembers its own zoom. (Before, zoom went by the surfer's size, so it
  changed from wave to wave.)

## Exporting clips (built 2026-10-16)

- ⋯ → Export fades into export mode in place: Cancel top-left, speed
  top-right. The wave being watched starts checked.
- Tapping a wave name checks / unchecks it and plays it. Waves not yet
  followed can't be checked. "Select all shown" checks every wave the
  surfer / star filters show. "Edit N waves" opens the export editor.
- **Export editor** (rebuilt 2026-10-19 after the owner rejected per-wave
  strips on the loop screen; modeled on InShot / Instagram Edits): a full
  screen of its own. The finished video plays at the top exactly as it will
  be exported (all waves back to back, cut to 9:16, at the speed). Under it
  a timeline with every wave side by side as frames cut like the export,
  a white playhead in the middle: slide it to move through the whole video,
  pinch to zoom it. Tap a wave to select it: yellow handles trim it, only
  within its loop; while a handle moves the video shows that frame, and the
  waves close up on letting go. A selected wave can be put back to its
  whole loop or removed. Top bar: back, "N waves" + length, speed, Export.
- Trims never change the loop. They're kept while going back to choose
  more waves, and reset when export mode is left.
- Each wave is exported as on the loop screen: following the surfer, as
  wide as the screen shows at the video's zoom, cut to 9:16 (1080×1920) by
  trimming sky and water above and below. Zoomed out too far for 9:16, it's
  as tall as the picture instead (no black bars).
- Waves are stitched in time order with straight cuts. Exported at the
  speed chosen, with sound, no labels.
- Saved straight into a "WaveScrub" album in Photos, then a "Saved to
  Photos" card with Done, Share, and Keep editing. The share sheet only
  opens on Share and leaves out "Save Video" (tapping it made a second
  copy). If saving failed, the card says so and the share sheet keeps it.

## Planned: tagging several surfers in one video

Status: built and installed on 2026-10-15.

**Problem.** When one video has waves from several people, each bookmark has
to be renamed and recolored by hand. That gets tedious fast.

### 1. Adding people (only when needed)
- Usually it's just the owner surfing. No screen pops up when a video
  opens. There is only a people button next to the loop button.
- With nobody named, bookmarks are Wave 1, Wave 2... always numbered in
  time order. Marking a wave before others renumbers the later ones (today
  the numbers get mixed up).
- The people button works with just one person too: naming yourself (e.g. K)
  turns Wave 1, Wave 2... into K 1, K 2...
- Adding a second person asks for the first person's name if it isn't set
  yet, then renames that person's bookmarks the same way.
- Each person gets the next unused color, which can be changed. Renaming or
  recoloring a person updates all their automatic bookmarks.
- No list of people from other videos (tried and removed at the owner's
  request).

### Naming and coloring single bookmarks
- **Names:** typing a name on one bookmark replaces its automatic label
  (e.g. "Barrel" instead of K 3). It still keeps its place in the count, so
  the others don't shift. Clearing the name returns it to automatic (K 3).
  Renaming the person leaves hand-typed names alone.
- **Colors:** a bookmark's color is always its person's color, whether
  it's one person or several. Bookmarks are never colored on their own.
  To change a color, change the person's color in the people button.
- Tapping a bookmark's dot opens the list of people to switch it to someone
  else. With one person, the list also offers "Add person".
- **Stars:** a star marks a special wave. Tap the star next to the wave's
  label on the main screen, or in the loop screen's top bar. Starred waves
  show a star before their name everywhere.
- When people are first set up, all existing bookmarks take their person's
  color.

### 2. One tap per surfer to bookmark
- With two or more people, the single flag becomes a row of colored buttons,
  one per person, showing their initial. Scrub to a takeoff and tap the
  person riding. That saves a bookmark like "K 3" in their color.
- No concept of sets. Each tap stands alone, so any order, missing surfers,
  or empty sets just work.
- Numbers follow time order per person. Marking an earlier wave renumbers
  the later ones.
- Only one person per wave. On a bookmark, the buttons give way to delete,
  as today.
- With 5 or more people, the buttons scroll sideways in landscape.

### 3. Reviewing
- The overview strip already colors bookmarks, so each person's waves stand
  out.
- The loop screen has a filter row: a star toggle, then All / each surfer.
  The star combines with the surfer choice. Switching keeps your place:
  the wave you're watching if it fits, else the last one watched that fits
  (watched under any choice), else the choice's first wave.

### Not doing for now
- Sets as their own thing. If wanted later, group waves into sets
  automatically by the time gaps between them, just for display.
- Using the surfer's identity to help the tracker follow them.

### Must not break
Existing bookmarks keep any hand-typed names; their Wave numbers are put
back in time order. Their individual colors are replaced by their person's
color (agreed with the owner). Naming a person changes only the automatic
labels.

### Build order
Time-ordered Wave numbers first (useful on its own), then adding people and the one-tap buttons, then the loop-screen filter.
