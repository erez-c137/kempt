# What Kempt promises

Each promise names a test that fails when the promise breaks. A row marked pending says what is not
kept yet and why. The pending parts show up as skips in the suite's summary.

| # | Promise | File | Case |
| --- | --- | --- | --- |
| 1 | Never install what was held or not asked for. | `test_update.sh` | `hold became --exclude`; `every pending app held → flatpak is not run at all, rather than run on all of them`; `abort runs no privileged command` |
| 2 | An update survives a closed terminal, a crashed widget or a dead plasmashell. **Partly pending:** see below. | `test_promises.sh`, `test_helpers.sh` | `...so killing that session leaves it running to the end`; `dnf-upgrade runs systemd-run` |
| 3 | Never show "Up to date" over a failed check. | `test_widget_logic.sh`, `test_status.sh` | `failed check, nothing waiting: says the check failed`; `status after a failed check: says so, no Up to date` |
| 4 | A failed run reads as failed, with the reason. | `test_widget_logic.sh`, `qml/probe_popup.py`, `test_other_updater.sh` | `...and so does any other failed run`; `...and the row left behind still says the update failed`; `status reads it as failed` |
| 5 | "Will this install on restart?" is answered truthfully, and "cannot tell" is a valid answer. **Partly pending:** see below. | `test_stage_unknown.sh`, `test_other_updater.sh` | `...and above all nothing was installed, as far as anyone says`; `...and stops saying staged` |
| 6 | Never arm, stage over or discard a Fedora upgrade or another program's stage by surprise. | `test_release_upgrade_states.sh`, `test_unstage.sh`, `test_other_updater.sh` | `...and staging over it is refused in pre-flight, changing nothing`; `a stored release upgrade refuses the unstage before anything is changed`; `...and answering s anyway never stages` |
| 7 | A non-admin gets no root. Helpers take no caller-chosen arguments. | `test_polkit.sh`, `test_helpers.sh` | `apply is auth_admin_keep`; `render refuses a template that lost the scope clause`; `apply: arm takes no arguments`; `apply: injection via exclude` |
| 8 | Warn before a risky live update. | `test_update.sh`, `test_check.sh` | `recommendation explains the risk`; `pending session-critical package is flagged` |
| 9 | Report other updaters. Never compete with them. | `test_other_updater.sh`, `test_widget_logic.sh` | `...and answering s anyway never stages`; `held, nothing staged: a banner in the staged slot` |
| 10 | Say when a restart is owed. | `test_status.sh`, `test_widget_logic.sh`, `qml/probe_popup.py` | `a restart owed has its line`; `a restart owed: the message shows`; `...and none of it is cut off` |
| 11 | Deleting the state folder costs at most one repeat notification. **Partly pending:** see below. | `test_promises.sh` | `deleting the state folder costs at most one notification` |

## Pending

**Promise 2, the closed terminal.** The test kills the session that started a detached update and
watches it finish. Closing a real terminal needs real systemd and a real window, so the suite only
checks that dnf5 starts as a service of its own.

**Promise 5, "cannot tell".** When dnf5's stored state cannot be read, Kempt keeps quiet and leaves
everything as it was. Only `kempt doctor` says so, and it gives the way to clear it. Saying "cannot tell"
anywhere else needs a message Kempt has yet to add.

**Promise 11, the armed stage.** The notification count holds. An armed stage drops off the screen
once the state folder is gone, because it is read from Kempt's own note and dnf5 is never asked.
The history of past runs goes with the folder as well.
