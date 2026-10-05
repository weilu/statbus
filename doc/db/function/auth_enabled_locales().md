```sql
CREATE OR REPLACE FUNCTION auth.enabled_locales()
 RETURNS locale[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT s.enabled_locales FROM public.settings AS s),
    enum_range(NULL::public.locale)
  );
$function$
```
