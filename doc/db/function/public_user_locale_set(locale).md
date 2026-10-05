```sql
CREATE OR REPLACE FUNCTION public.user_locale_set(p_locale locale)
 RETURNS locale
 LANGUAGE plpgsql
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
$function$
```
