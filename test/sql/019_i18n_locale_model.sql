-- i18n PR 1: the language model (doc/design/i18n-rtl.md section 2).
--
-- WHY THIS TEST EXISTS. The whole fallback rule (user choice -> instance
-- default -> 'en') lives in auth.effective_locale so the app and email share
-- it. Each layer that can refuse or fall through is asserted on its own:
-- the settings CHECKs, the auth.user trigger, RLS behind the INVOKER door, and
-- the auth responses that carry the result to the app.

-- OWN TRANSACTION, REQUIRED: pg_regress does not wrap test files, and the
-- SAVEPOINTs below need one (.claude/rules/testing.md). BEGIN must come BEFORE
-- setup.sql: setup resets worker.tasks, and outside a transaction that reset
-- commits into the shared test database and deletes the pending recurring
-- tasks that 096_worker_recurring_maintenance_survives_failure expects.
BEGIN;

\i test/setup.sql

-- login() signs a JWT; same test-only settings as 013_auth.
SET LOCAL "app.settings.jwt_secret" TO 'test-jwt-secret-for-testing-only';
SET LOCAL "app.settings.jwt_exp" TO '3600';
SET LOCAL "app.settings.refresh_jwt_exp" TO '86400';
SET LOCAL "app.settings.deployment_slot_code" TO 'test';

-- Terse errors: a refusal's DETAIL prints the whole settings row, including
-- serial and seed-derived foreign-key ids that move whenever the seed changes.
\set VERBOSITY terse

\echo === Baseline: shipped languages, door security mode, grants ===
SELECT enum_range(NULL::public.locale) AS shipped_locales;
-- INVOKER is load-bearing: RLS update_own_user is what confines the door to
-- the caller's own row. A DEFINER door would bypass it.
SELECT p.proname, p.prosecdef AS security_definer
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'user_locale_set';
-- The login page resolves its language through an anonymous auth_status call,
-- which works only because auth_status was never revoked from PUBLIC.
SELECT has_function_privilege('anon', 'public.auth_status()', 'EXECUTE') AS anon_can_call_auth_status;

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
\echo === F: user_locale_set changes only the row of the calling user ===
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
\echo --- anonymous callers cannot change any row
SAVEPOINT f_anon;
SET LOCAL ROLE anon;
\set ON_ERROR_STOP off
SELECT public.user_locale_set('en');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT f_anon;
\echo --- a soft-deleted user cannot write through the door
-- RLS update_own_user does not look at deleted_at, and a deleted user can
-- still hold an unexpired access token; the door's own filter is the guard.
SAVEPOINT f_deleted;
UPDATE auth."user" SET deleted_at = now() WHERE email = 'test.regular@statbus.org';
CALL test.set_user_from_email('test.regular@statbus.org');
\set ON_ERROR_STOP off
SELECT public.user_locale_set('en');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT f_deleted;
\echo --- a disabled language is refused through the door too
SAVEPOINT f2;
UPDATE public.settings SET enabled_locales = '{ar}', default_locale = 'ar';
CALL test.set_user_from_email('test.regular@statbus.org');
\set ON_ERROR_STOP off
SELECT public.user_locale_set('en');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT f2;

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
\echo --- login with a stored choice: the language of the user
UPDATE auth."user" SET locale = 'en' WHERE email = 'test.regular@statbus.org';
SELECT is_authenticated, locale, enabled_locales
  FROM public.login('test.regular@statbus.org', 'Regular#123!');
\echo --- expired token: user unknown until refresh, so the instance default
SELECT expired_access_token_call_refresh, locale
  FROM auth.build_auth_response(p_expired_access_token_call_refresh => true);
ROLLBACK TO SAVEPOINT g;

\echo
\echo === H: resolvers answer from the real settings row whatever the caller sees ===
-- A role that may read settings but matches no RLS policy (a future email
-- sender, say) must not silently get the fresh-install fallback.
SAVEPOINT h;
CREATE ROLE i18n_settings_blind NOLOGIN;
GRANT USAGE ON SCHEMA auth TO i18n_settings_blind;
GRANT SELECT ON public.settings TO i18n_settings_blind;
SET LOCAL ROLE i18n_settings_blind;
SELECT count(*) AS settings_rows_visible FROM public.settings;
SELECT auth.enabled_locales() AS enabled, auth.default_locale() AS default_locale;
RESET ROLE;
ROLLBACK TO SAVEPOINT h;

ROLLBACK;
