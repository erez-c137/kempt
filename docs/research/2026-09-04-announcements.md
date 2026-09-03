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

## r/kde - flair: Showcase

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

The widget alone is on the KDE Store, but it needs the CLI, so on Fedora the package is the
whole story. MIT, first release, Fedora-only for now - the backend contract is deliberately
small, and an apt or pacman backend is the contribution I would most love to see.

https://github.com/erez-c137/kempt

---

## KDE Discuss (discuss.kde.org) - category: Plasma, tags: widget, plasma6

**Title:** Kempt: a system tray updater for Plasma 6 that tries very hard not to lie

Same body as the r/kde post, plus this closing paragraph (this room will appreciate it):

The popup went through a proper HIG pass: messages are Kirigami InlineMessages in a stack, the
one primary action lives in a footer PlasmoidHeading and hides (never greys) when there is
nothing to run, the list uses ListSectionHeaders per backend, and every count in the popup is
dated ("Checked 4 min ago") because an undated number in a tray popup is a small lie waiting to
happen. Feedback on any of those calls is very welcome - especially where you think the HIG
reading is wrong.

---

## r/fedora - no flair needed

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

MIT, first release, Fedora 44 tested. Repo, docs and the honest-limitations list:
https://github.com/erez-c137/kempt

---

## Norms checklist (for whoever posts)

- Post from the founder account, reply to every substantive comment within the day.
- One channel at a time; never the same hour.
- If a thread turns critical, the voice stays the repo's: plain, specific, no defensiveness -
  a good bug report in a comment thread is a gift, treat it as one.
- Do not repost or bump. One post per channel per release.
