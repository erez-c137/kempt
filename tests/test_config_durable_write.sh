#!/usr/bin/env bash
# The durable write form the settings page dispatches: `<cmd> & wait $!`.
#
# What it is for. Plasma's configuration dialog runs OK as `applyAction.trigger();
# configDialog.close()` - the page's saveConfig() only DISPATCHES its writes, and the close that
# follows in the same turn destroys the page, its Executor and the DataSource behind it. The
# engine then deletes the KProcess nobody is connected to any more, and a KProcess destructor
# SIGKILLs its child: the `sh` running our `kempt config set`. The write is about 10 ms of work
# and the teardown is a couple of event-loop hops, so it is a race - and the founder lost it:
# a ticked box, OK, and `kempt config get auto_accept` still reading the old value.
#
# What this file proves, without a QML engine anywhere near it: a command written as
# `<cmd> & wait $!` survives a SIGKILL aimed at its shell, because the work is a background job
# and the shell is only waiting for it - while the plain form, killed at the same moment, loses
# the write entirely. The second half is the control. Without it this file could pass for the
# wrong reason (a kill that arrived after the write had already finished), which is exactly the
# shape of the bug being fixed.
#
# The command STRING the settings page builds is pinned separately, in tests/qml/probe_settings.py
# - that needs the real QML. This file pins the shell behaviour the string relies on.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# A deliberately slow `kempt`. The real one finishes in about 10 ms, which is why production is a
# race rather than a certainty - and a test whose kill lands after the write would prove nothing
# at all. The sleep puts the kill firmly INSIDE the write. exec, so the pid `$!` reports stays the
# pid doing the work.
SLOW="$TESTTMP/slow-kempt"
cat > "$SLOW" <<EOF
#!/usr/bin/env bash
sleep 1
exec "$KEMPT" "\$@"
EOF
chmod +x "$SLOW"

PIDFILE="$TESTTMP/jobpid"

# --- the durable form ---------------------------------------------------------------------------
# Exactly the shape page.durable() produces, plus the one addition a test needs: `echo $!` so the
# job's pid can be watched. `$!` is still the background job at that point, and still is at `wait`.
sh -c "$SLOW config set durable_key v1 & echo \$! > $PIDFILE; wait \$!" &
shpid=$!

# Wait for the FORK, not for a fixed interval: the pidfile appearing is the event, and a fixed
# sleep here would be the same guess this whole file exists to remove.
for _ in $(seq 1 200); do [[ -s "$PIDFILE" ]] && break; sleep 0.02; done
assert_exit 0 "the background job was forked" -- test -s "$PIDFILE"
jobpid="$(cat "$PIDFILE")"

# The SIGKILL the destroyed KProcess sends, aimed where it aims it: at the shell, by pid.
# Grouped with stderr closed only to swallow bash's own "Killed" job notice, which is this file
# working as intended and would otherwise read as a suite error.
shrc=0
{ kill -9 "$shpid"; wait "$shpid" || shrc=$?; } 2>/dev/null
assert_eq "$shrc" "137" "the shell died to SIGKILL, the way a destroyed KProcess kills it"
# Read immediately, while the job still has most of its second left to run: this is the claim.
jobalive=0; kill -0 "$jobpid" 2>/dev/null || jobalive=$?
assert_eq "$jobalive" "0" "...and the job it forked is still running, orphaned but alive"

# Bounded poll, then the only thing that actually matters: the value on disk.
for _ in $(seq 1 300); do kill -0 "$jobpid" 2>/dev/null || break; sleep 0.05; done
assert_eq "$("$KEMPT" config get durable_key)" "v1" \
  "the write landed after its shell was killed - this is the fix"

# --- the control: the same kill, without the durable form ---------------------------------------
# `sh -c '<compound>'` keeps a real shell in the middle (no exec optimisation), so the kill lands
# on the process that would have run the write, exactly as it does on a plain
# `sh -c 'kempt config set ...'` that has exec'd. Killing during the sleep is what makes it
# deterministic: the CLI has not been started yet and now never will be.
sh -c "sleep 1; $KEMPT config set durable_key v2" &
plainpid=$!
sleep 0.2
prc=0
{ kill -9 "$plainpid"; wait "$plainpid" || prc=$?; } 2>/dev/null
assert_eq "$prc" "137" "the control's shell died the same way"
assert_eq "$("$KEMPT" config get durable_key)" "v1" \
  "...and its write never landed, so the assertion above is not passing by luck"

# --- the exit status the page's rc handling depends on ------------------------------------------
# `wait $!`, not a bare `&`: setIfChanged reads rc to decide whether to keep Apply lit and what to
# put in the error label. A form that always answered 0 would report every failed write as saved.
# The trailing `#kemptN` is Executor's dedup tag, appended after the command - `#` opens a word
# here, so sh reads it as a comment, and this proves that has not changed under `&`.
rc=0; sh -c "$KEMPT config set durable_ok yes & wait \$! #kempt1" || rc=$?
assert_eq "$rc" "0" "a successful durable write exits 0, tag and all"
assert_eq "$("$KEMPT" config get durable_ok)" "yes" "...having written the value"
rc=0; sh -c "$KEMPT config set BAD-KEY x & wait \$! #kempt2" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a refused durable write propagates the CLI's own exit status, not the shell's"

finish
