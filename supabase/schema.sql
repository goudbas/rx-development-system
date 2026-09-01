-- RX Development System — MVP schema (Deel 14 subset)
-- Single personal user, protected via Supabase Auth + Row Level Security.
-- Run this once in Supabase SQL Editor (Project > SQL Editor > New query).

-- ============ Reference data (no RLS — just definitions, not personal data) ============
create table if not exists skills (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  domain text not null check (domain in ('gymnastics','skill','strength','conditioning','mobility'))
);

insert into skills (name, domain) values
  ('Ring Muscle-Up', 'gymnastics'),
  ('Handstand Walk', 'skill'),
  ('Double Unders', 'skill'),
  ('Butterfly Pull-up', 'gymnastics'),
  ('Toes-to-Bar', 'gymnastics')
on conflict (name) do nothing;

-- ============ Personal data (all RLS-protected) ============

create table if not exists training_blocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  start_date date not null,
  end_date date,
  primary_goals text[] not null default '{}',
  secondary_goals text[] not null default '{}',
  carry_over text,
  exit_criteria text,
  status text not null default 'active' check (status in ('active','completed')),
  created_at timestamptz not null default now()
);

create table if not exists weekly_targets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  block_id uuid not null references training_blocks(id) on delete cascade,
  week_number int not null,
  component text not null,
  target_min int not null,
  target_max int not null,
  actual_count int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists skill_progressions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  skill_id uuid not null references skills(id),
  current_step text not null,
  last_session_date date,
  success_rate numeric,
  updated_at timestamptz not null default now(),
  unique (user_id, skill_id)
);

create table if not exists training_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  date date not null default current_date,
  session_type text not null check (session_type in ('class','extra')),
  duration_min int,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists class_loads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  training_session_id uuid not null unique references training_sessions(id) on delete cascade,
  legs text check (legs in ('low','moderate','high')),
  pulling text check (pulling in ('low','moderate','high')),
  pushing text check (pushing in ('low','moderate','high')),
  overhead text check (overhead in ('low','moderate','high')),
  gymnastics text check (gymnastics in ('low','moderate','high')),
  olympic_lifting boolean default false,
  conditioning text check (conditioning in ('low','moderate','high')),
  overall_load text check (overall_load in ('easy','moderate','hard','very_hard'))
);

create table if not exists skill_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  training_session_id uuid references training_sessions(id) on delete cascade,
  skill_id uuid not null references skills(id),
  date date not null default current_date,
  step text,
  volume text,
  quality_score int check (quality_score between 1 and 5),
  success_pct numeric check (success_pct between 0 and 100),
  notes text
);

create table if not exists strength_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  training_session_id uuid references training_sessions(id) on delete cascade,
  date date not null default current_date,
  exercise text not null,
  sets int,
  reps int,
  load_kg numeric,
  rpe numeric check (rpe between 1 and 10)
);

create table if not exists daily_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  date date not null default current_date,
  readiness int check (readiness between 1 and 5),
  fatigue int check (fatigue between 1 and 5),
  soreness int check (soreness between 1 and 5),
  sleep int check (sleep between 1 and 5),
  pain_level text check (pain_level in ('none','mild','significant')),
  pain_location text,
  notes text,
  unique (user_id, date)
);

create table if not exists benchmarks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  block_id uuid references training_blocks(id),
  name text not null,
  date date not null default current_date,
  value text not null
);

create table if not exists coach_recommendations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id),
  date date not null default current_date,
  recommendation text not null,
  reasoning text,
  followed boolean
);

-- ============ Row Level Security ============
alter table training_blocks enable row level security;
alter table weekly_targets enable row level security;
alter table skill_progressions enable row level security;
alter table training_sessions enable row level security;
alter table class_loads enable row level security;
alter table skill_sessions enable row level security;
alter table strength_sessions enable row level security;
alter table daily_logs enable row level security;
alter table benchmarks enable row level security;
alter table coach_recommendations enable row level security;

do $$
declare
  t text;
begin
  for t in select unnest(array[
    'training_blocks','weekly_targets','skill_progressions','training_sessions',
    'class_loads','skill_sessions','strength_sessions','daily_logs',
    'benchmarks','coach_recommendations'
  ])
  loop
    execute format('drop policy if exists "owner_select" on %I', t);
    execute format('drop policy if exists "owner_insert" on %I', t);
    execute format('drop policy if exists "owner_update" on %I', t);
    execute format('drop policy if exists "owner_delete" on %I', t);
    execute format('create policy "owner_select" on %I for select using (auth.uid() = user_id)', t);
    execute format('create policy "owner_insert" on %I for insert with check (auth.uid() = user_id)', t);
    execute format('create policy "owner_update" on %I for update using (auth.uid() = user_id)', t);
    execute format('create policy "owner_delete" on %I for delete using (auth.uid() = user_id)', t);
  end loop;
end $$;

-- skills is reference data: readable by any logged-in user, not writable from the client
alter table skills enable row level security;
drop policy if exists "skills_read" on skills;
create policy "skills_read" on skills for select using (auth.role() = 'authenticated');

-- Migratie: welke spiergroepen vandaag (veel) spierpijn hebben, om extra oefeningen daarop af te stemmen.
alter table daily_logs add column if not exists sore_muscle_groups text[] not null default '{}';

-- ============ Migratie: skills wordt de algemene component-tabel (skill + strength + mobility), ============
-- ============ zodat de exercise-library data-driven is i.p.v. hardcoded in decision-engine.js. ============
alter table skills add column if not exists timing text not null default 'pre' check (timing in ('pre','post','any'));
alter table skills add column if not exists target_value numeric;
alter table skills add column if not exists target_unit text;
alter table skills add column if not exists goal_text text;

insert into skills (name, domain, timing, goal_text) values
  ('Strength', 'strength', 'post', '+10-15 kg front squat, duidelijk sterkere pulling strength.'),
  ('Mobility', 'mobility', 'any', 'Dagelijkse schouder-stability.')
on conflict (name) do nothing;

update skills set target_value = 3, target_unit = 'ongebroken reps',
  goal_text = '3-5 ongebroken RMU. Let op: bevriest bij "ring support hold" tot schouder 2 weken pijnvrij is.'
  where name = 'Ring Muscle-Up';
update skills set target_value = 15, target_unit = 'meter',
  goal_text = '15-20 meter ononderbroken.'
  where name = 'Handstand Walk';
update skills set target_value = 75, target_unit = 'ongebroken reps',
  goal_text = '75-100 ongebroken.'
  where name = 'Double Unders';
update skills set target_value = 15, target_unit = 'ongebroken reps',
  goal_text = '20+ ongebroken TTB.'
  where name = 'Toes-to-Bar';
update skills set target_value = 15, target_unit = 'ongebroken reps',
  goal_text = 'Al beheerst — onderhoudsvolume.'
  where name = 'Butterfly Pull-up';

-- Losse oefenstappen per component (vervangt BLOCK_CONTENT[x].steps).
create table if not exists skill_exercises (
  id uuid primary key default gen_random_uuid(),
  skill_id uuid not null references skills(id) on delete cascade,
  sort_order int not null default 0,
  step_text text not null,
  unique (skill_id, sort_order)
);
alter table skill_exercises enable row level security;
drop policy if exists "skill_exercises_read" on skill_exercises;
create policy "skill_exercises_read" on skill_exercises for select using (auth.role() = 'authenticated');

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, 'False grip hang — 3×20 sec'),
    (1, 'Low ring transitions — 4×5'),
    (2, 'Band/feet assisted RMU — 5×2'),
    (3, 'Ring support hold — 3×30 sec')
  ) as v(sort_order, step_text)
  where s.name = 'Ring Muscle-Up'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, 'Wall walks — 3×3'),
    (1, 'Shoulder taps — 3×20'),
    (2, 'Freestanding balance / walk attempts — 10 min')
  ) as v(sort_order, step_text)
  where s.name = 'Handstand Walk'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, '100 perfecte singles'),
    (1, '10 rondes: 10 DU pogingen'),
    (2, 'Stop zodra de techniek verslechtert')
  ) as v(sort_order, step_text)
  where s.name = 'Double Unders'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, 'EMOM 10: 5-7 perfecte TTB')
  ) as v(sort_order, step_text)
  where s.name = 'Toes-to-Bar'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, 'Butterfly drill — 4×8-12')
  ) as v(sort_order, step_text)
  where s.name = 'Butterfly Pull-up'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, 'Sessie A: Front Squat 5×5, Weighted Pull-up 5×5'),
    (1, 'Sessie B: Strict Press 5×5, Romanian Deadlift 4×8')
  ) as v(sort_order, step_text)
  where s.name = 'Strength'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

insert into skill_exercises (skill_id, sort_order, step_text)
  select s.id, v.sort_order, v.step_text from skills s
  cross join (values
    (0, 'Banded external rotation — 2×20'),
    (1, 'Face pull — 2×20'),
    (2, 'Scap push-up — 2×15'),
    (3, 'Dead hang — 2×45 sec'),
    (4, 'Thoracic extension — 2 min'),
    (5, 'Lat stretch — 2 min')
  ) as v(sort_order, step_text)
  where s.name = 'Mobility'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text;

-- Spiergroep-conflicten per component: 'block' = volledig uitsluiten, 'downgrade' = alleen kiezen
-- als er geen niet-gedowngrade kandidaat is (vervangt het binaire MUSCLE_AVOID_MAP). Coaching judgement [C].
create table if not exists skill_muscle_conflicts (
  id uuid primary key default gen_random_uuid(),
  skill_id uuid not null references skills(id) on delete cascade,
  muscle_group text not null,
  severity text not null check (severity in ('block', 'downgrade')),
  unique (skill_id, muscle_group)
);
alter table skill_muscle_conflicts enable row level security;
drop policy if exists "skill_muscle_conflicts_read" on skill_muscle_conflicts;
create policy "skill_muscle_conflicts_read" on skill_muscle_conflicts for select using (auth.role() = 'authenticated');

insert into skill_muscle_conflicts (skill_id, muscle_group, severity)
  select s.id, v.muscle_group, v.severity from skills s
  cross join (values ('schouders', 'block'), ('armen', 'block')) as v(muscle_group, severity)
  where s.name = 'Ring Muscle-Up'
  on conflict (skill_id, muscle_group) do update set severity = excluded.severity;

insert into skill_muscle_conflicts (skill_id, muscle_group, severity)
  select s.id, v.muscle_group, v.severity from skills s
  cross join (values ('schouders', 'downgrade')) as v(muscle_group, severity)
  where s.name = 'Handstand Walk'
  on conflict (skill_id, muscle_group) do update set severity = excluded.severity;

insert into skill_muscle_conflicts (skill_id, muscle_group, severity)
  select s.id, v.muscle_group, v.severity from skills s
  cross join (values ('rug', 'downgrade'), ('armen', 'downgrade'), ('core', 'downgrade')) as v(muscle_group, severity)
  where s.name = 'Toes-to-Bar'
  on conflict (skill_id, muscle_group) do update set severity = excluded.severity;

insert into skill_muscle_conflicts (skill_id, muscle_group, severity)
  select s.id, v.muscle_group, v.severity from skills s
  cross join (values ('kuiten', 'block')) as v(muscle_group, severity)
  where s.name = 'Double Unders'
  on conflict (skill_id, muscle_group) do update set severity = excluded.severity;

insert into skill_muscle_conflicts (skill_id, muscle_group, severity)
  select s.id, v.muscle_group, v.severity from skills s
  cross join (values
    ('schouders', 'downgrade'), ('rug', 'downgrade'), ('borst', 'downgrade'),
    ('armen', 'downgrade'), ('benen', 'downgrade')
  ) as v(muscle_group, severity)
  where s.name = 'Strength'
  on conflict (skill_id, muscle_group) do update set severity = excluded.severity;

-- ============ Migratie: skill-niveaus (Deel 6/10 vervolg) — genummerde niveaus met eigen ============
-- ============ oefeningen + slaagcriterium, i.p.v. één platte oefenlijst per skill. ============
-- Zie localfiles/Skill_Level_Content.md voor de volledige inhoud en onderbouwing per skill.

create table if not exists skill_levels (
  id uuid primary key default gen_random_uuid(),
  skill_id uuid not null references skills(id) on delete cascade,
  level_number int not null,
  name text not null,
  pass_criteria_text text,
  pass_quality_min int not null default 4,
  pass_sessions_min int not null default 3,
  unique (skill_id, level_number)
);
alter table skill_levels enable row level security;
drop policy if exists "skill_levels_read" on skill_levels;
create policy "skill_levels_read" on skill_levels for select using (auth.role() = 'authenticated');

alter table skill_exercises add column if not exists level_number int not null default 0;
alter table skill_progressions add column if not exists current_level_number int not null default 0;
alter table skill_sessions add column if not exists level_number int;

-- current_step is vervangen door current_level_number; de kolom blijft bestaan (geen dataverlies)
-- maar mag niet langer NOT NULL zijn, anders faalt de upsert voor een skill die nog nooit gelogd is.
alter table skill_progressions alter column current_step drop not null;

-- Ring Muscle-Up
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Fundament', 'False grip hang 3×20 sec pijnvrij vastgehouden', 4, 3),
    (1, 'Transitiekracht', '4×5 transities met controle, geen zwaai-momentum', 4, 3),
    (2, 'Assisted reps', '5×3 band-assisted reps met lichte weerstandsband', 4, 3),
    (3, 'Eerste strict reps', '3 losse strict RMU''s binnen één sessie', 4, 2)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Ring Muscle-Up'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

update skill_exercises set level_number = 0 where skill_id = (select id from skills where name = 'Ring Muscle-Up') and step_text = 'False grip hang — 3×20 sec';
update skill_exercises set level_number = 0 where skill_id = (select id from skills where name = 'Ring Muscle-Up') and step_text = 'Ring support hold — 3×30 sec';
update skill_exercises set level_number = 1 where skill_id = (select id from skills where name = 'Ring Muscle-Up') and step_text = 'Low ring transitions — 4×5';
update skill_exercises set level_number = 2 where skill_id = (select id from skills where name = 'Ring Muscle-Up') and step_text = 'Band/feet assisted RMU — 5×2';
insert into skill_exercises (skill_id, sort_order, step_text, level_number)
  select s.id, 4, 'Strict RMU singles — losse pogingen', 3 from skills s
  where s.name = 'Ring Muscle-Up'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number;

-- Handstand Walk
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Muur-posities', '3×3 wall walks met controle tot verticaal', 4, 3),
    (1, 'Balans en stabiliteit', '3×20 shoulder taps zonder voeten van de muur', 4, 3),
    (2, 'Freestanding', 'Groeiend aantal losse stappen richting het HSW-doel', 4, 3)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Handstand Walk'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

update skill_exercises set level_number = 0 where skill_id = (select id from skills where name = 'Handstand Walk') and step_text = 'Wall walks — 3×3';
update skill_exercises set level_number = 1 where skill_id = (select id from skills where name = 'Handstand Walk') and step_text = 'Shoulder taps — 3×20';
update skill_exercises set level_number = 2 where skill_id = (select id from skills where name = 'Handstand Walk') and step_text = 'Freestanding balance / walk attempts — 10 min';

-- Toes-to-Bar (niveau 0 en 1 zijn nieuw, bestaande rij wordt niveau 2; niveau 3 is nieuw)
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Basis compressie', 'Hollow hold 3×30 sec + 3×10 knee raises met controle', 4, 3),
    (1, 'Beat swing & compressie', '3×10 beat swings met ritme', 4, 3),
    (2, 'Gecontroleerde singles', 'EMOM 10 met 5-7 nette TTB per minuut', 4, 3),
    (3, 'Unbroken sets', '3×5 ongebroken TTB', 4, 2)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Toes-to-Bar'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

update skill_exercises set level_number = 2 where skill_id = (select id from skills where name = 'Toes-to-Bar') and step_text = 'EMOM 10: 5-7 perfecte TTB';
insert into skill_exercises (skill_id, sort_order, step_text, level_number)
  select s.id, v.sort_order, v.step_text, v.level_number from skills s
  cross join (values
    (1, 'Hollow hold — 3×30 sec', 0),
    (2, 'Hanging knee raise — 3×10', 0),
    (3, 'Beat swing — 3×10', 1),
    (4, 'Hanging compression — 3×10', 1),
    (5, 'TTB unbroken sets — 3×5', 3)
  ) as v(sort_order, step_text, level_number)
  where s.name = 'Toes-to-Bar'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number;

-- Double Unders
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Singles-consistentie', '100 singles zonder misser', 4, 3),
    (1, 'Korte DU-sets', 'Gemiddeld 7+/10 geslaagd over 10 rondes', 4, 3),
    (2, 'Volume onder vermoeidheid', '20+ ongebroken direct na vermoeiende inspanning', 4, 3)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Double Unders'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

update skill_exercises set level_number = 0 where skill_id = (select id from skills where name = 'Double Unders') and step_text = '100 perfecte singles';
update skill_exercises set level_number = 1 where skill_id = (select id from skills where name = 'Double Unders') and step_text = '10 rondes: 10 DU pogingen';
update skill_exercises set step_text = 'DU''s in sets van 20+ direct na cardio-inspanning', level_number = 2
  where skill_id = (select id from skills where name = 'Double Unders') and step_text = 'Stop zodra de techniek verslechtert';

-- Butterfly Pull-up, Strength, Mobility: één neutraal niveau (doorlopend, geen mastery-concept)
insert into skill_levels (skill_id, level_number, name, pass_criteria_text)
  select s.id, 0, 'Onderhoud', null from skills s where s.name = 'Butterfly Pull-up'
  on conflict (skill_id, level_number) do nothing;
insert into skill_levels (skill_id, level_number, name, pass_criteria_text)
  select s.id, 0, 'Doorlopend krachtprogramma', null from skills s where s.name = 'Strength'
  on conflict (skill_id, level_number) do nothing;
insert into skill_levels (skill_id, level_number, name, pass_criteria_text)
  select s.id, 0, 'Dagelijkse routine', null from skills s where s.name = 'Mobility'
  on conflict (skill_id, level_number) do nothing;

-- ============ Migratie: RX-krachtbenchmarks ============
-- Reference data (net als skills): welke lifts we tracken en wat "near RX" / "sterk RX" betekent.
-- Loggen zelf gebeurt in de bestaande, personal `benchmarks`-tabel (name = deze lift-naam, of een skill-naam).
create table if not exists benchmark_definitions (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  unit text not null default 'kg',
  target_near_rx numeric,
  target_strong_rx numeric,
  sort_order int not null default 0
);
alter table benchmark_definitions enable row level security;
drop policy if exists "benchmark_definitions_read" on benchmark_definitions;
create policy "benchmark_definitions_read" on benchmark_definitions for select using (auth.role() = 'authenticated');

-- `date` alleen (geen tijd) kan op dezelfde dag meerdere keren gelogde waarden niet ordenen —
-- created_at lost dat op zodat de nieuwste log altijd als "laatste waarde" telt.
alter table benchmarks add column if not exists created_at timestamptz not null default now();

insert into benchmark_definitions (name, sort_order, target_near_rx, target_strong_rx) values
  ('Back Squat', 0, 140, 180),
  ('Front Squat', 1, 120, 150),
  ('Deadlift', 2, 180, 220),
  ('Clean & Jerk', 3, 90, 120),
  ('Snatch', 4, 70, 95),
  ('Strict Press', 5, 60, 80),
  ('Push Press', 6, 80, 100),
  ('Push Jerk', 7, 90, 115),
  ('Weighted Pull-up', 8, 20, 40)
on conflict (name) do update set
  sort_order = excluded.sort_order, target_near_rx = excluded.target_near_rx, target_strong_rx = excluded.target_strong_rx;
