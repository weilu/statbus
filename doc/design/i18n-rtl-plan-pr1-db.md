# i18n PR 1: DB language model, implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** add the per-instance and per-user language model to the database.
That means the `public.locale` enum, `settings.default_locale`/`enabled_locales`,
`auth.user.locale`, the resolver functions, an enabled-language trigger, the
`public.user_locale_set` door, and `locale`/`enabled_locales` on every auth
response. No UI change.

**Architecture:** one migration pair (up/down) plus one pg_regress test. The
design's whole resolution rule lives in SQL (`auth.effective_locale`), so the app
(PR 2) and email (STATBUS-142) consume one function instead of re-implementing
the fallback. Existing installations get `default_locale = 'en'` and
`enabled_locales = '{en}'`, so they behave exactly as before.

**Tech Stack:** PostgreSQL 18, plpgsql, pg_regress (`./dev.sh test`), the Go
`./sb` CLI (migrate, types), PostgREST.

**Spec:** `doc/design/i18n-rtl.md`, sections 2 and 5. This plan implements PR 1
of the section 6 table.

## Global Constraints

- Follow `.claude/rules/sql.md` and AGENTS.md SQL conventions:
  - dollar quotes named after the function (`AS $effective_locale$`);
  - explicit `AS` table aliases;
  - `SET search_path = public, auth, pg_temp` on new functions;
  - variables named after their type.
- Modify existing functions by **dumping the current definition** with `\sf`, not
  by retyping. Never redirect stderr into a dump (`2>&1`).
- Migration and doc/db/types regeneration land in **one commit** (the
  pre-commit hook pairs them).
- **Never touch `../statbus-release` or the running `statbus-ye-*` containers.**
  They are the Yemen pipeline's live stack on slot offset 1 (ports 3010–3016).
  This worktree uses slot code `i18n`, offset 2 (ports 3020–3026).
- **Ask the user before** `./dev.sh create-db`, `recreate-database`,
  `delete-db` or `./sb migrate down` (`.claude/rules/testing.md`).
- Long commands (`./dev.sh test fast`, image builds) run in the background with
  `| tee tmp/<name>.log`.
- No anxiety tests: every assertion checks a real invariant.
- Never assert raw user ids. Use emails and booleans.

## Review Focus

1. **Existing installation upgraded** (Yemen and Norway production already
   have a `settings` row): the row must come out as `en` / `{en}` with no
   behaviour change. Pinned by test section B.
2. **Admin disables a language users had chosen:** their effective language
   falls back to the instance default, the stored choice is kept, and
   re-enabling restores it. Pinned by section D.
3. **Admin enters an invalid configuration** (default not enabled, empty list,
   duplicates, NULL entry): a CHECK refuses with a constraint name that says
   which rule failed. Pinned by section C.
4. **Expired access token:** `auth_status` returns the *instance default*, not
   the user's language, because the user is unknown until refresh. This is
   correct for the DB, but PR 2 must not overwrite the locale cookie on an
   expired-token response. Pinned by section G, with a hand-off note in Task 4.
5. **Anonymous or deleted caller hits the door:** anon has no EXECUTE on
   `user_locale_set`, and a caller with no active user row gets an error, not a
   silent no-op. Pinned by the baseline and section F.

---

## File structure

| File | Responsibility |
|---|---|
| `migrations/<ts>_i18n_locale_model.up.sql` | Enum, columns, constraints, helper functions, trigger, door, auth response extension |
| `migrations/<ts>_i18n_locale_model.down.sql` | Exact inverse, restoring the dumped original `auth.build_auth_response` |
| `test/sql/019_i18n_locale_model.sql` | pg_regress test for every rule above (019 is free and falls in the fast suite) |
| `test/expected/019_i18n_locale_model.out` | Blessed output after review |
| `test/expected/013_auth.out`, `015_*.out`, `016_*.out` | Re-blessed only if their diff is purely the new columns/objects |
| `doc/db/**`, `app/src/lib/database.types.ts` | Regenerated |
| `doc/design/smtp2go-email.md` | M3 marked DECIDED, pointing at `auth.effective_locale` |

`<ts>` is the timestamp `./sb migrate new` generates. Use the generated names
everywhere below.

---

### Task 0: Isolated dev environment for this worktree

There is no `./sb` binary, `.env.config`, Go or pnpm in this checkout today. The
only running StatBus stack belongs to the Yemen pipeline.

**Files:** `.env.config` (gitignored, created), `sb` (gitignored, built).

- [ ] **Step 1: Install toolchains (ask the user first; these are machine-wide installs).**

```bash
brew install go            # cli/go.mod requires go >= 1.25.5
corepack enable pnpm       # app/package.json pins pnpm@10.28.1; used in Task 3 for tsc
go version && pnpm --version
```

- [ ] **Step 2: Build `./sb`, the same way CI does.**

```bash
cd cli && CGO_ENABLED=0 go build -trimpath -o ../sb . && cd ..
./sb --help | head -5
```

- [ ] **Step 3: Write a config for slot `i18n`, offset 2, which won't collide with `statbus-ye`.**

```bash
cat > .env.config <<'CFG'
DEPLOYMENT_SLOT_NAME=i18n
DEPLOYMENT_SLOT_CODE=i18n
DEPLOYMENT_SLOT_PORT_OFFSET=2
CADDY_DEPLOYMENT_MODE=development
SITE_DOMAIN=localhost
CFG
./sb config generate
```

Expected: `.env` and `.env.credentials` exist, and `./sb dotenv -f .env get
COMMIT_SHORT` prints the current short sha.

- [ ] **Step 4: Build images and start everything except the app (PR 1 needs no app).**

```bash
./sb build all_except_app 2>&1 | tee tmp/i18n-build.log     # run in background
./sb start all_except_app
docker ps --format '{{.Names}}' | grep statbus-i18n
```

Expected: `statbus-i18n-db`, `-rest`, `-worker` and `-proxy` are running, and
`statbus-ye-*` is untouched.

- [ ] **Step 5: Create the DB (ask the user first, per testing rules).**

```bash
./dev.sh create-db 2>&1 | tee tmp/i18n-create-db.log
```

- [ ] **Step 6: Baseline the fast suite before any change.** Pre-existing
  failures must be known, not later blamed on this PR.

```bash
./dev.sh test fast 2>&1 | tee tmp/i18n-baseline-fast.log    # background
```

Record the list of failing tests (if any) in `tmp/agents/<agent>.md`. No commit.

---

### Task 1: Locale model, resolver, trigger and door

**Files:**
- Create: `migrations/<ts>_i18n_locale_model.up.sql` / `.down.sql`
- Create: `test/sql/019_i18n_locale_model.sql`, sections Baseline and A–F

**Interfaces (produced):**
- `public.locale` enum `('en','ar')`
- `public.locale_array_is_set(public.locale[]) RETURNS boolean`, IMMUTABLE
- `public.settings.default_locale public.locale NOT NULL DEFAULT 'en'`,
  `public.settings.enabled_locales public.locale[] NOT NULL DEFAULT '{en}'`
- `auth."user".locale public.locale NULL`
- `auth.enabled_locales() RETURNS public.locale[]`: the settings list, or every
  shipped value when no settings row exists
- `auth.default_locale() RETURNS public.locale`: the settings default, or `'en'`
- `auth.effective_locale(p_user auth."user") RETURNS public.locale`: the user's
  choice if non-NULL and enabled, else the default. A NULL user gives the
  default.
- `public.user_locale_set(p_locale public.locale) RETURNS public.locale`
  (SECURITY INVOKER) returns the caller's new effective locale

- [ ] **Step 1: Create the migration pair.**

```bash
./sb migrate new --description "i18n locale model"
ls -r migrations/*.sql | head -2      # note the generated <ts>
```

- [ ] **Step 2: Write the failing test** `test/sql/019_i18n_locale_model.sql`.

```sql
-- i18n PR 1: the language model (doc/design/i18n-rtl.md section 2).
--
-- WHY THIS TEST EXISTS. The whole fallback rule (user choice -> instance
-- default -> 'en') lives in auth.effective_locale so the app and email share
-- it. Each layer that can refuse or fall through is asserted on its own:
-- the settings CHECKs, the auth.user trigger, RLS behind the INVOKER door, and
-- the auth responses that carry the result to the app.

\i test/setup.sql

-- OWN TRANSACTION, REQUIRED: pg_regress does not wrap test files, and the
-- SAVEPOINTs below need one (.claude/rules/testing.md).
BEGIN;

-- login() signs a JWT; same test-only settings as 013_auth.
SET LOCAL "app.settings.jwt_secret" TO 'test-jwt-secret-for-testing-only';
SET LOCAL "app.settings.jwt_exp" TO '3600';
SET LOCAL "app.settings.refresh_jwt_exp" TO '86400';
SET LOCAL "app.settings.deployment_slot_code" TO 'test';

\echo === Baseline: shipped languages, door security mode, grants ===
SELECT enum_range(NULL::public.locale) AS shipped_locales;
-- INVOKER is load-bearing: RLS update_own_user is what confines the door to
-- the caller's own row. A DEFINER door would bypass it.
SELECT p.proname, p.prosecdef AS security_definer
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'user_locale_set';
-- The login page resolves its language through an anonymous auth_status call,
-- which works only because auth_status was never revoked from PUBLIC.
SELECT has_function_privilege('anon', 'public.user_locale_set(public.locale)', 'EXECUTE') AS anon_can_set_locale,
       has_function_privilege('anon', 'public.auth_status()', 'EXECUTE') AS anon_can_call_auth_status;

\echo
\echo === A: fresh install (no settings row) offers every shipped language, default en ===
SAVEPOINT a;
DELETE FROM public.settings;
SELECT auth.enabled_locales() AS enabled,
       auth.default_locale() AS default_locale,
       auth.effective_locale(NULL::auth."user") AS effective_for_nobody;
ROLLBACK TO SAVEPOINT a;

\echo
\echo === B: a settings row written without locale columns is English-only ===
DELETE FROM public.settings;
INSERT INTO public.settings(activity_category_standard_id, country_id, region_version_id)
SELECT (SELECT id FROM public.activity_category_standard WHERE code = 'nace_v2.1')
     , (SELECT id FROM public.country WHERE iso_2 = 'NO')
     , (SELECT id FROM public.region_version WHERE code = 'initial');
SELECT default_locale, enabled_locales FROM public.settings;
SELECT auth.enabled_locales() AS enabled, auth.default_locale() AS default_locale;

\echo
\echo === C: settings constraints refuse incoherent configurations ===
\echo --- default not enabled
SAVEPOINT c1;
\set ON_ERROR_STOP off
UPDATE public.settings SET default_locale = 'ar';
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT c1;
\echo --- empty list (refused by the default-must-be-enabled rule)
SAVEPOINT c2;
\set ON_ERROR_STOP off
UPDATE public.settings SET enabled_locales = '{}';
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT c2;
\echo --- duplicate entry
SAVEPOINT c3;
\set ON_ERROR_STOP off
UPDATE public.settings SET enabled_locales = '{en,en}';
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT c3;
\echo --- NULL entry
SAVEPOINT c4;
\set ON_ERROR_STOP off
UPDATE public.settings SET enabled_locales = ARRAY['en', NULL]::public.locale[];
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT c4;
\echo --- the Yemen configuration is accepted
UPDATE public.settings SET enabled_locales = '{ar,en}', default_locale = 'ar';
SELECT default_locale, enabled_locales FROM public.settings;

\echo
\echo === D: effective locale fallback order ===
SAVEPOINT d;
SELECT u.locale AS stored, auth.effective_locale(u) AS effective
  FROM auth."user" AS u WHERE u.email = 'test.regular@statbus.org';
UPDATE auth."user" SET locale = 'en' WHERE email = 'test.regular@statbus.org';
SELECT u.locale AS stored, auth.effective_locale(u) AS effective
  FROM auth."user" AS u WHERE u.email = 'test.regular@statbus.org';
\echo --- disabling the chosen language falls through but keeps the stored choice
UPDATE public.settings SET enabled_locales = '{ar}', default_locale = 'ar';
SELECT u.locale AS stored, auth.effective_locale(u) AS effective
  FROM auth."user" AS u WHERE u.email = 'test.regular@statbus.org';
\echo --- re-enabling restores it
UPDATE public.settings SET enabled_locales = '{ar,en}';
SELECT u.locale AS stored, auth.effective_locale(u) AS effective
  FROM auth."user" AS u WHERE u.email = 'test.regular@statbus.org';
ROLLBACK TO SAVEPOINT d;

\echo
\echo === E: the trigger refuses a disabled language whoever writes it ===
SAVEPOINT e;
UPDATE public.settings SET enabled_locales = '{ar}', default_locale = 'ar';
\set ON_ERROR_STOP off
UPDATE auth."user" SET locale = 'en' WHERE email = 'test.admin@statbus.org';
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT e;

\echo
\echo === F: user_locale_set changes only the caller's own row ===
SAVEPOINT f;
CALL test.set_user_from_email('test.regular@statbus.org');
SELECT public.user_locale_set('en') AS effective_after_set;
\echo --- NULL resets to the instance default
SELECT public.user_locale_set(NULL) AS effective_after_reset;
SELECT public.user_locale_set('en') AS effective_after_set_again;
RESET ROLE;
SELECT email, locale FROM auth."user"
 WHERE email IN ('test.admin@statbus.org', 'test.regular@statbus.org')
 ORDER BY email;
ROLLBACK TO SAVEPOINT f;
\echo --- a disabled language is refused through the door too
SAVEPOINT f2;
UPDATE public.settings SET enabled_locales = '{ar}', default_locale = 'ar';
CALL test.set_user_from_email('test.regular@statbus.org');
\set ON_ERROR_STOP off
SELECT public.user_locale_set('en');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT f2;

ROLLBACK;
```

- [ ] **Step 3: Run it and watch it fail.**

```bash
./dev.sh test 019_i18n_locale_model 2>&1 | tee tmp/i18n-019-red.log
```

Expected: FAIL. `type "public.locale" does not exist`, and no expected file
yet.

- [ ] **Step 4: Write the up migration** (Task 2 appends the auth-response part to this same file).

```sql
BEGIN;

CREATE TYPE public.locale AS ENUM ('en', 'ar');

-- CHECK constraints may only call IMMUTABLE functions; this one makes
-- "a set of languages" (no NULLs, no duplicates) checkable.
CREATE FUNCTION public.locale_array_is_set(p_locales public.locale[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $locale_array_is_set$
  SELECT count(l) = cardinality(p_locales) AND count(l) = count(DISTINCT l)
    FROM unnest(p_locales) AS l;
$locale_array_is_set$;

ALTER TABLE public.settings
  ADD COLUMN default_locale public.locale NOT NULL DEFAULT 'en',
  ADD COLUMN enabled_locales public.locale[] NOT NULL DEFAULT '{en}',
  -- Also rules out an empty list: default_locale is NOT NULL and must be in it.
  ADD CONSTRAINT settings_default_locale_enabled
    CHECK (default_locale = ANY (enabled_locales)),
  ADD CONSTRAINT settings_enabled_locales_is_set
    CHECK (public.locale_array_is_set(enabled_locales));

-- NULL means "follow the instance default", so changing the default moves
-- every user who never chose.
ALTER TABLE auth."user" ADD COLUMN locale public.locale NULL;

-- Before getting-started creates the settings row, every shipped language is
-- offered, so the operator can run the wizard in their own language.
CREATE FUNCTION auth.enabled_locales()
RETURNS public.locale[]
LANGUAGE sql
STABLE
SET search_path = public, auth, pg_temp
AS $enabled_locales$
  SELECT COALESCE(
    (SELECT s.enabled_locales FROM public.settings AS s),
    enum_range(NULL::public.locale)
  );
$enabled_locales$;

CREATE FUNCTION auth.default_locale()
RETURNS public.locale
LANGUAGE sql
STABLE
SET search_path = public, auth, pg_temp
AS $default_locale$
  SELECT COALESCE(
    (SELECT s.default_locale FROM public.settings AS s),
    'en'::public.locale
  );
$default_locale$;

-- The single fallback rule shared by the app (via auth responses) and email
-- (STATBUS-142 M3). A stored choice that is no longer enabled falls through
-- without being overwritten, so re-enabling the language restores it.
CREATE FUNCTION auth.effective_locale(p_user auth."user")
RETURNS public.locale
LANGUAGE sql
STABLE
SET search_path = public, auth, pg_temp
AS $effective_locale$
  SELECT CASE
    WHEN p_user.locale IS NOT NULL AND p_user.locale = ANY (auth.enabled_locales())
      THEN p_user.locale
    ELSE auth.default_locale()
  END;
$effective_locale$;

-- On the table, not in the door, so admin edits and any future door obey it.
CREATE FUNCTION auth.user_locale_enabled_check()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, auth, pg_temp
AS $user_locale_enabled_check$
BEGIN
  IF NEW.locale IS NOT NULL AND NOT (NEW.locale = ANY (auth.enabled_locales())) THEN
    RAISE EXCEPTION 'Language % is not enabled on this installation (enabled: %)',
      NEW.locale, auth.enabled_locales()
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$user_locale_enabled_check$;

CREATE TRIGGER user_locale_enabled_check
  BEFORE INSERT OR UPDATE OF locale ON auth."user"
  FOR EACH ROW EXECUTE FUNCTION auth.user_locale_enabled_check();

-- SECURITY INVOKER is load-bearing: authenticated already holds UPDATE on
-- auth.user under RLS update_own_user, which confines this to the caller's
-- own row. DEFINER would bypass that policy.
CREATE FUNCTION public.user_locale_set(p_locale public.locale)
RETURNS public.locale
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth, pg_temp
AS $user_locale_set$
DECLARE
  _user auth."user";
BEGIN
  UPDATE auth."user" AS u
     SET locale = p_locale
   WHERE u.email = current_user
     AND u.deleted_at IS NULL
  RETURNING u.* INTO _user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active user for role %', current_user;
  END IF;

  RETURN auth.effective_locale(_user);
END;
$user_locale_set$;

REVOKE EXECUTE ON FUNCTION public.user_locale_set(public.locale) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.user_locale_set(public.locale) TO authenticated;

END;
```

- [ ] **Step 5: Write the down migration** (Task 2 prepends its inverse at the top).

```sql
BEGIN;

DROP FUNCTION public.user_locale_set(public.locale);
DROP TRIGGER user_locale_enabled_check ON auth."user";
DROP FUNCTION auth.user_locale_enabled_check();
DROP FUNCTION auth.effective_locale(auth."user");
DROP FUNCTION auth.default_locale();
DROP FUNCTION auth.enabled_locales();
ALTER TABLE auth."user" DROP COLUMN locale;
ALTER TABLE public.settings
  DROP CONSTRAINT settings_enabled_locales_is_set,
  DROP CONSTRAINT settings_default_locale_enabled,
  DROP COLUMN enabled_locales,
  DROP COLUMN default_locale;
DROP FUNCTION public.locale_array_is_set(public.locale[]);
DROP TYPE public.locale;

END;
```

- [ ] **Step 6: Apply, run the test, and review the output line by line.**

```bash
./sb migrate up
./dev.sh test 019_i18n_locale_model 2>&1 | tee tmp/i18n-019-green.log
cat test/results/019_i18n_locale_model.out
```

The output must match this table, **including the error text**. Each refusal
must name its constraint or carry the trigger/door message:

| Section | Expected |
|---|---|
| Baseline | `{en,ar}`; `user_locale_set f`; `anon_can_set_locale f`, `anon_can_call_auth_status t` |
| A | `{en,ar}`, `en`, `en` |
| B | `en`, `{en}`; then `{en}`, `en` |
| C | `settings_default_locale_enabled` ×2, `settings_enabled_locales_is_set` ×2; then `ar`, `{ar,en}` |
| D | (NULL, `ar`) → (`en`, `en`) → (`en`, `ar`) → (`en`, `en`) |
| E | `Language en is not enabled on this installation (enabled: {ar})` |
| F | `en`, `ar`, `en`; admin NULL, regular `en`; then the same "not enabled" error |

If `anon_can_call_auth_status` is `f`, stop. The spec's anonymous login-page
path is wrong, and the design needs revisiting before PR 2, so report back
rather than patching around it.

- [ ] **Step 7: Bless.**

```bash
cp test/results/019_i18n_locale_model.out test/expected/019_i18n_locale_model.out
```

No commit yet. The migration commits together with its regeneration in Task 3.

---

### Task 2: Auth responses carry the language

**Files:**
- Modify: `migrations/<ts>_i18n_locale_model.up.sql` / `.down.sql` (same pair)
- Modify: `test/sql/019_i18n_locale_model.sql` (add section G before the final `ROLLBACK;`)

**Interfaces:**
- Consumes: `auth.effective_locale(auth."user")`, `auth.enabled_locales()` from Task 1
- Produces: `auth.auth_response.locale public.locale`,
  `auth.auth_response.enabled_locales public.locale[]`, filled by
  `auth.build_auth_response` on every path (`login`, `refresh`, `logout`,
  `auth_status`)

- [ ] **Step 1: Add the failing test section G** (insert before the final `ROLLBACK;`).

```sql
\echo
\echo === G: every auth response carries the resolved language ===
SAVEPOINT g;
DO $$ BEGIN
  PERFORM set_config('request.cookies', '{}', true);
  PERFORM set_config('request.headers', '{}', true);
END $$;
\echo --- anonymous (login page): instance default and the enabled list
SET LOCAL ROLE anon;
SELECT is_authenticated, locale, enabled_locales FROM public.auth_status();
RESET ROLE;
\echo --- login without a stored choice: instance default
SELECT is_authenticated, locale, enabled_locales
  FROM public.login('test.regular@statbus.org', 'Regular#123!');
\echo --- login with a stored choice: the user's language
UPDATE auth."user" SET locale = 'en' WHERE email = 'test.regular@statbus.org';
SELECT is_authenticated, locale, enabled_locales
  FROM public.login('test.regular@statbus.org', 'Regular#123!');
\echo --- expired token: user unknown until refresh, so the instance default
SELECT expired_access_token_call_refresh, locale
  FROM auth.build_auth_response(p_expired_access_token_call_refresh => true);
ROLLBACK TO SAVEPOINT g;
```

- [ ] **Step 2: Run it and watch it fail.**

```bash
./dev.sh test 019_i18n_locale_model 2>&1 | tee tmp/i18n-019-g-red.log
```

Expected: FAIL with `column "locale" does not exist`.

- [ ] **Step 2b: Roll back Task 1's migration *before* editing either file.**
  Ask the user first. Once the down file gains the `DROP ATTRIBUTE` lines it can
  no longer undo Task 1's version, which never added them.

```bash
./sb migrate down
```

- [ ] **Step 3: Dump the current builder.** Keep stderr on the terminal.

```bash
echo '\sf auth.build_auth_response' | ./sb psql > tmp/build_auth_response.sql
diff <(sed -n '/CREATE OR REPLACE/,/\$function\$$/p' tmp/build_auth_response.sql) \
     <(sed -n '/CREATE OR REPLACE/,/\$function\$$/p' "doc/db/function/auth_build_auth_response(auth_user, boolean, auth_login_error_code, timestamptz).md")
```

Expected: no diff. If it differs, the dump wins. Use it in steps 4–5.

- [ ] **Step 4: Append to the up migration**, before its final `END;`.

```sql
ALTER TYPE auth.auth_response
  ADD ATTRIBUTE locale public.locale,
  ADD ATTRIBUTE enabled_locales public.locale[];
```

Then paste the dumped `CREATE OR REPLACE FUNCTION auth.build_auth_response…`
and insert these two lines immediately before `RETURN result;`. They go after
`END IF;`, so both branches get them:

```sql
  -- Resolved for anonymous responses too: the login page renders in the
  -- instance default before anyone signs in.
  result.locale := auth.effective_locale(p_user_record);
  result.enabled_locales := auth.enabled_locales();
```

- [ ] **Step 5: Prepend to the down migration**, right after `BEGIN;`. The
  original builder must be restored before its attributes can be dropped.

Paste the **unmodified** dump from `tmp/build_auth_response.sql`, then:

```sql
ALTER TYPE auth.auth_response
  DROP ATTRIBUTE enabled_locales,
  DROP ATTRIBUTE locale;
```

- [ ] **Step 6: Re-apply and run.**

```bash
./sb migrate up
./dev.sh test 019_i18n_locale_model 2>&1 | tee tmp/i18n-019-g-green.log
```

Expected section G output:
- anon: `f`, `ar`, `{ar,en}`
- login without choice: `t`, `ar`, `{ar,en}`
- login with choice: `t`, `en`, `{ar,en}`
- expired: `t`, `ar`

The settings row from section B/C (`{ar,en}` / `ar`) is still in effect here.

- [ ] **Step 7: Prove the down migration is a true inverse.**

```bash
echo '\sf auth.build_auth_response' | ./sb psql > tmp/build_auth_response.after-up.sql
./sb migrate down
echo '\sf auth.build_auth_response' | ./sb psql > tmp/build_auth_response.after-down.sql
diff tmp/build_auth_response.sql tmp/build_auth_response.after-down.sql   # expect: no output
echo '\dT public.locale' | ./sb psql                                       # expect: no rows
./sb migrate up
```

- [ ] **Step 8: Bless 019 again.**

```bash
cp test/results/019_i18n_locale_model.out test/expected/019_i18n_locale_model.out
```

---

### Task 3: Regenerate, re-bless affected tests, commit

**Files:** `doc/db/**`, `app/src/lib/database.types.ts`, `test/expected/013_auth.out`,
`test/expected/015_generate_data_model_doc.out`,
`test/expected/016_generate_typescript_types_from_db.out` (only if changed).

- [ ] **Step 1: Regenerate**, following the `dev.sh` landing flow.

```bash
./sb migrate up --target seed && ./dev.sh create-test-template
./dev.sh generate-doc-db && ./sb types generate
git status --short doc/db app/src/lib/database.types.ts
```

Expected changes:
- new `doc/db/function/` files for the 6 functions;
- `public_settings.md` and `auth_user.md` gain the columns, constraints and trigger;
- `database.types.ts` gains `locale` in `Enums`, the settings columns, and `user_locale_set`.

- [ ] **Step 2: Run the fast suite** (background).

```bash
./dev.sh test fast 2>&1 | tee tmp/i18n-fast.log
./dev.sh diff-fail-all pipe 2>&1 | tee tmp/i18n-fast-diffs.log
```

- [ ] **Step 3: Classify every diff.**

| Diff shape | Action |
|---|---|
| A test that also failed in the Task 0 baseline, with the same diff | Leave it. Report it, don't bless. |
| `013_auth`: auth responses gain `"locale"` / `"enabled_locales"` keys and nothing else | Bless |
| `015` / `016`: only the new enum, columns, functions and type fields | Bless |
| Anything else | **Stop.** It's a real regression; investigate it (superpowers:systematic-debugging). |

Bless a test by copying `test/results/<name>.out` to `test/expected/`. For
`test/expected/explain/` and `performance/`, apply `.claude/rules/testing.md`:
`git checkout` trivial drift.

- [ ] **Step 4: Type-check the app** against the regenerated types.

```bash
cd app && pnpm install --frozen-lockfile && pnpm run tsc && cd ..
```

Expected: PASS. New settings columns have defaults, so existing `settings`
inserts still type-check.

- [ ] **Step 5: Commit.** Check the staged list before committing.

```bash
git add migrations/*_i18n_locale_model.*.sql test/sql/019_i18n_locale_model.sql \
        test/expected/019_i18n_locale_model.out doc/db app/src/lib/database.types.ts
git add test/expected/013_auth.out test/expected/015_generate_data_model_doc.out \
        test/expected/016_generate_typescript_types_from_db.out 2>/dev/null
git diff --cached --stat     # must list only the files above
git commit -m "i18n: Add locale model, resolver and user_locale_set door"
```

Use the session's attribution trailer. After the commit, re-run
`./dev.sh generate-doc-db` once on the clean tree to write the freshness stamp,
as the landing flow requires.

---

### Task 4: Close the loop in the docs

**Files:** `doc/design/smtp2go-email.md`, `doc/design/i18n-rtl.md`.

- [ ] **Step 1: Mark M3 decided** in `smtp2go-email.md`, replacing the open M3 bullet:

```markdown
- **M3 — locale source. DECIDED** (`doc/design/i18n-rtl.md` §2): populate
  `email_outbox.locale` from `auth.effective_locale(user)` — the user's
  `auth.user.locale` if set and enabled, else `public.settings.default_locale`,
  else `'en'`. The same function feeds the app's auth responses.
```

- [ ] **Step 2: Add a PR 2 hand-off** at the end of section 6 in
  `i18n-rtl.md`, from Review Focus 4:

```markdown
**PR 2 hand-off (from PR 1):** an `auth_status` response with
`expired_access_token_call_refresh = true` carries the instance default, not the
user's language. The app must keep its existing locale cookie in that case and
only overwrite it from an authenticated response.
```

- [ ] **Step 3: Commit.**

```bash
git add doc/design/smtp2go-email.md doc/design/i18n-rtl.md
git diff --cached --stat
git commit -m "doc: Record STATBUS-142 M3 locale decision and PR 2 hand-off"
```

---

## Out of this plan

The app (PR 2), RTL codemod (PR 3), E2E harness (PR 4), translations (PR 5+),
creating the `weilu/statbus` fork, and opening the fork PR. Each gets its own
plan once this PR is reviewed.
