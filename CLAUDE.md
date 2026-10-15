# WaveScrub

An iPhone app for scrubbing through long surf videos, bookmarking waves, and
looping each wave zoomed in on the surfer.

## Working with the owner

The owner is vibe coding. Talk about what the app does and how it feels to
use, not about code, files, or function names. Make the changes, test them,
and report the result in plain language.

## Planned: tagging several surfers in one video

Status: proposed on 2026-10-15, not built yet.

**Problem.** When one video has waves from several people, each bookmark has
to be renamed and recolored by hand. That gets tedious fast.

### 1. Pick the surfers once per video
- A "Who's surfing?" sheet opens when you open a video, and from a people
  button next to the loop button. Tap + and type a name. Each new surfer gets
  the next unused color, which can be changed.
- Surfers you've used before show as chips, so one tap adds a friend with
  their usual color. The same person is always the same color.
- Optional: with nobody added, the app works exactly as it does today.

### 2. One tap per surfer to bookmark
- The single flag becomes a row of colored buttons, one per surfer, showing
  their initial. Scrub to a takeoff and tap the person riding. That saves a
  bookmark named like "Kai 3" in Kai's color.
- No concept of sets. Each tap stands alone, so any order, missing surfers,
  or empty sets just work.
- Numbers follow time order per surfer. Marking an earlier wave renumbers
  the later ones.
- The buttons stay visible while sitting on a bookmark, so two surfers on the
  same wave can both be tagged.
- Tapping the wave's tag next to the time opens a menu: switch it to another
  surfer, give it a custom name, or delete it. Delete moves there from the
  toolbar.
- With 5 or more surfers, the buttons scroll sideways in landscape.

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
Existing bookmarks have no surfer. They keep their current names and colors.

### Build order
Parts 1 and 2 first, then the loop-screen filter.
