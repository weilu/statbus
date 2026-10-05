```sql
CREATE OR REPLACE FUNCTION auth.default_locale()
 RETURNS locale
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT s.default_locale FROM public.settings AS s),
    'en'::public.locale
  );
$function$
```
