```sql
CREATE OR REPLACE FUNCTION auth.user_locale_enabled_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
BEGIN
  IF NEW.locale IS NOT NULL AND NOT (NEW.locale = ANY (auth.enabled_locales())) THEN
    RAISE EXCEPTION 'Language % is not enabled on this installation (enabled: %)',
      NEW.locale, auth.enabled_locales()
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$function$
```
