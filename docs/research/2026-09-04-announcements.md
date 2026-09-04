# Announcement drafts for 0.1.x

Three posts, one per channel, written to be posted BY HAND from the founder's own accounts -
posting is never automated, and whoever posts stays around for the comments that day; the
replies are half the value of announcing at all.

**When:** after the first-run fix ships (the engine-missing message + the store shadow-copy
doctor check) and the store file is refreshed. The announcement wave sends store-first users at
the widget, and today the widget greets them with a raw shell error. Fix first, invite second.

**Order:** r/kde and KDE Discuss on day one (the warmest rooms for a Plasma widget), r/fedora a
day later so the posts read as posts, not as a campaign. Optional later, no hurry: Fedora
Discussion (Show & Tell), and a Show HN once a second distro backend exists and the story is
"universal updater", not "Fedora widget".

**Attach the screenshot** (docs/images/kempt-tray-popup.png) everywhere images are allowed.
It does the explaining.

---

## r/kde - flair: KDE Apps and Projects

(Verified 2026-09-04 against the live subreddit: recent widget announcements carry "KDE Apps
and Projects" or "Kontributions"; there is no Showcase flair. Rule 5 explicitly welcomes
original work; rule 6 bans disparaging other FOSS projects - so in comments, Discover gets
"two caches give two answers", never "Discover lies". Image posts are fine here.)

**Title:** I made Kempt - a tidy update widget for Plasma 6 on Fedora (dnf + Flatpak)

Kempt is a system tray updater for Fedora KDE. The badge shows how many dnf and Flatpak
updates are pending; the popup shows each one with the version it moves from and to and the
size of the download, and one button applies them - live in a terminal, silently in the
background, or staged so the next restart installs them.

Things I cared about while building it:

- The widget carries no package-manager logic of its own. The badge is the number the CLI just
  wrote, and Update Now runs the same engine, so the panel and the terminal can never disagree.
- Staging downloads **and** arms the transaction, so any restart installs it - the popup's
  button, the K menu, `reboot` in a terminal. Then it tells you what the restart installed.
- Failures come back in words. A cancelled password prompt says "authentication declined or
  cancelled", not a quoted pkexec error.
- Holds: `kempt hold dnf:kernel-core` keeps a package out of every run while it stays visible,
  so skipping something is never the same as forgetting it.

Install on Fedora (the package carries the CLI and the widget):

    sudo dnf copr enable erez-c137/kempt
    sudo dnf install kempt

The widget alone is on the KDE Store and in Plasma's Get New Widgets browser - it needs the
CLI, and if you install it first, the popup walks you through the rest (with a Copy Commands
button, because nobody should retype a dnf line off a tray popup). MIT, first release,
Fedora-only for now - the backend contract is deliberately small, and an apt or pacman backend
is the contribution I would most love to see.

https://github.com/erez-c137/kempt

---

## KDE Discuss (discuss.kde.org) - category: Community, tags: widget, plasma6

(Verified 2026-09-04: there is no top-level Plasma category. Third-party widget announcements
- On Air, Panel Colorizer, Dictee - all live in **Community** (category id 5). Panel Colorizer
got 26 replies there, so it is the room that works. r/kde's AutoModerator also points people
at Discuss and lemmy.kde.social on every post, which is one more reason to be present here.)

**Title:** Kempt: a system tray updater for Plasma 6 that tries very hard not to lie

Same body as the r/kde post, plus this closing paragraph (this room will appreciate it):

The popup went through a proper HIG pass: messages are Kirigami InlineMessages in a stack, the
one primary action lives in a footer PlasmoidHeading and hides (never greys) when there is
nothing to run, the list uses ListSectionHeaders per backend, and every count in the popup is
dated ("Checked 4 min ago") because an undated number in a tray popup is a small lie waiting to
happen. Feedback on any of those calls is very welcome - especially where you think the HIG
reading is wrong.

---

## r/fedora - flair: Announcement

**Title:** Kempt: dnf and Flatpak updates from the Plasma tray, with counts that match the
terminal and offline staging that actually arms

I got tired of the update notifier and my terminal disagreeing about what was pending, so I
built the updater I wanted. Kempt is a CLI with a Plasma 6 tray widget over it:

- `kempt check` reads the same root metadata cache the upgrade itself uses (`-C`, cache-only,
  answers offline), so the pending count and the transaction cannot drift apart.
- Offline staging runs `dnf5 upgrade --offline` and then arms it (status "ready" +
  `/system-update`), which is the step that makes "install on next restart" true - a staged
  transaction that is never armed installs on no restart at all. After the reboot, the widget
  reports what that restart installed.
- Root is scoped: separate polkit actions for metadata refresh and apply, argument-validating
  helpers, and optional passwordless mode is one rule for the one apply action, active local
  session only - not blanket sudo.
- Holds, per-run history and logs, an event log (`kempt log`), a download-size figure before
  you press the button, and `kempt doctor` for "is this install actually wired up".

Install:

    sudo dnf copr enable erez-c137/kempt
    sudo dnf install kempt

MIT, first release. Developed and tested on Fedora 44; the COPR builds for Fedora 43 through
45 and rawhide, x86_64 and aarch64 (so Asahi too - reports welcome). Repo, docs and the
honest-limitations list: https://github.com/erez-c137/kempt

---

## Likely questions and pushback, with the answers (researched 2026-09-04)

Built from reading the actual comment threads on comparable posts: KVitals and other widget
announcements on r/kde, Gnome Theme Manager on r/fedora, Panel Colorizer on KDE Discuss, and
r/openSUSE's "Tumbleweed system update tool" thread, which is Kempt's problem statement
written by a stranger and contains every objection in the wild.

**1. "Arch/AUR when? openSUSE? Debian?" - the single most common comment class.** Every widget
thread fills with other-distro users within hours. Answer: the backend contract is two
functions plus a shared parser in one file, link the architecture doc's
"adding a backend" section, and say plainly it is the contribution you would most love to
merge. Do not promise dates.

**2. "Just use an alias / just type sudo dnf upgrade."** Guaranteed, usually upvoted. Do not
argue with it; agree. The honest answer: correct, and the CLI half of Kempt exists because
the terminal is the primary surface - the widget is for the days you are not in one, and for
the count you can see without asking.

**3. "Why not Discover?"** r/kde rule 6 bans disparaging other FOSS projects, and the room
genuinely likes Discover for apps. The safe, true framing: Discover is a software centre
over PackageKit's own daemon and cache; dnf5 has another; two caches give two answers. Kempt
picked one source of truth rather than a second opinion. Never "Discover lies".

**4. The offline-updates orthodoxy (r/fedora's sharpest technical pushback).** Respected
voices there (gordonmessmer et al.) recommend offline updates for everything, because a
session crash mid-transaction leaves rpmdb in a state dnf5 struggles to repair. Expect "a GUI
that runs live dnf updates is teaching bad habits." The answers, all true:
- runs are detached with setsid, so a plasmashell crash does not touch a running update;
- the reboot verdict IS `dnf5 needs-restarting` (hardened: cache-only, repos disabled, no
  stdin), not a homegrown guess;
- when session-critical packages are pending (risky_regex), the popup recommends the offline
  surface, and offline staging genuinely arms;
- the terminal default matches what those same commenters already do by hand; Kempt's job is
  telling you when the careful path is warranted, not forcing it always.

**5. "Random COPR from a solo dev, running as root? No thanks."** Fair, and the answer is
posture, not persuasion: MIT, small readable bash, docs/security.md says exactly what runs as
root and why, separate polkit actions for refresh vs apply, argument-validating helpers, and
official Fedora packaging is on the roadmap once COPR proves it. Passwordless mode will get
poked specifically: optional, off by default, one rule, one action, active local session only.

**6. "Is this vibecoded?" / AI suspicion.** A one-word "vibeshat?" comment on the Gnome Theme
Manager thread scored 7 points; r/Fedora's rule 2 lists "AI content" as removable. This
question is near-certain and the founder answers it in his own words. What helps: the 2400+
assertion test suite, the design docs, and the honest-limitations register - projects that
ship those do not read as drive-by generated. Do not get defensive; do not volunteer the
topic unprompted.

**7. "topgrade exists" / "dnf-automatic exists" / "Apdatifier exists".** Prior art will be
cited. One respectful line each: topgrade runs everything with no tray, no state, no offline
staging; dnf-automatic is unattended, Kempt is visibility and control; Apdatifier is
pacman-first with the package logic in the widget, Kempt keeps the widget dumb over a CLI.
The prior-art survey in docs/research is linkable and shows the homework was done.

**8. Bug reports and distro-matrix reports arrive same-day.** KVitals had "TEMP shows - -"
(missing dependency) within hours, plus margin nitpicks and PR offers. Expect the equivalent:
kempt doctor output screenshots, F43/aarch64 reports now that the COPR carries them, locale
oddities. Treat each as the gift it is; `kempt doctor` output makes triage fast, ask for it.

**9. Feature requests to expect (from comparable threads):** firmware updates (fwupd) in the
one place, per-core/GPU-style "more data" asks translated to updates (changelogs per package,
update severity), notification-only mode, a "restart now" that skips the KDE prompt (decline
that one - a restart is offered, never performed), and Bazzite/Silverblue/atomic support
(rpm-ostree is a different beast; roadmap category, be honest it is not close).

**10. Pre-post prep that converts enthusiasm into contributors:** open three good-first-issue
tickets before posting - "apt backend", "pacman backend", "zypper backend" - each quoting the
two-function contract, so every "Debian when?" comment gets a link instead of a shrug.

## Norms checklist (for whoever posts)

- Post from the founder account, reply to every substantive comment within the day.
- One channel at a time; never the same hour.
- If a thread turns critical, the voice stays the repo's: plain, specific, no defensiveness -
  a good bug report in a comment thread is a gift, treat it as one.
- Do not repost or bump. One post per channel per release.
