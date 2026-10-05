# Internationalisation and right-to-left layout (Arabic first)

**Status:** proposed design, for review by the StatBus team. PR 1 (the database
language model, section 2) is implemented in this series; the app wiring, RTL
layout, E2E harness and translations (PR 2 onwards) are not yet built.

**Goal:** let StatBus web-app users switch between languages, with full
right-to-left (RTL) layout for Arabic. The Yemen installation defaults to Arabic.
The design is language-agnostic. Arabic is the first non-English language, not a
special case, and an English-only instance looks exactly like StatBus does today.

**Provenance and markers:** **VERIFIED** (measured in the repo at
`9738d46df`, 2026-10-05), **DECIDED** (agreed in design review with the Yemen NSO
contributor), **CONFIRM** (to be checked in the first implementation PR).

**Related:** `doc/design/smtp2go-email.md` (STATBUS-142) leaves decision
**M3, locale source**, open. This design answers it (section 2). The legacy C#
nscreg shipped en/ru/ky-KG, so multi-language support was an earlier requirement
that the rewrite dropped.

---

## 1. Starting point (VERIFIED)

- No i18n library. The root layout hard-codes `<html lang="en">`
  (`app/src/app/layout.tsx`), and nothing handles RTL.
- Stack: Next.js 16, React 19, Tailwind 4, jotai. The root layout is already
  `force-dynamic`, so per-request `lang`/`dir` costs nothing extra.
  221 of 327 `.tsx` files are client components, the rest server components.
- About 810 user-visible strings counted by a JSX/prop heuristic across about
  108 files. That count misses toasts, thrown messages and computed strings, so
  the real figure is probably 1,000–1,200.
- 423 Tailwind physical-direction classes in 101 files: `space-x` 102,
  `mr`/`ml` 118, `pl`/`pr` 78, `text-left`/`text-right` 49, positional
  `left`/`right` ~35, `rounded-l/r` ~13, `translate-x` 6. The heaviest areas are
  import (74), search (56), admin (56) and `components/ui` (45).
- `public.auth_status()`, `login()`, `refresh()` and `logout()` all return
  `auth.auth_response`. `proxy.ts` calls `auth_status` on every authenticated
  page request. The `/login` path skips that check.
- `public.settings` is a singleton row (country, activity standard, region
  version). `auth.user` has no locale column.
- App tests: Jest 30 + ts-jest in a `node` environment, with 8 pure-logic test
  files and no component or browser tests. DB: 109 pg_regress tests. CLI: Go
  tests. No Playwright.

## 2. Language model and resolution (DECIDED)

### Database (one migration)

```sql
CREATE TYPE public.locale AS ENUM ('en', 'ar');

ALTER TABLE public.settings
  ADD COLUMN default_locale  public.locale   NOT NULL DEFAULT 'en',
  ADD COLUMN enabled_locales public.locale[] NOT NULL DEFAULT '{en}',
  -- Also rules out an empty list: default_locale is NOT NULL and must be in it.
  ADD CONSTRAINT settings_default_locale_enabled
    CHECK (default_locale = ANY (enabled_locales)),
  -- No NULL or duplicate entries (helper is IMMUTABLE, so usable in a CHECK).
  ADD CONSTRAINT settings_enabled_locales_is_set
    CHECK (public.locale_array_is_set(enabled_locales));

ALTER TABLE auth."user" ADD COLUMN locale public.locale NULL;
```

- **Two layers.** *Shipped* languages are the enum values plus their
  `app/messages/*.json` files, and only developers change them. *Enabled*
  languages are `settings.enabled_locales`, a per-instance admin choice. A Nordic
  instance enables `{en}` and never sees Arabic. Yemen enables `{ar,en}` with
  default `ar`.
- `auth.user.locale` NULL means "follow the instance default", so changing the
  default moves every user who never chose a language.
- **One resolver:** `auth.effective_locale(auth.user) RETURNS public.locale`.
  1. It returns the user's locale if that is non-NULL **and** currently enabled.
     A user's choice of a language the admin later disabled falls through, but is
     not overwritten, so re-enabling the language restores it.
  2. Otherwise it returns `settings.default_locale`.
  3. Otherwise, before the settings row exists on a fresh install, it returns
     `'en'`.
- **Fresh install:** while no settings row exists, every shipped language counts
  as enabled. The operator can then run the getting-started wizard in Arabic.
- **This is the M3 answer for STATBUS-142.** The email outbox calls
  `auth.effective_locale()`, the same function the app uses, so app and email
  never disagree.
- `auth.auth_response` gains `locale public.locale` and
  `enabled_locales public.locale[]`. Every auth path fills them, including the
  unauthenticated response, which carries the instance default.
- `public.user_locale_set(p_locale public.locale)`, `SECURITY INVOKER`, updates
  only the caller's own row, and NULL resets the user to "follow default".
  - **INVOKER is deliberate (VERIFIED):** `authenticated` already holds `UPDATE`
    on `auth.user` under the `update_own_user` RLS policy, so RLS enforces the
    own-row rule, as it does for `public.user_delete`. A DEFINER function would
    bypass it.
  - **The enabled-language rule lives in a trigger,** `BEFORE INSERT OR UPDATE OF
    locale ON auth.user`. Admin edits and any future door therefore obey it too,
    not just this function.
- **Anonymous `auth_status` (RECONSTRUCTED):** the explicit grant to `anon` was
  removed, but `public.auth_status` was never revoked from `PUBLIC`. The server
  calls it without an `Authorization` header, so it runs as `anon` and works.
  PR 1's test pins this.

### Per request in the app

1. **Authenticated:** `proxy.ts` already calls `auth_status` and passes the
   returned `locale` to the page as a request header. No extra round-trip.
2. **Anonymous** (`/login`): the cookie `statbus-{slot}-locale`, named per the
   existing cookie convention, is used if it is valid and enabled. Otherwise the
   instance default comes from an anonymous `auth_status` call.
3. On login and on every switch, the cookie is overwritten with the effective
   locale, so the login page shows the last-used language after logout.
4. An unknown or disabled cookie value is ignored and resolution falls through.
   The enum makes invalid values impossible in the DB.

**Rejected alternatives:** a cookie-only language (no cross-device memory, and
email cannot know the user's language); an instance default or enabled list in
`.env.config` (a second source of truth the DB and email cannot see, and needs an
operator to change); language-prefixed URLs `/ar/...` (see 3.4).

## 3. App wiring (DECIDED)

### 3.1 Library: `next-intl` without i18n routing

- `app/messages/en.json` is the source of truth. `app/messages/ar.json` may be
  partial. Both are nested by feature namespace: `common`, `navbar`, `auth`,
  `search`, `unitDetail`, `import`, `reports`, `profile`, `admin`,
  `gettingStarted`.
- `app/src/i18n/request.ts` is the single per-request config.
  1. It reads the language (header, else cookie), validated against
     `Enums<'locale'>` and the enabled list.
  2. It loads `deepMerge(en, <locale>)`, so a missing key renders the English
     text. That merge is the English fallback the rollout relies on.
  3. `onError`/`getMessageFallback` log missing keys in development and never
     throw in production.
- Server components use `await getTranslations('ns')` and client components use
  `useTranslations('ns')`. The call is the same `t('key')` either way.
  `generateMetadata` translates `<title>`.
- **Typed keys:** `AppConfig.Messages = typeof en`, so an unknown key fails
  `tsc`.
- **ICU messages** handle variables and plurals. `ar.json` fills Arabic's
  `zero/one/two/few/many/other` forms.
- The root layout renders `<html lang={locale} dir={rtl ? 'rtl' : 'ltr'}>`
  inside `NextIntlClientProvider` and Radix `DirectionProvider`.
- **No jotai atom for the language.** The server decides it, and components
  read it with `useLocale()`. A parallel atom would be a second source of truth.

### 3.2 Language switcher

- `LanguageSwitcher` is built on the shadcn dropdown and shows native names
  ("English", "العربية"). It lives in the navbar user menu, on the login page and
  on the profile page.
- It renders nothing when only one language is enabled.
- **On change:** an authenticated user triggers `rpc('user_locale_set', { p_locale })`, then
  the cookie update, then `router.refresh()`. An anonymous visitor triggers the
  cookie update, then `router.refresh()`.
- **Admin:** the existing settings / getting-started screen gains controls for
  `default_locale` and `enabled_locales`.

### 3.3 String conventions

- Keys are `namespace.component.purpose` (e.g. `search.filters.clearAll`), never
  the English text, so fixing an English typo does not orphan the translation.
- Embedded values use ICU placeholders, never concatenation, because word order
  differs between languages.
- A helper script lists remaining hard-coded JSX text per directory. It assists
  PR authors and is not a CI gate.

### 3.4 Why no language prefix in URLs

Canonical next-intl routing (`/ar/search`) would move all 100
page/layout/route files under `app/[locale]/`, a rename that conflicts with
every in-flight upstream PR. It would also rewrite about 55 navigation call sites
in 32 files and 24 `next/link` imports, and change auth redirects in `proxy.ts`.
For a login-only internal tool, the only gain is links that pin a language, and
those would override the user's stored preference. The `t()` calls are identical
in both designs, so prefixed routing can be adopted later as a routing-only
change.

## 4. RTL layout (DECIDED)

- **Mechanism:** `<html dir="rtl">` drives flex/grid order, table columns, text
  alignment defaults and scrollbar side. Tailwind 4 logical utilities need no
  plugin.
- **Codemod, one scripted commit:**

  | Physical | Logical |
  |---|---|
  | `ml-*` / `mr-*` | `ms-*` / `me-*` |
  | `pl-*` / `pr-*` | `ps-*` / `pe-*` |
  | `left-*` / `right-*` | `start-*` / `end-*` |
  | `text-left` / `text-right` | `text-start` / `text-end` |
  | `border-l/r`, `rounded-l/r`, `rounded-tl…` | `border-s/e`, `rounded-s/e`, `rounded-ss…` |
  | `float-left/right` | `float-start/end` |

  Logical classes render identically in LTR, so the commit changes nothing
  visible for English users.
- **`space-x-*` / `divide-x-*`:** **CONFIRM** that Tailwind 4 emits
  `margin-inline-*` / `border-inline-*` for these, which would make them mirror
  for free. If it does not, add `rtl:space-x-reverse` / `rtl:divide-x-reverse`.
- **`translate-x-*`** (6 sites): an explicit `rtl:` counterpart per site.
- **ESLint guard:** a rule forbids physical-direction classes in `className`,
  using `eslint-plugin-tailwindcss` if it can be configured for this, otherwise a
  small custom rule. It prevents regressions after the codemod.
- **Directional icons:** back/forward/next meanings (lucide `ChevronLeft/Right`,
  `ArrowLeft/Right`, pagination) get `rtl:-scale-x-100`. Icons with no reading
  direction (search, check, clock, upload) stay as they are.
- **Typography:** Inter has no Arabic glyphs.
  - Add `IBM Plex Sans Arabic` via `next/font`, applied under `:lang(ar)` with
    Inter as fallback for Latin runs, and loaded only when `lang="ar"`.
  - One `:lang(ar)` line-height rule goes in `globals.css`.
- **Mixed-direction data:** unit names, identifiers, emails, URLs, codes and
  numbers in tables and detail views are wrapped in `<bdi>` or `dir="auto"`, and
  data inputs get `dir="auto"`.
- **Left LTR on purpose:** chart plot areas in `reports` (their titles, axes,
  legends and tooltips are still translated) and the PEV2 developer tool.

## 5. Testing (DECIDED)

- **pg_regress, a new test file:**
  - `effective_locale` fallback order, including the disabled-language
    fallthrough and the no-settings-row case.
  - Both `settings` CHECKs.
  - `user_locale_set` updates only the caller's own row and rejects a disabled
    language.
  - `auth_status`/`login` carry `locale` and `enabled_locales`, both
    authenticated and anonymous.
- **Jest (node):**
  - `request.ts` resolution: header vs cookie vs garbage cookie vs disabled
    language.
  - The en→ar merge fallback.
  - The message completeness checker, which is also the CI script that reports
    missing keys per language and namespace.
- **Static gates:** `tsc` (typed keys) and ESLint (the physical-class rule).
- **Playwright i18n E2E, minimal:**
  - A new `app-i18n-e2e` job in `fast-tests.yaml` reuses that workflow's stack
    bring-up (`docker compose --profile all up`). It then migrates the main DB,
    creates test users and sets `{ar,en}` / `ar`.
  - Chromium only, no pixel baselines.
  - `app/e2e/i18n-pages.ts` is the manifest of routes declared fully
    translated, with their namespaces. The same manifest scopes the completeness
    checker, so adding a route there is how a PR claims a screen is done.
  - **Per manifest page, as a user whose language is `ar`:**
    1. `<html lang="ar" dir="rtl">`.
    2. Mirroring: the navbar logo sits in the right half of the viewport, and
       the page heading is right-aligned relative to its LTR position.
    3. No horizontal overflow: `scrollWidth <= clientWidth`.
    4. No untranslated text: no visible text node equals an `en.json` value
       whose `ar.json` value differs (`<bdi>` data excluded), and no
       missing-message sentinel appears in the console.
    5. Switching to English yields `dir="ltr"`, and the choice persists across a
       reload.
  - Failure screenshots are uploaded as CI artifacts.
- **Translation quality** is not machine-checkable. A fluent speaker reviews the
  `ar.json` diff in every translation PR.

## 6. Rollout (DECIDED)

The principle: every PR stands alone, and an English-only instance sees no
change until an admin enables a second language.

| # | PR | Contents |
|---|---|---|
| 1 | DB: language model | Section 2 DB changes and the pg_regress test. Marks M3 decided in `smtp2go-email.md`. |
| 2 | App foundation | next-intl, `request.ts`, `proxy.ts` header, `lang`/`dir`, `DirectionProvider`, Arabic font, switcher, admin controls, `common`/`navbar`/`auth` namespaces, completeness checker, Jest tests. |
| 3 | RTL codemod | Class codemod (script committed), `rtl:` fixes, icon flips, `<bdi>`, ESLint guard. |
| 4 | E2E harness | Playwright, `app-i18n-e2e` job, manifest with `/login` and the navbar. |
| 5 | search | Strings into `search`, plus Arabic and manifest entries. |
| 6 | unit detail | Legal unit, establishment and enterprise detail pages. |
| 7 | import | Import flow and its steps. |
| 8 | reports | Page chrome plus chart titles/axes/legends/tooltips. |
| 9 | profile | Page strings plus the profile-page switcher. |
| — | **Yemen launch gate** | The manifest covers search, unit detail, import, reports, profile, navbar and login. E2E is green, `ar.json` is reviewed, and Yemen sets `{ar,en}` / `ar`. |
| 10+ | remaining areas | admin, getting-started, error pages, and the rest, with English fallback until done. |

**Estimates (rough):** about 3.2–4.0k changed lines and 550–700 Arabic strings
before the launch gate, and about 4.5–6k lines in total. About 60% of the lines
are mechanical string extraction. The pacing item is translation and its review,
not code.

**Translator workflow:** the completeness checker lists missing keys per
namespace. A fluent speaker fills them into `ar.json`, directly or through a
spreadsheet round-trip script, and the diff is reviewed in the same PR.

**PR 2 hand-off (from PR 1):** an `auth_status` response with
`expired_access_token_call_refresh = true` carries the instance default, not the
user's language. The app must keep its existing locale cookie in that case and
only overwrite it from an authenticated response.

**PR 2 hand-off (from PR 1 review):** the settings columns default to `'en'` /
`'{en}'`, which is right for upgraded installations but resets a fresh install.
While no settings row exists every shipped language is offered, but the
getting-started wizard's first save (an upsert of three columns in
`getting-started-server-actions.ts`) creates the row as English-only, so an
operator working in Arabic is switched to English mid-wizard. The wizard must
send `default_locale` and `enabled_locales` with that upsert, using the
admin control from 3.2.

### 6.1 Logistics: fork staging, single upstream PR

The upstream master moves fast (856 commits in the 30 days to 2026-10-05), so
the series is staged in a fork and offered upstream once complete.

- **Branches:**
  - `weilu/statbus:master` mirrors upstream master and is never committed to.
  - `weilu/statbus:i18n` is the integration branch.
  - One `feature/i18n-<step>` branch per PR in the table, targeting `i18n`.
    The fork must be a real GitHub fork so the final cross-repo PR works.
- **Review in the fork:** Copilot and the contributor review each PR, which is
  then **squash-merged**. `i18n` is therefore upstream master plus one commit per
  PR.
- **Sync:** rebase `i18n` onto upstream master (weekly and before the final PR),
  never merge, so the series stays a clean stack.
  - **PR 3 is re-generated, not rebased:** drop the codemod commit and re-run the
    committed script on the new base. The ESLint guard catches classes upstream
    added in between.
  - **Migration re-stamp:** StatBus orders migrations by filename timestamp, so
    PR 1's migration gets a fresh timestamp at the final rebase.
- **Fork CI:** run only the self-contained workflows (`app_build_and_lint`,
  `fast-tests` including `app-i18n-e2e`, `go-test`). Disable the
  release/deploy/LXD/image/cloud workflows in the fork's Actions settings rather
  than by editing files, which would leak into the upstream diff.
- **Upstream PR:** `weilu:i18n` → `statisticsnorway:master` with the commit
  series and this table. SSB can take it whole, review it commit by commit, or
  ask for the original PRs to be re-opened upstream in order.
- **This design note goes to SSB before PR 1.** PR 1 changes `auth.auth_response`
  and `public.settings`, which are shared contracts. Objections are cheap now and
  expensive after months of fork work.

### 6.2 Yemen staging and production

- **Production** stays on the upstream stable channel and receives this work
  only through an SSB release.
- **Staging** runs fork builds for user acceptance testing. All four images
  (`statbus-app`, `-worker`, `-db`, `-proxy`) are tagged `COMMIT_SHORT`, and a
  fork commit has none on GHCR, so staging builds all of them locally. The
  upgrade service always `docker compose pull`s, so it must be **disabled on
  staging** or it will move the box off the fork build.
- **Runbook:**
  1. Restore a fresh Yemen production dump: `./sb db dump` on production, then
     `./sb db restore <file>` on staging.
  2. `git fetch fork && git checkout <i18n sha>`.
  3. `./sb config generate`.
  4. `./sb build all`. Next.js needs about 2–4 GB RAM. **CONFIRM** db image
     build time.
  5. `./sb migrate up`, then `./sb start all`.
  6. Admin sets `{ar,en}` / `ar`.
- **Staging is disposable:** each refresh starts from a production dump. That
  also absorbs the PR 1 migration re-stamp. When production reaches the upstream
  release, rebuild staging from production or retire it.

## 7. Out of scope (named follow-ups)

1. **DB-originated messages** (import errors, `RAISE` texts) stay English. A
   likely future path is stable error codes translated in the app.
2. **Classification names** (ISIC, region, sector, legal form) are single `name`
   columns and need their own translation design. An official Arabic ISIC may
   exist to import.
3. **Number and date formatting** is unchanged. Arabic-Indic vs Western digits
   and Hijri vs Gregorian dates are product decisions for Yemen NSO.
4. **Email templates per language** belong to STATBUS-142, which consumes
   `auth.effective_locale()`.
5. **Language-prefixed URLs** can be adopted later as a routing-only change
   (3.4).
6. **More languages** each need an `ALTER TYPE public.locale ADD VALUE` plus a
   JSON file. nscreg's ru/ky-KG are candidates.
7. **Broader Playwright coverage** beyond the i18n manifest, if SSB wants
   browser testing generally.

## 8. Proposed backlog ticket (draft for SSB)

> **Title:** i18n: user-selectable UI language with RTL support (Arabic first)
>
> Add per-user language selection to the web app with an instance default and an
> instance-enabled language list (`public.settings`), resolved by one DB function
> that email (STATBUS-142 M3) also uses. Library: next-intl without URL
> prefixes. RTL via a logical-class codemod, an ESLint guard and a
> `DirectionProvider`. English-only instances see no change. Delivered as a
> commit series (DB model → app foundation → RTL codemod → E2E harness → one
> commit per translated area), first used by the Yemen installation.
> Design: `doc/design/i18n-rtl.md`.
>
> **Acceptance criteria:**
> - With `enabled_locales = {en}`, the UI is unchanged and no switcher shows.
> - The language resolves user choice → instance default → `en`, and the email
>   outbox uses the same resolver.
> - Arabic renders `dir="rtl"` with mirrored layout on every manifest route.
>   The `app-i18n-e2e` job checks this.
> - Untranslated keys fall back to English, and CI reports missing keys per
>   language.
