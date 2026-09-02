# Brand bake-off: Kanso vs Kempt

> Housekeeping (2026-08-25, after the decision): the three Kanso concept SVGs were removed from `brand/`; the two legibility sheets that show them beside the Kempt concepts remain as the evidence for this decision.

Date: 2026-08-25. Status: research only. Nothing is renamed by this document. It exists to close
the last open question from `docs/research/2026-08-25-naming.md`: of the two finalists, which one
**brands** better, given that the next two artefacts are an icon and a public GitHub page.

**Recommendation up front: Kempt.** The naming doc ranked Kanso first on namespace cleanliness.
That ranking does not survive re-verification, and it was never scored on the criteria that
matter now. Detail in section 7.

> **Correction to the prior doc.** Its central claim was that Kanso is "the only candidate with no
> live software collision anywhere that matters", resting on the fact that `kanso/kanso` has been
> archived since 2018. That search missed the collisions that actually exist. As of today Kanso is
> a **live and currently fashionable brand inside this exact community**: a dark-theme family with
> 580 stars on its Neovim repo plus VS Code, Zed, Alacritty, Kitty, Ghostty, Foot, Wezterm, Yazi
> and Zellij ports and an Omarchy theme; an immutable Linux distribution on SourceForge; an active
> crates.io design-system crate; and a live US software company holding trademark filings in
> software classes. Section 4 has the evidence.

---

## 1. Icon-ability

This section is the reason the recommendation flipped, and it is the only section with executed
evidence rather than opinion. Each concept was drawn as a real 16px-grid symbolic SVG, rendered at
true 16px and 22px, magnified 8x with nearest-neighbour so the pixel grid is visible, and placed
beside the actual Breeze icons it would sit next to in a panel. Files are in
`docs/research/brand/`.

### 1.1 Kanso concepts

Kanso is 簡素: simplicity through omitting the non-essential. Three honest readings:

- **A - the ensō** (`kanso-a-enso.svg`). A ring left deliberately open. "Complete through
  omission", and the opening is a natural seat for the pending-count badge. The idea is good on
  paper.
- **B - karesansui** (`kanso-b-karesansui.svg`). One stone, raked gravel lines around it. The dry
  garden as the emblem of considered emptiness.
- **C - subtraction** (`kanso-c-subtraction.svg`). Three rows shortening to a single mark. Many
  reduced to one, which is literally what the badge does.

### 1.2 Kempt concepts

Kempt is the surviving positive of *unkempt*, and its root is exact: Old English *cemban*, to comb.
Unkempt means uncombed. So the name hands over a concrete noun for free.

- **A - the combed-down comb** (`kempt-a-comb-arrow.svg`). A comb whose tooth-tips trace a
  downward arrow, fusing the brand shape and the category shape into one form.
- **B - the comb** (`kempt-b-comb.svg`). The plain comb. A spine and five teeth, nothing else.

### 1.3 What the renders actually showed

`brand/legibility-sheet-round1.png` - candidates at 16px and 22px, magnified, with Breeze
`view-refresh`, `network-wireless-connected-100` and `system-software-update` on the right for
comparison. `brand/legibility-sheet-round2.png` - the second round, with Breeze
`format-justify-left` for comparison.

| Concept | Reads at 16px as | Verdict |
| --- | --- | --- |
| Kanso A, ensō | The letter **C**, or a spinner. Placed beside Breeze `view-refresh` and `system-software-update` it is visibly the same shape family with the arrowheads taken off - the undifferentiated version of the two icons a Plasma panel already uses for exactly this job. | Fails |
| Kanso B, karesansui | Three stacked arcs over a dot. That is **the wifi icon**. Side by side with Breeze `network-wireless-connected-100` they are the same glyph. It is also the thinnest of the set and nearly disappears at 16px. In a panel it would sit a few icons from the real wifi indicator. | Fails badly |
| Kanso C, subtraction | Ragged left-aligned bars, which is **`format-justify-left`**. The comparison render makes it embarrassing: the concept and the stock Breeze align icon are near-identical. | Fails |
| Kempt A, combed-down comb | A comb with one long middle tooth. It reads as a **trident**, not an arrow. The V of the tooth tips needs more vertical drop than a 16px grid has room for. Deepening it from 4px to 6px (v2) did not rescue it. | Fails, honestly |
| **Kempt B, the comb** | **A comb.** Unmistakably, at both 16px and 22px. Crisp, high contrast, evenly spaced, right at Breeze's density sweet spot and no denser than `format-list-unordered`. Nothing in a default Plasma panel looks like it. | **Works** |

### 1.4 Reading the result

The finding is sharper than "Kempt's icon is nicer". It is structural.

**Kanso's meaning is anti-iconographic.** The concept is the absence of a thing, and a glyph has to
be a present thing. Every faithful attempt therefore lands on one of three shapes, and a Plasma
panel already uses all three: the ring is refresh, the arcs are wifi, the ragged bars are text
alignment. That is not bad luck across three tries. It is what happens when the brief is "draw
minimalism" in a visual language whose entire vocabulary is already minimal.

**Kempt's meaning hands over a noun.** The etymology does the work: kempt means combed, a comb is a
spine with teeth, and a spine with teeth is one of the most legible things you can draw on a 16px
grid. It is distinctive because no Linux tool uses it, ownable because it is derived from the name
rather than borrowed from a category, and it carries a quiet second reading - a comb pulls a row of
things straight, which is what the tool does to a package list.

**Neither name's glyph says "updates" by itself, and that is fine.** Panel-icon practice in this
category is that the badge carries the count and the tooltip carries the meaning. Discover's
notifier and apdatifier both rely on it. The correct split is: symbolic panel glyph = the brand
shape, plus the numeric badge; full-colour store icon = the same comb rendered with depth, on the
Breeze blue-grey palette, with an optional small down-chevron that has room to read at 48px and up
where it fails at 16px.

One caution to hand to whoever draws the final SVG: five 2px teeth with 1px gaps is at the top of
Breeze's density range. It rendered clean here, but check it against a light Breeze theme and at
125% and 150% scaling before committing. Four teeth is the safe fallback and loses almost nothing.

### 1.5 On the AI-generated concepts

The `nanobanana` skill is installed but **could not be run**: `google-genai` is not installed on
this box and no `GEMINI_API_KEY` is set. The skill requires a dedicated local key created by the
founder and explicitly forbids reusing Toran's production Gemini key, so no generation was
attempted. The SVGs in `docs/research/brand/` are hand-authored geometry studies rather than AI
concept art - which is the more useful artefact anyway, since the shipping icon is a hand-drawn
SVG and these are on the real 16px grid at the real stroke weights. They are studies, not
finished art.

---

## 2. Wordmark and typography

**Silhouette.** `kanso` is one ascender followed by four round x-height letters (a, n, s, o). It is
soft, even and calm, and also flat: the outline is nearly a rectangle, so it is forgettable at
small sizes. `kempt` is bookended by ascenders with a descender in the middle - k, e, m, p, t. That
outline has a shape you can recognise in a panel tooltip at 9pt without reading it. For a wordmark
that is a real advantage.

**Density.** `kempt`'s "mp" pair is the one weak spot; in a condensed grotesque it can clot. Any
normal-width UI face (Noto Sans, Inter, Source Sans) handles it. `kanso` has no such problem but
also no character.

**The macron problem.** The correct romanisation is *Kansō*. Using it is elegant in a README header
and a liability everywhere else: it is not typeable at a shell prompt, it will be dropped or
mangled by half the places that quote the project, and it forces a permanent split between the
display name and the command. Worse, the Kanso theme family already brands itself as
"Kansō (簡素) ... simplicity and the elimination of clutter". Writing that same sentence under a
Fedora updater makes the project look like a fork of a colourscheme. Dropping the macron avoids the
mangling but keeps the resemblance.

**Capitalisation convention.** For either name the answer is the same and it is the Git convention:
**Title case in prose, lowercase for the command.** "Kempt" in the README H1, the KDE Store title,
the `KPlugin.Name` and any sentence about the project; `kempt` in every code font, every command
example and the man page title. Never all-caps, never camel case. The store listing should be
**"Kempt - System Updates"**, with the keywords living in the summary line where search actually
reads them, exactly as the naming doc argued.

**In a README header.** `# Kempt` followed by "One-click system updates for Fedora" works without
any explanation line. `# Kanso` needs a second line explaining the word before the first line about
the product, which is a tax paid by every reader forever.

---

## 3. Voice fit

**At the prompt.**

```
kempt check                        kanso check
kempt update                       kanso update
kempt hold dnf:kernel-core         kanso hold dnf:kernel-core
kempt doctor                       kanso doctor
```

Both are five letters and both read cleanly in verb-object form. Typing feel slightly favours
Kanso: k-a-n-s-o alternates hands well on QWERTY, while kempt's "mp" is same-hand. It is a small
difference and it is the only ergonomic edge Kanso has.

**In a sentence.** This is where the gap opens.

- "Kempt says 3 updates." Reads.
- "Run kempt." Reads.
- "Keep your system kempt." **This is a tagline the name gives away for free**, because kempt is an
  adjective. It is the product's promise in four words, it is grammatical English, and no other
  candidate on the original twelve-name list produced one.
- "Keep your system kanso" is not English. Kanso yields no sentence at all, only an apposition:
  "Kanso, from the Japanese for simplicity." That is a footnote, not a tagline.

**Pronunciation friction.** Kempt has none for English speakers: it is *unkempt* minus the prefix,
so it is read correctly on sight even by people who have never seen the bare word. Non-native
speakers also read it right on sight, which matters more. Kanso has two or three plausible English
readings - KAHN-so, KAN-so as in "can", KAN-zo - and no way to tell which is right from the
spelling, so it will be said three ways in the same thread.

**The "kept" typo risk** the naming doc flagged is real: in speech, "kempt" gets heard as "kept".
It is self-correcting, because one mention of *unkempt* fixes it permanently, and it is a
one-time cost rather than the recurring one Kanso carries.

**Cute versus serious, for a tool that runs code as root.** Kempt is dry, plain and slightly
old-fashioned - it sounds like a butler, not a mascot. That is the right register for something
holding two polkit actions. Kanso's risk is not that it sounds cute; it is that in 2026 it sounds
like a *theme*. In the Linux desktop world that word currently means a colourscheme, and a
colourscheme is the least serious kind of software there is. A package manager borrowing a
colourscheme's name inherits its register.

The one place Kempt's register is a hazard: the small cluster of 2026 tools using "kempt" to mean
*tidy your source code* (section 4.2). "Kempt" is drifting toward "formatter" among developers.
Leading with "system updates" in every title and summary keeps that at bay.

---

## 4. Ownability

Everything in this section was checked today. Method and its limits are stated in 4.6.

### 4.1 Namespaces that decide whether it can ship

| | **Kanso** | **Kempt** |
| --- | --- | --- |
| Fedora 44 + updates + RPM Fusion (`dnf5 repoquery`) | free | free |
| COPR (`api_3/project/search`, exact-name match) | free (2 substring hits, 0 exact) | free (4 substring hits, 0 exact) |
| AUR (RPC v5 `info`) | free | free |
| Debian source package | free | free |
| KDE Store (OCS API; control search "weather" = 533) | **0 results** | **0 results** |
| GitHub repo under `erez-c137` | free | free |

Dead even, and both are shippable. This was already true in the naming doc and it still is.

### 4.2 GitHub

Both organisation names are gone. `github.com/kanso` is a live org since 2011 with 65 repos;
`github.com/kempt` is an empty org registered in 2015. Neither can be had, so the repo is
`erez-c137/<name>` either way and this is a wash.

The repo-name collisions are not a wash.

**Kanso.** `webhooked/kanso.nvim` is **580 stars and active**, a dark Neovim theme described as an
evolution of Kanagawa, with sibling repos `kanso-zed` (77 stars) and `kanso-vscode` (25 stars) and
ports to Alacritty, Kitty, Ghostty, Foot, Wezterm, iTerm2, Yazi, Zathura, Zellij and Windows
Terminal. `HANCORE-linux/omarchy-kanso-theme` carries the same name into the Omarchy/Hyprland
crowd. `psychosomat/Kanso` is an active "Zen-inspired desktop media player". `aktasfatih/kanso` is
a Nextcloud kanban board pushed **today**. `kanso/kanso`, the 488-star CouchApp tool the naming doc
treated as the only namesake, is indeed archived since 2018 and is the least relevant of the set.

**Kempt.** `ZacSweers/kempt` is 59 stars, active (v0.3.1 released 2026-07-28, pushed 2026-08-17), a
pre-commit-friendly multi-language source formatter. Behind it sits a scatter of small 2026
projects - `oomfware/kempt` ("keeps your generated code presentable"), `xz1220/Kempt` (an agent-debt
scanner), `faizanxmd/kempt` - all pushing the word toward "code tidiness". Nothing above 59 stars.

### 4.3 The `$PATH` question, verified at source

This is Kempt's real wart and it deserves to be stated precisely rather than hedged. `kempt`'s own
`Cargo.toml`, read directly, says:

```toml
# Crate name is `kempt-fmt` because the short `kempt` is already taken on
# crates.io by an unrelated sorted-collection library. The installed
# binary is still `kempt` (see [[bin]] below).
name = "kempt-fmt"
...
[[bin]]
name = "kempt"
```

So a `kempt` binary exists in the wild, is actively maintained, and will keep existing. Kanso has
no live binary: the npm `kanso` command belongs to the CouchApp tool, last modified 2022.

Severity, honestly: **real but bounded.** The two tools install through different channels
(cargo/cargo-dist versus dnf, COPR and AUR), serve almost disjoint audiences (a JVM/Kotlin
formatter versus a Fedora KDE desktop applet), and both land user-scoped, so the worst case is one
person who has both and renames one. It is friction, not a defect. Set against it, Kanso's
collisions are not in another building - the theme is installed on the same desktops this widget
wants to sit on.

### 4.4 Domains, checked by RDAP and WHOIS today

| | Kanso | Kempt |
| --- | --- | --- |
| `.dev` | registered 2021-01-20, Gandi | registered 2023-01-27, Gandi (A records point at GitHub Pages) |
| `.app` | registered 2021-05-17, GoDaddy | registered 2020-01-07, Squarespace |
| `.io` | registered 2024-12-29, Spaceship | registered 2025-05-13, GoDaddy |
| `.org` | registered 2004-12-31, Squarespace | **"Domain not found" - unregistered** |
| `.sh` | registered 2026-05-26, OVH | **"Domain not found" - unregistered** |
| `.com` | registered, in use | registered, in use |

Every domain Kanso could want is taken. **`kempt.org` is free**, which is the right TLD for an
MIT-licensed project anyway, and `kempt.sh` is free as a CLI-flavoured alternative. This is a
concrete, cheap, today-only advantage: a domain-backed identity, an eventual docs site, and if he
ever wants it, a reverse-DNS id that does not depend on GitHub.

### 4.5 Registries and handles

| | Kanso | Kempt |
| --- | --- | --- |
| npm | taken - CouchApp tool, 0.5.2, dormant since 2022 | taken - "object validation", 0.0.1, dormant since 2022 |
| PyPI | **free** | taken - "Keep your files kempt", 0.0.1, in development |
| crates.io | taken - egui design system, **active, updated 2026-06-07** | taken - khonsulabs ordered-map, 22k downloads, 2024 |
| Mastodon (fosstodon.org) | free | free |

None of this is load-bearing for a bash CLI plus a QML applet. It is a saturation signal, and the
signal says both words are contested and neither is contested badly.

X/Twitter and Reddit could not be checked: X returns its SPA shell for every handle whether taken
or not, and Reddit's JSON API returned 403 for all queries including controls. **Unverified.**

### 4.6 Trademark sanity

Search-engine level only. **This is not a clearance** and nobody should treat it as one - the
USPTO's own search, uspto.report, trademarkelite and Justia all returned 403 to automated fetches,
and the Playwright browser needed for the stealth fallback is not installed on this box.

**Kanso: a live software mark and a live software company.** `KANSO SOFTWARE` was filed with the
USPTO by HDS, LLC of Denver on 2019-01-10, covering downloadable software and SaaS for managing
subsidised, tribal and homeless-population housing services. HDS trades as Kanso Software at
kansosoftware.com with a LinkedIn page and a Facebook page. The mark's English translation is
recorded as "SIMPLE". Different field of use from a Linux desktop updater and there is no plausible
consumer confusion, so the legal risk to an MIT project is low - but note the shape of it: this is
structurally the same situation as UpKeep the CMMS company, which the naming doc counted against
the placeholder.

**Kempt: no live software mark found.** The one US registration for the bare word (serial 77463348,
Kempt LLC, New York) covered handbags and wallets and was **cancelled in 2015** under Section 8.
Kemp Technologies, now Progress Kemp, is a real and Linux-adjacent B2B brand - LoadMaster load
balancers run on a custom Linux - but that mark is "Kemp", not "Kempt", and load balancing is a
different category. Phonetic proximity is a small marketing annoyance, not a legal one.

EUIPO was not searched. **Unverified.**

### 4.7 The discoverability test, run the same way the naming doc ran it

Page one of "**kanso linux**": the Omarchy Kanso theme, the npm CouchApp package, the archived
`kanso/kanso`, Kano OS (a different product entirely, and a phonetic near-miss that will absorb
mistyped searches), the Kanso Linux distro on SourceForge, and `kanso.nvim`. Not one slot is
available to a Fedora updater, and the top result is a theme with the same philosophy sentence.

Page one of "**kempt linux**": kempt.net (a small IT consultancy), `ZacSweers/kempt` and its
announcement post, Kemp Technologies' Linux load balancer pages. Thinner, older, less contested,
and none of it is a desktop tool.

The Kanso Linux distro deserves its own line, because it is the sharpest version of the problem and
also the mildest in practice: registered 2026-05-01, last updated 2026-08-01, an immutable distro
built on niri and noctalia-shell, **2 downloads in its most recent week** and no reviews. A hobby
project with no reach. But the naming doc rejected Trilby precisely because `ners/trilby` is a
Fedora-modelled distro and "trilby fedora" would be a search lost forever. The same objection
applies here, against the name it recommended.

---

## 5. Community perception

**Is a Japanese loanword pretentious in a Western OSS project?** On the general question, no, and
the precedent is overwhelming in exactly this neighbourhood: KDE ships **Kirigami**, Fedora ships
**Koji** and **Bodhi**, the industry runs on **Kanban** and **Kaizen**, and the terminal world is
full of **Kanagawa**, **Zenburn**, **Sakura**, **Yuzu** and **Bonsai**. Nobody gets mocked for
this. Borrowed-word naming is the Fedora and KDE house style, and it is a point in Kanso's favour
that the naming doc scored correctly.

The problem is not the category, it is this word right now. "Kanso" in 2026 has three live
associations for the target reader: a wellness and interior-design buzzword, a dark theme, and a
housing SaaS. The first makes it read as trend-chasing rather than considered - the *wabi-sabi
candle* register, not the Kirigami register. The second is worse, because it is inside the
audience: a person who runs Neovim on a KDE desktop, which is a fair description of the early
adopter here, already has Kanso installed and it is a colourscheme. And a README that opens with
"Kansō (簡素) is the Japanese principle of simplicity and the elimination of clutter" is repeating,
almost word for word, the tagline of `omarchy-kanso-theme`. The reaction that earns is not
"pretentious", it is "isn't that the theme?", which is worse, because it is a correction rather
than a first impression.

**Is an archaic English word clever or obscure?** For Kempt specifically it is clever, and the
mechanism is worth naming: **kempt is obscure but self-explaining.** Nobody uses the bare word,
yet every English speaker knows *unkempt*, so the meaning arrives without a footnote and the small
surprise of the positive form is the memorable part. That is the opposite of Kanso, which is
opaque and requires an external explanation forever.

The Linux CLI world has a long, healthy habit of exactly this kind of name - `ripgrep`, `bat`,
`eza`, `zoxide`, `just`, `mise`, `hyperfine`, `starship`, `topgrade`, `yay`, `paru`, `bauh` - odd
real words and short coinages that reward a second's thought. Kempt sits comfortably in that list.
It is also, quietly, a hacker-culture callback: "a utility for keeping a directory of files clean
and kempt" is the description of a Go tool from 2014. The word has been reached for in this exact
sense before, by people with the same instinct.

Set against the community's own baseline in this category - `bs-updater`, `apdatifier`,
Discover's notifier - either name is a large upgrade. This is a comparison between two good
options, not a rescue.

---

## 6. Reverse-DNS proposal

**Use `io.github.erez_c137.kempt`, as one string, everywhere.**

The Flathub rules, verified against the current requirements page:

- Apps hosted on github.com **must** use the `io.github.` prefix and have at least four components.
- Each component may contain only `[A-Za-z0-9_]`. A dash is permitted **only** in the last
  component.
- The domain portion must be lowercase, and dashes convert to underscores.

So `erez-c137` becomes `erez_c137`, and `org.erez.*` is out on two counts: it is not a domain he
controls, and a personal-name namespace with no backing domain will not pass Flathub review.

Three practical consequences worth writing into the rename plan:

1. **The id encodes the repo name.** Flathub resolves `io.github.erez_c137.kempt` back to
   `https://github.com/erez-c137/kempt` by converting underscores to dashes. The repository must
   therefore be named exactly `kempt`, and renaming the repo later invalidates the id. Pick the
   name and the repo slug together, once.
2. **Lowercase final component.** Flathub recommends but does not require lowercase, and both
   styles are common there. Lowercase is the right choice here because the same string has to be
   the Plasma applet `Id`, where KDE's own convention is all-lowercase
   (`org.kde.plasma.digitalclock`). One string, no case drift between the plasmoid directory, the
   polkit actions and a future Flatpak.
3. **One string covers six places**, and they should all change in the same commit: the plasmoid
   `KPlugin.Id` in `plasmoid/metadata.json` (currently `org.erez.upkeep`), the installed path
   `~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt`, the `kpackagetool6` calls in
   `install.sh`, the two polkit actions, the `.desktop` file, and the AppStream metainfo id.

Polkit actions become:

```
io.github.erez_c137.kempt.refresh
io.github.erez_c137.kempt.apply
```

Root helpers become `kempt-refresh` and `kempt-apply`, and the polkit rules file becomes
`49-kempt.rules.in`.

One note on the alternative. `kempt.org` is unregistered today (section 4.4). If he registers it,
`org.kempt.kempt` becomes available as a domain-backed id and is arguably cleaner. **Do not wait
for that.** `io.github.erez_c137.kempt` is valid, conventional, free and available right now, and
the plasmoid `Id` is the one identifier that is genuinely expensive to change after the widget
ships. Register `kempt.org` for the docs site and the email if he wants it; keep the id on
`io.github.`.

---

## 7. Recommendation

**Kempt.**

1. **It is the only one of the two with an ownable panel icon, and this was tested rather than
   argued.** Kanso's three faithful glyphs each render as something Plasma already has - a refresh
   ring, a wifi fan, a text-align stack. Kempt's etymology hands over a comb, which is legible at
   16px, unlike anything else in a panel, and derived from the name rather than borrowed from the
   category. The next artefact is an icon; this is the criterion that should carry the most weight
   right now.
2. **It explains itself and Kanso does not.** Kempt is *unkempt* minus the prefix, so it lands with
   no footnote for native and non-native English readers alike, and it hands over "keep your system
   kempt" as a tagline for free. Kanso needs a sentence of explanation in every README, forum post
   and hallway conversation, forever - and the sentence it needs is currently a colourscheme's
   tagline.
3. **Its collisions are further away, and it has room that Kanso does not.** Kanso's namesakes are
   live, fashionable and inside the target audience: a 580-star theme family with ten terminal
   ports, an Omarchy theme, a niri-based distro, an active design-system crate and a US software
   company with trademark filings in software classes. Kempt's largest namesake is a 59-star
   formatter. On top of that, `kempt.org` and `kempt.sh` are unregistered today while every Kanso
   domain is gone, and no live software trademark for "Kempt" was found while `KANSO SOFTWARE` is
   on file.

**The runner-up's strongest counter-argument.** There is a `kempt` binary in the wild and there is
no `kanso` binary. `ZacSweers/kempt` is actively maintained, shipped a release last month, and its
`Cargo.toml` explicitly documents that the installed binary is named `kempt` even though the crate
had to be published as `kempt-fmt`. A `$PATH` collision between two live tools is exactly the kind
of sloppiness this project's character argues against, and Kanso simply does not have it. The
counter to the counter: different install channels, near-disjoint audiences, user-scoped installs,
and a worst case of one person renaming a shim - whereas Kanso's theme is installed on the same
desktops the widget is trying to reach.

**Reverse-DNS:** `io.github.erez_c137.kempt`, adopted in the same commit as the rename, with
`kempt-refresh` / `kempt-apply` helpers and `io.github.erez_c137.kempt.{refresh,apply}` polkit
actions. Register `kempt.org` if a docs site is wanted; do not make the id depend on it.

**Do it before the widget plan runs.** The naming doc's timing argument is unchanged and is the
real deadline: `plasmoid/metadata.json` still carries `Id: "org.erez.upkeep"` and
`Icon: "system-software-update"`. Both are wrong, both are one edit today, and the plugin `Id`
becomes a migration the moment a KDE Store listing or a single user's panel references it.

### What was not verified

- **X/Twitter and Reddit handles.** X serves an identical SPA shell for taken and free handles;
  Reddit's JSON API returned 403 for every request including controls.
- **Trademark clearance.** Search-engine level only. USPTO, uspto.report, TrademarkElite and Justia
  all blocked automated fetches, and the browser needed for a stealth fallback is not installed
  here. EUIPO and WIPO were not searched at all. Nothing here is legal advice or a clearance.
- **Domain purchasability.** "Domain not found" from WHOIS for `kempt.org` and `kempt.sh` means
  unregistered at the registry, not necessarily purchasable at a normal price. Check a registrar.
- **AI concept icons.** Not generated - `google-genai` is not installed and no dedicated
  `GEMINI_API_KEY` exists, and the production Toran key must not be reused. The SVGs in
  `docs/research/brand/` are hand-authored geometry studies rendered with ImageMagick's internal
  SVG renderer, which is adequate for solid rectangles and arcs but is not Qt's renderer. Re-check
  the final icon in an actual Plasma panel.
- **Fedora EPEL and Rawhide-only packages**, as in the naming doc.
