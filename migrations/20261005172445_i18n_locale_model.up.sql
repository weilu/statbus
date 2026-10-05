-- Migration 20261005172445: i18n locale model
-- Design: doc/design/i18n-rtl.md section 2.
BEGIN;

CREATE TYPE public.locale AS ENUM ('en', 'ar');

-- CHECK constraints may only call IMMUTABLE functions; this one makes
-- "a set of languages" (flat, no NULLs, no duplicates) checkable. The
-- dimension check matters because unnest flattens '{{en,ar}}', which would
-- otherwise pass and reach the API as a nested JSON array.
CREATE FUNCTION public.locale_array_is_set(p_locales public.locale[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $locale_array_is_set$
  SELECT COALESCE(array_ndims(p_locales), 1) = 1
     AND count(l) = cardinality(p_locales)
     AND count(l) = count(DISTINCT l)
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
-- SECURITY DEFINER so the answer never depends on the caller's RLS: a role that
-- matches no settings policy would otherwise see "no row" and silently get the
-- fresh-install fallback. The values are not secret (auth_status shows them to
-- anonymous visitors).
CREATE FUNCTION auth.enabled_locales()
RETURNS public.locale[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $enabled_locales$
  SELECT COALESCE(
    (SELECT s.enabled_locales FROM public.settings AS s),
    enum_range(NULL::public.locale)
  );
$enabled_locales$;

-- SECURITY DEFINER for the same reason as auth.enabled_locales.
CREATE FUNCTION auth.default_locale()
RETURNS public.locale
LANGUAGE sql
STABLE
SECURITY DEFINER
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

-- No REVOKE FROM PUBLIC: sql_saga's health_checks event trigger currently
-- rejects every REVOKE (admin_user privileges on the temporal tables are not
-- mirrored on their __for_portion_of_valid views). anon still cannot change
-- anything: it holds no UPDATE on auth.user. Same shape as public.user_delete.
GRANT EXECUTE ON FUNCTION public.user_locale_set(public.locale) TO authenticated;

ALTER TYPE auth.auth_response
  ADD ATTRIBUTE locale public.locale,
  ADD ATTRIBUTE enabled_locales public.locale[];

CREATE OR REPLACE FUNCTION auth.build_auth_response(p_user_record auth."user" DEFAULT NULL::auth."user", p_expired_access_token_call_refresh boolean DEFAULT false, p_error_code auth.login_error_code DEFAULT NULL::auth.login_error_code, p_token_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS auth.auth_response
 LANGUAGE plpgsql
AS $function$
DECLARE
  result auth.auth_response;
BEGIN
  IF p_user_record IS NULL THEN
    result.is_authenticated := false;
    result.uid := NULL;
    result.sub := NULL;
    result.email := NULL;
    result.display_name := NULL;
    result.role := NULL;
    result.statbus_role := NULL;
    result.last_sign_in_at := NULL;
    result.created_at := NULL;
    result.error_code := p_error_code;
    result.expired_access_token_call_refresh := p_expired_access_token_call_refresh;
    result.token_expires_at := p_token_expires_at;
  ELSE
    result.is_authenticated := true;
    result.uid := p_user_record.id;
    result.sub := p_user_record.sub;
    result.email := p_user_record.email;
    result.display_name := p_user_record.display_name;
    result.role := p_user_record.email;
    result.statbus_role := p_user_record.statbus_role;
    result.last_sign_in_at := p_user_record.last_sign_in_at;
    result.created_at := p_user_record.created_at;
    result.error_code := NULL;
    result.expired_access_token_call_refresh := p_expired_access_token_call_refresh;
    result.token_expires_at := p_token_expires_at;
  END IF;
  -- Resolved for anonymous responses too: the login page renders in the
  -- instance default before anyone signs in.
  result.locale := auth.effective_locale(p_user_record);
  result.enabled_locales := auth.enabled_locales();
  RETURN result;
END;
$function$;

END;
