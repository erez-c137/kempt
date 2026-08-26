# Kempt tray popup - simulated usability panel

Subject: the Plasma 6 popup behind the Kempt tray icon (repo `/mnt/dev_workspace/projects/kempt`).
Method: six personas, each shown the CURRENT popup (both states) and the PROPOSED popup (both
states), reacting as if they had just clicked the tray icon. Reactions first, then a poll on the
four open questions. Date: 2026-08-26.

---

## 1. Dana - three months off Windows 11, afraid of restarts

My eyes go straight to the number, then to the blue button, and then I hunt for the word
"restart". In the current popup that word only turns up when there is a kernel involved, and
after I press Update Now all I get is a timestamp, "38s" and a tick. Nothing tells me whether my
laptop is about to do the thing Windows used to do to me at four in the afternoon. So I close it
and I keep worrying.

The proposed one is the first update screen I have not been scared of. "Restart to finish
installing updates" with a Restart button that is mine to press, and a line saying when it last
checked, so I know it is actually awake and not just quiet. Two things still stop me. "Stage
offline instead" sounds like it is going to disconnect my internet. And there is no way anywhere
to say "not now, I am in a call".

## 2. Yuval - Fedora power user, lives in `sudo dnf upgrade`

First thing I look at is the version strings, and the proposal breaks the one thing the current
popup gets right. `2:24.19.0-1nodesource → 2:24.20.0-1nodesource` tells me the epoch and the
vendor tag. `24.19 → 24.20` tells me nothing, and I cannot tell a plain rebuild from a real bump.
Do not truncate.

Otherwise the changes are fine by me. Refresh belongs as an icon because I am never going to
press it, my terminal already refreshed. Making Update Now the only filled button is honest about
there being exactly one action here.

What I want and neither layout gives me: the kernel warning says "restart after" but not that
`akmod-nvidia` is in the same transaction, which is the thing that has actually left me at a
black screen. And I want the log path for the last run, not a tick mark.

## 3. Ravi - laptop, battery, metered hotspot

I open this on a train, tethered. My eyes go to the count and then straight down the list looking
for a number in MB, and there is not one in either layout. Neither one tells me whether the
packages are already downloaded or whether pressing that button starts pulling 800MB through my
phone plan. That is the entire decision for me, and both designs skip it.

Second thing I look for is a way out that is not "close the popup and forget": a Later, a
Tonight, a "wifi only". Also not there.

The proposed layout is nicer to read, and "Checked 4 min ago" in the corner is the sort of quiet
detail I like, but it answers a question I did not ask. If Kempt cannot tell me the size, it
should at least say "downloads now" beside Update Now so I know what I am agreeing to before I
agree to it.

## 4. Maria - remote caretaker of two Fedora machines

I am not the user here, my dad is, but I am the one opening this over a remote session at eleven
at night. I need three facts in the first second: is it clean, when was that true, and does it
need a reboot that my father will never do on his own.

The current popup gives me one of the three, and the run line vanishes when the popup closes, so
the evidence of the update I just ran is gone. The proposal gives me all three on one screen and
that is a big deal. "Last update: 18 min ago, 1 package" is the line I would screenshot.

Two problems. "1 held back" does not say which package, or whether my father clicked something he
should not have, and I cannot click it to find out. And with two timestamps stacked, "Checked 4
min ago" over "Last update 18 min ago", I know which is which. He never will.

## 5. Tom - keyboard only, Orca screen reader

I get here by keyboard and then I tab. Today the order is sensible: heading, Update Now, Refresh,
then the list. The proposal puts Refresh, settings and pin between the title and the count, so I
pass three icon buttons before I reach the one action I came for. Put the primary first in the
tab order even if it sits to the right on screen.

The pin buttons are the best thing in here, by the way. Orca reads "Hold nodejs at its current
version", which is a real label rather than "button". Do that everywhere.

What worries me is the furniture that appears and disappears. A Restart button that materialises
after a run, a warning row that shows up only sometimes, a Details section that changes the
height: each one moves my focus without warning me. And nothing announces results. After Refresh,
Orca says nothing at all, so I never learn that it finished.

## 6. Lin - designer, macOS by day, judging KDE fit

The current popup has a hierarchy problem. "Up to date" and "Everything is up to date" are the
same sentence twice at two sizes, with an enormous grey icon wedged between them. And two filled
buttons side by side means neither one is primary.

The proposal fixes both, and fixes them the way Plasma already does it: one action on the heading
row, the secondary demoted to an icon, a quiet timestamp at the foot. That is the battery and
network popup pattern, so it will feel native rather than ported.

Two notes. The heading row now carries back, title, refresh, gear and pin, which is five targets
in one strip at popup width, and the tray already draws a gear and a pin of its own. Drop yours
there. And the up-to-date state stacks a centred icon block, then a left-aligned warning strip,
then a left-aligned footer strip. Pick one axis. As drawn it reads as three unrelated cards.

---

# Moderator report

## Q1 - Restart: a `Restart…` button, or state the fact only?

**Button: 4** (Dana, Maria, Lin, Ravi). **Button with conditions: 1** (Tom).
**Fact only: 1** (Yuval).

- For: **Dana** - *"'Restart to finish installing updates' with a Restart button that is mine to
  press... the first update screen I have not been scared of."*
- Against: **Yuval** - *"I want the log path for the last run, not a tick mark."* His poll answer:
  a button next to a warning is a nag; he reboots on his own schedule and the fact is enough.
- Condition from **Tom**: *"A Restart button that materialises after a run... moves my focus
  without warning me."* Ship the button, but reserve its space or announce its arrival.

**Call: ship the button.** It is the single largest trust gain in the whole proposal, and it is
the one thing the popup cannot do today that the CLI already knows (`reboot_needed` is written
into every history entry). The safety property Dana needs is that it opens KDE's own confirmation
and never acts alone, which the proposal already specifies. Say so in the tooltip.

## Q2 - Refresh: heading icon, or text button beside Update Now?

**Icon: 4** (Yuval, Lin, Ravi, Maria). **Text button: 2** (Dana, Tom).

- For: **Yuval** - *"Refresh belongs as an icon because I am never going to press it, my terminal
  already refreshed."*
- Against: **Tom** - *"I pass three icon buttons before I reach the one action I came for."*
  Dana seconds it for a different reason: she does not read the circular arrow as "check again",
  she reads it as "undo".

**Call: icon, with two conditions.** Give it the same treatment the pin buttons already get, a
real `text:` on the ToolButton so Orca says "Check for updates now", and put it last in the tab
order, after Update Now. The icon then costs nothing to the two people who voted against it.

## Q3 - Primary action on the heading row, or its own button row?

**Heading row: 5** (Lin, Yuval, Maria, Ravi, Dana). **Separate row: 1** (Tom).

- For: **Lin** - *"one action on the heading row, the secondary demoted to an icon, a quiet
  timestamp at the foot. That is the battery and network popup pattern, so it will feel native."*
- Against: **Tom** - *"Put the primary first in the tab order even if it sits to the right on
  screen."*

**Call: heading row.** This is the least controversial change on the table and it removes the
current design's worst flaw, two equally weighted filled buttons. Tom's objection is entirely
about tab order, not about position, and tab order is settable independently of layout.

## Q4 - The persistent "Last update … [Details ▾]" strip: useful or clutter?

**Useful: 3** (Maria, Dana, Yuval). **Clutter as drawn: 3** (Lin, Ravi, Tom). Moderator breaks
the tie toward **keep, but merge it into one line.**

- For: **Maria** - *"the run line vanishes when the popup closes, so the evidence of the update I
  just ran is gone... 'Last update: 18 min ago, 1 package' is the line I would screenshot."*
- Against: **Lin** - *"with two timestamps stacked... I know which is which. He never will."*
  (Maria said it; Lin, Ravi and Tom all voted the same way for the same reason.)

**Call:** the strip earns its place because it fixes a real regression in the current build, where
the only proof a run happened disappears with the popup. But three of six read two timestamps as
one confusing thing. Collapse "Checked 4 min ago" and "Last update: 18 min ago" into a single
footer line, and let `Details` open the existing history entry rather than an inline expander that
changes the popup height (Tom's objection, and it is cheap to honour).

---

## Missing from both layouts

Ranked by how many personas asked and how badly its absence changes the outcome. Attributions
marked "seconded" came from the post-reaction poll rather than the reactions above.

1. **Download size, and whether the packages are already downloaded.** Ravi unprompted, seconded
   by Yuval and Maria. This is the only gap that makes a persona close the popup and do nothing.
   Verified against the repo: there is no size field anywhere in the state JSON
   (`lib/common.sh:283`), so this is an engine gap first and a layout gap second.
2. **A defer: Later, Tonight, or wifi only.** Dana and Ravi. Both currently "handle" the popup by
   closing it, which is the worst possible outcome for an updater. Dana wants it because of what
   she is doing right now; Ravi wants it because of what he is connected to right now.
3. **Which package is held, reachable from the up-to-date state.** Maria, Yuval, Tom. The held
   list already exists in the pending view, but the proposed up-to-date state reduces it to a
   number with no way through. Make the count a link into the Held group.
4. **What is happening during a run, and whether closing the popup kills it.** Dana, Ravi, Tom.
   The in-popup surface tails a log today, but neither sketch shows a run in progress, and none of
   the three could tell me whether walking away would abort it.
5. **Plain language for "Stage offline instead".** Dana, Lin, Maria. Two of the three guessed it
   meant going offline. The concept is the safest thing Kempt does and it is named after its
   implementation.
6. **Full version strings, untruncated.** Yuval, seconded by Maria, who compares two machines by
   eye. The current popup gets this right and the proposal regresses it.
7. **A spoken result after an action.** Tom, seconded by Dana, who wants the same thing visually:
   a confirmation that outlives the popup. Verified against the repo: there are no `Accessible.*`
   properties in any QML file, so today nothing is announced at all.

---

## Copy nits

No em dashes in any proposed line.

**"Checked 4 min ago"** - Maria and Dana both had to work out *what* was checked, and it sits two
lines from "Last update: 18 min ago", which is a different clock.
Proposed: **"Last checked for updates 4 min ago"**, or when space is tight, merge both clocks into
one footer: **"Checked 4 min ago. Last update 18 min ago, 1 package."** followed by `Details`.

**"1 held back"** - reads as a failure report. Windows says "held back" when something went wrong,
which is exactly the wrong association for a deliberate hold the user asked for. It is also
passive, so Maria could not tell whether her father did it or Kempt did. The tooltip in the code
today says the plainer `1 held`.
Proposed: **"1 package on hold"**, as a clickable link. Where there is room:
**"1 package you are holding"**.

**"Restart to finish installing updates"** - Dana read "installing" as still in progress and
assumed something was running. The updates are already applied; only the running kernel or the
running session is stale.
Proposed: **"Updates are installed. Restart to finish."**
Alternative, if the reason matters: **"Restart to start using the new kernel."**

**"Everything is up to date"** - Lin's redundancy complaint is against the current build, where the
heading says "Up to date" and the body repeats it larger. In the proposal the heading is gone from
that state, so the line is fine on its own, with one exception Yuval raised: it is not true when
something is held.
Proposed: keep **"Everything is up to date"** when nothing is held. When something is held:
**"Up to date, apart from 1 package you are holding."** Never print both the heading and the body
version of this sentence at once.

**Two bonus lines the panel stumbled on, not in the brief:**

- "⚠ Kernel update - restart after" → **"This includes a kernel update. Restart when it
  finishes."** Yuval also wants the driver named when one is in the transaction:
  **"This includes a kernel update and the NVIDIA driver. Restart when it finishes."**
- "Stage offline instead" → **"Install on next restart (safer)"**, with the tooltip carrying the
  reason: **"Applies the update during a restart, so nothing changes underneath your running
  desktop."**
- The post-run line `Kempt - 2026-08-26T21:08:20+03:00 (terminal, 38s) ✓` → **"Updated 3 packages
  in 38s"**. Nobody on this panel read an ISO 8601 timestamp as friendly, and the machine-readable
  form belongs in `kempt history`, not in the popup.

---

## Final recommendation

1. Ship the proposed layout: primary on the heading row, Refresh as an icon, quiet footer. Five of
   six preferred it and it matches the Plasma popups next to it in the same tray.
2. Ship the `Restart…` button. It is the biggest trust gain available, the data is already in
   every history entry, and its safety comes from opening KDE's own confirmation, never acting.
3. Fix the two regressions the proposal introduces: keep full version strings untruncated, and put
   Update Now first in the tab order with a real accessible label on every icon button.
4. Merge the two clocks into one footer line, and make "1 package on hold" a link into the Held
   group so the up-to-date state is not a dead end.
5. Before this ships to anyone on a metered or slow connection, put a size next to Update Now.
   That is an engine change, not a layout one, and it is the only gap that made a persona close
   the popup and update nothing.
