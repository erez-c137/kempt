# Download size next to "Update Now" - can we, and how

Research only. Captured 2026-08-26/27 on the dev box (Fedora 44, dnf5 5.4.3.0, flatpak 1.18.1,
x86_64). Nothing was pending at capture, so every `--upgrades` run returned zero rows; format,
unit and cost were validated against installed and repo packages instead, called out where
substituted. No cache writes, no depsolve, no builds.

## Answer

Yes. Both backends expose the number in **metadata already on disk**, with no depsolve, no
network and no transaction. dnf costs about **1.4 s**, flatpak about **0.12 s**, on top of the
check Kempt already runs. dnfdragora's flaw (survey line 244, "full metadata re-index on every
popup open") is not what this needs: nothing re-indexes, nothing runs on popup open. It runs
once per check, in the CLI, and lands in state.json. The figure is **an estimate with error in
both directions**, so the wording must not imply a bound. See "Wording".

## dnf5 findings

### The command in the brief does not work as written

    $ dnf5 -C repoquery --installed --qf '%{name}\t%{evr}\t%{download_size}\t%{repoid}\n' bash
    bash\t5.3.9-3.fc44\t%{download_size}\t@System

`%{download_size}` is not a tag and is echoed literally; `\t` in a plain single-quoted string
reaches dnf5 as two characters. Real tags (`dnf5 repoquery --querytags`) are **`downloadsize`**
and **`installsize`**. Tabs need `$'...'`.

    $ dnf5 -C repoquery --qf $'%{name}\t%{evr}\t%{downloadsize}\t%{repoid}\n' --latest-limit 1 bash firefox kernel nodejs
    bash            5.3.9-3.fc44            1985877     fedora
    firefox         154.0-5.fc44            93624598    updates
    kernel          7.1.10-200.fc44         243833      updates
    nodejs          2:24.20.0-1nodesource   47807328    nodesource-nodejs

`downloadsize` is **bytes**, integer, non-zero for repo packages. Installed packages report `0`
(rpmdb does not keep it), so any row resolving to `@System` is worthless:

    $ dnf5 -C repoquery --installed --qf $'%{name}\t%{evr}\t%{downloadsize}\t%{installsize}\n' bash
    bash    5.3.9-3.fc44    0    8873537

### `--upgrades` lists every newer candidate, not just the newest

Man page: "Limit to available packages that provide an upgrade for some already installed
package." Plural, per candidate version. Plain repoquery shows the shape:

    $ dnf5 -C repoquery --qf $'%{name}\t%{evr}\t%{downloadsize}\n' nodejs | wc -l         → 27
    $ dnf5 -C repoquery --qf $'%{name}\t%{evr}\t%{downloadsize}\n' --latest-limit 1 nodejs → 1

A box three nodesource releases behind would contribute nodejs three times to a naive sum.
**`--latest-limit 1` is mandatory**, not an optimisation.

Related trap: dnf5 **deduplicates identical formatted output lines**. `--qf '%{name}\n' nodejs`
returns 1 row; adding `%{evr}` returns 27. Row count depends on the format string, so any test
that counts rows must pin the exact format.

### `--latest-limit 1` is per name.arch, and multilib twins are both downloaded

    $ dnf5 -C repoquery --qf $'%{name}\t%{evr}\t%{arch}\t%{downloadsize}\n' --latest-limit 1 glibc
    glibc   2.43-8.fc44   i686     2282613
    glibc   2.43-8.fc44   x86_64   2483277

Kempt's existing pipeline cannot supply this: `dnf_parse_check_update` strips the arch and
`sort -u` collapses same-EVR twins, so a size joined onto the collapsed item list loses the i686
2.28 MB. Sizes must be summed from repoquery's own rows, keyed by name+arch, then folded per name.

### Installonly (kernel) behaves normally, with one untested gap

    $ dnf5 -C repoquery --qf $'%{name}\t%{evr}\t%{downloadsize}\t%{repoid}\n' kernel-core
    kernel-core   6.19.10-300.fc44   21394553   fedora
    kernel-core   7.1.10-200.fc44    21711309   updates

Sizes present and sane. **Untestable today:** whether `--upgrades` emits installonly kernel rows
at all, since a new kernel is an install rather than an upgrade and none are pending here. The
design fails safe either way (a missing row means no size, which suppresses the figure). The one
verification this doc still owes, to run on a lagging box:

    dnf5 -C repoquery --upgrades --latest-limit 1 --qf $'%{name}\t%{arch}\t%{evr}\t%{downloadsize}\n' | tee /tmp/sizes
    dnf5 --cacheonly check-update --quiet | wc -l   # every name here must appear in /tmp/sizes

### Cost does not grow with the update count

    --upgrades --latest-limit 1, warm:   1.590s 1.282s 1.373s 1.227s 1.474s 1.388s 1.390s
    format ALL 103945 available pkgs:    1.125s
    today's check (check-update --quiet): 1.849s 1.623s 1.875s
    depsolve on the same empty txn:      2.270s

Formatting every available package costs less than one empty `--upgrades` run: the cost is
loading the solv cache, not producing rows. This roughly doubles the dnf portion of a check. The
depsolve number is the misleading one - with nothing to solve it looks cheap, while on a real
backlog it grows, can fail outright, and can block on the rpm transaction lock (dnf5#2435).

### Which cache an unprivileged repoquery reads

Kempt's check runs as **root** via `libexec/kempt-refresh` against `/var/cache/libdnf5`;
`kempt-refresh refresh` fills only that cache, never the user's (see the comment in
`dnf_reboot_needed`). A repoquery run as the user could read staler metadata and disagree with
the check - the "front-end disagreeing with the CLI" failure at survey line 256.

    $ dnf5 -C --setopt=cachedir=$PWD/emptycache repoquery --latest-limit 1 --qf $'...' bash
    bash    5.3.9-3.fc44    1985877

It still answers, so libdnf5 falls back to the world-readable system cache (`/var/cache/libdnf5`,
`drwxr-xr-x root root`) when the user cache is empty. Both caches currently carry the same
repomd revisions (fedora 1776864872, updates 1787704458). Unprivileged is viable and needs no
polkit change. It is not *guaranteed* identical, which is why every unmatched name must degrade
to "no size" rather than to zero.

## flatpak findings

`download-size` and `installed-size` both exist on 1.18.1 (`flatpak remote-ls --columns=help`).
`installed-size` is **not** valid for `flatpak list` ("error: Unknown column"), so only the
remote-ls side gains anything.

    $ flatpak remote-ls flathub --system --app --columns=application,version,download-size | head -3 | cat -A
    ai.jan.Jan^I0.8.4^I88.2M-BM- MB$
    ai.lmstudio.lm-studio^I0.4.18-1^I1.1M-BM- GB$
    ai.loomfy.Loomfy^I1.6.2^I196.8M-BM- MB$

Fields are tab separated (`^I`), so the TSV contract survives. The value is a **human string, not
bytes**, rounded to one decimal. The gap between number and unit is `M-BM- ` = **U+00A0 NO-BREAK
SPACE**, so a whitespace-splitting parser silently fails. Units across all 3474 flathub apps:

    3106 MB    331 kB    34 GB    3 bytes

SI decimal (lowercase `k`), matching `g_format_size`. `remote-info` returns the same rounded
string, so exact bytes are unavailable from the CLI at all.

    remote-ls --updates --system --app --columns=application,version                     2.382s
    remote-ls --updates --system --app --columns=application,version,download-size,...   2.498s
    remote-ls flathub --system --app --cached --columns=application,download-size        0.139s  (3474 rows)

3474 apps with sizes in 0.139 s cannot be per-ref network fetches: sizes come from the local
summary. Adding the column costs about **0.12 s** and no extra network.

## Caching, deltas, and why this is not a ceiling

- **deltarpm does not exist in dnf5.** `man dnf5.conf` has no `deltarpm` option; drpm was dropped.
  The delta question is moot on the rpm side.
- **`keepcache` defaults to `False`** and is unset in `/etc/dnf/dnf.conf` (which sets only
  `fastestmirror` and `max_parallel_downloads`); `/etc/dnf/dnf5.conf` does not exist.
  `find /var/cache/libdnf5 -name '*.rpm' | wc -l` returns **0**. Nothing is pre-downloaded.
- **Except after Kempt's own offline staging.** `kempt-apply dnf-offline-stage` runs
  `dnf5 upgrade --offline`, which downloads and stages. Afterwards the remaining download is
  effectively zero while repoquery still reports the full size.
- **flatpak uses ostree static deltas**, so the real transfer is routinely a fraction of
  `download-size`. Largest single over-count in the feature.
- The other way: dnf pulls **new dependencies** `--upgrades` never lists, and Kempt's flatpak
  command uses `--app`, excluding **runtime** updates a real `flatpak update` would download.

High for flatpak and for staged transactions, low for dependencies and runtimes. An estimate.

## How other tools present it

KDE Discover shows a "Total size" line above the update list, computed from the resolved
PackageKit transaction - which is why it inherits PackageKit's stalls and its disagreements with
dnf. GNOME Software shows a per-app "Download size" in update detail plus a total on the Updates
page, again post-resolution. Apdatifier, the closest prior art in the survey, shows no sizes at
all. Copy Discover's placement (one small total adjacent to the action button); avoid its
provenance (a resolved transaction, which is the depsolve we are refusing).

## Recommendation

Ship it, both backends, computed inside `kempt check` from on-disk metadata, written to
state.json as optional fields, rendered as one approximate figure next to "Update Now". Never
gate the check on it: if the size step fails or returns nothing, the check still succeeds and
the surfaces show no number.

## Spec

### State schema v1, additive only

`assemble_state` freezes schema 1 as a public interface, so all three fields are **optional** and
readers must tolerate absence. Absent means "not known", never zero.

- `items[].size_bytes` - integer bytes, summed over all arches of that name. Omitted if unknown.
- `backends.<name>.download_bytes` - written **only when every non-held item in that backend has
  a `size_bytes`**. Partial coverage omits the key.
- `download_bytes` (top level) - sum of the per-backend keys, **omitted if any enabled backend
  omitted its own**. Held items are excluded everywhere: Kempt passes `--exclude=` for them and
  their bytes are never fetched.

No `schema` bump. Readers that predate this see exactly what they see today.

### Backend contract

Both backends gain a bytes column. flatpak converts in-backend; the human string never escapes.

`backends/dnf.sh` - new function, called from `dnf_check` after the parse, non-fatal on failure:

```sh
KEMPT_DNF_SIZES_CMD="${KEMPT_DNF_SIZES_CMD:-}"   # seam, same shape as KEMPT_DNF_INSTALLED_CMD

dnf_sizes() {   # → TSV name<TAB>bytes, one row per name, arches summed. Empty on any failure.
  { if [[ -n "$KEMPT_DNF_SIZES_CMD" ]]; then $KEMPT_DNF_SIZES_CMD
    else timeout 60 $KEMPT_DNF_CMD -C repoquery --upgrades --latest-limit 1 \
           --qf $'%{name}\t%{arch}\t%{evr}\t%{downloadsize}\n' 2>/dev/null; fi; } \
  | awk -F'\t' '$4 ~ /^[0-9]+$/ && $4 > 0 { s[$1] += $4 }
                END { for (n in s) print n "\t" s[n] }' \
  | sort -t "$(printf '\t')" -k1,1
}
```

`--latest-limit 1` is load-bearing (27 nodejs rows without it). `$4 > 0` drops `@System` rows.
Summing per name before the join preserves the multilib i686 bytes the item pipeline collapses
away. `-C` keeps it offline; **never remove it**.

`backends/flatpak.sh` - the existing command gains one column:

```sh
KEMPT_FLATPAK_REMOTE_CMD="${KEMPT_FLATPAK_REMOTE_CMD:-flatpak remote-ls --updates --system --app --columns=application,version,download-size}"

flatpak_parse_sizes() {   # stdin: remote-ls rows → TSV appid<TAB>bytes; unparseable rows omitted
  awk -F'\t' '
    function tobytes(s,   n,u,a) {
      gsub(/\xc2\xa0/, " ", s)                     # U+00A0 NBSP, not a space
      if (s ~ /^[[:space:]]*$/) return -1
      n = s; sub(/[[:space:]].*$/, "", n)
      u = s; sub(/^[^[:space:]]*[[:space:]]*/, "", u); gsub(/[[:space:]]/, "", u)
      if (n !~ /^[0-9]+(\.[0-9]+)?$/) return -1
      a["bytes"]=1; a["B"]=1; a["kB"]=1000; a["KB"]=1000
      a["MB"]=1000000; a["GB"]=1000000000; a["TB"]=1000000000000
      if (!(u in a)) return -1
      return int(n * a[u] + 0.5)
    }
    NF >= 3 && $1 !~ /^#/ { b = tobytes($3); if (b >= 0) print $1 "\t" b }' \
  | sort -t "$(printf '\t')" -k1,1
}
```

Verified against every unit this box produces, plus an empty column and a literal `?`, both of
which correctly yield no row. `flatpak_parse_remote_ls` must read `$1`/`$2` under `-F'\t'` rather
than by whitespace, since the row is now three fields wide.

### The join, in `lib/common.sh`

```sh
attach_sizes() {   # $1 = sizes TSV; stdin: items JSON (after mark_held) → items + optional size_bytes
  jq --rawfile tsv "$1" '
    ($tsv | split("\n") | map(select(length>0) | split("\t"))
          | map({key: .[0], value: (.[1] | tonumber)}) | from_entries) as $sz
    | map(. + (if $sz[.name] != null then {size_bytes: $sz[.name]} else {} end))'
}

backend_download_bytes() {   # stdin: items JSON → bytes, or "" when coverage is incomplete
  jq -r '[.[] | select(.held | not)] as $a
         | [$a[] | select(has("size_bytes"))] as $k
         | if ($a | length) == ($k | length) then ($k | map(.size_bytes) | add // 0) else "" end'
}
```

Join by **name**, not name+evr: an item's `to` can be a comma-joined EVR list for divergent
multilib twins (`5.3.9-4.fc44,5.3.10-1.fc44`), so it is not a usable key, and `--latest-limit 1`
has already guaranteed one candidate per name+arch on the size side. Verified end to end: five
items (one held, one with no size row) produced `download_bytes` over the three fully-known
unheld items and correctly omitted `size_bytes` from the ghost row.

### Wording

Use **"~"**, not "up to". "Up to" claims a ceiling, and the ceiling is false in two directions
(new dependencies, excluded flatpak runtimes).

- SI, one decimal: `~1.4 GB`, `~140 MB`. Under 1 MB say `< 1 MB`, not a kB figure nobody reads.
- **Show nothing when the key is absent.** No "unknown", no "0 MB", no dash. The surfaces already
  degrade this way for `reboot_needed`; copy that.
- Popup footer beside the button: `Update Now  ·  ~140 MB`. The footer already joins on
  `DOT = " · "` (`plasmoid/contents/ui/logic.js:95`), so this is one more `footerParts.push`
  behind an `if (downloadBytes)` guard.
- Tooltip: append to `subParts` as `~140 MB to download`, only when known and `actionable > 0`.
- `kempt check` prints JSON only today; there is no human check surface to add a line to, and the
  fields land in that JSON. If a human line is wanted later it belongs on a new `check --human`,
  not on `kempt summary`, which reports a run that has already downloaded everything.
- `docs/architecture.md`, next to the schema table: state once that the figure excludes held
  packages, omits dependencies dnf will pull in, and ignores flatpak static deltas.

### Tests

Fixtures captured from this box, provenance in `tests/fixtures/MANIFEST.md` in the existing style
(real names and real sizes; hand-written only where nothing was pending to capture):

- `dnf-repoquery-sizes.tsv` - hand-written in the captured format, using the **real** sizes this
  box reports for the names already in `dnf-check-update.txt`: `bash 1985877`, `curl 245312`,
  `git-core 5711811`, `tar 889035`, `vim-minimal 916208`, `aajohan-comfortaa-fonts 210107`. Add
  the live multilib pair (`glibc x86_64 2483277`, `glibc i686 2282613`) to exercise the per-name
  sum, and deliberately **omit** `brandnew` so the coverage guard fires.
- `flatpak-remote-ls-sizes.tsv` - real captured rows including the NBSP:
  `net.mkiol.SpeechNote<TAB>4.8.4<TAB>1.2<U+00A0>GB`, `org.gimp.GIMP<TAB>3.2.4<TAB>99.7<U+00A0>MB`,
  plus one `847<U+00A0>bytes` row, one empty-size row, one `?` row.

Assertions: the NBSP row parses (a regular-space fixture would pass a broken parser, so the byte
sequence must be verified with `cat -A` in the manifest note); glibc's two arches sum to 4765890;
a held item contributes nothing; a missing size row omits `size_bytes` **and** suppresses
`download_bytes` for that backend and top level; every existing schema test passes unchanged; a
state file with no size fields renders exactly the current widget output.

### Must not

- No depsolve. Not `dnf5 upgrade --assumeno`, not `--downloadonly`, not PackageKit. That is the
  dnfdragora and Discover failure both, and it can block on the rpm lock.
- No network in check. `-C` on every repoquery; the flatpak command keeps `--updates` unchanged.
- No blocking. `timeout` on the size call; any failure degrades to no number, never to a failed
  check or a `stale` status.
- Nothing on popup open. Sizes are computed once per check and read from state.json.
- No `installed-size`. Not what the button is about, and `flatpak list` rejects the column.
- No new pkexec call. Unprivileged repoquery reads the system cache; a `sizes` verb in
  `libexec/kempt-refresh` is the fallback only if the probe above shows real cache divergence.
