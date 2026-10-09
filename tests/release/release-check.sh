#!/usr/bin/env bash
# What a RELEASE is checked against: the packages, installed on a machine that has never seen
# Kempt, exercised the way a person meets them, then removed.
#
# This is not the test suite. The suite proves the code; this proves the PACKAGE - that the spec
# puts the files where Plasma looks, that the widget QML the package installed actually runs (every
# probe elsewhere executes the checkout, which is a different directory), that a first-time user
# gets sensible answers, and that `dnf remove` leaves nothing behind but their own settings.
#
# It INSTALLS AND REMOVES packages and creates users, so it refuses to run anywhere but in a
# throwaway container. tests/release/run-release-check.sh builds one and calls this.
#
# Version-agnostic on purpose: an earlier copy of this script hardcoded a release nine times, went
# a version out of date the week it was written, and was never run again.
set -u
[[ "${KEMPT_RELEASE_CONTAINER:-}" == "1" ]] || {
  echo "refusing to run: this installs and removes packages and creates users." >&2
  echo "run it through tests/release/run-release-check.sh, which builds a throwaway container." >&2
  exit 2; }

SRC="${KEMPT_SRC:-/src}"
VER="$(head -1 "$SRC/VERSION" | tr -d '[:space:]')"
[[ -n "$VER" ]] || { echo "no VERSION in $SRC" >&2; exit 2; }

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "     got: $2"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "'$2' (expected '$3')"; }
sec() { echo; echo "=== $* ==="; }

echo "release check for $VER, from $SRC"

sec "build the release artifacts"
dnf -y -q install rpm-build rpmdevtools appstream jq util-linux-core createrepo_c >/dev/null 2>&1
id builder >/dev/null 2>&1 || useradd -m builder
id alice   >/dev/null 2>&1 || useradd -m alice
dnf -y -q install $(rpmspec -q --buildrequires "$SRC/kempt.spec" | tr '\n' ' ') >/dev/null 2>&1
# The tarball the spec expects, built from the tree under test rather than downloaded: this checks
# THIS source, which is the whole point of running it before a tag exists.
install -d /tmp/pack/"kempt-$VER"
tar -C "$SRC" --exclude=.git --exclude=internal -cf - . | tar -xf - -C /tmp/pack/"kempt-$VER"
tar -C /tmp/pack -czf "/tmp/kempt-$VER.tar.gz" "kempt-$VER"
chown builder "/tmp/kempt-$VER.tar.gz"
su - builder -c "rpmdev-setuptree && cp /tmp/kempt-$VER.tar.gz ~/rpmbuild/SOURCES/ && cp $SRC/kempt.spec ~/rpmbuild/SPECS/ && rpmbuild -bb ~/rpmbuild/SPECS/kempt.spec > /tmp/b.log 2>&1" \
  && ok "the package builds, test suite and all" \
  || { bad "the package does not build"; su - builder -c 'grep -n "^FAIL\|error:" /tmp/b.log | head -10'; exit 1; }
mkdir -p /localrepo && cp /home/builder/rpmbuild/RPMS/noarch/*.rpm /localrepo/ && createrepo_c -q /localrepo
printf '[local]\nname=local\nbaseurl=file:///localrepo\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/local.repo

sec "the built package, linted"
# rpmlint, with the warnings docs/RELEASING.md describes as known filtered out: package-with-huge-docs
# (the guides are the point of the package), no-documentation on the widget package (its licence is
# its only file; the guides ship with the CLI) and setlocale (depends on the build shell). An
# error, or any OTHER warning, fails; it is read before it is waved through.
RPMFILE=$(ls /localrepo/kempt-[0-9]*.noarch.rpm | head -1)
dnf -y -q install rpmlint man-db groff-base >/dev/null 2>&1
if command -v rpmlint >/dev/null 2>&1; then
  lint="$(rpmlint /localrepo/*.rpm 2>&1)"
  is "rpmlint reports no errors" "$(grep -c ': E: ' <<<"$lint")" "0"
  other="$(grep ': W: ' <<<"$lint" | grep -vE 'package-with-huge-docs|no-documentation|setlocale' || true)"
  [[ -z "$other" ]] && ok "...and no warning beyond the known ones" || bad "rpmlint has an unlisted warning" "$other"
else
  echo "note: rpmlint could not be installed, so the package was NOT linted"
fi
is "the package ships no configuration file, so there is no .rpmnew case" \
   "$(rpm -qcp "$RPMFILE" | wc -l)" "0"
if command -v man >/dev/null 2>&1; then
  mw="$(MANWIDTH=80 man --warnings -l "$SRC/docs/man/kempt.1" 2>&1 >/dev/null)"
  [[ -z "$mw" ]] && ok "man kempt renders with no warnings" || bad "the man page renders with warnings" "$(head -3 <<<"$mw")"
else
  echo "note: man could not be installed, so the man page render was NOT checked"
fi

sec "the Flatpak listing's dependencies come only with flatpak"
# Asked of the transaction dnf would run (--assumeno), before anything is installed. Weak
# dependencies are off, or the Recommends on flatpak would bring it in on both sides.
# libexec/kempt-flatpak-unused needs PyGObject and the Flatpak typelib in flatpak-libs.
tx_names() { dnf --assumeno --setopt=install_weak_deps=False install "$@" 2>&1 | awk '/^ [^ ]/ { print $1 }'; }
tx_without="$(tx_names kempt)"
tx_with="$(tx_names kempt flatpak)"
grep -qx kempt <<<"$tx_without" && grep -qx flatpak <<<"$tx_with" \
  && ok "dnf resolves kempt with and without flatpak" \
  || bad "dnf did not resolve the kempt transactions" "$(tail -3 <<<"$tx_with")"
for dep in python3-gobject-base flatpak-libs; do
  if rpm -q "$dep" >/dev/null 2>&1; then
    echo "note: the image already has $dep, so its place in the transaction was NOT checked"
    continue
  fi
  grep -qx "$dep" <<<"$tx_without" && bad "$dep is installed without flatpak" || ok "$dep stays out without flatpak"
  grep -qx "$dep" <<<"$tx_with" && ok "...and comes with flatpak" || bad "$dep does not come with flatpak"
done

sec "a Plasma user installs the widget package"
dnf -y --setopt=tsflags= install kempt-plasmoid > /tmp/i.log 2>&1 \
  && ok "kempt-plasmoid installs" || { bad "install failed"; tail -5 /tmp/i.log; exit 1; }
is "the CLI came with it" "$(rpm -q --qf '%{VERSION}' kempt)" "$VER"
is "and the widget is the same version" "$(rpm -q --qf '%{VERSION}' kempt-plasmoid)" "$VER"
is "nothing is left unowned: rpm verifies both packages" "$(rpm -V kempt kempt-plasmoid >/dev/null 2>&1 && echo clean || echo dirty)" "clean"

sec "Plasma can find the installed widget"
PDIR=/usr/share/plasma/plasmoids/io.github.erez_c137.kempt
[[ -f "$PDIR/metadata.json" ]] && ok "the applet is at the system path" || bad "no metadata.json at $PDIR"
is "...declaring the id Plasma loads it by" "$(jq -r '.KPlugin.Id' $PDIR/metadata.json)" "io.github.erez_c137.kempt"
is "...at the released version" "$(jq -r '.KPlugin.Version' $PDIR/metadata.json)" "$VER"
is "...as a tray applet, which is what makes it appear without being added by hand" \
   "$(jq -r '.KPlugin.Category' $PDIR/metadata.json)" "System Information"
ls /usr/share/plasma/plasmoids/ 2>/dev/null | grep -q '^io.github.erez_c137.kempt$' \
  && ok "it sits in the system applet directory, beside Plasma's own" \
  || bad "the applet is not in /usr/share/plasma/plasmoids"
[[ ! -e /root/.local/share/plasma/plasmoids/io.github.erez_c137.kempt ]] \
  && ok "...and NOT in a user directory, where it would shadow every future package update" \
  || bad "a user-scope copy exists and would shadow the packaged one"

sec "the root helpers, as the package installed them"
for h in kempt-refresh kempt-apply; do
  is "$h runs bash in privileged mode" "$(head -1 /usr/libexec/$h)" "#!/usr/bin/bash -p"
  is "...owned by root, not group or world writable" \
     "$(stat -c '%U:%G %a' /usr/libexec/$h)" "root:root 755"
done
for pair in kempt-refresh:/usr/libexec/kempt-refresh kempt-apply:/usr/libexec/kempt-apply \
            kempt-flatpak-unused:/usr/share/kempt/libexec/kempt-flatpak-unused; do
  is "${pair%%:*} is byte-for-byte the repo's" \
     "$(sha256sum < "${pair#*:}")" "$(sha256sum < "$SRC/libexec/${pair%%:*}")"
done
[[ -f /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy ]] \
  && ok "the polkit policy is installed" || bad "no polkit policy"
is "...declaring both actions, refresh and apply" \
   "$(grep -c '<action id=' /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy)" "2"

sec "the INSTALLED widget's QML, executed"
# The gap this closes: every probe run elsewhere executes the CHECKOUT. These are the files the
# package put on the machine, in a different directory, which nothing else ever runs.
dnf -y -q install python3-pyside6 kf6-kirigami nodejs >/dev/null 2>&1
if KEMPT_UI_DIR="$PDIR/contents/ui" timeout 900 bash "$SRC/tests/test_widget_qml.sh" > /tmp/qml.log 2>&1; then
  grep -c '^ok' /tmp/qml.log | xargs -I{} echo "  {} assertions against the installed QML"
  ok "every probe passes against the installed copy"
else
  bad "a probe failed against the installed copy"; grep -E -A2 '^FAIL:' /tmp/qml.log | head -15
fi
grep -q '^skip:' /tmp/qml.log \
  && { bad "a probe skipped, so this proved less than it claims"; grep '^skip:' /tmp/qml.log | head -3; } \
  || ok "...and none of them skipped"

sec "first contact, as an ordinary user"
su - alice -c "kempt doctor" > /tmp/doc.log 2>&1; drc=$?
is "doctor exits 0 on a fresh packaged install" "$drc" "0"
grep -q 'all checks passed' /tmp/doc.log && ok "...and says so" || { bad "doctor did not pass"; grep '^FAIL' /tmp/doc.log; }
is "the version it reports is the released one" "$(su - alice -c 'kempt --version')" "kempt $VER"
su - alice -c "kempt holds" >/dev/null 2>&1 && ok "holds runs on a box that has never held anything" || bad "holds failed"
su - alice -c "kempt summary --json" >/dev/null 2>&1 && ok "summary --json runs with no history" || bad "summary --json failed"
su - alice -c "kempt history" >/dev/null 2>&1 && ok "history runs with no history" || bad "history failed"
is "the default surface is the documented one" "$(su - alice -c 'kempt config get surface')" "popup"
su - alice -c "kempt config set surface background" >/dev/null 2>&1 \
  && is "...and a setting round-trips" "$(su - alice -c 'kempt config get surface')" "background" \
  || bad "config set failed"
su - alice -c "kempt config set surface popup" >/dev/null 2>&1
su - alice -c "kempt hold dnf:zsh" >/dev/null 2>&1 && is "a hold is recorded" "$(su - alice -c 'kempt holds')" "dnf:zsh" || bad "hold failed"
su - alice -c "kempt unhold dnf:zsh" >/dev/null 2>&1 && is "...and released" "$(su - alice -c 'kempt holds')" "" || bad "unhold failed"
su - alice -c "kempt nonsense" >/dev/null 2>&1; is "an unknown command exits 2" "$?" "2"

sec "what the package carries"
# Asked of the PACKAGE, not the filesystem: a Fedora container installs with tsflags=nodocs, so a
# missing man page on disk says something about the image and nothing about the build.
RPMFILE=$(ls /localrepo/kempt-$VER*.noarch.rpm | head -1)
rpm -qlp "$RPMFILE" | grep -q 'share/man/man1/kempt.1' && ok "the package carries the man page" || bad "no man page in the package"
rpm -qlp "$RPMFILE" | grep -q 'share/doc/kempt/docs/usage.md' && ok "...and the user guides" || bad "no docs in the package"
rpm -qlp "$RPMFILE" | grep -q 'share/doc/kempt/docs/widget.md' && ok "...and the widget guide" || bad "no widget guide in the package"
rpm -qlp "$RPMFILE" | grep -q 'share/doc/kempt/README.md' && ok "...including the README its links start from" || bad "no README in the package"
rpm -qlp "$RPMFILE" | grep -q 'share/doc/kempt/docs/RELEASING.md' \
  && bad "the maintainer's release procedure is shipping to users" \
  || ok "...and NOT the maintainer documents, which are for the forge"

sec "removal leaves nothing behind"
dnf -y remove kempt-plasmoid kempt >/dev/null 2>&1
[[ ! -e "$PDIR" ]] && ok "the widget directory is gone" || bad "widget files survived removal"
[[ ! -e /usr/share/kempt ]] && ok "the CLI tree is gone" || bad "/usr/share/kempt survived"
[[ ! -e /usr/libexec/kempt-apply ]] && ok "the root helpers are gone" || bad "a root helper survived"
[[ ! -e /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy ]] \
  && ok "the polkit action is gone" || bad "the polkit action survived"
left="$(find /usr /etc \( -path '/etc/yum.repos.d' -o -path '/usr/share/doc/kempt-*' \) -prune -o \
          \( -iname '*kempt*' -o -path '*/kempt/*' \) -print 2>/dev/null)"
is "nothing named for Kempt is left under /usr or /etc" "$left" ""
[[ -e /home/alice/.config/kempt/config ]] \
  && ok "...and the user's own settings are left alone, as a package should" \
  || echo "note: alice had no config to keep"

sec "an existing install upgrades to this build"
# The half a fresh install cannot prove, and the one a package SPLIT can break: somebody already
# running the previous release must end up on this one, with the widget still there. Done last,
# because it needs the machine emptied first.
dnf -y -q install dnf5-plugins >/dev/null 2>&1
if dnf -y -q copr enable "${KEMPT_COPR:-erez-c137/kempt}" >/dev/null 2>&1 \
   && dnf -y -q --disablerepo=local --setopt=tsflags= install kempt kempt-plasmoid >/dev/null 2>&1; then
  prev="$(rpm -q --qf '%{VERSION}' kempt)"
  echo "  the released version on this machine: $prev"
  if [[ "$prev" == "$VER" ]]; then
    echo "  note: the repository already publishes $VER, so this upgrades $VER to $VER"
  fi
  # Somebody who has used Kempt and never chose a surface: a state file and no config. When the
  # default was the terminal, that meant the terminal, and the upgrade must keep it so.
  su - alice -c 'rm -rf ~/.config/kempt ~/.local/state/kempt && mkdir -p ~/.local/state/kempt/history ~/.local/state/kempt/snapshots && cd ~/.local/state/kempt && echo "{}" > state.json && echo "{}" > history/20250101T000000.json && echo pkg > snapshots/offline-pre-1.tsv'
  mine="$(su - alice -c 'cd ~/.local/state/kempt && sha256sum state.json history/* snapshots/*')"
  dnf -y -q --setopt=tsflags= upgrade "/localrepo/kempt-$VER"*.noarch.rpm "/localrepo/kempt-plasmoid-$VER"*.noarch.rpm >/dev/null 2>&1 \
    || dnf -y -q --setopt=tsflags= --allowerasing install "/localrepo/kempt-$VER"*.noarch.rpm "/localrepo/kempt-plasmoid-$VER"*.noarch.rpm >/dev/null 2>&1
  is "the CLI ends on this build" "$(rpm -q --qf '%{VERSION}' kempt)" "$VER"
  is "...and so does the widget, rather than being left behind by the split" \
     "$(rpm -q --qf '%{VERSION}' kempt-plasmoid)" "$VER"
  is "...with both packages verifying clean" \
     "$(rpm -V kempt kempt-plasmoid >/dev/null 2>&1 && echo clean || echo dirty)" "clean"
  [[ -f "$PDIR/metadata.json" ]] && ok "...and the widget is still where Plasma looks" \
    || bad "the upgrade left no widget behind"
  is "...at this version" "$(jq -r '.KPlugin.Version' $PDIR/metadata.json)" "$VER"
  # Read BEFORE the next kempt command runs, since running one is allowed to write.
  is "the user's state, history and snapshots survive the upgrade untouched" \
     "$(su - alice -c 'cd ~/.local/state/kempt && sha256sum state.json history/* snapshots/*')" "$mine"
  is "an install that used the terminal keeps it across the upgrade" \
     "$(su - alice -c 'kempt config get surface')" "terminal"
  # The other install that predates the default: a config with a setting and no state at all.
  su - alice -c 'rm -rf ~/.config/kempt ~/.local/state/kempt && mkdir -p ~/.config/kempt && echo "notify_security=false" > ~/.config/kempt/config'
  is "an install with only a settings file keeps the terminal too" \
     "$(su - alice -c 'kempt config get surface')" "terminal"
  # Back to the release it came from, if the repository still carries it. A downgrade is the
  # rollback somebody reaches for when an update misbehaves.
  if [[ "$prev" != "$VER" ]]; then
    if dnf -y -q --disablerepo=local --setopt=tsflags= downgrade kempt kempt-plasmoid >/dev/null 2>&1; then
      is "a downgrade returns the CLI to $prev" "$(rpm -q --qf '%{VERSION}' kempt)" "$prev"
      is "...and the widget with it" "$(rpm -q --qf '%{VERSION}' kempt-plasmoid)" "$prev"
      is "...both verifying clean" "$(rpm -V kempt kempt-plasmoid >/dev/null 2>&1 && echo clean || echo dirty)" "clean"
      is "...and the CLI still runs" "$(su - alice -c 'kempt --version')" "kempt $prev"
    else
      echo "note: the repository no longer carries $prev, so the downgrade was NOT checked (manual Phase 3 step)"
    fi
  else
    echo "note: the repository publishes $VER already, so there is no older release to downgrade to"
  fi
else
  echo "note: the COPR repository could not be reached, so the upgrade path was NOT checked"
fi

echo; echo "RELEASE CHECK: $pass ok, $fail FAIL"
exit $(( fail > 0 ))
