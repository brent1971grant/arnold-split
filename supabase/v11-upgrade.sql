-- Arnold Split v11 upgrade.
-- Run once in Supabase: SQL Editor > New query > paste all of this > Run.
-- Safe to run again; it changes nothing the second time.

-- 1. Reps with the top set. The app starts sending reps once this column exists.
alter table public.training_log add column if not exists top_reps smallint;

-- 2. Automatic weigh-ins from Health Auto Export (a "Health Metrics" automation).
-- Takes the Weight & Body Mass readings and fills that day's body weight, but only
-- when the day has no weight yet, so a weight typed in the app always wins.
create or replace function public.ingest_hae_metrics(jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb;
  p jsonb;
  kg numeric;
  filled integer := 0;
begin
  for m in select value from jsonb_array_elements(coalesce($1 #> '{data,metrics}', '[]'::jsonb)) loop
    continue when m->>'name' is distinct from 'weight_body_mass';
    for p in select value from jsonb_array_elements(coalesce(m->'data', '[]'::jsonb)) loop
      kg := (p->>'qty')::numeric;
      continue when kg is null;
      if lower(coalesce(m->>'units', 'kg')) in ('lb', 'lbs') then
        kg := kg * 0.45359237;
      end if;
      kg := round(kg, 1);
      continue when kg < 30 or kg > 250;
      -- Health Auto Export dates look like '2026-10-18 07:12:00 +0100'; the first
      -- ten characters are the local date.
      update public.training_log
         set body_weight = kg, updated_at = now()
       where date::text = left(p->>'date', 10)
         and body_weight is null;
      if found then filled := filled + 1; end if;
    end loop;
  end loop;
  return filled;
end;
$$;

revoke all on function public.ingest_hae_metrics(jsonb) from public;
grant execute on function public.ingest_hae_metrics(jsonb) to anon, authenticated;

-- Make the new function visible to the API straight away.
notify pgrst, 'reload schema';
