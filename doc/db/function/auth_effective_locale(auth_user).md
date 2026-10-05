```sql
CREATE OR REPLACE FUNCTION auth.effective_locale(p_user auth."user")
 RETURNS locale
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN p_user.locale IS NOT NULL AND p_user.locale = ANY (auth.enabled_locales())
      THEN p_user.locale
    ELSE auth.default_locale()
  END;
$function$
```
