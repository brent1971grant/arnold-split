-- Arnold Split v19 upgrade: Apple Health daily summary.
-- Run once in Supabase: SQL Editor > New query > paste all of this > Run.
-- Safe to run again. Run v11-upgrade.sql first if you haven't yet.

-- One row per day: the numbers the Stats panels chart.
create table if not exists public.health_daily (
  date date primary key,
  steps integer,
  active_kcal integer,
  exercise_min integer,
  resting_hr numeric,
  hrv numeric,
  sleep_h numeric,
  updated_at timestamptz not null default now()
);

-- Read access matches how the app reads its other tables without signing in (the anon key).
-- Revisit this with the family-accounts plan, when each person gets their own sign-in.
alter table public.health_daily enable row level security;
drop policy if exists "health_daily read" on public.health_daily;
create policy "health_daily read" on public.health_daily for select to anon, authenticated using (true);
grant select on public.health_daily to anon, authenticated;

-- Health Auto Export "Health Metrics" automation posts here, with time grouping Day.
-- Steps, energy, exercise, resting HR, HRV and sleep go into health_daily. Weight fills
-- that day's body weight in training_log, only when the day has no weight yet.
create or replace function public.ingest_hae_daily(jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb;
  p jsonb;
  n text;
  u text;
  d date;
  v numeric;
  done integer := 0;
begin
  for m in select value from jsonb_array_elements(coalesce($1 #> '{data,metrics}', '[]'::jsonb)) loop
    n := m->>'name';
    u := lower(coalesce(m->>'units', ''));
    continue when n not in ('step_count', 'active_energy', 'apple_exercise_time', 'resting_heart_rate',
                            'heart_rate_variability', 'sleep_analysis', 'weight_body_mass');
    for p in select value from jsonb_array_elements(coalesce(m->'data', '[]'::jsonb)) loop
      -- Dates look like '2026-10-18 00:00:00 +0100'; the first ten characters are the local date.
      d := left(p->>'date', 10)::date;
      if n = 'sleep_analysis' then
        v := coalesce(nullif(p->>'totalSleep', '')::numeric, nullif(p->>'asleep', '')::numeric);
      else
        v := nullif(p->>'qty', '')::numeric;
      end if;
      continue when v is null or d is null;

      if n = 'weight_body_mass' then
        if u in ('lb', 'lbs') then v := v * 0.45359237; end if;
        v := round(v, 1);
        if v between 30 and 250 then
          update public.training_log
             set body_weight = v, updated_at = now()
           where date::text = d::text and body_weight is null;
        end if;
        continue;
      end if;

      if n = 'active_energy' and u = 'kj' then v := v * 0.239006; end if;
      insert into public.health_daily (date) values (d) on conflict (date) do nothing;
      update public.health_daily set
        steps        = case when n = 'step_count' then round(v)::integer else steps end,
        active_kcal  = case when n = 'active_energy' then round(v)::integer else active_kcal end,
        exercise_min = case when n = 'apple_exercise_time' then round(v)::integer else exercise_min end,
        resting_hr   = case when n = 'resting_heart_rate' then round(v, 1) else resting_hr end,
        hrv          = case when n = 'heart_rate_variability' then round(v, 1) else hrv end,
        sleep_h      = case when n = 'sleep_analysis' then round(v, 2) else sleep_h end,
        updated_at   = now()
       where date = d;
      done := done + 1;
    end loop;
  end loop;
  return done;
end;
$$;

revoke all on function public.ingest_hae_daily(jsonb) from public;
grant execute on function public.ingest_hae_daily(jsonb) to anon, authenticated;

-- Make the new table and function visible to the API straight away.
notify pgrst, 'reload schema';
