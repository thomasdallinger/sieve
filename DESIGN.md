# Design

Sieve's job is to sift a whole disk down to the file you meant. The interface should feel like a precise instrument:
dark ink, clean cards, and one violet signal that always means "this is it".

## Principles

1. **Names are the truth.** Every file shows its full name with its extension. The extension is quieter, but always
   there.
2. **Visible over discoverable.** Sorting, filters, scope and match counts are on screen and phrased in words
   ("Date Modified · Newest first", "Home 340"), never hidden behind a View Options panel.
3. **Exact first, clever second.** Literal matches appear instantly and are marked in violet. Suggestions from the
   local model arrive in their own labelled section, and each row says which word it matched ("≈ invoice").
4. **Never a dead end.** An empty result offers the next wider scope, and a missing model comes with a button to
   fetch it.
5. **Speed is a feature.** Nothing waits on the disk or on a system search service. Anything slower than a frame
   runs off the main thread.

## Signature elements

- **Canvas and cards.** The window is a cool ink canvas. Every folder column, list, result set and preview is a
  rounded card floating on it, with an 8 pt gap.
- **Column headers.** Each column card names its folder and counts what it shows ("12 of 40" when filters hide
  some).
- **Two-tone selection.** A solid violet pill marks where the keyboard is. A soft violet tint marks the trail of
  folders that led there.
- **Location pill.** Breadcrumbs live in the toolbar. Click the pill to type a path.
- **Status strip.** Counts and free space on the left; a live index indicator (green when current, amber while
  indexing) on the right.
- **Solid sidebar.** Small-caps section labels (PINNED, DRIVES). The selected place is drawn in violet, not
  white-on-blue.
- **Icon.** A round mesh in a metal ring, with violet grains falling through.

## Tokens

| Role | Light | Dark | Use |
|---|---|---|---|
| Accent | `#5B4CF0` | `#8F84FF` | active filters, matches, icons of selected places |
| Selection | `#5B4CF0` | `#6352F0` | focused selection pill (white text) |
| Accent tint | accent at 13 % | accent at 24 % | selection trail, match highlight, scope pills |
| Accent text | `#3F31D1` | `#B4ACFF` | text on the tint |
| Canvas | `#EDEDF2` | `#111115` | window background |
| Card | `#FFFFFF` | `#1A1A20` | columns, lists, results, preview |
| Card border | black 7 % | white 7 % | 1 px around cards and under headers |
| Sidebar | `#E6E6EC` | `#0C0C0F` | solid sidebar panel |
| Hover | black 4.5 % | white 4.5 % | row hover, inactive pills |

- **Type:** SF Pro 13 (names), 12 semibold (column headers), 11 (captions). Section labels are 10 pt semibold
  caps with 0.9 tracking. Dates and sizes use tabular digits.
- **Shape:** card radius 10, row and pill radius 7. Rows are 26 pt for browsing and 30 pt for results.
- **Motion:** 160 ms ease-out when a column slides in. Motion is off when *Reduce motion* is on.
