# WaveScrub

An iPhone app for scrubbing through long surf videos, bookmarking waves, and
looping each wave zoomed in on the surfer.

## Working with the owner

The owner is vibe coding. Talk about what the app does and how it feels to
use, not about code, files, or function names. Make the changes, test them,
and report the result in plain language.

## Planned: tagging several surfers in one video

Status: proposed on 2026-10-15 and revised with the owner the same day. Not built yet.

**Problem.** When one video has waves from several people, each bookmark has
to be renamed and recolored by hand. That gets tedious fast.

### 1. Adding people (only when needed)
- Usually it's just the owner surfing. No screen pops up when a video
  opens. There is only a people button next to the loop button.
- With nobody added, bookmarks are Wave 1, Wave 2... but always numbered in
  time order. Marking a wave before others renumbers the later ones (today
  the numbers get mixed up). Bookmarks renamed by hand keep their names and
  are skipped in the numbering.
- Adding a second person also asks for a name for the first person (the
  owner). Then every existing "Wave N" bookmark is renamed to that name
  plus its number, e.g. Wave 1 -> K 1. Those bookmarks take the first
  person's color. Bookmarks the owner already renamed by hand keep their
  names.
- Each person gets the next unused color, which can be changed. Names can be
  edited from the people button at any time, and every bookmark follows.
- People used before show as quick picks with their usual color.

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
- Tapping the wave's tag next to the time lets you switch it to another
  person or give it a custom name.
- With 5 or more people, the buttons scroll sideways in landscape.

### 3. Reviewing
- The overview strip already colors bookmarks, so each person's waves stand
  out.
- The loop screen gets a filter (All / each surfer), to swipe through only
  one person's waves.

### Not doing for now
- Sets as their own thing. If wanted later, group waves into sets
  automatically by the time gaps between them, just for display.
- Using the surfer's identity to help the tracker follow them.

### Must not break
Until a second person is added, existing bookmarks keep their colors and any
hand-typed names; only their Wave numbers are put back in time order.

### Build order
Time-ordered Wave numbers first (useful on its own), then adding people and the one-tap buttons, then the loop-screen filter.
