```sql
CREATE OR REPLACE FUNCTION public.locale_array_is_set(p_locales locale[])
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(array_ndims(p_locales), 1) = 1
     AND count(l) = cardinality(p_locales)
     AND count(l) = count(DISTINCT l)
    FROM unnest(p_locales) AS l;
$function$
```
