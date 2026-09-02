# Kempt Popup Redesign - Research Provenance

This directory holds the research and decisions backing the 2026-08-26 popup redesign. The two reports below were reviewed by the founder before committing to the scope and shape outlined in the implementation plan.

## Files

- **[user-panel.md](./user-panel.md)** - Simulated usability panel. Six personas (Dana, Yuval, Ravi, Maria, Tom, Lin) shown the current popup and the proposed redesign, reacting as if they had just clicked the tray icon. Captures usability friction, feature requests, and reactions to the four open design questions.

- **[hig-review.md](./hig-review.md)** - KDE Plasma interaction guidelines review. Read Plasma 6.7.4 as shipped on this box (Bluetooth, Vault, Klipper, Device Notifier, KDE Connect, DiscoverNotifier plasmoids, plus Plasma's own logout/shutdown DBus services). Cites file paths to actual shipped Plasma QML and configuration. No speculation or historical recall.

## Founder's Decisions (2026-08-26)

- **Restart button**: YES. Opens KDE's own restart prompt via `org.kde.LogoutPrompt.promptReboot`. Nothing restarts on its own.
- **Refresh**: An icon, not a text button, plus refresh-on-open, fired only when the last successful check is older than the configured interval or five minutes, whichever is smaller.
- **Persistent last-update line**: YES. Shown in all states except briefly during post-run transient feedback.
- **Primary action placement**: Footer, not heading row. HIG reviewer's evidence: the heading is the only row Plasma's containment is allowed to replace; all shipped applets treat heading content as expendable; `PlasmoidHeading` is a `ToolBar` (flat controls only); the KDE HIG places the primary action bottom-right.

Where the two reports disagreed, the founder followed the HIG review: the panel voted 5-1 for the primary action on the heading row, and the HIG review's reading of Plasma's own applets showed that row is the one a containment may replace. The footer won.

See the implementation plan at [../../plans/2026-08-26-kempt-popup.md](../../plans/2026-08-26-kempt-popup.md).
