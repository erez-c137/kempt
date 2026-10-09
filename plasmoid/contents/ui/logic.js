// logic.js - the widget's entire derivation layer, in ENGINE-AGNOSTIC JavaScript.
//
// Loaded twice: by the plasmoid (`import "logic.js" as Logic`, QML's JS engine) and by
// tests/test_widget_logic.sh (node, through the CommonJS guard at the bottom). That is the point.
// A QML plasmoid cannot be executed in a test suite, so every rule the panel shows a human - the
// badge number, the icon state, the tooltip, the popup rows - is derived HERE, where a node test
// can pin it. Nothing in this file may touch Qt, i18n, the filesystem or a network.
//
// NOT `.pragma library`: that pragma is not valid JavaScript, so node could not load this file at
// all. The functions are pure, so the one shared copy it would buy buys nothing.
// Old-school JS (var, function expressions, indexOf): this runs unchanged in whatever JS engine
// the installed Plasma version ships.
//
// Input contract: state schema v1 (docs/architecture.md), the CLI's frozen public interface. Two
// of its rules are load-bearing and enforced below:
//   1. empty stdout with exit 0 means "no data, keep the last known state", NEVER "zero updates";
//   2. `status: "stale"` keeps the last known counts - a tooltip fact, not a fabricated 0.

// Titles match the CLI's own renderer (lib/common.sh render_summary) so the popup and the terminal
// never name the same group differently.
var SECTION_TITLES = { dnf: "System (dnf)", flatpak: "Apps (flatpak)" };
var BACKEND_ORDER = ["dnf", "flatpak"];

// A backend may group its pending items further, by the `kind` its items carry. Flatpak is the one
// that does: `flatpak update` updates runtimes as well as apps, so Kempt counts and itemizes them -
// and they get a heading of their own UNDER the apps rather than sitting among them beneath a title
// that says "Apps". An item with no `kind` at all is the ordinary case and keeps the backend's own
// heading, which is what makes the key additive: every state file written before runtimes were
// counted has no `kind` anywhere in it and renders exactly as it always did.
var KIND_SECTION_TITLES = { flatpak: { runtime: "Flatpak runtimes" } };

// --- the copy table ----------------------------------------------------------------------------
// Every user-facing string the QML writes as a literal, in ONE place, so the wording is decided
// once and a node test can pin it. House rules: Title Case for buttons, sentence case for
// messages; a real ellipsis (U+2026) on anything that opens something else; no em dashes; "held",
// never "held back" - the CLI's section is Held and the command is `kempt hold`.
//
// IMPORTANT, and not what it looks like: the QML does NOT read these at runtime. It writes the
// literal, `i18n("Update Now")`, because translation extraction works on LITERALS -
// `i18n(Logic.COPY.updateNow)` extracts nothing and ships an untranslatable widget. This table is
// the SPECIFICATION; the QML repeats the same literal. Do not "fix" that duplication by routing
// these through i18n().
// tests/test_widget_logic.sh pins the duplication so it cannot drift, and it does NOT ask for
// "verbatim in a .qml" - that would be wrong for the 23 entries below that the view model renders
// and the QML therefore never spells out. An entry has to be used in one of three ways: repeated
// verbatim in a .qml, read as `Logic.COPY.<key>` by a .qml where a literal cannot go, or used by
// this file. An entry in none of them is wording kept as a specification for nothing.
//
// What the table does NOT hold is the sentences viewModel ASSEMBLES - footerText, lastRunText,
// postRunLine, relativeTime. QML cannot wrap an assembled string in i18n() at all, and moving
// their fragments in here would not make them translatable either: a fragment is not a
// translatable unit, and this widget has no message-format layer to turn it into one. That layer
// is a later release; meanwhile the tests pin every assembled shape exactly.
var COPY = {
    // Header, and the placeholder under it - deliberately NOT the same sentence, so the popup does
    // not say the same words twice in one glance.
    upToDate: "Up to date",
    everythingUpToDate: "Everything is up to date",

    // `restartMessage` states a fact about the machine; `restartAction` opens KDE's own
    // logout/restart prompt and nothing else. Kempt never restarts anything itself, in any state,
    // with any setting.
    restartMessage: "Restart to apply installed updates",
    restartAction: "Restart…",
    restartFailed: "Could not open the restart prompt.",

    // The two actions. Refresh is icon-only in the header, so this is its tooltip and its
    // accessible name as well as its entry in the contextual-actions menu.
    checkForUpdates: "Check for Updates",
    updateNow: "Update Now",

    // ...and what those icon-only buttons DO, which is a different question from what they are
    // called. `text` is already the accessible name, so a description bound to `text` spends the
    // one slot that could explain the effect.
    checkForUpdatesDescription:
        "Asks dnf and flatpak what is pending now, instead of waiting for the timer.",
    configureDescription:
        "Check interval, where updates run, restart reminders, and the packages you hold.",

    // --- the pin ---------------------------------------------------------------------------------
    // The name carries the STATE, with a residual: a `checkable: false` button exposes no checked
    // state to AT-SPI on Qt 6.11 (measured), and the one role that does - CheckBox - makes Breeze
    // draw its sunken checked background on a control sitting directly under the tray's own
    // checked Keep Open pin. So the state is words: these four sentences, the "Held" token on the
    // row, and the glyph.
    // TWO PAIRS, because a package that is not installed yet has no current version to be held AT:
    // the CLI writes "?" for that `from`, and what the pin does there is refuse the install.
    holdAt: "Hold %1 at %2",
    stopHolding: "Stop holding %1",
    skipInstalling: "Skip installing %1",
    stopSkipping: "Stop skipping %1",
    // The description is the CONSEQUENCE. Per package, and Kempt only - a dnf user reads
    // versionlock into a padlock, and this is where that is answered.
    holdConsequence: "Kempt skips it on every update until you stop holding it.",
    heldConsequence: "Kempt offers its update again.",
    // ...and the two for an app installed both ways: a hold is by id, so it covers both copies.
    holdConsequenceBoth: "Kempt skips both copies, the system one and the one for you only, until you stop holding it.",
    heldConsequenceBoth: "Kempt offers the update again for both copies, the system one and the one for you only.",
    // A per-user Flatpak app, as a word on its row beside "Held".
    forYouOnlyToken: "For you only",
    // The state in words on the row. A glyph, a position and an opacity dip are not enough: a dip
    // is a contrast REDUCTION on rows a person deliberately protected.
    heldToken: "Held",
    // A system package whose pending update fixes a security advisory, as a word on its row. Only
    // for someone who turned notify_security on: the CLI asks dnf about advisories for nobody else.
    securityToken: "Security",
    // ...and how many of them, in the panel tooltip after the pending names.
    securityCount: "%1 security updates",
    securityCountOne: "1 security update",
    // What a row draws where the CLI wrote "?": "? → 9.9.9-1.fc44" reads as "the widget does not
    // know". The DATA keeps the "?" - it is the CLI's sentinel and the padlock recognises it too.
    versionNew: "new",
    // When an update's version string does not move. Most Flatpak runtimes carry a date or nothing
    // at all as their version, and the commit is what changes, so "2024-05-30 -> 2024-05-30" is a
    // real update rendered as a contradiction. Said once here and used by every surface.
    newBuild: "new build",
    // ...and the line the Held heading owes a first-timer: a hold is Kempt's own list and does not
    // touch `dnf upgrade`.
    heldKemptOnly: "Kempt skips these. Other updaters still see them.",
    // The version line as a sentence: on screen it is "3.105-… → 3.106-1.fc44", and that arrow
    // goes through a screen reader's character table as a word nobody wants to hear.
    versionRange: "from %1 to %2",

    // --- the pane a run replaces the popup with ---------------------------------------------------
    // One sentence per surface, each naming where to look, and staging says what it is rather than
    // calling itself an update. Never the CONFIGURED surface, and never the word "surface".
    updatingTerminal: "Updating in a terminal window…",
    updatingBackground: "Updating in the background…",
    updatingHere: "Updating…",
    updatingOffline: "Staging updates for the next restart…",
    // ...and the way out. Only a state.json change ends the updating state, and a terminal run
    // that is aborted or closed never writes one - so without this the popup sits on an empty pane
    // until a three-hour guard fires. On the default configuration that is what a first-timer gets
    // for taking the default answer to Kempt's one question.
    notUpdatingCheckAgain: "Not Updating? Check for Updates",

    // The offline path, named for what it does to the user rather than for the dnf5 flag behind
    // it. The tooltip names what waits for the restart and what does not: Flatpak has no offline
    // route, so a staging run still updates apps live. The footer button uses it too, and both
    // take the shorter one when no Flatpak app is waiting (stageTooltipOf).
    installOnNextRestart: "Install on Next Restart",
    installOnNextRestartTooltip:
        "Installs system updates during the next restart. Flatpak apps update now.",
    // ...and the same without the Flatpak half, for when no Flatpak app is waiting.
    installOnNextRestartSystemTooltip: "Installs system updates during the next restart.",
    // ...and the other answer, offered beside it only after Update Now was pressed on a set the
    // message above calls risky, on a box that would otherwise install it live without asking.
    installNow: "Install Now",
    installNowTooltip: "Installs the update now, while your desktop is running.",

    // The one offer of the new default, to an install that kept the terminal when the default
    // changed. Each button is an answer, so the message has no close button. In the words Settings
    // uses for the two choices: In this widget, Terminal window.
    surfaceOffer: "Updates can now run in this widget instead of a terminal window.",
    surfaceOfferUse: "Use This Widget",
    surfaceOfferKeep: "Keep the Terminal Window",
    // ...and what the popup says once either answer is saved. `kempt config set` prints nothing,
    // so these are the widget's own words for what the person just chose.
    surfaceSetPopup: "Updates now run in this widget.",
    surfaceSetTerminal: "Updates keep running in a terminal window.",
    // An answer the CLI did not confirm in time (ANSWER_TIMEOUT_MS). The write may still land.
    answerTimedOut: "Kempt did not answer in time, so your answer may not be saved. Try again.",
    // ...the same for a switch in Settings, and for a hold, which are changes rather than answers.
    settingTimedOut: "Kempt did not answer in time. The setting may not have changed. Try again.",
    holdTimedOut: "Kempt did not answer in time. The hold may not have changed. Try again.",

    // The one offer to turn off Discover's own update notifier, while it starts with the session.
    // Turning it back on is in Settings, under the same name.
    discoverOffer: "Discover, Plasma's software center, also shows update notifications. Its count can differ from Kempt's, and its checks can make an update wait. Kempt shows new updates on its panel icon and does not send notifications for them.",
    discoverOfferOff: "Turn Off Discover's Notifier",
    discoverOfferKeep: "Keep Discover's Notifier",
    discoverOn: "Turn On Discover's Notifier",
    discoverStatusOn: "Discover also shows update notifications, with its own count.",
    discoverStatusOff: "Discover's notifier is off.",
    discoverStatusOwn: "Discover's notifier is turned off by a startup file: %1. Delete that file to turn it back on.",
    discoverStatusOwnNoPath: "Discover's notifier is turned off by a startup file. Delete that file to turn it back on.",

    // Four spellings, because two things vary: whether a kernel is in the set, and whether the
    // NVIDIA driver is with it (that box has a second, worse failure mode - a kernel module built
    // against a kernel that is not the running one - and naming it makes the advice credible).
    // Each says what the BUTTON underneath does, never "restart when it finishes": recommending
    // the live path over a button offering the offline one reads as an order to restart now.
    kernelRestart:
        "This update includes a kernel. The safest way is to install it on the next restart, "
        + "so nothing changes under the running desktop.",
    kernelNvidiaRestart:
        "This update includes a kernel and the NVIDIA driver. The safest way is to install them "
        + "on the next restart, so nothing changes under the running desktop.",
    // ...and the same recommendation with no kernel in the set. The family list is kept, capped
    // where the count sentence caps it, because it is the evidence for the claim.
    riskySessionOne:
        "This update touches 1 package your running session depends on (%1). "
        + "The safest way is to install it on the next restart.",
    riskySessionMore:
        "This update touches %1 packages your running session depends on (%2). "
        + "The safest way is to install them on the next restart.",
    // When Update Now turns that message into a choice: the lead-in goes in front of it on screen,
    // because nothing else says the click did not start a run, and the question ends what is read
    // out, because the focus lands on a button and a screen reader would read only that.
    riskyAskLead: "Nothing is installed yet.",
    riskyAskQuestion: "Install on the next restart, or now?",
    // The same risk with no advice, for a box with no route to the next restart.
    riskySummaryOne: "1 pending update touches a package your running session depends on (%1).",
    riskySummaryMore: "%1 pending updates touch packages your running session depends on (%2).",

    // `held` is a suffix to a number ("3 held") rather than a sentence, because the same word has
    // to serve the tooltip too.
    held: "held",
    restartPending: "restart pending",
    // What the footer gains while the counts above it are stale: three words on the line that
    // DATES those counts. The CLI's reason goes in the tooltip of the button that tries again.
    lastCheckFailed: "last check failed",
    // ...and while the per-user apps could not be listed. The rest of the check stands, so this is
    // a footer fact like the one above. The sentence replaces "Everything is up to date".
    userAppsUnchecked: "Apps installed for you only could not be checked.",
    userAppsUncheckedShort: "apps for you only not checked",
    // "No SUCCESSFUL check", not "not checked": the footer dates the counts by last_success, so
    // its fallback has to be about last_success. A box whose every check since install has failed
    // HAS checked - and that box is the one most likely to be reading this line.
    noSuccessfulCheckYet: "No successful check yet",
    // A check that never answered. The first is the problem line when there is no state at all;
    // the other two are the report over counts we still hold, which otherwise change nothing on
    // screen. Never the Executor's own "timeout after 540000ms": that is a log line, not a reason.
    checkTimedOut: "The check did not finish in time.",
    checkUnfinished: "The check did not finish. The counts shown are from the last check.",
    checkFailedOver: "The check failed. The counts shown are from the last check.",
    // What Check for Updates says out loud when the check itself reported a failure (status
    // "stale"). Short on purpose: the footer line it replaces also carried the metadata age, the
    // held count and the download size. %1 is the failed half, %2 when the counts are from.
    checkFailedFor: "The check failed for %1.",
    checkFailedPlain: "The check failed.",
    // The placeholder over a check that answered nothing and left no counts to show. The tool's
    // own words stay on screen in small print under it (vm.problemDetail). A network failure gets
    // its own sentence, and no Check Installation: nothing in the installation is wrong.
    checkFailedHeadline: "The check failed",
    checkFailedHint: "Check Installation can find out why.",
    checkNetworkHeadline: "Kempt could not reach the update servers",
    checkNetworkHint: "Check your network connection.",
    // dnf has no package lists and no network failure explains why. Doctor reports nothing
    // wrong here, so neither hint offers Check Installation.
    checkNoCacheHeadline: "The package lists have not been downloaded yet",
    // Which one follows the check's refresh_skipped. The CLI tests power first, so a computer on
    // battery AND a metered connection is told to plug in, and the next check names the network.
    checkNoCacheHint: "Press Check for Updates to download them.",
    checkNoCachePowerHint: "Plug in, then press Check for Updates.",
    checkNoCacheMeteredHint: "Switch to an unmetered connection, then press Check for Updates.",
    // KEMPT_SKIP_REFRESH turns fetching off, so no press can download them.
    checkNoCacheOffHint: "Fetching package lists is turned off.",
    checkRefreshFailedHint: "dnf could not download them. Its error is below.",
    // ...and the panel tooltip in that state: a title, and the reason in a few words.
    checkFailedTooltip: "Cannot check for updates",
    stateUnreadableTooltip: "Cannot read the update state",
    checkNetworkShort: "Could not reach the update servers",
    checkFailedShort: "Open Kempt to see why",
    // The age of the counts in the stale tooltip. %1 is a relative time ("1 day ago").
    lastSuccessfulCheck: "Last successful check %1",
    countsFrom: "The counts are from %1.",
    // A Check for Updates whose fetch did not land, over counts the check still answered from the
    // lists already here. One lead says why, then fetchCountsFrom says how old those lists are.
    // %1 is an age such as "3 hours old".
    fetchNoServers: "Kempt could not reach the update servers to download fresh package lists.",
    fetchFailed: "Kempt could not download fresh package lists.",
    fetchWaitsForPower: "Kempt waits for mains power to download fresh package lists.",
    fetchWaitsForUnmetered: "Kempt waits for an unmetered connection to download fresh package lists.",
    fetchMissed: "Kempt did not get fresh package lists.",
    // The button on fetchWaitsFor* and under the battery and metered no-cache hints. One press runs
    // one check that downloads anyway. Its tooltip follows the reason the check published.
    downloadAnyway: "Download Anyway",
    downloadAnywayPowerTip: "Downloads fresh package lists now, on battery power.",
    downloadAnywayMeteredTip: "Downloads fresh package lists now over this metered connection.",
    // A press whose check waited out another check's lock: the CLI served the state from before
    // the press and downloaded nothing, so the press is asked for again.
    anywayLost: "Another check was running. Press Download Anyway again.",
    fetchCountsFrom: "The counts are from lists %1.",

    // The last run: its expander action, and the two phrases that stand in for a package list.
    showLog: "Show Log",
    noPackageChanges: "No package changes",
    updateFailed: "Update failed",

    // THREE spellings, because two things vary independently: the count can be unknown (a marker
    // written before the CLI recorded one), and one update is not the plural with a 1 in it: noun
    // and verb move together ("1 update IS staged and INSTALLS"). `stagedTail` stays a
    // FRAGMENT for the plural spellings only, so the two say the identical thing about the
    // identical transaction; the tests pin the finished sentences, not the pieces.
    stagedTail: "are staged and install on the next restart",
    stagedOne: "1 update is staged and installs on the next restart",
    stagedUnknownCount: "Updates are staged and install on the next restart",
    // ...and what the banner shows under the header, which already says how many are staged.
    // The full sentence above stays its accessible name and what is announced.
    stagedBannerOne: "It installs when you restart.",
    stagedBannerMore: "They install when you restart.",

    // A staging run that staged NOTHING. Every pending dnf update was held, or nothing was pending
    // at all: the run succeeded, correctly did nothing, and the three sentences above are all lies
    // about the restart that follows. Word for word what the CLI's own notification says, so the
    // panel and the notification that arrives beside it cannot describe the same second
    // differently. Saying WHICH of the two reasons it was is the point: "Kempt did nothing" reads
    // as a fault, and "your holds did what you asked" is the same fact told properly.
    stagedNothingHeld: "Nothing to stage, because every pending update is held",
    stagedNothingNonePending: "Nothing to stage, because no updates are pending",
    // ...and the past-tense form, for the row that describes a run that has already finished.
    lastRunNothingStaged: "nothing needed staging",

    // ...and the HEADER over that banner, same three spellings, same reasons. While a stage is
    // armed the pending count is a true number saying a false thing: "23 updates available" over a
    // green banner about the same 23 reads as "so it did not work?". The BADGE is deliberately
    // untouched - those updates really are pending until the restart runs.
    stagedHeaderOne: "1 update staged for the next restart",
    stagedHeaderTail: "updates staged for the next restart",
    stagedHeaderUnknown: "Updates staged for the next restart",

    // A stage Kempt made that the next restart will NOT install: another updater (Discover, through
    // PackageKit) has prepared that restart, and dnf5 does not run behind its symlink. The CLI
    // publishes offline_stage_blocked for it and never offline_staged, so nothing above applies.
    stageBlocked: "Another updater has prepared the next restart, so the updates Kempt staged "
        + "will not install then. Restart to let that update install. Kempt then shows what is "
        + "still pending.",

    // ...and the three the banner has once a hold lands behind the stage. These REPLACE
    // stagedTail/stagedOne rather than joining them: a warning appended to a reassurance is the
    // contradiction one level down. "%1"/"%2" because these are the only entries whose
    // subject is a package name from another program, and a sentence with a name in it must be
    // one whole translatable string, never a head and a tail glued together; stagedVariantOf
    // substitutes.
    // A NAME then a count of the rest, not familiesOf - collapsing kernel-core and kernel-modules
    // is right for "what is risky here" and wrong here, where the person is owed the number of
    // packages their holds did not stop. In the USER'S order of events, with BOTH remedies: named
    // after the mechanism it has no antecedent once the green banner is gone.
    stagedConflictOne:
        "You held %1 after the update was staged, so it still installs. "
        + "Rebuild the staged update to skip %1, or stop holding %1 to keep the current plan.",
    stagedConflictMore:
        "You held %1 and %2 more after the update was staged, so they still install. "
        + "Rebuild the staged update to skip them, or stop holding them to keep the current plan.",
    // "may", because that is exactly what is known: names_source "none" means an empty conflict
    // list is "cannot tell", never "no conflict". The spec's rule is that names may CONFIRM a
    // conflict and may never DENY one, so silence here would be denying one on no evidence.
    stagedConflictUnknown:
        "You added holds after the update was staged, so it may still install held packages. "
        + "Rebuild the staged update to apply your holds.",
    // The cost, as the banner's SECOND SENTENCE rather than only in the action's tooltip, which
    // discloses it only to somebody who has already hovered the button they are deciding about.
    stagedRebuildCost: "Rebuilding may ask for your password. If it fails, nothing stays staged.",

    // The one action a warning variant offers, and its whole cost. Both facts are real: it runs
    // `kempt update --surface=offline`, a privileged verb, and dnf5 destroys the stored
    // transaction the moment a re-stage begins, so a failed rebuild leaves nothing
    // staged. It deliberately does NOT say "re-downloads" - a replace-stage reuses dnf5's package
    // cache (container-measured) - and says "removed", the CLI's own word for it.
    stagedRebuildAction: "Rebuild Staged Update",
    stagedRebuildTooltip:
        "Builds the staged update again with your current holds. May ask for your password. "
        + "If the rebuild fails, the current staged update is removed.",
    // What the rebuild says instead of acting when the stage it was offered over is not the stage
    // on disk any more - the only sentence that stops a press with no effect being
    // indistinguishable from a broken button. main.qml assigns it, like restartFailed.
    stagedChanged:
        "The staged update changed since this was offered. Nothing was rebuilt; "
        + "check the banner above.",

    // --- discarding the staged update from the popup instead of from a terminal ------------------
    // The other way out of a staged update, and the one a person who simply changed their mind
    // wants: remove it, and let the next restart install nothing. The CLI's own verb all the way
    // through - `kempt unstage` prints "Discarded the staged update", and the usage page says
    // discard - so the button says Discard. "Cancel Staged Update" was the other candidate and it
    // is worse in exactly one place: a button labelled Cancel inside a message reads as "close
    // this message", which is the one thing it does not do.
    stagedDiscardAction: "Discard Staged Update",
    // The whole cost, before the press, and the second half is what separates this from a rebuild:
    // a rebuild reuses dnf5's package cache, and this deletes it (`dnf5 offline clean` removes the
    // downloaded packages with the transaction). Said as what happens NEXT time rather than as a
    // warning, because that cost is only paid by somebody who stages again.
    stagedDiscardTooltip:
        "Removes the update waiting for the next restart, so the restart installs nothing. "
        + "May ask for your password. It deletes the packages it downloaded, so staging again "
        + "downloads them again.",
    // One sentence per outcome, for the run that said nothing for itself - discardStagedMessage
    // prefers the CLI's own first line wherever there is one. None of them is silence: this press
    // makes a banner disappear and nothing else, and a message that only vanished is
    // indistinguishable from a button that did nothing at all.
    stagedDiscardDone: "The staged update is gone. The next restart installs nothing.",
    stagedDiscardRefused: "Nothing was discarded. Press Check Installation to find out why.",
    stagedDiscardBusy:
        "An update is running, so nothing was discarded. Try again when it has finished.",
    // The status is in this one because it is the only evidence left: a failure the CLI could not
    // describe leaves the reader with nothing else to quote.
    stagedDiscardFailed:
        "The staged update could not be discarded (exit %1). "
        + "Press Check Installation to find out why.",
    // ...and the click-time re-verify's refusal, the same sentence stagedChanged is for the
    // rebuild: a press with no effect must never be indistinguishable from a broken button.
    // main.qml assigns it.
    stagedDiscardChanged:
        "The staged update changed since this was offered. Nothing was discarded; "
        + "check the banner above.",

    // The hold round trip. The first two are never DRAWN: the popup speaks them through one
    // Accessible.announce when the row has actually moved, because otherwise a hold lands in
    // complete silence. Their %1 is substituted in the QML - an announcement is one translatable
    // sentence with a name in it.
    holdAnnounce: "Holding %1",
    unholdAnnounce: "No longer holding %1",
    // ...and the failure, reported in the ROW that failed rather than in a message up to 300 px
    // from the pin that caused it. main.qml substitutes and assigns it.
    holdFailed: "Could not change the hold on %1.",

    // Right-click, and the popup's own gear. Opens a dialog, so: real ellipsis.
    configure: "Configure Kempt…",

    // The store-first first run: the KDE Store carries the plasmoid and not the CLI, so a store
    // install's first check runs against nothing. Two entries because the message renders two lines
    // - what is true, then what to type - and a person who cannot act on the second still gets the
    // first. INGREDIENTS: engineFaultMessage assembles them; the tooltip takes the first alone.
    // The commands are WHOLE: half a command line fails somewhere the reader has to debug.
    // The header above it already says the engine is not installed, so this does not repeat it.
    engineMissing: "Nothing can check for updates yet.",
    // One command per line, so neither wraps in the middle.
    engineMissingInstall:
        "To install it on Fedora, run:\n"
        + "sudo dnf copr enable erez-c137/kempt\n"
        + "sudo dnf install kempt-plasmoid\n"
        + "On other systems, see github.com/erez-c137/kempt.",
    // The CLIPBOARD form: one line, chained, one paste. Separate from engineMissingInstall because
    // that one is a sentence (commas, "then", a URL) and a sentence pasted into a shell fails.
    // The tests drift-guard the two: every command this copies must appear verbatim in the other.
    engineMissingCopy: "sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt-plasmoid",
    // The OTHER way an engine can be unavailable, and a different fact with a different remedy:
    // the program is THERE and will not start. Reinstalling it is not the answer, and a message
    // that says to sends somebody to fix what is not broken. Three things produce it - a file
    // without the execute bit, a noexec mount, a missing interpreter - and the widget cannot tell
    // which from an exit code, so it names none of them and hands over the one command that can.
    // The header above it already says the engine will not run, so this does not repeat it.
    engineUnrunnable: "The engine is installed but cannot start, so nothing can check for updates.",
    engineUnrunnableFix: "Check Installation can find the problem. If it cannot start, its error says why.",
    engineUnrunnableCopy: "kempt doctor",
    // The Copy button's label, which follows its payload rather than being fixed: the install
    // remedy is two commands and the repair one is a single command, and a button offering to copy
    // "Commands" that copies one is the kind of small wrongness that makes a person check.
    engineCopyCommands: "Copy Commands",
    engineCopyCommand: "Copy Command",

    // Check Installation: `kempt doctor`, run by the widget so a message that names it can offer a
    // button. Doctor reads files and needs no password. The result goes in its own message, and
    // the full report opens under it. doctorOutcomeOf picks the sentence.
    doctorAction: "Check Installation",
    doctorRunning: "Checking Kempt's installation…",
    doctorPassed: "Kempt checked its installation and found no problems.",
    doctorFoundOne: "Kempt found a problem with its installation: %1",
    doctorFoundMore: "Kempt found %1 problems with its installation. The first: %2",
    // The shell's own reason ("sh: line 1: ...") goes in the full report, never in this sentence.
    doctorCouldNotRun: "Kempt could not check its installation. The full report has the error.",
    doctorCouldNotRunCode: "Kempt could not check its installation (exit %1).",
    doctorTimedOut: "Kempt stopped waiting for the installation check. Try again in a minute.",
    doctorShowReport: "Show Full Report",

    // A Fedora release upgrade somebody has staged outside Kempt. dnf5 keeps ONE stored
    // transaction for that and for an ordinary offline update alike, so staging updates for a
    // restart would cancel it - and re-downloading a release upgrade is gigabytes. The CLI refuses
    // to; this is the popup saying so before the press rather than after it.
    // Two entries, joined: what is true and the commands that install or remove it, then what it
    // means for this widget. Text only: a Copy button cannot offer two commands with one payload.
    releaseUpgradeStaged: "A Fedora %1 upgrade is staged and installs on the next restart. To remove it, run sudo dnf5 offline clean.",
    // ...and the state a release upgrade actually spends most of its life in: downloaded, and not
    // started. Nothing installs on any restart until somebody arms it, so saying it does would send
    // a person to restart a machine that comes back exactly as it was.
    releaseUpgradeReady: "A Fedora %1 upgrade has been downloaded but not started, so no restart installs it yet. To install it, restart with sudo dnf5 system-upgrade reboot. To remove it, run sudo dnf5 offline clean.",
    // The third state, which reads as neither of the others: it WAS armed, and a restart has
    // already been past it without running it. Nothing further will until somebody arms it again,
    // so "installs on the next restart" and "not started yet" are both false here.
    releaseUpgradeStranded: "A Fedora %1 upgrade was set to install, but a restart went by without installing it. To install it, restart with sudo dnf5 system-upgrade reboot. To remove it, run sudo dnf5 offline clean.",
    // The fourth: dnf5 says the transaction did not finish - download-incomplete, or one that
    // started during a restart and stopped part way. "Downloaded" would say the opposite of the
    // word dnf5 recorded, and pointing at `system-upgrade reboot` would be advice dnf5 declines.
    releaseUpgradeIncomplete: "A Fedora %1 upgrade is stored but did not finish, so no restart installs it. Run sudo dnf5 offline log to see what happened. To remove it, run sudo dnf5 offline clean.",
    // The fifth: dnf5 says ready, but /system-update points at another updater's prepared update,
    // so the next restart runs that instead. The upgrade's own commands work only after it.
    releaseUpgradeForeign: "A Fedora %1 upgrade is stored, but another updater has prepared the next restart, so it will not install then. After that restart, sudo dnf5 system-upgrade reboot installs the upgrade and sudo dnf5 offline clean removes it.",
    releaseUpgradeNoStage: "Kempt will not stage updates for a restart while it is there, because that would cancel it.",
    // ...and only where it is true. A box configured to run updates on the next reboot has no
    // "update now" to fall back on: staging IS what its button does, and that is the thing being
    // refused. Saying otherwise would send a person to press it and watch the run decline.
    releaseUpgradeLiveStillWorks: "Updating now still works.",
    releaseUpgradeNoRoute: "This computer is set to install updates on the next restart, so there is nothing to press until the upgrade is installed or removed.",

    // An image-based Fedora: Silverblue, Kinoite, Bazzite, a bootc image. rpm-ostree owns /usr and
    // dnf is not how the machine updates - but those images ship dnf5 and plasma-workspace, so
    // Kempt installs cleanly, the widget appears and every list here fills in. Nothing about the
    // box gives it away, which is why this has to be said outright.
    // Two entries, joined, on the pattern the engine messages use: what is true, then what to do.
    imageBased: "This system updates with rpm-ostree, so Kempt cannot install updates on it. Support for these images is planned.",
    // Names bootc as well, because bootc images set the same marker and `rpm-ostree upgrade` is not
    // their command. And it points at Discover for the Flatpak rows, which are the one thing on
    // this list somebody CAN act on - saying nothing about them next to a list of them would be
    // its own small lie.
    imageBasedUse: "Use Discover, or run rpm-ostree upgrade in a terminal (bootc upgrade on a bootc image). Discover also updates the Flatpak apps listed below.",

    // --- unused Flatpak runtimes (`kempt reclaim`) ---------------------------------------------
    // The offer, assembled by reclaimMessageOf. The size is formatDownload's "~" figure: the CLI's
    // own estimate, never a promise. The second sentence is why removing them is safe.
    reclaimSized: "%1 can be freed. No installed app uses these Flatpak runtimes.",
    reclaimUnsized: "Space can be freed. No installed app uses these Flatpak runtimes.",
    // Added with reclaim=automatic, where the next successful update removes them anyway.
    reclaimAutomatic: "Kempt removes them after the next update.",
    // After a ref in the Show What list whose branch Flatpak marks end of life.
    reclaimEol: "(no longer supported)",
    reclaimShowWhat: "Show What",
    // After Free Up Space. The size one is filled from reclaim.last, in the offer's own spelling.
    reclaimFreed: "Freed %1.",
    reclaimNothing: "Nothing to remove. Every installed Flatpak runtime is in use.",
    reclaimChanged: "What Flatpak can remove changed since this was shown. Nothing was removed.",
    reclaimNeedsAuth: "Removing these needs an administrator. Nothing was removed.",
    // Added after a removal when reclaim.last.in_use names extensions Flatpak removed although an
    // app had just started using them (the CLI's sentence, bin/kempt reclaim_outcome_lines). Also
    // after a run whose automatic removal did the same (its entry's reclaimed.in_use).
    reclaimInUseOne: "Flatpak also removed an extension that an app installed during the removal uses. Run flatpak update to put it back.",
    reclaimInUseMore: "Flatpak also removed %1 extensions that apps installed during the removal use. Run flatpak update to put them back.",
    // Flatpak stopped part-way. The first is filled with the size of what did go.
    reclaimPartial: "Freed %1. Flatpak could not remove all of them.",
    reclaimPartialUnsized: "Flatpak removed some of them, but not all.",
    // The list between the two passes failed, so the extensions were never tried and nothing was
    // refused (reclaim.last.skipped). Said after what went. The leftover refs keep their since, so
    // the next offer needs no new hour, and the popup shows an offer from RECLAIM_MIN_BYTES.
    reclaimSkipped: "Some extensions were left in place because Flatpak did not answer when asked what is unused. This widget offers them again if they take 100 MB or more.",
    // Flatpak failed and Kempt could not read what is left afterwards.
    reclaimUnknown: "Flatpak stopped with an error, so the removal may be partial. Press Check for Updates to see what is left.",
    reclaimNothingRemoved: "Could not free the space. Nothing was removed.",
    reclaimBusy: "An update is already running. Nothing was removed.",
    reclaimFailed: "Could not free the space (exit %1).",
    reclaimTimedOut: "Kempt stopped waiting. The removal may still finish. Press Check for Updates in a few minutes.",
    // The Last update row and the line after a run, when automatic reclaim removed something.
    reclaimFreedTail: "%1 freed",
    reclaimRemovedOne: "1 unused runtime removed",
    reclaimRemovedMore: "%1 unused runtimes removed"
};

// MIDDLE DOT with a space each side. One constant, because the footer status line and the Last
// update row both use it and two would drift the first time one was edited.
var DOT = " \u00b7 ";

// How big the pending download is, in words.
// "~", never "up to": the figure has error in BOTH directions, so any wording implying a ceiling
// is false - dnf pulls in dependencies `--upgrades` never listed, flatpak transfers ostree deltas
// far smaller than the published size, and a transaction already staged offline is downloaded in
// full while the number still counts it, so the view model shows no figure while a stage is armed.
// Under a megabyte it says "< 1 MB": nobody decides differently between 300 kB and 800 kB, and a
// number that small next to an update button invites the reader to think it is precise.
// "" for absent, zero, negative or not-a-number, and empty means render NOTHING: no "unknown",
// no "0 MB", no dash.
function formatDownload(bytes) {
    if (typeof bytes !== "number" || !isFinite(bytes) || bytes <= 0) return "";
    if (bytes < 1000000) return "< 1 MB";
    var mb = Math.round(bytes / 100000) / 10;
    // 999999999 bytes rounds to 1000.0 MB, which is a gigabyte spelled the long way.
    if (mb < 1000) return "~" + trimZero(mb) + " MB";
    return "~" + trimZero(Math.round(bytes / 100000000) / 10) + " GB";
}

// One decimal, minus a pointless one. Not toFixed(1) plus a string trim: toFixed rounds a second
// time on an already-rounded value, and the two can disagree at the boundary.
function trimZero(n) {
    return String(Math.round(n * 10) / 10);
}

// How many session-critical families the offline recommendation names before ", …". Same number
// the CLI's notification uses (bin/kempt), which ends its list in three ASCII dots instead.
var RISKY_FAMILIES_SHOWN = 4;

// Highest number the panel badge spells out; above this it reads "999+". COMPACT ONLY - the popup
// header is never capped, and a person opening it is asking for the real number.
// 999 and not 99: a Fedora box left alone for a few weeks routinely has two or three hundred
// pending, so a cap of 99 would be vague in the ordinary case rather than the extreme one.
var BADGE_MAX = 999;

// shellQuote(s) -> the string as ONE shell word, safe to paste into a command line.
//
// The widget's only injection surface, and a real one: package names come out of the CLI's JSON
// and the popup builds `kempt hold <backend>:<name>` from them, so a name containing `;` or a
// backtick would be a second command running as the user from inside the panel process. POSIX
// single quotes disable every expansion the shell has; the only character that cannot appear
// inside them is the single quote, which is closed, escaped and reopened ('\'').
// Anything state-derived that reaches a command line goes through here. No exceptions - not
// "obviously safe" package names, not log paths.
function shellQuote(s) {
    if (s === undefined || s === null) return "''";
    return "'" + String(s).split("'").join("'\\''") + "'";
}

// fill(template, token, value) -> EVERY occurrence replaced. String.replace with a string needle
// replaces one, and stagedConflictOne names its package three times. split/join rather than a
// regex, because the value is a package name from another program and a regex would interpret it.
function fill(template, token, value) {
    return String(template).split(token).join(value);
}

// Is this really an array? `typeof v.length === "number"` is not enough: a STRING has a length,
// and iterating one yields characters that would render as packages.
function isArray(v) { return Object.prototype.toString.call(v) === "[object Array]"; }
function arrayOf(v) { return isArray(v) ? v : []; }

// The run surfaces the CLI knows, in the order the settings page offers them.
var SURFACES = ["terminal", "popup", "background", "offline"];
// What a config with no `surface` key runs on: lib/common.sh's kempt_default, which this twins.
// A value the CLI does not recognise is a different case and still means terminal (resolveSurface).
var DEFAULT_SURFACE = "popup";

// isTrue(s) -> the same answer lib/common.sh's is_true() gives. The settings page reads booleans
// back as the TEXT `kempt config get` printed, and the two must not disagree about what "yes"
// means: a checkbox that renders a config value as its opposite is how a user turns something off
// and finds it back on.
function isTrue(value) {
    if (typeof value === "boolean") return value;
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return s === "true" || s === "1" || s === "yes";
}

// resolveSurface(s) -> a surface the CLI recognises, mirroring bin/kempt's resolve_surface():
// anything unknown is `terminal`, because that is what the CLI itself would run.
function resolveSurface(value) {
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return SURFACES.indexOf(s) >= 0 ? s : "terminal";
}

// updatingLabelOf(surface) -> what the pane says while a run on that surface is in flight. Takes
// the surface the RUNNING transaction is using, which is not always the configured one: with
// confirmation on `kempt run` collapses every surface to terminal, and Install on Next Restart
// stages offline whatever the setting says.
function updatingLabelOf(surface) {
    switch (resolveSurface(surface)) {
    case "popup":      return COPY.updatingHere;
    case "background": return COPY.updatingBackground;
    case "offline":    return COPY.updatingOffline;
    default:           return COPY.updatingTerminal;
    }
}

// effectiveSurfaceOf(surface, autoAccept) -> the surface a run will ACTUALLY use. bin/kempt's
// cmd_run resolves the configured surface and then overrides it: with auto_accept false only a
// terminal can ask the confirmation question. The popup has to apply the same rule or it offers an
// in-widget log pane while a terminal window is what opens.
function effectiveSurfaceOf(surface, autoAccept) {
    return isTrue(autoAccept) ? resolveSurface(surface) : "terminal";
}

// updateButtonOf(surface, dnfActionable, flatpakPending) -> the footer button: whether the press
// stages, its label, and its tooltip. Takes the CONFIGURED surface: with confirmation on, the run
// opens a terminal, and `kempt update` on a terminal still stages when offline is configured.
// Only system updates stage, so with none actionable (only Flatpak pending, or every dnf update
// held) the press stages nothing and the button says Update Now. The tooltip names Flatpak only
// when Flatpak apps are waiting.
function updateButtonOf(surface, dnfActionable, flatpakPending) {
    if (resolveSurface(surface) !== "offline" || typeof dnfActionable !== "number" || !(dnfActionable > 0))
        return { stages: false, text: COPY.updateNow, tooltip: "" };
    return { stages: true, text: COPY.installOnNextRestart,
             tooltip: stageTooltipOf(flatpakPending) };
}

// stageTooltipOf(flatpakPending) -> the tooltip of a press that installs at the next restart. Only
// promises that Flatpak apps update now when some are waiting.
function stageTooltipOf(flatpakPending) {
    return flatpakPending === true ? COPY.installOnNextRestartTooltip
                                   : COPY.installOnNextRestartSystemTooltip;
}

// backendActionable(state, key) -> the actionable count of one backend: 0 when it is disabled or
// absent, its own count when it publishes one, else its items that are not held.
function backendActionable(state, key) {
    var b = (state && state.backends && typeof state.backends === "object") ? state.backends[key] : null;
    if (!b || typeof b !== "object" || b.enabled === false) return 0;
    if (typeof b.actionable === "number") return b.actionable;
    var items = (b.items && typeof b.items.length === "number") ? b.items : [], n = 0;
    for (var i = 0; i < items.length; i++) if (items[i] && !items[i].held) n++;
    return n;
}

// --- how big the panel icon is asked to be -----------------------------------------------------
// snapIconSize answers "how big when nobody said" (the `auto` setting); resolveIconSize answers
// "how big, given what the user asked for".
//
// The hinted sizes an icon theme actually draws, smallest first. Breeze ships 16px and 22px
// symbolics as SEPARATE artwork, each aligned to the pixel grid AT THAT SIZE, so asking for 15 or
// 24 scales one by a fraction and every hinted stroke lands between pixels. Every size below is
// one of these steps, never an arithmetic result; the QML passes Kirigami's own values in this
// order.
var ICON_STEPS = [16, 22, 32, 48, 64];

// The cell thickness at which each step takes over, paired by index with the steps above.
// NOT "the largest icon that fits": a 44px panel fits 32px, but the system tray beside it draws
// 22, and an icon that fills its cell when nothing around it does reads as a mistake. So the rungs
// are pinned to what the tray does at ordinary panel thicknesses - a 22px panel up to a 47px one
// asks for 22. 48 is where a panel stops being an ordinary panel.
var ICON_CELL_MIN = [16, 22, 48, 96, 192];

// snapIconSize(cell, steps) -> the hinted size an `auto` icon asks for in a cell this thick.
// Below the first rung there is no hinted size to snap to, so it falls back to a whole number of
// pixels: scaling is the only option left, but it can at least be scaled to an integer.
function snapIconSize(cell, steps) {
    var c = Number(cell), list = usableSteps(steps), chosen = 0, i;
    if (!isFinite(c) || c <= 0) return 0;
    for (i = 0; i < list.length && i < ICON_CELL_MIN.length; i++) {
        if (c >= ICON_CELL_MIN[i]) chosen = list[i];
    }
    // Never wider than the cell holding it, whatever a caller's step list says.
    return chosen > 0 ? Math.min(chosen, Math.floor(c)) : Math.floor(c);
}

// The step list a caller supplied, cleaned - or the built-in one when they supplied nothing
// usable. An empty list is a caller that could not read its theme, and the right answer to that is
// still a hinted size. It is also what lets node call snapIconSize(44) with no second argument.
function usableSteps(steps) {
    var out = [], i, s;
    if (!steps || !steps.length) return ICON_STEPS.slice();
    for (i = 0; i < steps.length; i++) {
        s = Number(steps[i]);
        if (isFinite(s) && s > 0) out.push(s);
    }
    return out.length ? out : ICON_STEPS.slice();
}

// The `widget_icon_size` values the settings page offers, and the step each names. INDEXES into
// the step list rather than pixel counts, so a theme whose "small" is not 16 still gets its own
// hinted artwork rather than a number this file invented.
var ICON_SIZE_SETTINGS = { auto: -1, small: 0, medium: 1, large: 2 };

// ...and the ones that must never come out SMALLER than `auto` would have drawn. Only the largest
// option, and the asymmetry is the point: see resolveIconSize.
var ICON_SIZE_FLOOR_AT_AUTO = { large: true };

// resolveIconSizeSetting(value) -> a setting the widget recognises; anything unknown is `auto`.
// This is the ONLY validation `widget_icon_size` gets - the CLI stores whatever it is handed
// (config_set checks the key's shape, not the value's meaning), so a typo, an older CLI's empty
// line and a future version's value all land here and all mean: decide automatically, say nothing.
function resolveIconSizeSetting(value) {
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return Object.prototype.hasOwnProperty.call(ICON_SIZE_SETTINGS, s) ? s : "auto";
}

// resolveReclaimSetting(value) -> ask | automatic | off, read as the CLI's reclaim_mode reads it:
// case-folded, and anything that is not exactly automatic or off is ask.
function resolveReclaimSetting(value) {
    var s = String(value === undefined || value === null ? "" : value).toLowerCase();
    return (s === "automatic" || s === "off") ? s : "ask";
}

// resolveIconSize(setting, cell, steps) -> the pixel size the icon is actually asked for.
// A chosen size the cell cannot hold falls back to `auto` rather than overflowing: inside the tray
// the cell is the tray's to decide, and 32px in a 22px slot pushes every other entry around.
function resolveIconSize(setting, cell, steps) {
    var list = usableSteps(steps), c = Number(cell);
    var auto = snapIconSize(c, list);
    if (!isFinite(c) || c <= 0) return auto;          // no cell yet: nothing to draw into
    var key = resolveIconSizeSetting(setting);
    var idx = ICON_SIZE_SETTINGS[key];
    if (idx < 0) return auto;
    var want = Number(list[idx]);
    if (!isFinite(want) || want <= 0) return auto;    // a step list too short to name it
    // "Large" is a promise about size, and on a big cell the named step breaks it: auto reaches 48
    // at a 96px cell and 64 at 192, while `large` names the third step (32) - so on a vertical dock
    // or a HiDPI panel, Large would draw SMALLER than Automatic. Floored rather than relabelling
    // the options as pixel counts, which would make every label a number the user must translate.
    // Small and Medium are deliberately NOT floored: going below Automatic is why they exist.
    if (ICON_SIZE_FLOOR_AT_AUTO[key]) want = Math.max(want, auto);
    return want > c ? auto : want;
}

// --- the watcher stamp -----------------------------------------------------------------------
// main.qml polls four mtimes every 30 seconds. WHICH of them moved is the part that matters,
// because /var/lib/rpm is rewritten continuously all the way through a dnf transaction: comparing
// the stamp as one string says only "something changed", which during a run of ours is true every
// 30 seconds - so the widget declares the run finished a few seconds in, prints a summary of the
// PREVIOUS run, and starts a `kempt check` that wants the lock the transaction is holding. Only
// OUR state file says a run ended, and these field names are that distinction (here, not in QML,
// so node can pin them).
// The five paths main.qml stats, in its order: rpmdb.sqlite, the rpm directory, flatpak,
// state.json, config. The first two are one question - "did the package database move" - asked of
// the file Fedora actually writes and of the directory an older rpm layout wrote. Anything that is
// not the state file or the config file counts as packages, so both land there without a rule of
// their own.
var WATCH_FIELDS = 5;
var WATCH_STATE_FIELD = 3;
var WATCH_CONFIG_FIELD = 4;

// watchChange(prev, next) -> { any, packages, state, config, comparable }
// `comparable` is false when either stamp is not the four fields main.qml asks for (an older
// widget's stamp left across a reload, say). Then the answer degrades to a whole-string comparison
// with every category true, rather than guessing which column is which: wrong-but-noisy beats
// wrong-and-silent when what is at stake is noticing a finished run.
function watchChange(prev, next) {
    var a = watchFieldsOf(prev), b = watchFieldsOf(next), i;
    var out = { any: false, packages: false, state: false, config: false, comparable: false };
    if (a.length !== WATCH_FIELDS || b.length !== WATCH_FIELDS) {
        out.any = a.length > 0 && b.length > 0 && a.join(" ") !== b.join(" ");
        out.packages = out.any;
        out.state = out.any;
        out.config = out.any;
        return out;
    }
    out.comparable = true;
    for (i = 0; i < WATCH_FIELDS; i++) {
        if (a[i] === b[i]) continue;
        out.any = true;
        if (i === WATCH_STATE_FIELD) out.state = true;
        else if (i === WATCH_CONFIG_FIELD) out.config = true;
        else out.packages = true;
    }
    return out;
}

function watchFieldsOf(stamp) {
    var raw = String(stamp === undefined || stamp === null ? "" : stamp).trim(), out = [], i;
    if (raw === "") return out;
    raw = raw.split(/\s+/);
    for (i = 0; i < raw.length; i++) if (raw[i] !== "") out.push(raw[i]);
    return out;
}

// --- the quiet window after a check ------------------------------------------------------------
// A run leaves a wake - rpm rewritten throughout, state.json rewritten by the CLI's own post-run
// check, /var/lib/flatpak moved - so the 30-second watcher goes on finding changes for a minute
// after that check has accounted for all of them, and each one is a line in `kempt log`.
//
// So a WATCHER-triggered check is dropped while the last completed check is still recent. Only the
// watcher's: a Refresh press, the scheduled check, the popup opening and a settings write are all
// somebody ASKING. The end of a run is not checked from the widget at all: the CLI checks on its
// way out, and the widget waits for that (main.qml, pollWatch's `endedRun`). The cost is bounded - a change from elsewhere inside
// the window is absorbed and the next scheduled check finds it, so the badge can only
// over-report, never under-report.
var CHECK_QUIET_MS = 60000;

// watcherCheckDue(lastCheckFinished, now) -> whether a watcher-triggered check should run.
// `lastCheckFinished` is 0 until a check has completed, and that answers yes: with no check behind
// us there is no footprint of ours for this change to be.
function watcherCheckDue(lastCheckFinished, now) {
    var last = Number(lastCheckFinished), t = Number(now);
    if (!isFinite(last) || last <= 0) return true;
    if (!isFinite(t)) return true;
    var since = t - last;
    // A clock that moved backwards (NTP, a suspend) must never suppress a check: an optimisation
    // that can silence the widget indefinitely on a bad clock is not one.
    if (since < 0) return true;
    return since >= CHECK_QUIET_MS;
}

// checkedSince(state, sinceMs) -> whether `state` was written by a check that ran after `sinceMs`.
// A run ends with the CLI's own check (the end of cmd_update), and that check is what the widget
// used to run a second time. last_check has whole seconds, so `sinceMs` is floored to its second:
// a check stamped in the same second as the press counts. A state with no readable last_check
// answers no, which means the caller checks - the safe side.
function checkedSince(state, sinceMs) {
    if (!state || typeof state !== "object") return false;
    var at = stampMs(state.last_check), since = Number(sinceMs);
    if (!isFinite(at) || !isFinite(since) || since <= 0) return false;
    return at >= Math.floor(since / 1000) * 1000;
}

// checkedAfterRun(state, run, sinceMs) -> checkedSince, anchored to the run's END rather than its
// press. `run` is the newest history entry. The CLI writes it before its closing check, so a check
// stamped at or after it is that check - and one stamped between the press and the entry is not:
// a check somebody asked for mid-run. That check's last_check survives into the state the run
// publishes on its way out (publish_staged_state touches only the staged key), so the press alone
// would take it for the closing check and stand the fallback down before the real one had landed.
// With no entry of this run's (a run that ended before writing one, or a summary that did not
// answer) the press is the only anchor there is.
function checkedAfterRun(state, run, sinceMs) {
    var at = run ? stampMs(run.when) : NaN;
    var anchor = isFinite(at) && runFinishedSince(run, sinceMs) ? at : sinceMs;
    return checkedSince(state, anchor);
}

// holdsOf(text) -> [{ id, backend, name }] from `kempt holds` output (raw `backend:name` lines).
// Split at the FIRST colon, exactly like cmd_hold's ${1%%:*} / ${1#*:}, so a name containing a
// colon still round-trips to the same hold the CLI would remove.
// discoverSettingOf(stdout) -> what Settings shows for Discover's notifier, from
// `kempt discover-notifier status --json`: {state, verb}. state is "on", "off" (by Kempt) or "own"
// (off by the person's own entry), and picks the sentence: discoverStatusOn, Off or Own. verb is
// the command the button runs, "off" or "on", or "" for no button. null when there is nothing to
// show: not installed, or no answer. Turn On is offered only for Kempt's own entry, the one `on`
// can remove.
function discoverSettingOf(stdout) {
    var st;
    try { st = JSON.parse(String(stdout === undefined || stdout === null ? "" : stdout)); }
    catch (e) { return null; }
    if (!st || typeof st !== "object" || st.installed !== true) return null;
    if (st.enabled === true) return { state: "on", verb: "off" };
    if (st.by_kempt === true) return { state: "off", verb: "on" };
    return { state: "own", verb: "", path: typeof st.entry === "string" ? st.entry : "" };
}

function holdsOf(text) {
    var out = [], lines, i, line, cut;
    if (typeof text !== "string") return out;
    lines = text.split("\n");
    for (i = 0; i < lines.length; i++) {
        line = lines[i].trim();
        if (line === "") continue;
        cut = line.indexOf(":");
        if (cut <= 0 || cut === line.length - 1) continue;   // not a backend:name pair
        out.push({ id: line, backend: line.substring(0, cut), name: line.substring(cut + 1) });
    }
    return out;
}

// logTailOf(text) -> the run's log tail as the widget shows it. dnf pads a line out to a counter
// at the right edge ("Upgrading bash-5.3-1.fc44.x86_64          31/62"). The widget wraps long
// lines, so the padding would push the counter onto a line of its own. It becomes one space.
function logTailOf(text) {
    if (typeof text !== "string") return "";
    return text.replace(/[ \t]{2,}(\d+\/\d+)[ \t]*$/gm, " $1");
}

// lastLinesOf(text, max) -> the last `max` non-blank lines, trimmed, joined with " ". The result
// line under the passwordless buttons. The LAST lines: pkexec and polkit print their progress
// before their verdict, and the verdict is the part worth showing.
function lastLinesOf(text, max) {
    var kept = [], lines, i, line;
    if (typeof text !== "string") return "";
    if (!max || max < 1) max = 2;
    lines = text.split("\n");
    for (i = 0; i < lines.length; i++) {
        line = lines[i].trim();
        if (line !== "") kept.push(line);
    }
    return kept.slice(Math.max(0, kept.length - max)).join(" ");
}

// firstLineOf(text) -> the first non-blank line, trimmed, or "". Trimming here rather than in QML
// is what lets a node test pin it.
function firstLineOf(text) {
    if (typeof text !== "string") return "";
    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line !== "") return line;
    }
    return "";
}

// parseState(text) -> the state object, or null.
// null means "we learned nothing from this call". Every caller must treat it as "keep what you
// had", which is why nothing here ever invents an empty-but-valid state.
function parseState(text) {
    if (typeof text !== "string") return null;
    if (text.trim() === "") return null;
    var parsed;
    try {
        parsed = JSON.parse(text);
    } catch (e) {
        return null;
    }
    // A number, a string, null or an array are all valid JSON and none of them is a state.
    if (parsed === null || typeof parsed !== "object") return null;
    if (Object.prototype.toString.call(parsed) === "[object Array]") return null;
    return parsed;
}

// Is this object schema-v1 shaped? A parsed object carrying neither a count nor backends is
// something else (a future schema, a foreign file), and the widget says so rather than rendering
// it as "no updates".
function looksLikeState(state) {
    if (!state || typeof state !== "object") return false;
    // A declared schema we do not know is NOT rendered optimistically. Version skew is the normal
    // state of this pair, not an edge case: the CLI is installed as a symlink into the checkout
    // while the widget is a COPY, so after a `git pull` the CLI is new and the widget is whatever
    // was last installed - and a schema 2 field could mean anything.
    if (typeof state.schema === "number" && state.schema !== 1) return false;
    if (typeof state.actionable === "number") return true;
    if (state.backends && typeof state.backends === "object") return true;
    return false;
}

// What a `from` looks like when there is no current version: the package is not installed and the
// update would ADD it. The CLI's own sentinel, named because the popup recognises it twice - to
// say "Skip installing X" instead of "Hold X at ?", and to draw it as a word.
var VERSION_UNKNOWN = "?";

// What ANY row draws for a `from` the CLI could not know. The pending list and the Last update
// history rows both go through this, so a package that was not installed reads "new" in both
// places rather than "?" in one of them.
function fromTextOf(from) {
    return from === VERSION_UNKNOWN ? COPY.versionNew : from;
}

// What a row draws BETWEEN two versions, which is not always an arrow. A Flatpak runtime can get a
// genuine update whose version string does not move: most runtimes carry a date, or nothing at all,
// in their version metadata, and the commit is what actually differs. Measured on a real box: 3 of 7
// installed runtimes had NO version string, so an update to them arrived as "? -> ?", and a theme
// runtime's update arrived as "2024-05-30 -> 2024-05-30". An arrow between two identical values, or
// between two unknowns, tells the reader the update is fictional.
//
// Returns "" when there is nothing honest to draw at all, and the caller hides the line rather than
// printing punctuation around two blanks. Both QML sites and the CLI's own summary follow this rule,
// so one update reads the same everywhere.
function versionTextOf(from, to) {
    if (from === VERSION_UNKNOWN && to === VERSION_UNKNOWN) return "";
    if (from === to) return String(to) + " (" + COPY.newBuild + ")";
    return fromTextOf(from) + " \u2192 " + to;
}

// A runtime's identity is its id AND its branch, and the two are folded into one `id/branch` key so
// that sort, join and the snapshot diff have a single field to work on. That key is a JOIN KEY, not
// a name: the pending rows already split it back apart and draw "org.kde.Platform 5.15-24.08", while
// the history rows drew the raw fold, so one transaction was spelled two ways by one product.
//
// The LAST slash is always the one Kempt added - a flatpak app id cannot contain one, which is
// exactly why that character was chosen as the separator - and a dnf package name has no slash at
// all, so this is a no-op for everything else.
function displayNameOf(name) {
    var s = String(name === null || name === undefined ? "" : name);
    var i = s.lastIndexOf("/");
    return i > 0 ? s.slice(0, i) + " " + s.slice(i + 1) : s;
}

// newestOf("a,b,c") -> "c". The CLI collapses multilib and installonly duplicates into ONE row
// with the versions comma-joined, and its own renderer shows the last of the set (lib/common.sh:
// `def newest(v): v | split(",") | last`). The widget copies that rule exactly: a popup that
// renders a version differently from `kempt summary` is the front-end disagreeing with the CLI.
function newestOf(versionSet) {
    if (versionSet === null || versionSet === undefined) return VERSION_UNKNOWN;
    var s = String(versionSet);
    if (s === "") return VERSION_UNKNOWN;
    var parts = s.split(",");
    return parts[parts.length - 1];
}

// familiesOf(names, max) -> { shown: [families, capped at max], total: <unique family count> }.
// A family is the name up to its first "-" or "." - kernel-core and kernel-modules are one
// decision - unique and sorted, exactly like the CLI's `sed 's/[-.].*//' | sort -u`.
// max <= 0 (or omitted) means no cap.
function familiesOf(names, max) {
    var seen = {}, families = [], i, family;
    if (!names || typeof names.length !== "number") return { shown: [], total: 0 };
    for (i = 0; i < names.length; i++) {
        family = String(names[i]).replace(/[-.][\s\S]*$/, "");
        if (family === "") continue;
        // "#" prefix: a family called "constructor" or "toString" would otherwise collide with
        // Object.prototype and silently vanish from the list.
        if (seen["#" + family]) continue;
        seen["#" + family] = true;
        families.push(family);
    }
    families.sort();
    return {
        shown: (max && max > 0 && families.length > max) ? families.slice(0, max) : families.slice(0),
        total: families.length
    };
}

// The families Kempt ships a plain-language name for. "mesa" is a package name, not a word, and
// this popup asks somebody whether it is safe to update their graphics driver while the desktop is
// running - a question nobody can answer in vocabulary they do not have.
//
// Mirrors family_label in lib/common.sh on purpose: the terminal listing, this popup and the
// notification all describe one transaction, and three vocabularies for it would be the product
// disagreeing with itself. Keys are FAMILIES as familiesOf derives them (the name up to its first
// - or .), so plasma-workspace keys as "plasma" and kwin-x11 as "kwin". The "#" prefix is there for
// the reason familiesOf uses one: a family called "constructor" must not find Object.prototype's.
//
// ONLY the families in the DEFAULT risky_regex appear here. risky_regex is the user's to extend, so
// an unknown family keeps its bare name rather than wearing a description nobody wrote for it.
var FAMILY_LABELS = {
    "#kernel":  "the Linux kernel",
    "#systemd": "the service manager",
    "#glibc":   "the core system library",
    "#dbus":    "the system message bus",
    "#mesa":    "graphics drivers",
    "#qt6":     "the desktop toolkit",
    "#kf6":     "KDE framework libraries",
    "#plasma":  "the Plasma desktop",
    "#kwin":    "the window manager"
};

function labelFor(family) {
    var v = FAMILY_LABELS["#" + family];
    return typeof v === "string" ? v : "";
}

// The families in a risky set, capped, as both sentences below name them. One function, because a
// count sentence and a recommendation listing the same set differently would be the popup
// disagreeing with itself about one transaction.
//
// LABELS, not package names: the popup already lists every pending package by name in its rows, so
// the sentence's job is to say what those packages ARE. The terminal listing keeps the name beside
// the label, because there the name is the row's identity and there is room for both.
function riskyFamiliesOf(names) {
    var fams = familiesOf(names, RISKY_FAMILIES_SHOWN), out = [], i, lbl;
    for (i = 0; i < fams.shown.length; i++) {
        lbl = labelFor(fams.shown[i]);
        out.push(lbl !== "" ? lbl : fams.shown[i]);
    }
    return out.join(", ") + (fams.total > fams.shown.length ? ", …" : "");
}

// "20 pending updates touch packages your running session depends on (dbus, glibc, kernel, kf6,
// ...).", from the same family names as the CLI's notification. Drawn only where the
// recommendation below cannot be: there is no route to the next restart.
function riskySummaryOf(names) {
    if (!names || !names.length) return "";
    return names.length === 1
        ? fill(COPY.riskySummaryOne, "%1", riskyFamiliesOf(names))
        : fill(fill(COPY.riskySummaryMore, "%1", String(names.length)), "%2", riskyFamiliesOf(names));
}

// pendingNamesOf(sections, riskyNames) -> "kernel-core, bash, curl and 7 more", for the panel
// tooltip. The session-critical rows come first, then the list's own order. Only names that are
// rows in the list, so the tooltip never names a package the popup does not show.
var PENDING_NAMES_SHOWN = 3;
function pendingNamesOf(sections, riskyNames) {
    var risky = [], rest = [], i, j, items, name;
    var riskySet = {};
    for (i = 0; riskyNames && i < riskyNames.length; i++) riskySet[String(riskyNames[i])] = true;
    for (i = 0; sections && i < sections.length; i++) {
        items = sections[i].items || [];
        for (j = 0; j < items.length; j++) {
            name = items[j].name;
            if (!name) continue;
            (Object.prototype.hasOwnProperty.call(riskySet, name) ? risky : rest).push(name);
        }
    }
    var all = risky.concat(rest), shown = all.slice(0, PENDING_NAMES_SHOWN);
    if (shown.length === 0) return "";
    if (all.length > shown.length) return shown.join(", ") + " and " + (all.length - shown.length) + " more";
    if (shown.length === 1) return shown[0];
    return shown.slice(0, -1).join(", ") + " and " + shown[shown.length - 1];
}

// riskyMessageOf(names) -> what to DO about a session-critical transaction, in one sentence.
// A kernel changes the answer: staging it offline does not help, because the kernel you are
// running keeps running until you restart either way. The two ingredient tests are deliberately
// different shapes:
//   * KERNEL is a FAMILY test - kernel-core, kernel-modules and kernel.x86_64 are one decision,
//     and it keeps kernelcare, which merely starts the same, out of it.
//   * NVIDIA is a SUBSTRING test, case-insensitive, because the driver arrives under families with
//     nothing in common: akmod-nvidia, xorg-x11-drv-nvidia, nvidia-settings.
// NVIDIA without a kernel says nothing special: the extra sentence is about a module built against
// a kernel that is about to stop being the running one.
function riskyMessageOf(names) {
    if (!isArray(names) || names.length === 0) return "";
    // The 0 is a cap of NONE and has to stay one. This is a LOOKUP, not a list being shown:
    // RISKY_FAMILIES_SHOWN caps what riskySummaryOf PRINTS, and passing it here - the
    // obvious-looking tidy-up - would make the kernel warning depend on where "kernel" falls in an
    // alphabetical sort. Four families ahead of it (akmod, alsa, atk, bash) and the most important
    // sentence this popup has silently stops being said.
    if (familiesOf(names, 0).shown.indexOf("kernel") < 0) {
        // No kernel: the offline install really is safer and nothing has to be said about the
        // running kernel. Whole literals, because count, noun and pronoun move together.
        var fams = riskyFamiliesOf(names);
        return names.length === 1
            ? fill(COPY.riskySessionOne, "%1", fams)
            : fill(fill(COPY.riskySessionMore, "%1", String(names.length)), "%2", fams);
    }
    for (var i = 0; i < names.length; i++) {
        if (String(names[i]).toLowerCase().indexOf("nvidia") >= 0) return COPY.kernelNvidiaRestart;
    }
    return COPY.kernelRestart;
}

// stagedMessageOf(offline_staged) -> what the next restart will install, in one sentence.
//
// The CLI publishes this key only after reconciling its own marker against dnf5's transaction
// status, and only for a transaction genuinely ARMED (lib/common.sh, offline_staged_state), so the
// judgement is not re-derived here: the key's presence IS the answer. The count is optional and no
// reader may invent it - a marker written before the count existed carries null, and the sentence
// loses the number rather than gaining a wrong one. The type check matters because this is JSON
// from another program: a string here would reach `.count` as undefined and render the popup's
// most reassuring sentence about a transaction that does not exist.
function stagedMessageOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return COPY.stagedUnknownCount;
    // Exactly one takes the singular - zero is plural in English ("0 updates"), so `=== 1`.
    return n === 1 ? COPY.stagedOne : n + " updates " + COPY.stagedTail;
}

// --- how many messages the popup may show at once ------------------------------------------------
// Two. Measured: at the default popup size (26 x 24 grid units = 468 x 432 px) five messages left
// the list 95 px tall, and at Layout.minimumHeight the messages alone overflowed - they sit
// OUTSIDE the ScrollView, so nothing scrolled and the list was simply gone.
//
// A RULE and not four visibility bindings, which is why it lives where a node test can state it: a
// binding can say "am I true", and only something that sees all four can say "am I one of the two
// that fit".
var MESSAGE_CAP = 2;

// Priority order, and each position is an argument:
//   report   what the person just did. First: it answers a question asked seconds ago.
//   staged   what the next restart will install, and whether a hold landed behind it. The one
//            message that changes what the rest of the popup may offer.
//   restart  a restart is owed. The footer says "restart pending" whenever this message is not on
//            screen, so the fact is never lost.
//   fetchMissed  a Check for Updates whose fetch did not land. Below the banners, whose buttons
//            act on the system: when it is crowded out the footer gives the lists' age instead.
//   kernel   the offline recommendation: advice about a transaction that will still be there next
//            time the popup is opened.
//   reclaim  unused Flatpak runtimes. Last: the space stays free to take at any later open.
// `releaseUpgrade` sits below the report and imageBased, above Kempt's own staged transaction:
// the next restart replaces the whole operating system, which outranks anything below it, and it is the reason the offline
// button is missing - a person looking for that button needs this message, not the one it displaced.
// `riskyChoice` is the kernel message again, with Install Now beside Install on Next Restart. It
// comes first because it answers the Update Now press just made, and nothing runs until it is
// answered. `surfaceOffer` keeps until it is answered, so it waits below the advice.
// `discoverOffer` is the other one-time offer. It waits for the surface offer to be answered, so
// only one of the two is ever on screen.
var MESSAGE_ORDER = ["riskyChoice", "report", "imageBased", "releaseUpgrade", "staged", "restart",
                     "fetchMissed", "kernel", "surfaceOffer", "discoverOffer", "reclaim"];

// messageStack(wants) -> the messages that may actually be drawn, in order.
// `engineFault` is not in the order at all: it shows ALONE, because everything below it presumes
// an engine that answered. The one exception is the result of its own Check Installation button.
// Anything displaced is not shown. It does not shuffle into the next slot mid-glance, and it does
// not stack below the fold.
// `doctor`, the result of Check Installation, is outside the cap. It answers a press made seconds
// ago, so it must show whatever else is up, and it must not push out the staged or restart banner
// to do it. It sits under the report whose button asked for it, or first when there is none, and
// it closes with its own button.
function messageStack(wants) {
    var w = (wants && typeof wants === "object") ? wants : {};
    if (w.engineFault) return w.doctor ? ["engineFault", "doctor"] : ["engineFault"];
    var out = [], i;
    for (i = 0; i < MESSAGE_ORDER.length && out.length < MESSAGE_CAP; i++) {
        if (w[MESSAGE_ORDER[i]]) out.push(MESSAGE_ORDER[i]);
    }
    if (w.doctor) {
        var at = out.indexOf("report");
        out.splice(at >= 0 ? at + 1 : 0, 0, "doctor");
    }
    return out;
}

// --- the reclaim offer ------------------------------------------------------------------------
// Below this the message is not worth one of the two slots. SI bytes, as formatDownload counts.
var RECLAIM_MIN_BYTES = 100 * 1000 * 1000;
var RECLAIM_DIGEST_RE = /^[0-9a-f]{16}$/;
// How long Free Up Space waits for `kempt reclaim`. Above the engine's worst case, from
// backends/flatpak.sh and lib/common.sh: KEMPT_RECLAIM_PKCHECK_TIMEOUT (10 s),
// KEMPT_RECLAIM_UNINSTALL_TIMEOUT (600 s, both removal passes together), five listings of
// KEMPT_RECLAIM_LIST_TIMEOUT (15 s: the offer, the removal's own, the re-check, the one between
// the two passes, the after-list), two runs of KEMPT_RECLAIM_DU_TIMEOUT (30 s), then the closing
// check: KEMPT_CHECK_LOCK_WAIT (60 s) and the check itself (CHECK_BODY_MS, 150 s). 955 s in all,
// plus over half a minute of margin.
// Killing the CLI sooner frees the update lock while the uninstall still runs. A test ties the two.
var RECLAIM_TIMEOUT_MS = 990000;

// The size on offer, or null when the CLI could not work it out. A value of the wrong type is
// read as unknown, never coerced.
function reclaimBytesOf(reclaim) {
    var b = reclaim.offerable_bytes;
    return (typeof b === "number" && isFinite(b) && b >= 0) ? b : null;
}

// reclaimOffered(state.reclaim) -> may the popup offer to remove these? Only with a digest: the
// CLI leaves it empty when nothing is unused or part of the list is younger than an hour.
function reclaimOffered(reclaim) {
    if (!reclaim || typeof reclaim !== "object" || isArray(reclaim)) return false;
    if (typeof reclaim.digest !== "string" || !RECLAIM_DIGEST_RE.test(reclaim.digest)) return false;
    var bytes = reclaimBytesOf(reclaim);
    return bytes === null || bytes >= RECLAIM_MIN_BYTES;
}

// reclaimMessageOf(state.reclaim) -> the offer's one line. The automatic sentence is left out
// while the last automatic try needed an administrator or failed: the next update skips that set.
// reclaimAutoPending(reclaim) -> will the next update remove this set? Not after an automatic try
// that failed or needed an administrator: the CLI skips that set until it changes.
function reclaimAutoPending(reclaim) {
    return reclaimOffered(reclaim) && reclaim.mode === "automatic"
        && reclaim.status !== "needs_auth" && reclaim.status !== "failed";
}

function reclaimMessageOf(reclaim) {
    if (!reclaimOffered(reclaim)) return "";
    var bytes = reclaimBytesOf(reclaim);
    var line = bytes === null ? COPY.reclaimUnsized
                              : fill(COPY.reclaimSized, "%1", formatDownload(bytes));
    if (reclaimAutoPending(reclaim)) line += " " + COPY.reclaimAutomatic;
    return line;
}

// reclaimRefLineOf({ref, eol}) -> "org.kde.Platform 5.15-23.08", the id and branch of a
// kind/id/arch/branch ref. Any other shape is shown as the CLI wrote it.
function reclaimRefLineOf(entry) {
    if (!entry || typeof entry !== "object" || typeof entry.ref !== "string") return "";
    var parts = entry.ref.split("/");
    var line = parts.length === 4 ? parts[1] + " " + parts[3] : entry.ref;
    if (typeof entry.eol === "string" && entry.eol !== "") line += " " + COPY.reclaimEol;
    return line;
}

// stagedHeaderOf(offline_staged) -> what the popup header and the panel tooltip say while a
// transaction is armed, or "" when none is. Same input and tolerance as stagedMessageOf, but a
// second function rather than a flag on it: the banner states what the next restart will DO, while
// this replaces a count of what is available.
function stagedHeaderOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return COPY.stagedHeaderUnknown;
    return n === 1 ? COPY.stagedHeaderOne : n + " " + COPY.stagedHeaderTail;
}

// stagedVariantOf(staged, heldDnf) -> which of the three banners this stage gets, and its words:
//   { type: "positive" | "warning", message, banner, conflictNames: [...], stagedAt: "" }
// banner is set on the plain variant only; viewModel shows a warning's whole message.
//
// THE PROBLEM IT EXISTS FOR: stage 83 updates with a kernel among them, press the pin on
// kernel-core, and restart into the kernel you just tried to keep out. dnf5 built and stored that
// transaction at stage time and offers no way to edit a stored one, so a hold applies from the
// NEXT transaction Kempt builds while this one still installs the package. The banner does not
// GAIN a warning line - that is a contradiction one level down, with the button on the reassuring
// half - it changes what it IS.
//
// The judgement is NOT re-derived here. `holds_conflict` is the CLI's own answer, computed at
// check time from dnf5's stored transaction read live, and `names_source` says what an EMPTY list
// means: "transaction"/"marker" mean it was read and there is nothing in it, "none" means it could
// not be read at all. Two states, two sentences.
//
// heldDnf is the one fact this file supplies itself: whether the box holds any dnf package at all.
// It gates the generic warning only - with nothing held there is nothing to be vague ABOUT. dnf
// only, because the offline surface stages dnf and only dnf.
//
// TOLERANCE: a key of the wrong type is IGNORED, never duck-typed - a string has a length and
// indexes into its own characters, so a duck-typed check would warn about a package called "k".
// Everything malformed falls back to the plain banner and nothing throws. The ONE asymmetry is
// deliberate: a well-formed list of names warns whether or not names_source is readable, because
// names may CONFIRM a conflict and may never DENY one.
function stagedVariantOf(staged, heldDnf) {
    var plain = { type: "positive", message: stagedMessageOf(staged), banner: "", conflictNames: [],
                  stagedAt: "" };
    if (plain.message === "") return plain;
    // The plain banner sits under a header that already gives the count, so it shows only the
    // rest. A warning shows its whole message.
    plain.banner = staged.count === 1 ? COPY.stagedBannerOne : COPY.stagedBannerMore;
    // A stamp that is not a string is not a stamp. main.qml compares this for EQUALITY against the
    // state file at click time, and a number here would compare equal to a number there and spend
    // the user's consent on a transaction they never saw.
    if (typeof staged.staged_at === "string") plain.stagedAt = staged.staged_at;

    var names = [], i, name;
    if (isArray(staged.holds_conflict)) {
        for (i = 0; i < staged.holds_conflict.length; i++) {
            name = staged.holds_conflict[i];
            // One bad entry discards the LIST, not just the entry: "kernel-core and 2 more" is
            // only worth saying when the 2 is true.
            if (typeof name !== "string" || name === "") { names = []; break; }
            names.push(name);
        }
    }

    // The cost is joined on HERE rather than written into each of the three templates: one fact
    // about one button, identical in all three, and three copies would drift. It only ever rides a
    // warning, because the warning is the only variant that offers the button it is about.
    if (names.length > 0) {
        return { type: "warning",
                 message: (names.length === 1
                     ? fill(COPY.stagedConflictOne, "%1", names[0])
                     : fill(fill(COPY.stagedConflictMore, "%1", names[0]),
                            "%2", String(names.length - 1)))
                     + " " + COPY.stagedRebuildCost,
                 conflictNames: names, stagedAt: plain.stagedAt };
    }
    if (staged.names_source === "none" && heldDnf) {
        return { type: "warning",
                 message: COPY.stagedConflictUnknown + " " + COPY.stagedRebuildCost,
                 conflictNames: [], stagedAt: plain.stagedAt };
    }
    return plain;
}

// The head of anything formatStamp can RENDER. Anything else it hands back verbatim, and
// isRenderableStamp is how a caller asks which of the two it is about to get.
var STAMP_HEAD_RE = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/;
// ...and the offset on the end, in either spelling `date -Iseconds` and its neighbours produce
// (+HH:MM, +HHMM), or Z.
var STAMP_OFFSET_RE = /(Z|[+-]\d{2}:?\d{2})$/;

function isRenderableStamp(iso) {
    return typeof iso === "string" && STAMP_HEAD_RE.test(iso.split("\n")[0].trim());
}

// formatStamp(iso) -> "2026-08-24 22:11 +03:00", or "never" when there is no stamp.
// Textual, not Date-based, on purpose: it cannot print "Invalid Date", it cannot shift a stamp
// into another timezone, and it survives the recorded corruption where two state documents arrive
// newline-joined. The OFFSET is part of the answer - this is the EXACT stamp people hover a
// relative line to compare against, and as a bare wall-clock reading it can disagree with that
// line by hours with nothing on screen to explain the gap. Normalised to one shape (+HH:MM, Z as
// +00:00) so two stamps from two producers can be read against each other.
function formatStamp(iso) {
    if (typeof iso !== "string") return "never";
    var s = iso.split("\n")[0].trim();
    if (s === "") return "never";
    var m = STAMP_HEAD_RE.exec(s);
    if (!m) return s;
    var z = STAMP_OFFSET_RE.exec(s);
    var off = "";
    if (z) off = " " + (z[1] === "Z" ? "+00:00" : z[1].slice(0, 3) + ":" + z[1].slice(-2));
    return m[1] + " " + m[2] + off;
}

// The one strict shape relativeTime will do arithmetic on: YYYY-MM-DDTHH:MM:SS, optionally
// fractional, optionally with Z or an offset (+HH:MM or +HHMM - `date -Iseconds` writes the colon,
// some producers do not). Anything else is not a timestamp here, and the answer to that is always
// the absolute stamp.
var ISO_STAMP_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/;

// stampMs(iso) -> the stamp as UTC milliseconds, or NaN. The one place a stamp becomes a number,
// shared by relativeTime and shouldRefreshOnOpen so the two can never disagree about what counts
// as readable.
function stampMs(iso) {
    if (typeof iso !== "string") return NaN;
    var m = ISO_STAMP_RE.exec(iso.split("\n")[0].trim());
    if (!m) return NaN;

    var y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
    var h = Number(m[4]), mi = Number(m[5]), s = Number(m[6]);
    // The regex proves the digits are digits, not that they are a date: Date.UTC happily rolls
    // month 13 into next January and would answer with a confident wrong number.
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 60) return NaN;

    var off = 0, zone = m[7];
    // No zone at all is read as UTC: the only reading available without Date's own string parsing,
    // since local time is a property of the machine and not of the text. The CLI's now_iso always
    // writes an offset, so this is a foreign-file case.
    if (zone && zone !== "Z") {
        var digits = zone.substring(1).replace(":", "");
        off = (Number(digits.substring(0, 2)) * 60 + Number(digits.substring(2))) * 60000;
        if (zone.charAt(0) === "-") off = -off;
    }
    // The offset says how far AHEAD of UTC the wall clock is, so it comes off to get UTC.
    return Date.UTC(y, mo - 1, d, h, mi, s) - off;
}

// relativeTime(iso, nowMs) -> "4 min ago", or the absolute stamp when it cannot be sure.
// No Date parsing, same as formatStamp: Date.UTC is pure arithmetic, with no locale, no local
// timezone and no string parsing, which is what keeps formatStamp's three guarantees. The clock is
// an ARGUMENT rather than a Date.now() call, so every bucket boundary is something a node test can
// assert exactly instead of racing. Everything it cannot be sure about hands back to formatStamp,
// including a NEGATIVE age: "in -3 minutes" is worse than a date in every way.
function relativeTime(iso, nowMs) {
    var at = stampMs(iso);
    if (!isFinite(at) || typeof nowMs !== "number" || !isFinite(nowMs)) return formatStamp(iso);

    var age = nowMs - at;
    if (age < 0) return formatStamp(iso);
    if (age < 60000) return "just now";
    var n = Math.floor(age / 60000);
    if (n < 60) return n === 1 ? "1 min ago" : n + " min ago";
    n = Math.floor(age / 3600000);
    if (n < 24) return n === 1 ? "1 hour ago" : n + " hours ago";
    n = Math.floor(age / 86400000);
    // A week is the last age at which counting days answers "when?" better than the date does.
    // Past it, "23 days ago" makes a person do the arithmetic the stamp would have saved.
    if (n <= 7) return n === 1 ? "1 day ago" : n + " days ago";
    return formatStamp(iso);
}

// How old the package metadata behind the counts is, in words, or "" when it is not worth saying.
// A check answers from a cache that is refreshed at most once every three hours and not at all on
// battery or a metered link, so "Checked 4 min ago" can sit above counts derived from week-old
// metadata - and nothing else on the popup would give that away.
// 24 hours is the floor because under it there is nothing to report: that is the ordinary state of
// a plugged-in machine, and a line on every popup would be noise that teaches people to skip the
// footer. The clock is an ARGUMENT, like relativeTime's, so a test can assert each boundary.
// `floorMs` lowers that floor. The footer passes 60000 after a Check for Updates whose refresh did
// not land (battery, metered, offline), so the person can tell the list may be old.
var METADATA_STALE_MS = 86400000;
function metadataAgeText(iso, nowMs, floorMs) {
    if (typeof nowMs !== "number" || !isFinite(nowMs)) return "";
    var at = stampMs(iso);
    // Unreadable or absent says nothing at all, the same silence relativeTime falls back to: an
    // age nobody could work out is not an age to put a number on.
    if (!isFinite(at)) return "";
    var age = nowMs - at;
    var floor = (typeof floorMs === "number" && isFinite(floorMs) && floorMs >= 60000)
        ? floorMs : METADATA_STALE_MS;
    if (age < floor) return "";
    if (age >= METADATA_STALE_MS) {
        var days = Math.floor(age / METADATA_STALE_MS);
        return "metadata " + days + (days === 1 ? " day old" : " days old");
    }
    var hours = Math.floor(age / 3600000);
    if (hours >= 1) return "metadata " + hours + (hours === 1 ? " hour old" : " hours old");
    return "metadata " + Math.floor(age / 60000) + " min old";
}

// refreshMissed(state, askedMs) -> whether the check a Check for Updates press started at `askedMs`
// answered without fresh metadata: the refresh was skipped (battery, metered) or failed (offline).
// metadata_refreshed has whole seconds, so `askedMs` is floored to its second. No stamp, no claim.
function refreshMissed(state, askedMs) {
    var asked = Number(askedMs);
    if (!state || typeof state !== "object" || !isFinite(asked) || asked <= 0) return false;
    var at = stampMs(state.metadata_refreshed);
    return isFinite(at) && at < Math.floor(asked / 1000) * 1000;
}

// fetchMissedOf(state, askedMs, pressStamp) -> the notice for a Check for Updates press whose fetch
// did not land, or "". Only while the state on screen is the one that press's own check answered
// with: `pressStamp` is that answer's last_check (main.qml records it), so the next check, whoever
// starts it, takes the notice away. A state served while another check held the lock (last_check
// before the press) tried nothing. A stale check has its own report.
// The lead comes from what the check published. A press passes the 3-hour gate, so with no
// refresh_skipped the fetch ran, and a missed one left refresh_error behind. An engine older than
// both fields, or one with refreshing turned off, gets the lead that says only what is known.
// The age is measured at the check, not now, so the sentence does not change while it is on
// screen and a screen reader hears it once.
function fetchMissedOf(state, askedMs, pressStamp) {
    if (!refreshMissed(state, askedMs) || state.status === "stale") return "";
    if (typeof pressStamp !== "string" || pressStamp === "" || state.last_check !== pressStamp) {
        return "";
    }
    var asked = Math.floor(Number(askedMs) / 1000) * 1000;
    var checked = stampMs(state.last_check);
    if (!isFinite(checked) || checked < asked) return "";
    var age = ageWords(checked - stampMs(state.metadata_refreshed));
    if (age === "") return "";
    var err = state.backends && typeof state.backends === "object" && state.backends.dnf
        && typeof state.backends.dnf.refresh_error === "string"
        ? firstLineOf(state.backends.dnf.refresh_error) : "";
    var lead = state.refresh_skipped === "battery" ? COPY.fetchWaitsForPower
        : state.refresh_skipped === "metered" ? COPY.fetchWaitsForUnmetered
        : err === "" || typeof state.refresh_skipped === "string" ? COPY.fetchMissed
        : REFRESH_NETWORK_RE.test(err) ? COPY.fetchNoServers : COPY.fetchFailed;
    return lead + " " + COPY.fetchCountsFrom.replace("%1", age);
}

// servedBeforePress(state, askedMs) -> whether a check started at `askedMs` answered with a state
// some earlier check wrote: last_check before the press, which is what the CLI prints when another
// check held the lock past its wait. Both are floored to whole seconds, as last_check is. No
// stamp, no claim.
function servedBeforePress(state, askedMs) {
    var asked = Number(askedMs);
    if (!state || typeof state !== "object" || !isFinite(asked) || asked <= 0) return false;
    var checked = stampMs(state.last_check);
    return isFinite(checked) && checked < Math.floor(asked / 1000) * 1000;
}

// anywayReasonOf(refreshSkipped) -> "battery" or "metered" when Download Anyway can pass the rule
// that skipped the fetch, else "". Fetching turned off ("off") is a setting no press overrides.
function anywayReasonOf(refreshSkipped) {
    return refreshSkipped === "battery" || refreshSkipped === "metered" ? refreshSkipped : "";
}

// ageWords(ms) -> "5 min old", "3 hours old", "2 days old", or "" for an age that is not one.
function ageWords(age) {
    if (typeof age !== "number" || !isFinite(age) || age < 0) return "";
    if (age < 60000) return "less than a minute old";
    var days = Math.floor(age / METADATA_STALE_MS);
    if (days >= 1) return days + (days === 1 ? " day old" : " days old");
    var hours = Math.floor(age / 3600000);
    if (hours >= 1) return hours + (hours === 1 ? " hour old" : " hours old");
    return Math.floor(age / 60000) + " min old";
}

// --- the check command ------------------------------------------------------------------------
// checkArgs(automatic, refresh, anyway) -> what doCheck appends to `kempt`. Check for Updates fetches
// fresh metadata (`--refresh`). Download Anyway also passes the battery and metering rules, and
// only for a press: never for a check nobody asked for. The checks nobody asked for coalesce and
// keep the CLI's 3-hour interval. Any other press (a hold, Check again) runs a check of its own
// from the cache.
function checkArgs(automatic, refresh, anyway) {
    if (anyway === true && refresh === true && automatic !== true) return " check --anyway";
    if (refresh === true) return " check --refresh";
    return automatic === true ? " check --coalesce" : " check";
}

// How long the widget waits for any `kempt check` before giving up on it. A ceiling for EVERY check,
// because an automatic one fetches too once the 3-hour interval is up, and a kill mid-fetch leaves
// a root dnf5 running unwatched. A check with no fetch ends in seconds anyway.
// CHECK_BODY_MS is the check without its fetch: 120 s for its own queries, and 30 s for what
// notify_security adds (lib/common.sh: the 15 s advisory query, two 5 s waits for the writers'
// lock and the 5 s notification). The fetch adds Flatpak's KEMPT_REFRESH_TIMEOUT (120 s) once per
// installation, system and per-user, and dnf's makecache. That one runs as root, where the CLI's
// timeout cannot reach it, so libexec/kempt-refresh bounds it as root with the same 120 s, plus a
// 10 s grace before SIGKILL. Plus 30 s, which covers that grace:
// 150 + 240 + 120 + 30 = 540 s.
var CHECK_BODY_MS = 150000;
var CHECK_TIMEOUT_MS = 540000;

// The oldest the popup's counts may be before opening it asks for fresh ones. A CEILING, not an
// alternative to the configured interval: somebody who set an hour still opened the popup to LOOK
// at the counts. Somebody who set two minutes gets two, because the smaller always wins.
var REFRESH_ON_OPEN_CEILING_MS = 5 * 60000;

// shouldRefreshOnOpen(lastSuccessIso, intervalMin, nowMs) -> should the popup re-check now?
// The order of the guards matters: an unusable clock is checked FIRST, so it beats "we know
// nothing, so ask" - firing a package-manager command on every popup open because an argument was
// undefined is worse than not auto-refreshing. A missing stamp with a usable clock still asks.
function shouldRefreshOnOpen(lastSuccessIso, intervalMin, nowMs) {
    if (typeof nowMs !== "number" || !isFinite(nowMs)) return false;
    var at = stampMs(lastSuccessIso);
    if (!isFinite(at)) return true;
    var age = nowMs - at;
    if (age < 0) return false;      // a stamp from the future is a moved clock, not a due check
    // Number(), because config values arrive as the TEXT `kempt config get` printed.
    var mins = Number(intervalMin);
    var limit = (isFinite(mins) && mins > 0)
        ? Math.min(mins * 60000, REFRESH_ON_OPEN_CEILING_MS)
        : REFRESH_ON_OPEN_CEILING_MS;
    return age > limit;             // OLDER than the limit; exactly at it is not yet stale
}

// Backend iteration order: the two we know, then anything the CLI grew since this widget was
// written. architecture.md promises a new backend is an additive schema-1 key, so an unknown key
// must appear in the popup under its own name, never be silently dropped.
function backendKeys(backends) {
    var out = [], i, key;
    for (i = 0; i < BACKEND_ORDER.length; i++) {
        if (backends[BACKEND_ORDER[i]]) out.push(BACKEND_ORDER[i]);
    }
    for (key in backends) {
        if (!Object.prototype.hasOwnProperty.call(backends, key)) continue;
        if (out.indexOf(key) < 0) out.push(key);
    }
    return out;
}

// securityOf(state) -> the CLI's `security` block as the widget uses it, or an empty one. The block
// is optional (notify_security off, an older CLI, a check whose advisory query failed), and every
// field is checked before it is believed. `attention` needs a digest, because acknowledging the set
// is what clears it and `kempt security-ack` takes nothing else.
function securityOf(state) {
    var s = state && state.security && typeof state.security === "object" ? state.security : null;
    var none = { count: 0, names: {}, attention: false, digest: "" };
    if (s === null || typeof s.count !== "number" || !(s.count >= 1)) return none;
    var names = {}, packages = arrayOf(s.packages), i;
    for (i = 0; i < packages.length; i++) names[String(packages[i])] = true;
    var digest = typeof s.digest === "string" && /^[0-9a-f]{16}$/.test(s.digest) ? s.digest : "";
    return { count: Math.floor(s.count), names: names, attention: s.attention === true && digest !== "",
             digest: digest };
}

// Walk the backends once, producing the popup's pending sections and the flat Held list.
// A backend with enabled:false contributes NOTHING - no section, no held rows, no counts - so
// "include_flatpak=false" renders as an absent Apps section rather than an empty one.
function collectItems(state) {
    var sections = [], heldItems = [], actionable = 0, heldTotal = 0;
    var securityNames = securityOf(state).names;
    var backends = (state && state.backends && typeof state.backends === "object") ? state.backends : {};
    var keys = backendKeys(backends), i, j;
    for (i = 0; i < keys.length; i++) {
        var key = keys[i];
        var backend = backends[key];
        if (!backend || typeof backend !== "object") continue;
        if (backend.enabled === false) continue;
        var items = (backend.items && typeof backend.items.length === "number") ? backend.items : [];
        // The backend's own group, then one group per `kind` its items carry, in the order the
        // kinds are first seen - so the CLI decides the order here too, exactly as it does for rows.
        var pending = [], byKind = {}, kindOrder = [], k;
        // Which ids are installed both ways. A hold is by id, so it covers both copies, and the
        // padlock on either row says so.
        var scopesOf = {};
        for (j = 0; j < items.length; j++) {
            var it = items[j] || {};
            if (it.name === undefined || it.name === null) continue;
            var sk = String(it.name);
            if (!scopesOf[sk]) scopesOf[sk] = {};
            scopesOf[sk][it.scope === "user" ? "user" : "system"] = true;
        }
        for (j = 0; j < items.length; j++) {
            var item = items[j] || {};
            var itemKind = (item.kind === undefined || item.kind === null) ? "" : String(item.kind);
            var row = {
                name: item.name === undefined || item.name === null ? "" : String(item.name),
                from: newestOf(item.from),
                to: newestOf(item.to),
                held: !!item.held,
                backend: key,  // half of the `kempt hold <backend>:<name>` argument
                // A runtime's identity is its id AND its branch: the same runtime is routinely
                // installed on two branches, and two rows reading the same name with no branch
                // between them are two rows a person cannot tell apart. "" for everything else.
                branch: (item.branch === undefined || item.branch === null) ? "" : String(item.branch),
                // Whether this row gets a padlock. Runtimes do not: `kempt hold` refuses them,
                // because apps share a runtime and holding one breaks the next app that needs it.
                // A padlock that reports a refusal every time is worse than no padlock.
                holdable: itemKind !== "runtime",
                // Installed with `flatpak install --user`, so it is this person's alone. The row
                // says so, which also tells apart one id installed both ways.
                forYouOnly: item.scope === "user",
                // A system package the CLI's security block names. dnf rows only: Flatpak apps
                // publish no security notices, and a name shared with an app must not borrow it.
                security: key === "dnf" && item.name !== undefined && item.name !== null
                          && securityNames[String(item.name)] === true,
                bothScopes: !!(item.name !== undefined && item.name !== null
                               && scopesOf[String(item.name)].user && scopesOf[String(item.name)].system)
            };
            if (row.held) { heldItems.push(row); heldTotal++; }
            else {
                if (itemKind === "") pending.push(row);
                else {
                    if (!byKind[itemKind]) { byKind[itemKind] = []; kindOrder.push(itemKind); }
                    byKind[itemKind].push(row);
                }
                actionable++;
            }
        }
        if (pending.length > 0) {
            sections.push({ title: SECTION_TITLES[key] || key, backend: key, items: pending });
        }
        // A kind this build has never heard of still gets a section, under a title built from its
        // own two words - the same rule backendKeys follows for an unknown backend. Dropping it
        // would hide pending updates the badge has already counted.
        for (k = 0; k < kindOrder.length; k++) {
            var kd = kindOrder[k];
            var kindTitles = KIND_SECTION_TITLES[key] || {};
            sections.push({ title: kindTitles[kd] || (key + " " + kd),
                            backend: key, kind: kd, items: byKind[kd] });
        }
    }
    return { sections: sections, heldItems: heldItems, actionable: actionable, heldTotal: heldTotal };
}

// rowsOf(sections, heldItems) -> ONE flat list for the popup's ListView, as
// {kind: "header", title, held} or {kind: "item", ...the item, plus `held`}. A flat model creates
// delegates lazily, so 1200 pending updates cost what six cost, and flattening here makes the
// grouping something a node test can check. A header carries `held` so the popup can find the Held
// heading without comparing the title against the literal "Held", which a translator will change.
function rowsOf(sections, heldItems) {
    var rows = [], i, j;
    for (i = 0; i < sections.length; i++) {
        rows.push({ kind: "header", title: sections[i].title, held: false });
        for (j = 0; j < sections[i].items.length; j++) rows.push(rowOf(sections[i].items[j], "item"));
    }
    // Held last and always its own group: the spec's promise is that a held item stays VISIBLE
    // with its waiting version, just out of the way of the things you can act on.
    if (heldItems.length > 0) {
        rows.push({ kind: "header", title: "Held", held: true });
        for (i = 0; i < heldItems.length; i++) rows.push(rowOf(heldItems[i], "item"));
    }
    return rows;
}

// `kind` here is the ROW kind - "item" or "header" - and has nothing to do with an item's flatpak
// kind, which never reaches a row: the section above it already carries that, and the two facts a
// row itself needs are its branch and whether it can be held.
function rowOf(item, kind) {
    return { kind: kind, title: "", name: item.name, from: item.from, to: item.to,
             held: item.held, backend: item.backend,
             branch: item.branch || "",
             // Absent means holdable, so a row built by an older caller keeps its padlock.
             holdable: item.holdable !== false,
             forYouOnly: item.forYouOnly === true,
             security: item.security === true,
             bothScopes: item.bothScopes === true };
}

// --- the last run --------------------------------------------------------------------------------
// Everything below reads ONE history entry, served byte for byte by `kempt summary --json` rather
// than re-rendered, so what arrives is what cmd_update wrote:
//   {timestamp, surface, status, duration_sec, reboot_needed, log, error,
//    backends: {<name>: {updated:[{name,from,to}], added:[{name,to}], removed:[{name,from}],
//                        status, skipped_held:[]}}}
// Re-deriving any of this from the human summary text would be a second, lossier copy of
// render_summary's rules living in the widget. Hence --json.

// lastRunOf(text) -> the last run as data, or null.
// null means "no last run", and every caller must render NOTHING for it - never a fabricated empty
// run. Same contract `kempt summary --json` keeps: with no history it prints empty stdout under
// exit 0, because a box that has never updated has not "updated 0 packages".
// Every field tolerates absence, because history entries outlive the build that wrote them. The
// one field that is deliberately NOT optimistic is `failed`: a status we cannot read is not a
// success, and the cost of the two mistakes is not symmetric.
function lastRunOf(text) {
    // The same tolerant parse the state file gets: empty, whitespace, truncated, a bare number and
    // a JSON array all mean "we learned nothing".
    var entry = parseState(text);
    if (entry === null) return null;

    var backends = (entry.backends && typeof entry.backends === "object") ? entry.backends : {};
    var keys = backendKeys(backends);
    var items = [], updated = 0, added = 0, removed = 0, i, j, backend, up, item;
    for (i = 0; i < keys.length; i++) {
        backend = backends[keys[i]];
        if (!backend || typeof backend !== "object") continue;
        up = arrayOf(backend.updated);
        for (j = 0; j < up.length; j++) {
            item = up[j] || {};
            // newestOf on both sides: a multilib pair or an installonly kernel set arrives
            // comma-joined and the popup's own rows already render the last element, so anything
            // else here would be the same package rendered two ways on one screen.
            items.push({ name: item.name === undefined || item.name === null ? "" : String(item.name),
                         from: newestOf(item.from), to: newestOf(item.to) });
        }
        updated += up.length;
        added += arrayOf(backend.added).length;
        removed += arrayOf(backend.removed).length;
    }

    // What automatic reclaim removed after this run (backends.flatpak.reclaimed). Only a removal
    // counts: a failed or refused one never fails the run and is reported through the state.
    var reclaimed = backends.flatpak && typeof backends.flatpak === "object"
        ? backends.flatpak.reclaimed : null;
    var reclaimedCount = 0, reclaimedBytes = null, reclaimedInUse = 0;
    if (reclaimed && typeof reclaimed === "object" && reclaimed.status === "removed") {
        reclaimedCount = arrayOf(reclaimed.refs).length;
        // Extensions Flatpak took although an app installed during the removal uses them.
        reclaimedInUse = arrayOf(reclaimed.in_use).length;
        if (typeof reclaimed.bytes === "number" && isFinite(reclaimed.bytes) && reclaimed.bytes > 0) {
            reclaimedBytes = reclaimed.bytes;
        }
    }

    var status = typeof entry.status === "string" ? entry.status : "";
    var when = typeof entry.timestamp === "string" ? entry.timestamp : "";
    return {
        when: when,
        whenStamp: formatStamp(when),
        surface: typeof entry.surface === "string" ? entry.surface : "",
        status: status,
        failed: status !== "ok",
        error: typeof entry.error === "string" ? entry.error : "",
        // null when the entry does not say, NOT 0 - 0 is a real duration here. The CLI writes
        // `$(date +%s) - start`, so any run finishing inside a second records zero, and collapsing
        // absent onto zero puts "in 0s" on a run this build had no timing for.
        durationSec: (typeof entry.duration_sec === "number" && isFinite(entry.duration_sec))
            ? entry.duration_sec : null,
        updatedCount: updated,
        addedCount: added,
        removedCount: removed,
        // Installs and removals changed the machine as much as upgrades did, and the CLI counts
        // them (run_counts_phrase). Counting only upgrades announces "No package changes" after a
        // transaction that added two.
        changedCount: updated + added + removed,
        items: items,
        logPath: typeof entry.log === "string" ? entry.log : "",
        // Strictly the boolean. This entry's reboot_needed is a fact about THAT RUN, not about now
        // - the state file carries the live answer - so nothing renders an affirmative from it.
        rebootNeeded: entry.reboot_needed === true,
        // Why a staging run staged nothing, or null when it staged something - AND null for an
        // entry written before the CLI recorded this, which is the same answer for a different
        // reason and deliberately so: those two cannot be told apart, and guessing would report a
        // real stage as nothing. Only the two words the CLI writes are accepted; anything else is
        // a build this one does not understand, and "I do not know" is the honest reading of it.
        stagedNothing: (entry.staged_nothing === "held" || entry.staged_nothing === "nothing_pending")
            ? entry.staged_nothing : null,
        reclaimedCount: reclaimedCount,
        reclaimedBytes: reclaimedBytes,
        reclaimedInUse: reclaimedInUse
    };
}

// reclaimInUseSentence(n) -> "" or the sentence about n extensions Flatpak removed although an app
// installed during the removal uses them. One spelling for Free Up Space and for a run's removal.
function reclaimInUseSentence(n) {
    if (!(n > 0)) return "";
    return n === 1 ? COPY.reclaimInUseOne : fill(COPY.reclaimInUseMore, "%1", String(n));
}

// reclaimInUseTailOf(run) -> "" or " " + that sentence for the run's automatic removal. A failed
// run removed nothing (reclaim runs only after a successful one), so it never carries this. Nor
// does an entry with no readable stamp: it has no Last update row and could never be marked seen.
function reclaimInUseTailOf(run) {
    if (!run || run.failed || !isRenderableStamp(run.when)) return "";
    var s = reclaimInUseSentence(run.reclaimedInUse);
    return s === "" ? "" : " " + s;
}

// reclaimedTailOf(run) -> "" or the clause the run lines append: " · ~1.5 GB freed".
function reclaimedTailOf(run) {
    if (!run || run.failed || !(run.reclaimedCount > 0)) return "";
    if (typeof run.reclaimedBytes === "number") {
        return DOT + fill(COPY.reclaimFreedTail, "%1", formatDownload(run.reclaimedBytes));
    }
    return DOT + (run.reclaimedCount === 1 ? COPY.reclaimRemovedOne
                  : fill(COPY.reclaimRemovedMore, "%1", String(run.reclaimedCount)));
}

// postRunLine(run) -> the transient line shown once, right after a run finishes.
// A failed run is reported as failed WHATEVER its counts say: a transaction that upgraded four
// packages and then died is a failure, and "Updated 4 packages" is the worst thing to say about it.
function postRunLine(run) {
    if (!run) return "";
    if (run.failed) {
        // The CLI's own worked-out reason (run_failure_reason), not a generic apology - first line
        // only, because a panel is one line wide and the log is one click away.
        var why = firstLineOf(run.error);
        return why === "" ? COPY.updateFailed : COPY.updateFailed + ": " + why;
    }
    // The staging run's entry has empty package lists BY CONSTRUCTION - nothing changes until the
    // restart - so the count sentences below would call it "No package changes": true about the
    // rpm set and no answer to what the person just did. Exact match, never a prefix: the harvest
    // writes "offline (applied on reboot)" and its counts are real changes.
    // ...unless the run staged nothing, which is a successful `offline` run too and was described
    // in the same words as one that staged sixty packages.
    // Flatpak still updates live on a staging run, so its automatic removal can report in_use too.
    if (run.surface === "offline" && run.stagedNothing !== null) {
        return (run.stagedNothing === "held" ? COPY.stagedNothingHeld : COPY.stagedNothingNonePending)
            + reclaimInUseTailOf(run);
    }
    if (run.surface === "offline") return COPY.stagedUnknownCount + reclaimInUseTailOf(run);
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    if (n === 0) return COPY.noPackageChanges + reclaimedTailOf(run) + reclaimInUseTailOf(run);
    // The duration is a CLAUSE, not a field with a default: a run whose entry does not say how
    // long it took is described without it rather than described as instantaneous. A negative
    // duration is the clock stepping backwards during the run, not a measurement, so it is left
    // out the same way.
    var secs = run.durationSec;
    var howLong = (typeof secs === "number" && isFinite(secs) && secs >= 0) ? " in " + secs + "s" : "";
    return "Updated " + n + (n === 1 ? " package" : " packages") + howLong + reclaimedTailOf(run)
        + reclaimInUseTailOf(run);
}

// reportRepeatsStaged(run) -> does the post-run line only say what the staged message says?
// A clean staging run reports "Updates are staged", and the staged message above it says the same
// with the count and its Restart and Discard buttons. Two boxes for one fact, so the report gives
// way while that message is on screen, and the Last update row (with Show Log) takes its place.
// Anything the line adds keeps it: a run that staged nothing, a failure, an in-use note.
function reportRepeatsStaged(run) {
    // A stamp the row cannot render would leave the Last update row with no title in its place.
    return !!run && !run.failed && run.surface === "offline" && run.stagedNothing === null
        && isRenderableStamp(run.when) && reclaimInUseTailOf(run) === "";
}

// runFinishedSince(run, sinceMs) -> is this entry the run we just watched finish?
// `kempt summary --json` answers with the newest entry it can read; the CLI is the primary guard
// and this is the belt to those braces, covering what the CLI cannot see - a summary answered from
// a history directory that has not caught up yet.
//
// SECOND resolution on both sides, not as a rounding convenience: the CLI stamps entries with
// `date -Iseconds`, so a run that took 400ms carries a stamp truncated to the second it finished
// in, which can be numerically BELOW the millisecond clock noted when the run started. Full
// precision would silently drop the line for the fastest runs, which are the ordinary ones.
//
// A stamp that cannot be read answers NO, unlike every other field of an entry (see lastRunOf):
// this question is about identity. It costs only the transient line - the persistent Last update
// row is bound to `lastRun`.
function runFinishedSince(run, sinceMs) {
    if (!run) return false;
    // No moment to compare against - a widget that never saw this run start - means the question
    // does not apply rather than that the answer is no.
    if (typeof sinceMs !== "number" || !isFinite(sinceMs) || sinceMs <= 0) return true;
    var at = stampMs(run.when);
    if (!isFinite(at)) return false;
    return Math.floor(at / 1000) >= Math.floor(sinceMs / 1000);
}

// runStartMessage(rc, stdout, stderr) -> "" when `kempt run` started a run, otherwise what to tell
// the person. Only exit 0 means a run began, so only exit 0 may enter the updating pane: any other
// status is a run that will never write state.json, and the pane would wait three hours for it.
// The CLI's own first line wherever there is one: exit 4 names the missing emulator, exit 5 a
// window that never opened, exit 3 the update already holding the lock.
function runStartMessage(rc, stdout, stderr) {
    if (rc === 0) return "";
    var msg = firstLineOf(stderr) || firstLineOf(stdout);
    if (msg !== "") return msg;
    if (rc === 3) return "An update is already running.";
    return "Could not start the update (exit " + rc + ").";
}

// discardStagedMessage(rc, stdout, stderr) -> the one sentence the popup reports after
// `kempt unstage`. NEVER "", which is where it differs from runStartMessage: that one enters the
// updating pane on success and the pane is the report, while this press only makes a banner
// disappear, and a message that merely vanished says nothing to somebody who was not looking at it
// and nothing at all to a screen reader.
//
// The CLI's own first line wherever there is one, exactly as runStartMessage does it: exit 5 names
// the Fedora release upgrade the refusal protected, exit 3 the update holding the lock, exit 1
// what could not be discarded. Success reads stdout for the same reason and a stronger one - the
// CLI says two different true things there ("Discarded the staged update", and nothing was staged
// to discard) and the exit code cannot tell them apart, so the words come from the run rather than
// from a guess here.
function discardStagedMessage(rc, stdout, stderr) {
    if (rc === 0) return firstLineOf(stdout) || COPY.stagedDiscardDone;
    var msg = firstLineOf(stderr) || firstLineOf(stdout);
    if (msg !== "") return msg;
    // Nothing was read and nothing was changed, which is what makes exit 5 a refusal rather than a
    // failed run - the CLI's own distinction, and the reason these are two sentences.
    if (rc === 5) return COPY.stagedDiscardRefused;
    if (rc === 3) return COPY.stagedDiscardBusy;
    return fill(COPY.stagedDiscardFailed, "%1", String(rc));
}

// --- answering an offer, or changing a setting through a CLI verb ----------------------------------
// How long the widget waits for `kempt config set` or `kempt discover-notifier`. Each takes the
// CLI's writers' lock, which waits up to 30 s for another writer before it gives up, so anything
// shorter would report a write as lost while the CLI was still about to make it.
var ANSWER_TIMEOUT_MS = 40000;

// answerOutcomeOf(rc, stdout, stderr, fallback, timedOut) -> {ok, text}: what the popup or the
// settings page says after such a verb. Success is the CLI's first line, or `fallback` when it
// printed nothing. Failure is its own reason, except the Executor's kill, which gets a sentence:
// `timedOut` when given (a setting, a hold), COPY.answerTimedOut otherwise.
function answerOutcomeOf(rc, stdout, stderr, fallback, timedOut) {
    if (rc === 0) {
        return { ok: true, text: firstLineOf(stdout) || (typeof fallback === "string" ? fallback : "") };
    }
    if (isExecutorTimeout(rc, stderr)) {
        return { ok: false, text: typeof timedOut === "string" && timedOut !== "" ? timedOut
                                                                                 : COPY.answerTimedOut };
    }
    return { ok: false, text: firstLineOf(stderr) || firstLineOf(stdout) };
}

// --- Check Installation (`kempt doctor`) --------------------------------------------------------
// How long the widget waits for doctor. It reads files and takes well under a second; its slowest
// row is the unused-runtime listing, capped at KEMPT_RECLAIM_LIST_TIMEOUT (15 s).
var DOCTOR_TIMEOUT_MS = 60000;

// mentionsDoctor(text) -> does this message tell the person to run `kempt doctor`? The CLI's own
// refusals end "See: kempt doctor", and so do the copy table's fallbacks. Each one gets the button.
function mentionsDoctor(text) {
    return typeof text === "string"
        && (/\bkempt doctor\b/.test(text) || text.indexOf(COPY.doctorAction) >= 0);
}

// The longest result sentence. Longer ones end at a word, with the full report one press away.
var DOCTOR_SUMMARY_MAX = 150;

function capAtWord(text, max) {
    if (text.length <= max) return text;
    var cut = text.slice(0, max - 1);
    var space = cut.lastIndexOf(" ");
    if (space > max / 2) cut = cut.slice(0, space);
    return cut.replace(/[\s,;:.]+$/, "") + "…";
}

// doctorOutcomeOf(rc, stdout, stderr) -> {failed, summary, report}: what the popup says after
// Check Installation. Doctor prints one row per check, "FAIL  <text>" for each problem, and exits
// 1 when there is one. The summary quotes the first problem; the report is everything it printed.
// A doctor that printed no rows did not run, and stderr says why: on a box whose engine will not
// start, that is the shell's own reason.
function doctorOutcomeOf(rc, stdout, stderr) {
    var said = doctorVerdictOf(rc, stdout, stderr);
    said.summary = capAtWord(said.summary, DOCTOR_SUMMARY_MAX);
    return said;
}

function doctorVerdictOf(rc, stdout, stderr) {
    var out = typeof stdout === "string" ? stdout : "";
    var err = typeof stderr === "string" ? stderr : "";
    var report = [out.replace(/\s+$/, ""), err.replace(/\s+$/, "")]
        .filter(function (t) { return t !== ""; }).join("\n");
    var fails = [];
    out.split("\n").forEach(function (line) {
        var m = /^FAIL\s+(.*\S)\s*$/.exec(line);
        if (m) fails.push(m[1]);
    });
    if (fails.length === 1) {
        return { failed: true, summary: fill(COPY.doctorFoundOne, "%1", fails[0]), report: report };
    }
    if (fails.length > 1) {
        return { failed: true, report: report,
                 summary: fill(fill(COPY.doctorFoundMore, "%1", String(fails.length)), "%2", fails[0]) };
    }
    // Exit 0 with no FAIL row is a clean report, printed or not: doctor exits 1 on any problem.
    if (rc === 0) return { failed: false, summary: COPY.doctorPassed, report: report };
    // The Executor's own kill: it answers 124 and names its timeout on stderr.
    if (rc === 124) return { failed: true, summary: COPY.doctorTimedOut, report: report };
    // Only stderr explains a failure. Stdout holds doctor's info rows, which do not. The
    // report carries stderr, so the sentence only says where to read it.
    var why = firstLineOf(err);
    return { failed: true, report: report,
             summary: why !== "" ? COPY.doctorCouldNotRun
                                 : fill(COPY.doctorCouldNotRunCode, "%1", String(rc)) };
}

// reclaimOutcomeOf(rc, stdout, stderr, last, sinceMs) -> {ok, text}: what the popup reports after
// Free Up Space (`kempt reclaim -y --expect=<digest>`). `last` is the state's
// reclaim.last as read after the run, and only counts when it is at least as new as the press
// (seconds, as runFinishedSince): the CLI writes none when nothing at all is unused.
// stdout is never an error: with -y it starts with the list of runtimes, so on success the CLI's
// LAST line is its outcome, and on failure stderr's first line is.
function reclaimOutcomeOf(rc, stdout, stderr, last, sinceMs) {
    var fresh = null;
    if (last && typeof last === "object" && typeof sinceMs === "number" && isFinite(sinceMs)) {
        var at = stampMs(last.at);
        if (isFinite(at) && Math.floor(at / 1000) >= Math.floor(sinceMs / 1000)) fresh = last;
    }
    // This press removed extensions an app had just started using: said after what was freed.
    var inUse = fresh !== null && fresh.result === "removed" ? arrayOf(fresh.in_use).length : 0;
    var withInUse = function (text) {
        return inUse === 0 ? text : text + " " + reclaimInUseSentence(inUse);
    };
    if (rc === 0) {
        if (fresh !== null && fresh.result === "removed" && typeof fresh.bytes === "number"
                && isFinite(fresh.bytes) && fresh.bytes > 0) {
            return { ok: true, text: withInUse(fill(COPY.reclaimFreed, "%1", formatDownload(fresh.bytes))) };
        }
        var lines = String(stdout === undefined || stdout === null ? "" : stdout).split("\n");
        var tail = "";
        for (var i = lines.length - 1; i >= 0 && tail === ""; i--) tail = lines[i].trim();
        return { ok: true, text: withInUse(tail !== "" ? tail : COPY.reclaimNothing) };
    }
    // polkit's no, from Kempt's own check or from flatpak's helper: exit 5 and this press's record.
    if (rc === 5 && fresh !== null && fresh.result === "needs_auth") {
        return { ok: false, text: COPY.reclaimNeedsAuth };
    }
    // Flatpak failed after the removal began. `partial` with refs null: what went is unknown, and
    // "nothing was removed" could be false. With refs: some went, and a plain "Freed" would be.
    if (rc === 1 && fresh !== null && fresh.partial === true) {
        if (fresh.refs === null) return { ok: false, text: COPY.reclaimUnknown };
        if (fresh.result === "removed") {
            var sized = typeof fresh.bytes === "number" && isFinite(fresh.bytes) && fresh.bytes > 0;
            if (fresh.skipped === true) {
                // What went first, as the CLI prints it: the size, or its "Removed N runtimes." count.
                var first = COPY.reclaimPartialUnsized;
                if (sized) {
                    first = fill(COPY.reclaimFreed, "%1", formatDownload(fresh.bytes));
                } else {
                    var outLines = String(stdout === undefined || stdout === null ? "" : stdout).split("\n");
                    var outTail = "";
                    for (var j = outLines.length - 1; j >= 0 && outTail === ""; j--) outTail = outLines[j].trim();
                    if (/^Removed [0-9]+ runtimes?\.$/.test(outTail)) first = outTail;
                }
                return { ok: false, text: withInUse(first + " " + COPY.reclaimSkipped) };
            }
            if (sized) return { ok: false, text: withInUse(fill(COPY.reclaimPartial, "%1", formatDownload(fresh.bytes))) };
            return { ok: false, text: withInUse(COPY.reclaimPartialUnsized) };
        }
    }
    // A failed uninstall whose record says nothing is gone.
    if (rc === 1 && fresh !== null && fresh.result === "failed" && isArray(fresh.refs) && fresh.refs.length === 0
            && !(typeof fresh.bytes === "number" && fresh.bytes > 0)) {
        return { ok: false, text: COPY.reclaimNothingRemoved };
    }
    if (rc === 3) return { ok: false, text: COPY.reclaimBusy };
    var msg = firstLineOf(stderr);
    // The Executor's own kill (Executor.qml): the CLI never answered, and its removal may be running.
    if (rc === 124 && msg.indexOf("timeout after ") === 0) return { ok: false, text: COPY.reclaimTimedOut };
    if (msg !== "") return { ok: false, text: msg };
    if (rc === 6) return { ok: false, text: COPY.reclaimChanged };
    return { ok: false, text: fill(COPY.reclaimFailed, "%1", String(rc)) };
}

// lastRunText(run, nowMs) -> the persistent Last update row's title.
// The counting phrases are built here rather than kept in COPY because they are grammar around a
// number, not a wording decision. The zero case is the exception: "no package changes" is the
// CLI's own wording, emitted verbatim by KEMPT_JQ_COUNTS in lib/common.sh, and this line quotes
// the terminal (lowercase because it sits mid sentence after the dot). Do NOT reword it here
// alone - the tests tie all three spellings together.
function lastRunText(run, nowMs) {
    if (!run) return "";
    // An entry we cannot DATE gets no row. relativeTime answers "never" for a missing stamp, so
    // the sentence would describe a run in the same breath as denying there was one; an unreadable
    // stamp pastes "not a date" into an English sentence. WHEN it happened is the one thing this
    // line exists to say. A test of the STAMP, not of relativeTime's output: with an unusable
    // clock relativeTime falls back to the absolute stamp, which is a perfectly good row.
    if (!isRenderableStamp(run.when)) return "";
    // The staging run, between the stage and the restart: its zero counts are true and misleading,
    // same reasoning as postRunLine. `failed` is checked because this row otherwise ignores
    // failure, and a staging run that FAILED staged nothing. Exact match on "offline" - the
    // harvest's surface is "offline (applied on reboot)" and its counts render.
    if (!run.failed && run.surface === "offline") {
        // The same exception postRunLine makes, for the same reason: a run that staged nothing is
        // `offline` and `ok`, and "staged for restart" over it promises an install that no restart
        // performs. WHICH reason is left to the post-run line - this row is one line among several
        // and the distinction needs a clause it has no room for.
        if (run.stagedNothing !== null) {
            return "Last update " + relativeTime(run.when, nowMs) + DOT + COPY.lastRunNothingStaged;
        }
        return "Last update " + relativeTime(run.when, nowMs) + DOT + "staged for restart";
    }
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    var what = n === 0 ? "no package changes" : (n === 1 ? "1 package" : n + " packages");
    return "Last update " + relativeTime(run.when, nowMs) + DOT + what + reclaimedTailOf(run);
}

// lastRunSubtitle(run, seenWhen) -> the Last update row's second line, or "".
// A failed run: why, as postRunLine says it. Otherwise the in-use sentence when the run's automatic
// removal took extensions an app uses, and only until the popup has shown it once: `seenWhen` is
// the timestamp of the run whose sentence the popup was closed over (main.qml's reclaimInUseSeen,
// session-only like restartDismissed). The next run replaces the entry, and its flatpak update puts
// the extensions back, so the sentence does not outlive its run either way.
function lastRunSubtitle(run, seenWhen) {
    if (!run) return "";
    if (run.failed) return postRunLine(run);
    if (typeof seenWhen === "string" && seenWhen !== "" && seenWhen === run.when) return "";
    return reclaimInUseTailOf(run).trim();
}

// reclaimInUseOnScreen(run, seenWhen, updating, reportShown, reportText) -> is the in-use sentence
// on screen right now? main.qml asks as the popup closes, and marks the run seen only on yes.
// The updating pane replaces the main one. Otherwise the report slot, when shown, hides the Last
// update row (FullRepresentation.qml), so the sentence is seen only if the report carries it: the
// post-run line does, a failed press or a finished action does not.
function reclaimInUseOnScreen(run, seenWhen, updating, reportShown, reportText) {
    if (!run || updating === true) return false;
    var tail = reclaimInUseTailOf(run);
    if (tail === "") return false;
    if (reportShown === true) return String(reportText === undefined || reportText === null ? "" : reportText).indexOf(tail.trim()) >= 0;
    return lastRunSubtitle(run, seenWhen) !== "";
}

// isExecutorTimeout(rc, stderr) -> did Executor.qml's kill timer end this call? It reports that as
// rc 124 with "timeout after Nms", words meant for a log, never for a person.
function isExecutorTimeout(rc, stderr) {
    return rc === 124 && firstLineOf(stderr).indexOf("timeout after ") === 0;
}

// checkErrorOf(rc, stderr) -> the widget's own report of a check that answered nothing, with no
// state to fall back on (main.qml's cliError). The CLI's first stderr line, except for the
// Executor's kill, which gets a sentence.
function checkErrorOf(rc, stderr) {
    if (isExecutorTimeout(rc, stderr)) return COPY.checkTimedOut;
    return firstLineOf(stderr);
}

// The words of a check that could not reach a server. Bare "timed out" is left out: a lock or a
// polkit prompt can time out too. The dnf check is cache-only, so these come from flatpak; dnf
// says only that it has no cache, and NO_CACHE_RE below handles that.
var NETWORK_ERROR_RE = new RegExp([
    "curl error", "could(n't| not) resolve", "temporary failure in name resolution",
    "name or service not known", "error resolving", "cannot download", "failed to download",
    "all mirrors were tried", "could(n't| not) connect", "connection (refused|reset|timed out)",
    "operation timed out", "timeout was reached", "network is unreachable", "no route to host",
    "while fetching"
].join("|"), "i");

// The same for dnf's own refresh error (backends.dnf.refresh_error), and stricter: a repository
// that answers 404 also gives "Curl error" and "Cannot download", and that server was reached.
var REFRESH_NETWORK_RE = new RegExp([
    "could(n't| not) resolve", "temporary failure in name resolution", "name or service not known",
    "could(n't| not) connect", "failed to connect", "connection (refused|reset|timed out)",
    "operation timed out", "timeout was reached", "network is unreachable", "no route to host"
].join("|"), "i");

// dnf5 --cacheonly with no metadata: 'Cache-only enabled but no cache for repository "fedora"'.
var NO_CACHE_RE = /no cache for repository/i;

// checkProblemOf(text, dnfRefreshError, refreshSkipped) -> {network, noCache, headline, detail, hint} for a check
// that answered nothing and left no counts. The headline is plain words, and the hint the line
// under it. The tool's first line is kept as the detail, for the small print. The widget's own
// timeout sentence is already plain, so it has no detail.
// The CLI joins the dnf and flatpak failures with "; ". It is a network failure only when every
// part is one. dnf's "no cache" counts as one only when dnf's own refresh error (a string while
// the latest refresh failed) is a network error and this check did not skip the fetch on battery
// or a metered link. A text that names kempt doctor never is.
function checkProblemOf(text, dnfRefreshError, refreshSkipped) {
    var raw = firstLineOf(typeof text === "string" ? text : "");
    var none = { network: false, noCache: false, headline: "", detail: "", hint: "" };
    if (raw === "") return none;
    if (raw === COPY.checkTimedOut) {
        return { network: false, noCache: false, headline: raw, detail: "", hint: COPY.checkFailedHint };
    }
    var failed = { network: false, noCache: false, headline: COPY.checkFailedHeadline, detail: raw,
                   hint: COPY.checkFailedHint };
    if (mentionsDoctor(raw)) return failed;
    var refreshError = typeof dnfRefreshError === "string" ? firstLineOf(dnfRefreshError) : null;
    // A fetch this check skipped on battery or a metered link was never tried, so an older
    // network error on record does not explain the missing lists.
    var skippedByRule = refreshSkipped === "battery" || refreshSkipped === "metered";
    var refreshNetwork = refreshError !== null && !skippedByRule
        && REFRESH_NETWORK_RE.test(refreshError);
    var parts = raw.split(/; (?=(?:dnf|flatpak) check failed\b)/);
    var network = 0, noCache = 0;
    for (var i = 0; i < parts.length; i++) {
        var dnfNoCache = /^dnf check failed\b/.test(parts[i]) && NO_CACHE_RE.test(parts[i]);
        if (dnfNoCache ? refreshNetwork : NETWORK_ERROR_RE.test(parts[i])) network++;
        else if (dnfNoCache) noCache++;
    }
    if (network === parts.length) {
        return { network: true, noCache: false, headline: COPY.checkNetworkHeadline, detail: raw,
                 hint: COPY.checkNetworkHint };
    }
    if (noCache === parts.length) {
        // This check's own skip comes first: a refresh error on record can be older than it, and
        // the power and metered hints are the ones Download Anyway sits under. That error is still
        // the detail. Otherwise a refresh that failed says why in its own words, and with none on
        // record it was skipped or turned off.
        var hasRefreshError = refreshError !== null && refreshError !== "";
        if (skippedByRule) {
            return { network: false, noCache: true, headline: COPY.checkNoCacheHeadline,
                     detail: hasRefreshError ? refreshError : raw,
                     hint: refreshSkipped === "battery" ? COPY.checkNoCachePowerHint
                         : COPY.checkNoCacheMeteredHint };
        }
        return hasRefreshError
            ? { network: false, noCache: true, headline: COPY.checkNoCacheHeadline,
                detail: refreshError, hint: COPY.checkRefreshFailedHint }
            : { network: false, noCache: true, headline: COPY.checkNoCacheHeadline, detail: raw,
                hint: refreshSkipped === "off" ? COPY.checkNoCacheOffHint : COPY.checkNoCacheHint };
    }
    return failed;
}

// checkFailedOverOf(rc) -> the report for a Check for Updates that answered nothing while a state
// is still held. The counts on screen do not change, so without this the press looked ignored.
function checkFailedOverOf(rc) {
    return rc === 124 ? COPY.checkUnfinished : COPY.checkFailedOver;
}

// staleAnswerOf(state, nowMs) -> what Check for Updates says out loud for a check that reported a
// failure. Which half failed comes from the CLI's own `error` ("dnf check failed: ...; flatpak
// check failed: ..."), by its fixed prefixes only: what follows them is a tool's stderr, which is
// not something to read to a person. Then how old the counts are, from last_success.
function staleAnswerOf(state, nowMs) {
    var names = [];
    var parts = (typeof state.error === "string" ? state.error : "").split("; ");
    for (var i = 0; i < parts.length; i++) {
        var m = /^(dnf|flatpak) check failed/.exec(parts[i]);
        if (m === null) continue;
        var name = m[1] === "flatpak" ? "Flatpak" : "dnf";
        if (names.indexOf(name) < 0) names.push(name);
    }
    var said = names.length > 0 ? fill(COPY.checkFailedFor, "%1", names.join(" and "))
                                : COPY.checkFailedPlain;
    var ls = typeof state.last_success === "string" ? state.last_success.trim() : "";
    if (ls === "") return said + " " + COPY.noSuccessfulCheckYet + ".";
    if (!isRenderableStamp(ls)) return said;
    var when = relativeTime(ls, nowMs);
    if (when === "just now") when = "a moment ago";
    return said + " " + fill(COPY.countsFrom, "%1", when);
}

// viewModel(state, updating, cliError, opts) -> everything the QML layer binds to. Called on every
// state change; the QML side holds no derived state of its own.
//
// `opts` and every field in it are optional, so the three-argument call keeps working. It carries
// the facts that are not in the state file:
//   nowMs            - the clock. Absent means every relative time falls back to its absolute
//                      stamp rather than guessing.
//   restartReminder  - the `restart_reminder` config value. ABSENT is not false: the caller did
//                      not say, and the CLI's default is true. Read with isTrue, because config
//                      values arrive as text.
//   restartDismissed - closed in THIS plasmashell session. Nothing persists it, by design.
//   reclaimDismissed - the reclaim digest whose offer was closed in this session, or "". A new
//                      digest (a different set of runtimes) shows the offer again.
//   engineFault      - "" when the engine answered, else WHICH way it did not: "missing" (rc 127,
//                      nothing to run) or "unrunnable" (rc 126, there and would not start). Any
//                      other value reads as "", because this replaces the popup's whole body and
//                      an unrecognised one must not be able to blank it. A separate input rather
//                      than a magic cliError value: "we could not get an answer" and "there is
//                      nothing here to answer" are different facts.
//
// cliError is the widget's own report of a check that produced nothing usable; a failure INSIDE
// `kempt check` arrives in the state's own `error` field and comes out as staleReason.
//
// iconState is decided in this order, and the order is the contract. Two steps answer `unknown`,
// which is not an oversight: "the engine is not installed" and "the first check has not finished"
// are different sentences about the same honest verdict, and the panel has no idea what is pending
// in either.
//   updating          - we started a run; it wins over whatever the last check said
//   unknown (engine)  - no engine and nothing to show. NOT the error state; see the branch
//   error             - no state AND the CLI failed us, or an object that is not schema v1
//   unknown (no data) - no state, but nothing has gone wrong yet (first load, still checking)
//   stale             - the last check failed; the counts below are the last known good ones
//   updates           - actionable > 0
//   uptodate          - actionable == 0 (held items do not count: spec, Holds semantics)
//
// "stale" is deliberately NOT an error: the counts are the best known truth and the user does not
// need alarming about a repo that flapped, so the panel keeps rendering the CONTENTS and the
// explanation goes in the tooltip. Only "we cannot read this at all" earns a warning emblem.
function viewModel(state, updating, cliError, opts) {
    updating = !!updating;
    cliError = firstLineOf(typeof cliError === "string" ? cliError : "");
    opts = (opts && typeof opts === "object") ? opts : {};
    var engineFault = (opts.engineFault === "missing" || opts.engineFault === "unrunnable")
        ? opts.engineFault : "";
    var noEngine = engineFault !== "";
    var usable = looksLikeState(state);
    var counted = collectItems(usable ? state : null);
    var stale = usable && state.status === "stale";

    // The count and the list under it are ONE answer, and the walk is what produces the list. The
    // CLI's totals come from the same items this file walks (lib/common.sh:
    // `[.[] | select(.held|not)] | length`), so the two can only disagree when something is wrong,
    // and whatever the cause the ROWS are what the person is looking at. The totals are still the
    // answer when there is nothing to walk: a state with counts and no items is a state with no
    // list, and reading it as zero is the confident-zero mistake rule 1 exists to prevent.
    var walked = counted.sections.length > 0 || counted.heldItems.length > 0;
    var actionable = usable
        ? (walked ? counted.actionable
                  : (typeof state.actionable === "number" ? state.actionable : counted.actionable))
        : null;
    var heldTotal = usable
        ? (walked ? counted.heldTotal
                  : (typeof state.held_total === "number" ? state.held_total : counted.heldTotal))
        : null;

    var noState = (state === null || state === undefined);
    var everSucceeded = usable && typeof state.last_success === "string" && state.last_success.trim() !== "";
    var nothingKnown = counted.sections.length === 0 && counted.heldItems.length === 0;

    // Calm-stale is for a FLAP OVER KNOWN COUNTS: we had an answer, this check failed, the old
    // numbers stand. A box that has never had a successful check has no counts to be calm about -
    // "up to date" there is a clean lie, and it is exactly what a box whose root helpers were
    // never installed looks like. That belongs with the errors.
    var neverAnswered = usable && stale && !everSucceeded && nothingKnown;

    var iconState;
    if (updating) iconState = "updating";
    // A SETUP STEP, not a malfunction. `error` is the panel's alarm - CompactRepresentation hangs
    // a warning emblem off the icon - and that is a statement about a machine that cannot be
    // trusted; alarming a first-timer trains them to ignore the emblem for the day it means
    // something. `uptodate` would be worse: knowing nothing and rendering a clean icon is the
    // confident zero rule 1 forbids. `unknown` renders dimmed with no emblem, which is exactly
    // what is true. Only where there is nothing else to show - with counts from an earlier working
    // engine the rows are still the best truth there is, and they keep their own state below.
    // ...and only while the engine is MISSING. An engine that is installed and will not start is
    // a malfunction, which is what the warning emblem is for; dimming it would file a broken
    // installation under "nothing has happened yet".
    else if (engineFault === "missing" && noState) iconState = "unknown";
    else if (engineFault === "unrunnable" && noState) iconState = "error";
    else if (noState && cliError !== "") iconState = "error";
    else if (noState) iconState = "unknown";
    else if (!usable) iconState = "error";
    else if (neverAnswered) iconState = "error";
    else if (stale) iconState = "stale";
    else if (actionable > 0) iconState = "updates";
    else iconState = "uptodate";

    // No count, no badge: rule 1 in one line, "no data" must never reach the panel as a confident
    // zero. Capped at BADGE_MAX because a four-digit badge is a layout problem in a panel; it
    // stays truthful, and the exact number is one hover away in a tooltip that is never capped.
    var badgeText = "";
    if (usable && actionable > 0) badgeText = actionable > BADGE_MAX ? BADGE_MAX + "+" : String(actionable);

    // The per-user apps could not be listed, so the check answered for the system ones only. The
    // CLI keeps the last check's per-user rows, and this says they are not today's answer.
    var fpBackend = usable && state.backends && typeof state.backends === "object"
        ? state.backends.flatpak : null;
    var userUnchecked = !!(fpBackend && typeof fpBackend === "object" && fpBackend.scopes
        && typeof fpBackend.scopes === "object" && fpBackend.scopes.user === "failed");

    var countPhrase = "";
    if (usable) {
        // "Up to date" over rows with waiting versions in them is a lie by omission, which is what
        // a box whose every pending update is held would draw. Nothing is ACTIONABLE, which is
        // what the badge and the button are about; the header is the sentence, and the sentence
        // owes the held count.
        countPhrase = actionable === 0
            ? (heldTotal > 0 ? COPY.upToDate + DOT + heldTotal + " " + COPY.held
                : userUnchecked ? COPY.upToDate + DOT + COPY.userAppsUncheckedShort : COPY.upToDate)
            : (actionable === 1 ? "1 update available" : actionable + " updates available");
    }

    // --- a transaction that is already staged and armed ------------------------------------------
    // Derived HERE, above the header, because it changes what the header may say: while a stage is
    // armed the pending count is a true number saying a false thing. Nine of the returned fields
    // depend on it.
    //
    // heldDnf is walked out of the items collectItems already built rather than re-read from the
    // state: those rows are what the popup is SHOWING as held, and a banner whose warning
    // disagreed with the Held group under it would contradict itself in one glance.
    // What kind of machine this is, and what else is in dnf5's one transaction slot. Both are read
    // HERE, above the staged banner, because that banner depends on the second of them.
    //
    // Strictly `=== true`: absent in every state file written before this existed, and it takes the
    // primary button off the screen, so nothing unexpected may switch it on.
    var imageBased = usable && state.image_based === true;
    var imageBasedMessage = imageBased ? COPY.imageBased + "\n" + COPY.imageBasedUse : "";

    // Guarded the same way, and both halves or neither: "a Fedora  upgrade" with a hole where the
    // number goes is worse than saying nothing at all.
    var relUp = (usable && state.release_upgrade && typeof state.release_upgrade === "object")
        ? state.release_upgrade : null;
    var relTo = (relUp && typeof relUp.to === "string") ? relUp.to : "";
    var relFrom = (relUp && typeof relUp.from === "string") ? relUp.from : "";
    var releaseUpgrade = (relTo !== "" && relFrom !== "");
    // WHICH of the three states it is in, and the sentence turns on it. `armed` is the only one a
    // restart installs; `downloaded` is where `dnf5 system-upgrade download` leaves one, and where
    // a box can sit for days; `stranded` is `ready` with the boot symlink gone, which a restart has
    // already walked past. Anything this file does not recognise - including a state file from a
    // CLI that published no state at all - reads as `downloaded`, the one that promises nothing.
    var REL_STATES = ["armed", "stranded", "incomplete", "downloaded", "foreign"];
    var relState = (releaseUpgrade && REL_STATES.indexOf(relUp.state) >= 0)
        ? relUp.state : "downloaded";
    // What a run started now would ACTUALLY do, which decides whether "updating now" is a thing
    // this box can do at all. Unstated reads as terminal, the CLI's own fallback.
    var runSurface = resolveSurface(typeof opts.surface === "string" ? opts.surface : "");
    var stagesByDefault = (runSurface === "offline");
    var flatpakPending = usable && backendActionable(state, "flatpak") > 0;
    var updateButton = updateButtonOf(
        typeof opts.configuredSurface === "string" ? opts.configuredSurface : runSurface,
        usable ? backendActionable(state, "dnf") : 0, flatpakPending);
    var releaseUpgradeMessage = !releaseUpgrade ? ""
        : (relState === "armed"      ? COPY.releaseUpgradeStaged.replace("%1", relTo)
         : relState === "stranded"   ? COPY.releaseUpgradeStranded.replace("%1", relTo)
         : relState === "incomplete" ? COPY.releaseUpgradeIncomplete.replace("%1", relTo)
         : relState === "foreign"    ? COPY.releaseUpgradeForeign.replace("%1", relTo)
                                     : COPY.releaseUpgradeReady.replace("%1", relTo))
          + " " + COPY.releaseUpgradeNoStage
          + " " + (stagesByDefault ? COPY.releaseUpgradeNoRoute : COPY.releaseUpgradeLiveStillWorks);

    var heldDnf = false;
    for (var h = 0; h < counted.heldItems.length; h++) {
        if (counted.heldItems[h].backend === "dnf") { heldDnf = true; break; }
    }
    // A stored release upgrade means Kempt's own staged transaction is not the one dnf5 has: there
    // is ONE slot, and a transaction whose target release differs from the system's cannot be one
    // Kempt built. A current CLI stops publishing offline_staged in that state; this handles a file
    // an older one wrote, and it is what stops the popup showing both banners - the second of which
    // tells the reader to press a Rebuild button the first has just taken away.
    var stagedVariant = stagedVariantOf(
        (usable && !releaseUpgrade) ? state.offline_staged : null, heldDnf);
    var stagedMessage = stagedVariant.message;
    var staged = stagedMessage !== "";
    // A stage another updater's restart stands in front of (COPY.stageBlocked). It borrows the
    // staged slot as a warning and offers none of its actions: no restart (the restart installs the
    // other update), no rebuild (it would land behind the same symlink), and no discard (the CLI
    // refuses one, since dnf5 offline clean would cancel the other update too). An object is all
    // that is read: the sentence needs neither the count nor the stamp.
    var stageBlocked = usable && !releaseUpgrade && !staged && !imageBased
        && !!state.offline_stage_blocked && typeof state.offline_stage_blocked === "object"
        && !isArray(state.offline_stage_blocked);
    // The flip, in one boolean. Everything downstream reads THIS rather than re-testing the
    // variant, so "which banner is this" is decided in exactly one place.
    var stagedWarning = stagedVariant.type === "warning";

    // What to DO about a session-critical set, which is a different question from how big it is.
    // Silent while a transaction is already staged: this message IS the "Install on Next Restart"
    // offer, and offering it over an armed transaction invites a second staging of the same
    // updates. riskySummary is deliberately NOT silenced - those packages really are still pending
    // until the restart runs.
    // isArray, not a duck-typed length check: a STRING has a numeric length and indexes into its
    // own characters, so `risky_pending: "kernel-core"` would walk out of here as "11
    // session-critical pending (c, e, k, l, ...)".
    // The recommendation is only printable where the route it recommends exists. Where it does not,
    // the summary sentence stands in - it states the risk and advises nothing, which is the honest
    // half to keep.
    var noOfflineRoute = releaseUpgrade || imageBased;
    // ...and on a box Kempt cannot update AT ALL, the risk is not the widget's to raise: no button
    // it offers can act on it, dnf's view is not what installs there, and a second message under
    // the one saying so would be a count with nowhere to go. The release-upgrade case is the
    // opposite - the live button stays on screen, so the warning has to stay with it.
    var riskyIsMoot = imageBased;
    var riskyPending = usable && isArray(state.risky_pending) ? state.risky_pending : [];
    // Where the offline route exists, the recommendation - what to DO about a kernel. Where it does
    // not, the summary, which states the same risk and advises nothing. Silence was the wrong third
    // option: it took the warning off the screen while the live button stayed on it.
    var riskyMessage = (staged || riskyIsMoot) ? ""
        : (noOfflineRoute ? riskySummaryOf(riskyPending) : riskyMessageOf(riskyPending));
    // Whether Update Now asks before it runs: a risky set, a route to the next restart, and a run
    // that would install it live with nobody asked. A terminal asks for itself, and the offline
    // surface already is the next restart.
    var updateAsksFirst = riskyMessage !== "" && !noOfflineRoute
        && (runSurface === "popup" || runSurface === "background");
    var riskyChoice = opts.riskyChoiceOpen === true && updateAsksFirst && !updating;

    // The one offer of the popup default. The CLI publishes surface_offer only while updates run
    // in the terminal; the configured surface is checked again here because a choice made in
    // Settings reaches this file before the next check does. With confirmation on, the popup
    // cannot run updates, so the offer would change nothing.
    var surfaceOffer = usable && state.surface_offer === true && !updating
        && opts.surfaceOfferAnswered !== true
        // Not before the widget has read the setting: until then its surface is only the default.
        && opts.surfaceKnown !== false
        && resolveSurface(typeof opts.configuredSurface === "string" ? opts.configuredSurface : "")
            === "terminal"
        && isTrue(opts.autoAccept === undefined ? true : opts.autoAccept);
    // The one offer to turn off Discover's notifier. The CLI publishes discover_offer while the
    // notifier starts with the session and nobody has answered. One offer at a time: it waits
    // while the surface offer is showing, and while the surface offer is still undecided because
    // the setting is unread, or it would show and then give way under the pointer. It also waits
    // for the widget to read the CLI's answered marker, which a state.json from before the answer
    // does not reflect.
    var discoverOffer = usable && state.discover_offer === true && !updating
        && opts.discoverOfferAnswered !== true && opts.discoverAnswerKnown !== false
        && !surfaceOffer && !(state.surface_offer === true && opts.surfaceKnown === false);

    // Strictly the boolean, and only out of a state this build can read. In this schema `false`
    // means "nothing to say", NEVER "no restart needed": backends/dnf.sh's dnf_reboot_needed
    // answers false plus a warning whenever it could not work the verdict out - rc 1 with empty
    // stdout (a cold user cache, the DEFAULT on a fresh install) and every unexpected rc land
    // there. So a false is indistinguishable from "we could not tell", and nothing renders an
    // affirmative from it. docs/architecture.md states the same rule for every reader.
    // Derived up here rather than with the restart message below, because the panel tooltip reads
    // it too.
    var rebootNeeded = usable && state.reboot_needed === true;

    // The security block, and whether the panel icon asks for attention: a set with an advisory
    // nobody has seen in the popup yet (the CLI's `attention`), and only while there is something
    // to press. Not while a stage is armed (the person already chose to install them), nor during
    // an update, nor without an engine to acknowledge the set with.
    var security = securityOf(usable ? state : null);
    var needsAttention = security.attention && !staged && !updating && !noEngine;

    var tooltipMain, headerText;
    if (updating) {
        tooltipMain = COPY.updatingHere;
        headerText = COPY.updatingHere;
    } else if (noEngine) {
        // Names the state instead of quoting the shell: `sh: line 1: kempt: command not found` is
        // true, unreadable, and about a program the reader has never heard of.
        headerText = engineFault === "missing"
            ? "Kempt's engine is not installed"
            : "Kempt's engine will not run";
        // The header is the tooltip's title, and COPY.engineMissing or COPY.engineUnrunnable under
        // it carries on from it rather than repeating it.
        tooltipMain = headerText;
    } else if (iconState === "unknown") {
        tooltipMain = "Kempt";
        headerText = "No update data yet";
    } else if (iconState === "error") {
        tooltipMain = (cliError !== "" || neverAnswered)
            ? COPY.checkFailedTooltip : COPY.stateUnreadableTooltip;
        headerText = (cliError !== "" || neverAnswered)
            ? "Kempt cannot check for updates"
            : "Could not read the update state";
    } else if (staged) {
        // The one place the count gives way. Not a second line under it and not a badge emblem:
        // the header is the sentence a person reads first, and while a stage is armed the honest
        // answer to "where do I stand" is that the work is done and waiting for a restart.
        headerText = stagedHeaderOf(state.offline_staged);
        tooltipMain = headerText;
    } else {
        tooltipMain = countPhrase;
        headerText = countPhrase;
    }

    var lastSuccessText = usable ? formatStamp(state.last_success) : "";
    var staleReason = stale
        ? (typeof state.error === "string" && state.error !== "" ? state.error : "the last check failed")
        : "";

    // The one sentence an error state owes the user, in descending order of how much it knows.
    // A failed check is said in plain words, with the tool's own line kept as the detail.
    var problemText = "", problemDetail = "", problemNetwork = false, problemNoCache = false;
    var problemHint = "";
    if (iconState === "error") {
        var problemRaw = cliError !== "" ? cliError                  // we could not run the CLI
            : (neverAnswered ? staleReason : "");                    // it ran, and told us why not
        if (problemRaw !== "") {
            var problem = checkProblemOf(problemRaw, usable && !!state.backends
                && !!state.backends.dnf ? state.backends.dnf.refresh_error : undefined,
                usable ? state.refresh_skipped : undefined);
            problemText = problem.headline;
            problemDetail = problem.detail;
            problemNetwork = problem.network;
            problemNoCache = problem.noCache;
            problemHint = problem.hint;
        } else {
            problemText = "the update state could not be read";      // it answered something else
        }
    }

    // The whole answer for a box with no working engine, assembled here so the popup binds one
    // string: what is true, then what to do about it. Empty in every other state, which is what
    // the popup gates on - and the same for the clipboard text and its button label, which only
    // exist while the message does.
    var engineFaultMessage = "", engineFaultCopyText = "", engineFaultActionLabel = "";
    if (engineFault === "missing") {
        engineFaultMessage = COPY.engineMissing + "\n" + COPY.engineMissingInstall;
        engineFaultCopyText = COPY.engineMissingCopy;
        engineFaultActionLabel = COPY.engineCopyCommands;
    } else if (engineFault === "unrunnable") {
        engineFaultMessage = COPY.engineUnrunnable + "\n" + COPY.engineUnrunnableFix;
        engineFaultCopyText = COPY.engineUnrunnableCopy;
        engineFaultActionLabel = COPY.engineCopyCommand;
    }
    // Check Installation only where kempt is there to run. A missing engine has no doctor.
    var engineFaultOffersDoctor = engineFault === "unrunnable";

    // Read only out of a state this build can read, like every optional key: a schema-1 reader
    // tolerates the key being absent (every file written before this existed) and being the wrong
    // type. formatDownload answers "" to both. Nothing while a stage is armed: its packages are
    // already downloaded, and "to download" beside them is false.
    var downloadText = usable && !staged ? formatDownload(state.download_bytes) : "";

    var subParts = [];
    // The fact, and only the fact. The install commands belong in the popup, where they can be
    // read and copied; two command lines under a panel hover is noise.
    if (engineFault === "missing") subParts.push(COPY.engineMissing);
    else if (engineFault === "unrunnable") subParts.push(COPY.engineUnrunnable);
    else if (iconState === "unknown") subParts.push("no data until the first check finishes");
    else if (iconState === "error") {
        // A short reason, never the tool's stderr: the popup has that in small print.
        subParts.push(problemNetwork ? COPY.checkNetworkShort
            : (problemDetail !== "" ? COPY.checkFailedShort : problemText));
    }
    else {
        // What is pending, by name - the count says how many, this says what. Not while a stage
        // is armed: the header already says the work is done and waiting for a restart.
        var pendingNames = staged ? "" : pendingNamesOf(counted.sections, riskyPending);
        if (pendingNames !== "") subParts.push(pendingNames);
        // ...and how many of them fix a security advisory. Not while a stage is armed, like the
        // names: the work is done and waiting for a restart.
        if (!staged && security.count > 0) {
            subParts.push(security.count === 1 ? COPY.securityCountOne
                                               : fill(COPY.securityCount, "%1", security.count));
        }
        // The Holds promise: a box whose only pending updates are held LOOKS up to date, and the
        // tooltip is where it still says the held ones exist.
        // Not when the tooltip title already ends in it ("Up to date · 10 held").
        if (heldTotal > 0 && tooltipMain.indexOf(heldTotal + " " + COPY.held) < 0) {
            subParts.push(heldTotal + " " + COPY.held);
        }
        // Only with something to download AND something to press. On an up-to-date box the number
        // is zero or absent; next to a held-only list it would describe bytes no run will fetch.
        if (actionable > 0 && downloadText !== "") subParts.push(downloadText + " to download");
        // Staleness is a tooltip fact, not an icon alarm, so the tooltip carries BOTH halves: what
        // went wrong, and how old the numbers above it therefore are.
        if (stale) {
            subParts.push(staleReason);
            subParts.push(everSucceeded
                ? fill(COPY.lastSuccessfulCheck, "%1", relativeTime(state.last_success, opts.nowMs))
                : COPY.noSuccessfulCheckYet);
        }
        if (userUnchecked) subParts.push(COPY.userAppsUncheckedShort);
        // A pending restart is the one fact needing an action from the person; without this line
        // it could only be found by opening the popup. Last, because it is about the machine
        // rather than about the counts above it.
        if (rebootNeeded) subParts.push(COPY.restartPending);
    }

    // What the popup shows where the list would be, when there is no list to show.
    var emptyStateText = "";
    if (updating) emptyStateText = "";
    // Silent, and that silence keeps the popup from saying one thing twice: the engine-missing
    // message already carries the whole answer, and the placeholder's own sentence ("the first
    // check has not finished") would be a promise about a check that will never finish. The
    // placeholder hides itself on empty text.
    else if (noEngine) emptyStateText = "";
    else if (iconState === "unknown") emptyStateText = "No update data yet. The first check has not finished.";
    else if (iconState === "error") emptyStateText = problemText;
    else if (nothingKnown) {
        emptyStateText = stale ? "No updates in the last known state."
            : (userUnchecked ? COPY.userAppsUnchecked : COPY.everythingUpToDate);
    }

    // The one thing a stuck user can usefully be told to type - offered ONLY where the widget has
    // nothing else to show. NOT on calm staleness: keeping quiet about a repo that flapped is the
    // point of that state, and staleReason already names doctor when that is what is wrong. NOT
    // when there is no working engine either, which is the case that proves the rule: `kempt
    // doctor` is a kempt subcommand, so on the box where kempt is what is absent this would tell
    // the user to run the very thing they do not have. Those states carry their own message, which
    // says the right thing for each.
    // ...and not for a network failure or missing package lists either: nothing in the
    // installation is wrong, and doctor would say so.
    var remedyCommand = (!noEngine && (cliError !== "" || neverAnswered) && !problemNetwork
                         && !problemNoCache) ? "kempt doctor" : "";

    // --- the restart, and what the popup is allowed to say about it -----------------------------
    // `rebootNeeded` itself is derived above, next to the tooltip that reads it.
    // Absent is not false: the caller simply did not say, and the CLI's default is true.
    var restartReminder = (opts.restartReminder === undefined || opts.restartReminder === null)
        ? true : isTrue(opts.restartReminder);
    var restartMessageVisible = rebootNeeded && restartReminder && !isTrue(opts.restartDismissed);

    // --- unused Flatpak runtimes ------------------------------------------------------------------
    var reclaim = usable ? state.reclaim : null;
    var reclaimMessage = reclaimMessageOf(reclaim);
    var reclaimDigest = reclaimMessage !== "" ? reclaim.digest : "";
    var reclaimLines = [];
    if (reclaimMessage !== "") {
        var reclaimRefs = arrayOf(reclaim.refs);
        for (var r = 0; r < reclaimRefs.length; r++) {
            var refLine = reclaimRefLineOf(reclaimRefs[r]);
            if (refLine !== "") reclaimLines.push(refLine);
        }
    }
    var reclaimShown = reclaimMessage !== "" && opts.reclaimDismissed !== reclaimDigest;

    // --- which messages actually fit ------------------------------------------------------------
    // Decided HERE and not in the popup, because the footer depends on the answer: a restart the
    // cap displaced has to reappear as "restart pending" on the status line, and a popup deciding
    // this by itself would leave logic.js unable to tell whether it had.
    // `reportShown` is the one input this file cannot derive - the post-run line and a failed press
    // are main.qml's own state, not the CLI's.
    // A Check for Updates whose fetch did not land. Shown until the next check, whoever starts it, or
    // its close button (opts.fetchMissedDismissed).
    var fetchMissedMessage = usable && !updating && !noEngine
        ? fetchMissedOf(state, opts.refreshAskedMs, opts.refreshCheckStamp) : "";
    var messageSlots = messageStack({
        engineFault: engineFaultMessage !== "",
        // ...and while a blocked stage is up, a report saying the stage installs on the next restart
        // is the very promise that warning takes back, so it gives way the same way.
        report: opts.reportShown === true
            && !((staged || stageBlocked) && opts.reportRepeatsStaged === true),
        fetchMissed: fetchMissedMessage !== "" && opts.fetchMissedDismissed !== true,
        // Check Installation's result, or its busy line: main.qml's own state, like the report.
        // Never hidden with a report that repeats the staged message: it says something else.
        doctor: opts.doctorShown === true && !updating,
        // ...including `updating`, because a run hides the whole stack. Without it the popup's own
        // dismissal guard could not tell a run starting from the user closing the message.
        restart: restartMessageVisible && !updating,
        staged: staged || stageBlocked,
        // Above everything except a report of something that just happened: it is the one message
        // that says what this machine is, and every other message here presumes a box Kempt can
        // update. The kernel message is not displaced here but SILENCED (riskyIsMoot above): with
        // no button of any kind on offer, a count of session-critical packages has nowhere to go.
        imageBased: imageBasedMessage !== "",
        releaseUpgrade: releaseUpgradeMessage !== "",
        // The kernel message RECOMMENDS installing on the next restart, which a stored release
        // upgrade does not allow - so what is shown there is the summary instead: the same fact,
        // without the advice. Dropping it entirely took the warning off the screen while the live
        // button stayed on it, which is the wrong half to lose. On an image-based box there is no
        // live button either, and riskyIsMoot silences it outright.
        // ...and while the choice is open the same message is in the first slot instead, so it is
        // never drawn twice.
        kernel: riskyMessage !== "" && !riskyChoice,
        riskyChoice: riskyChoice,
        surfaceOffer: surfaceOffer,
        discoverOffer: discoverOffer,
        reclaim: reclaimShown && !updating
    });
    var restartShown = messageSlots.indexOf("restart") >= 0;

    // --- the footer status line ------------------------------------------------------------------
    // "Checked ..." is derived from last_success and NOT last_check, because the counts above it
    // are as of the last check that told us something; dating them by a failed check would put a
    // fresh time on stale numbers. The fallback is worded off last_success too: this line is a
    // DATELINE for the counts, and "Not checked yet" would conflate "no counts of any age" with a
    // box that never ran a check - the two differ precisely on the bad day, where a stale state
    // carries a last_check and an empty last_success.
    var footerParts = [];
    if (usable) {
        // Three answers, and the third is silence. A stamp that is present and unreadable gives
        // relativeTime nothing to work with, so it hands the text back verbatim - right for a
        // tooltip, wrong in a sentence, where it reads "Checked not a date". The raw stamp stays
        // one hover away in footerTooltip.
        if (!everSucceeded) footerParts.push(COPY.noSuccessfulCheckYet);
        else if (isRenderableStamp(state.last_success)) {
            footerParts.push("Checked " + relativeTime(state.last_success, opts.nowMs));
        }
        // ...and the staleness, beside the date it explains. Not an alarm - the counts above are
        // still the best known truth - with the CLI's reason one hover away on the retry button.
        if (stale) footerParts.push(COPY.lastCheckFailed);
        if (userUnchecked) footerParts.push(COPY.userAppsUncheckedShort);
        // ...and how old the metadata behind those counts is, which the dateline above cannot say.
        // The two are different clocks: the check ran four minutes ago, the metadata it answered
        // from may be a week old, and only this line can tell the person that.
        var metaAge = metadataAgeText(state.metadata_refreshed, opts.nowMs,
                                      refreshMissed(state, opts.refreshAskedMs) ? 60000 : undefined);
        // ...unless the notice above is saying it already.
        if (metaAge !== "" && messageSlots.indexOf("fetchMissed") < 0) footerParts.push(metaAge);
    } else if (noState) {
        // No state at all - the first seconds of a session, or a CLI that could not be run. There
        // has been no successful check as far as this widget knows, and saying so is true.
        footerParts.push(COPY.noSuccessfulCheckYet);
    }
    // ...and the case with no branch: a state we HOLD and cannot read (a schema this build does
    // not know). It may well record a successful check; we cannot tell, and the header already
    // says the state could not be read.
    if (heldTotal > 0) footerParts.push(heldTotal + " " + COPY.held);
    // Beside Update Now, which is the question it answers: pressing this costs about this much.
    // Same two conditions as the tooltip, and the same silence when either fails.
    if (actionable > 0 && downloadText !== "") footerParts.push(downloadText);
    // ...and the restart, whenever the message is not carrying it - including one the CAP
    // displaced, which is what makes displacing it honest rather than merely quiet. With the
    // reminder off, or dismissed for this session, this line is the only place it is said.
    if (rebootNeeded && !restartShown) footerParts.push(COPY.restartPending);

    // What Check for Updates says out loud when it lands, in the words already on screen. ONE
    // sentence for both places that can speak it (the panel icon while the popup is closed, the
    // popup while it is open), so the two cannot drift apart.
    //   * the line at the top, which is the answer: "3 updates available", "Up to date", or that
    //     the engine is missing or will not run.
    //   * a check that failed: which half failed and how old the counts are (staleAnswerOf). The
    //     counts at the top are the old ones, and reading them out as the answer would be the
    //     wrong news.
    //   * a check whose fetch did not happen (battery, metered, offline): the top line plus the age
    //     the footer gives, because "Up to date" from old lists is not what the person asked for.
    //   * a check that answered nothing over a state we hold: the report main.qml put on screen
    //     for it (opts.checkUnfinished), since the counts at the top did not change.
    var checkAnswerText = headerText;
    var checkUnfinished = typeof opts.checkUnfinished === "string" ? opts.checkUnfinished : "";
    if (!updating && !noEngine && checkUnfinished !== "") checkAnswerText = checkUnfinished;
    else if (!updating && !noEngine && usable) {
        if (stale) checkAnswerText = staleAnswerOf(state, opts.nowMs);
        else if (fetchMissedMessage !== "") checkAnswerText = headerText + ". " + fetchMissedMessage;
        else if (metaAge !== "" && refreshMissed(state, opts.refreshAskedMs)) {
            checkAnswerText = headerText + ". " + metaAge.charAt(0).toUpperCase() + metaAge.slice(1);
        }
    }

    return {
        iconState: iconState,
        badgeText: badgeText,
        badgeVisible: badgeText !== "",
        tooltipMain: tooltipMain,
        tooltipSub: subParts.join(DOT),
        headerText: headerText,
        sections: counted.sections,
        heldItems: counted.heldItems,
        rows: rowsOf(counted.sections, counted.heldItems),
        actionable: actionable,
        heldTotal: heldTotal,
        stale: stale,
        // "" when fine; otherwise the CLI's own error text, so the popup says what actually went
        // wrong instead of a generic apology.
        staleReason: staleReason,
        cliError: cliError,
        // The fact, then what to do about it, on two lines. Empty means there is nothing to say,
        // and that empty string is the popup's only gate - exactly how riskyMessage and
        // stagedMessage already work. The other two follow it: the clipboard payload the button
        // copies, and the button's own label, which names how many commands that is.
        engineFaultMessage: engineFaultMessage,
        engineFaultCopyText: engineFaultCopyText,
        engineFaultActionLabel: engineFaultActionLabel,
        engineFaultOffersDoctor: engineFaultOffersDoctor,
        emptyStateText: emptyStateText,
        // The tool's own line under a plain emptyStateText, and whether it was a network failure.
        problemDetail: problemDetail,
        problemNetwork: problemNetwork,
        // The line under emptyStateText: what to do about it. Check Installation's when it is offered.
        problemHint: remedyCommand !== "" ? COPY.checkFailedHint
            : (problemNetwork || problemNoCache ? problemHint : ""),
        remedyCommand: remedyCommand,
        // isArray, not a duck-typed length check - see the riskyMessage derivation above for what
        // a string in this key otherwise renders as. These two must agree about the same key.
        riskySummary: riskySummaryOf(
            usable && isArray(state.risky_pending) ? state.risky_pending : []),
        riskyMessage: riskyMessage,
        // Update Now opens the risky choice instead of running (main.qml, startUpdate).
        updateAsksFirst: updateAsksFirst,
        stagedMessage: stageBlocked ? COPY.stageBlocked : stagedMessage,
        // A Check for Updates whose fetch did not land: why, and how old the lists are. Shown in
        // the "fetchMissed" slot. Empty when there is nothing to say.
        fetchMissedMessage: fetchMissedMessage,
        // Why that message may offer Download Anyway: "battery", "metered", or "" for no button.
        fetchMissedAnyway: fetchMissedMessage !== "" ? anywayReasonOf(state.refresh_skipped) : "",
        // The same for the placeholder over lists never downloaded: only under the battery and
        // metered hints, so never beside Check Installation or fetching turned off. A refresh
        // error from before is only the detail there (checkProblemOf).
        problemAnyway: usable && problemNoCache && remedyCommand === ""
            && (problemHint === COPY.checkNoCachePowerHint || problemHint === COPY.checkNoCacheMeteredHint)
            ? anywayReasonOf(state.refresh_skipped) : "",
        // What the banner shows: the plain one gives way to the header's count.
        stagedBanner: stageBlocked ? COPY.stageBlocked
            : stagedVariant.type === "warning" ? stagedMessage : (stagedVariant.banner || ""),
        // "there is an armed transaction", for the surfaces that have to stand down rather than
        // say something about it. Update Now is hidden on this: pressing it over an armed stage
        // starts a second, live update of the same packages.
        stagedArmed: staged,
        // The panel icon asks for attention (Plasma's NeedsAttentionStatus), and the digest the
        // popup passes to `kempt security-ack` when it is opened. "" whenever it does not ask.
        needsAttention: needsAttention,
        securityDigest: needsAttention ? security.digest : "",
        securityCount: security.count,
        // "positive" for the ordinary armed stage, "warning" once a hold has landed behind it. A
        // string rather than a boolean because the QML binds it to a Kirigami.MessageType, and a
        // third spelling is a plausible next state for this banner rather than an exotic one.
        stagedType: stageBlocked ? "warning" : stagedVariant.type,
        // The blocked stage above: in the staged slot, with no action of its own.
        stageBlocked: stageBlocked,
        // Never two Restart… buttons in one popup: the restart Warning already carries one
        // whenever it is on screen.
        // ...and never a Restart… on a warning variant at all, which is the stricter rule and the
        // reason the flip is worth anything: the person is looking at a sentence saying the next
        // restart will install the package they tried to keep out.
        stagedShowRestart: staged && !restartMessageVisible && !stagedWarning,
        // ...and what stands in its place. Only on the variants where there is something to
        // change: rebuilding an ordinary armed stage would destroy a good transaction to
        // produce the same one back.
        // ...and never where a stage is refused: a rebuild runs the same privileged verb, so it
        // would cancel a stored release upgrade exactly as a first stage would, and abort in
        // pre-flight on an image-based box exactly as a first stage would.
        stagedShowRebuild: stagedWarning && !noOfflineRoute,
        // ...and the way out that is neither a restart nor a rebuild: discard the staged update,
        // and let the next restart install nothing. Offered on BOTH banners, which is where it
        // differs from the rebuild: a rebuild only makes sense where there is something to change,
        // while "install nothing at all" is an answer to either one - and on a warning the person
        // has just said they did not want one of those packages, so it is the least surprising
        // button on that message. It is drawn LAST, so it stands beside the conflict remedy rather
        // than where the conflict remedy stands.
        // The guard is the rebuild's, for the rebuild's reason: `kempt unstage` refuses with exit
        // 5 while a Fedora release upgrade is stored (dnf5 has one slot, and discarding what is in
        // it would cancel the upgrade), so the button is not offered on a box the CLI would turn
        // down. Belt and braces on that path - a release upgrade already takes the whole banner
        // away - and the half that acts is the image-based one, where dnf is not how the machine
        // updates at all.
        stagedShowDiscard: staged && !noOfflineRoute,
        // Whether the popup may OFFER to stage at all. The CLI refuses the press; this is what
        // stops it being offered, so nobody has to press a button to be told no.
        // Both refusals land here: on an image-based system `kempt update` aborts in pre-flight
        // whatever surface it was asked for, so staging is no more available than updating.
        offlineStageOffered: !noOfflineRoute,
        releaseUpgradeMessage: releaseUpgradeMessage,
        // ...and the same for Update Now, which is the primary button. HIDDEN rather than
        // disabled, exactly as it is for a box with nothing pending: there is no action to offer
        // here, and a greyed primary button with its explanation elsewhere is a puzzle.
        // ...and not on a box whose Update Now IS the staging that is refused: with the run surface
        // set to offline, pressing it runs exactly the command the CLI turns down. Hidden rather
        // than left to fail, on the same rule as everything else here.
        updateOffered: !imageBased && !(releaseUpgrade && stagesByDefault),
        // The footer button's words. The QML writes both literals for i18n and picks one with
        // updateStages; the text and tooltip are published so a test can pin the pair.
        updateStages: updateButton.stages,
        updateButtonText: updateButton.text,
        updateButtonTooltip: updateButton.tooltip,
        stageTooltipNamesFlatpak: flatpakPending,
        imageBasedMessage: imageBasedMessage,
        // Published rather than left as a literal in the QML's Accessible.description, so the
        // words a screen reader hears and the words the tooltip shows are one decision. The QML
        // still writes the literal for i18n extraction; the probe ties the two together.
        stagedRebuildTooltip: COPY.stagedRebuildTooltip,
        // The stamp this banner was derived from, for main.qml's click-time re-verify. Consent is
        // given to a BANNER, and a banner describes ONE transaction: between render and click it
        // can be consumed by a restart, replaced or cleaned away, and a rebuild is destructive at
        // its start. "" means there is nothing to compare, which the re-verify reads as "do not
        // act".
        stagedStagedAt: stagedVariant.stagedAt,
        // The names behind the sentence. The banner shows the first and a count; anything that has
        // to say them again takes them from here rather than parsing them out of the sentence.
        stagedConflictNames: stagedVariant.conflictNames,
        lastSuccessText: lastSuccessText,
        rebootNeeded: rebootNeeded,
        restartMessageVisible: restartMessageVisible,
        // ...and whether that message may carry its own Restart button. Everywhere else it may: a
        // restart applies updates that are already installed. NOT while the staged banner is a
        // warning - in that state a restart installs the very package the warning says the person
        // tried to keep out.
        restartShowAction: restartShown && !stagedWarning,
        // Which messages the popup may draw, in order, and never more than two. The rule and its
        // reasons are messageStack above.
        messageSlots: messageSlots,
        // The reclaim offer: its line, one line per runtime for Show What, the digest the button
        // passes to `kempt reclaim --expect`, and which of the two button labels applies.
        reclaimMessage: reclaimMessage,
        reclaimLines: reclaimLines,
        reclaimDigest: reclaimDigest,
        reclaimAutomatic: reclaimMessage !== "" && reclaimAutoPending(reclaim),
        footerText: footerParts.join(DOT),
        checkAnswerText: checkAnswerText,
        // Published rather than left inside the two strings above, so a future surface (a
        // notification, a `check --human` line) renders the same words instead of its own.
        downloadText: downloadText,
        // The relative time in footerText is the convenience; this is the truth, and people
        // compare the two. Empty rather than "never" when there has been no successful check: the
        // footer already says so in words.
        footerTooltip: everSucceeded ? lastSuccessText : ""
    };
}

// The node half of the double life. `module` does not exist in QML's JS engine, so this is a
// no-op there; typeof on an undeclared name is safe in every engine.
if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        COPY: COPY,
        VERSION_UNKNOWN: VERSION_UNKNOWN,
        fromTextOf: fromTextOf,
        versionTextOf: versionTextOf,
        displayNameOf: displayNameOf,
        parseState: parseState,
        viewModel: viewModel,
        newestOf: newestOf,
        familiesOf: familiesOf,
        formatStamp: formatStamp,
        formatDownload: formatDownload,
        relativeTime: relativeTime,
        shouldRefreshOnOpen: shouldRefreshOnOpen,
        refreshMissed: refreshMissed,
        fetchMissedOf: fetchMissedOf,
        anywayReasonOf: anywayReasonOf,
        servedBeforePress: servedBeforePress,
        checkArgs: checkArgs,
        CHECK_BODY_MS: CHECK_BODY_MS,
        CHECK_TIMEOUT_MS: CHECK_TIMEOUT_MS,
        riskyMessageOf: riskyMessageOf,
        pendingNamesOf: pendingNamesOf,
        stagedMessageOf: stagedMessageOf,
        stagedVariantOf: stagedVariantOf,
        messageStack: messageStack,
        MESSAGE_CAP: MESSAGE_CAP,
        RECLAIM_MIN_BYTES: RECLAIM_MIN_BYTES,
        reclaimOffered: reclaimOffered,
        reclaimMessageOf: reclaimMessageOf,
        reclaimRefLineOf: reclaimRefLineOf,
        reclaimOutcomeOf: reclaimOutcomeOf,
        RECLAIM_TIMEOUT_MS: RECLAIM_TIMEOUT_MS,
        lastRunOf: lastRunOf,
        postRunLine: postRunLine,
        reportRepeatsStaged: reportRepeatsStaged,
        runFinishedSince: runFinishedSince,
        runStartMessage: runStartMessage,
        discardStagedMessage: discardStagedMessage,
        DOCTOR_TIMEOUT_MS: DOCTOR_TIMEOUT_MS,
        DOCTOR_SUMMARY_MAX: DOCTOR_SUMMARY_MAX,
        mentionsDoctor: mentionsDoctor,
        doctorOutcomeOf: doctorOutcomeOf,
        lastRunText: lastRunText,
        lastRunSubtitle: lastRunSubtitle,
        reclaimInUseOnScreen: reclaimInUseOnScreen,
        shellQuote: shellQuote,
        firstLineOf: firstLineOf,
        isExecutorTimeout: isExecutorTimeout,
        ANSWER_TIMEOUT_MS: ANSWER_TIMEOUT_MS,
        answerOutcomeOf: answerOutcomeOf,
        checkErrorOf: checkErrorOf,
        checkProblemOf: checkProblemOf,
        logTailOf: logTailOf,
        checkFailedOverOf: checkFailedOverOf,
        staleAnswerOf: staleAnswerOf,
        rowsOf: rowsOf,
        securityOf: securityOf,
        isTrue: isTrue,
        DEFAULT_SURFACE: DEFAULT_SURFACE,
        resolveSurface: resolveSurface,
        effectiveSurfaceOf: effectiveSurfaceOf,
        updateButtonOf: updateButtonOf,
        stageTooltipOf: stageTooltipOf,
        backendActionable: backendActionable,
        updatingLabelOf: updatingLabelOf,
        SURFACES: SURFACES,
        holdsOf: holdsOf,
        discoverSettingOf: discoverSettingOf,
        lastLinesOf: lastLinesOf,
        snapIconSize: snapIconSize,
        resolveIconSize: resolveIconSize,
        resolveIconSizeSetting: resolveIconSizeSetting,
        resolveReclaimSetting: resolveReclaimSetting,
        ICON_STEPS: ICON_STEPS,
        watchChange: watchChange,
        watchFieldsOf: watchFieldsOf,
        WATCH_FIELDS: WATCH_FIELDS,
        watcherCheckDue: watcherCheckDue,
        checkedSince: checkedSince,
        checkedAfterRun: checkedAfterRun,
        CHECK_QUIET_MS: CHECK_QUIET_MS
    };
}
