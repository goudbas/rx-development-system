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

-- Bewaart de bij aanmaak opgegeven bloklengte, zodat "week X van Y" getoond kan worden
-- zonder te vertrouwen op hoeveel weekly_targets-rijen er toevallig nog bestaan.
alter table training_blocks add column if not exists total_weeks int;

-- ============ Migratie: na-de-class-invoer vereenvoudigd naar RPE + workout-type ============
-- (i.p.v. de losse legs/pulling/pushing/overhead/gymnastics/conditioning/olympic_lifting-chips,
-- die op één na (overhead/pulling, voor de schouder-veiligheidsregel) nergens werden uitgelezen).
alter table class_loads add column if not exists rpe int check (rpe between 1 and 10);
alter table class_loads add column if not exists workout_type text check (workout_type in ('cardio', 'strength', 'mixed'));

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

-- ============ Migratie: coach-feedback verwerken (Training A/B, safety freeze, rijkere niveaus) ============
-- Zie localfiles/Skill_Level_Content.md (bron: localfiles/feedbackskills.md) voor de volledige onderbouwing.

alter table skill_exercises add column if not exists variant text not null default 'a' check (variant in ('a', 'b', 'c'));
alter table skills add column if not exists common_mistakes_text text;
alter table skill_progressions add column if not exists frozen boolean not null default false;
alter table skill_progressions add column if not exists frozen_reason text;
alter table skill_progressions add column if not exists frozen_at date;
alter table skill_sessions add column if not exists variant text check (variant in ('a', 'b', 'c'));
alter table skill_sessions add column if not exists pain_score int check (pain_score between 0 and 10);
alter table benchmark_definitions add column if not exists target_tussenstap numeric;

-- Niveau-indeling van RMU/HSW/TTB/DU/Butterfly wordt volledig vervangen (niet uitgebreid) door de
-- coach-versie — oude niveau-nummers dekken een andere lading dan de nieuwe, dus we resetten ook
-- ieders voortgang op deze 5 skills naar niveau 0 i.p.v. een oud nummer op nieuwe content te laten wijzen.
delete from skill_exercises where skill_id in (
  select id from skills where name in ('Ring Muscle-Up', 'Handstand Walk', 'Toes-to-Bar', 'Double Unders', 'Butterfly Pull-up')
);
delete from skill_levels where skill_id in (
  select id from skills where name in ('Ring Muscle-Up', 'Handstand Walk', 'Toes-to-Bar', 'Double Unders', 'Butterfly Pull-up')
);
update skill_progressions set current_level_number = 0, frozen = false, frozen_reason = null, frozen_at = null
  where skill_id in (
    select id from skills where name in ('Ring Muscle-Up', 'Handstand Walk', 'Toes-to-Bar', 'Double Unders', 'Butterfly Pull-up')
  );

-- ---------- Ring Muscle-Up: 6 niveaus (0-5) ----------
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Ringfundament', 'False grip hang 3×30 sec + ring support met lichte turnout 3×30 sec + 10 gecontroleerde false-grip ring rows, alles in één sessie', 4, 3),
    (1, 'Pull- en dipkracht', '5 strict chest-to-ring pull-ups + 5 strict ring dips tot schouder onder elleboog + 3 eccentrics van min. 5 sec, geen verlies van false grip', 4, 3),
    (2, 'Transitiekracht', '5×4 low-ring transitions met minimale voetdruk, min. 4 van 5 technisch goed, elke rep eindigt in stabiele support', 4, 3),
    (3, 'Swing en dynamische pull', '4×6 ritmische beat swings + 5×3 high pulls tot min. borsthoogte + 5×3 box-assisted turnovers zonder sprong', 4, 3),
    (4, 'Eerste Ring Muscle-Up', '3 succesvolle RMU-singles in één sessie, min. 60 sec rust tussen pogingen, gecontroleerde lockout, geen gemiste rep tussen laatste 2', 4, 2),
    (5, 'Koppelen en RX-capaciteit', '3×3 ongebroken RMU, daarna in een aparte testsessie 1 set van 5, alle reps geldig', 4, 2)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Ring Muscle-Up'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, v.level_number, v.variant from skills s
  cross join (values
    (0, 'False grip hang — 3×20-30 sec', 0, 'a'), (1, 'Active ring hang — 3×8', 0, 'a'),
    (2, 'Ring support hold — 4×20 sec', 0, 'a'), (3, 'Ring rows — 3×10', 0, 'a'), (4, 'Hollow hold — 3×30 sec', 0, 'a'),
    (50, 'False-grip ring rows — 4×8', 0, 'b'), (51, 'Ring support met turnout — 4×15-20 sec', 0, 'b'),
    (52, 'Scap pull-ups aan ringen — 3×10', 0, 'b'), (53, 'Ring push-ups — 3×10', 0, 'b'), (54, 'Arch hold — 3×30 sec', 0, 'b'),
    (100, 'Strict chest-to-ring pull-up — 5×3', 1, 'a'), (101, 'Strict ring dip — 5×3', 1, 'a'),
    (102, 'False-grip pull-up eccentric — 3×3, 5 sec zakken', 1, 'a'), (103, 'Hollow-to-arch swing — 3×8', 1, 'a'),
    (150, 'Weighted strict pull-up — 5×3', 1, 'b'), (151, 'Ring dip met pauze onderin — 4×4', 1, 'b'),
    (152, 'Feet-elevated false-grip ring row — 4×8', 1, 'b'), (153, 'Ring support knee raises — 3×8', 1, 'b'),
    (200, 'Low-ring transition met voeten — 5×4', 2, 'a'), (201, 'Seated transition zonder beenafzet — 4×4', 2, 'a'),
    (202, 'Russian ring dip — 4×3', 2, 'a'), (203, 'False-grip chest-to-ring pull — 4×4', 2, 'a'),
    (250, 'Low-ring transition met langzame eccentric — 5×3', 2, 'b'), (251, 'Box-assisted turnover — 4×4', 2, 'b'),
    (252, 'Deep ring dip — 4×5', 2, 'b'), (253, 'Ring support turnout — 3×25 sec', 2, 'b'),
    (300, 'Ring beat swing — 4×6-8', 3, 'a'), (301, 'Kip-to-high-pull — 5×3', 3, 'a'),
    (302, 'Box-assisted kipping transition — 5×3', 3, 'a'), (303, 'Ring support hold — 3×20 sec', 3, 'a'),
    (350, 'Kleine naar grotere ringswing — 4×6', 3, 'b'), (351, 'Toes-to-rings drill — 4×5', 3, 'b'),
    (352, 'Hip-to-rings pull — 5×2-3', 3, 'b'), (353, 'Low-ring fast turnover — 4×4', 3, 'b'),
    (400, 'RMU singles — 6-10 pogingen', 4, 'a'), (401, 'High pull + turnover drill — 4×2', 4, 'a'),
    (402, 'Strict ring dip — 3×5', 4, 'a'), (403, 'Controlled RMU eccentric — 3×1', 4, 'a'),
    (450, 'EMOM 10: 1 RMU-poging', 4, 'b'), (451, 'Low-ring transition — 3×5', 4, 'b'),
    (452, 'Ring swing — 3×6', 4, 'b'), (453, 'Deep ring dip — 3×5', 4, 'b'),
    (500, '5 sets van 2-3 RMU — rust 2-3 min', 5, 'a'), (501, 'Daarna 3×5 strict ring dips', 5, 'a'),
    (550, 'EMOM 10: 2 RMU', 5, 'b'), (551, 'Daarna 3 rondes: 5 chest-to-ring pull-ups + 5 ring dips', 5, 'b')
  ) as v(sort_order, step_text, level_number, variant)
  where s.name = 'Ring Muscle-Up'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

-- ---------- Handstand Walk: 5 niveaus (0-4) ----------
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Inversie en muurpositie', '3 wall walks tot max 15 cm van de muur + 3×40 sec chest-to-wall hold, ellebogen gestrekt, buik aangespannen', 4, 3),
    (1, 'Schouderverplaatsing', '20 afwisselende shoulder taps (min. 8/10 zonder voetcorrectie), beheerst uitstappen', 4, 3),
    (2, 'Loskomen van de muur', '3 losse handstandholds van min. 10 sec, min. 5/10 kick-ups onder controle, veilig uitstappen aan beide zijden', 4, 3),
    (3, 'Eerste stappen', '5 pogingen van min. 5 m, min. 1 poging van 10 m, geen botsing of ongecontroleerde val', 4, 3),
    (4, 'Afstand en controle', '3×15 m binnen één sessie, 1 ongebroken poging van 20 m, min. 70% van de pogingen haalt 10 m', 4, 3)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Handstand Walk'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, v.level_number, v.variant from skills s
  cross join (values
    (0, 'Wall walk — 4×3', 0, 'a'), (1, 'Chest-to-wall hold — 4×30 sec', 0, 'a'),
    (2, 'Handstand bodyline drill — 3×20 sec', 0, 'a'), (3, 'Wrist rocks — 2×15', 0, 'a'),
    (50, 'Box pike hold — 4×30 sec', 0, 'b'), (51, 'Wall-facing scap shrugs — 3×10', 0, 'b'),
    (52, 'Hollow hold — 3×30 sec', 0, 'b'), (53, 'Wall walk eccentric — 3×2', 0, 'b'),
    (100, 'Chest-to-wall shoulder taps — 4×10 per zijde', 1, 'a'), (101, 'Weight shifts — 3×20', 1, 'a'),
    (102, 'Handstand shrugs — 3×10', 1, 'a'), (103, 'Wall line drill — 3×30 sec', 1, 'a'),
    (150, 'Box handstand shoulder taps — 4×16', 1, 'b'), (151, 'Wall hand lifts — 4×8 per zijde', 1, 'b'),
    (152, 'Handstand pirouette exit — 5 per zijde', 1, 'b'), (153, 'Wrist conditioning — 3×12', 1, 'b'),
    (200, 'Heel pulls — 5×5', 2, 'a'), (201, 'Toe pulls — 5×5', 2, 'a'),
    (202, 'Freestanding kick-ups — 10 pogingen', 2, 'a'), (203, 'Partner line drill — 5×20 sec', 2, 'a'),
    (250, 'Wall toe float — 5×10-15 sec', 2, 'b'), (251, 'Freestanding hold attempts — 10 min', 2, 'b'),
    (252, 'Controlled bail practice — 5 per zijde', 2, 'b'), (253, 'Overhead plate carry — 3×30 m', 2, 'b'),
    (300, 'HSW attempts vanaf kick-up — 10×3-5 m', 3, 'a'), (301, 'Wall shoulder taps — 3×20', 3, 'a'), (302, 'Overhead carry — 3×40 m', 3, 'a'),
    (350, 'HSW naar wand — 8 pogingen', 3, 'b'), (351, 'HSW vanaf wand — 8 pogingen', 3, 'b'),
    (352, 'Partner-assisted walk — 5×8 m', 3, 'b'), (353, 'Freestanding hold — 5 pogingen', 3, 'b'),
    (400, '5×10 m HSW', 4, 'a'), (401, '3× obstacle line crossing', 4, 'a'), (402, '5 gecontroleerde starts', 4, 'a'),
    (450, 'EMOM 10: 8-12 m HSW', 4, 'b'), (451, '4× turnaround practice', 4, 'b'), (452, '3× max-distance attempt', 4, 'b')
  ) as v(sort_order, step_text, level_number, variant)
  where s.name = 'Handstand Walk'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

-- ---------- Toes-to-Bar: 5 niveaus (0-4) ----------
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Hang en compressie', '3×30 sec active hang + 3×10 knee raises zonder zwaai + 10 gecontroleerde pike compression lifts', 4, 3),
    (1, 'Beat swing', '3×10 identieke beat swings, geen extra tussenswing, schouders blijven actief', 4, 3),
    (2, 'Hoge compressie', '3×8 knees-to-elbows, 5 strict eccentrics van min. 3 sec, voeten min. ooghoogte bij 8/10 pogingen', 4, 3),
    (3, 'Gecontroleerde TTB', 'EMOM 10 met 5 geldige reps, geen failed reps, max. 1 extra swing per set', 4, 3),
    (4, 'Unbroken volume', '3×10 ongebroken, 1 set van min. 15, min. 90% geldige reps', 4, 2)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Toes-to-Bar'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, v.level_number, v.variant from skills s
  cross join (values
    (0, 'Active hang — 3×30 sec', 0, 'a'), (1, 'Hollow hold — 3×30 sec', 0, 'a'),
    (2, 'Hanging knee raise — 3×10', 0, 'a'), (3, 'Seated pike compression lifts — 3×10', 0, 'a'),
    (50, 'Dead hang — 3×40 sec', 0, 'b'), (51, 'Hollow rocks — 3×15', 0, 'b'),
    (52, 'Strict knee-to-chest — 4×8', 0, 'b'), (53, 'V-ups — 3×10', 0, 'b'),
    (100, 'Beat swing — 5×8', 1, 'a'), (101, 'Hollow-to-arch floor drill — 3×10', 1, 'a'),
    (102, 'Hanging knee raise vanuit swing — 4×6', 1, 'a'), (103, 'Lat activation drill — 3×10', 1, 'a'),
    (150, 'Kip swing met stop — 5×6', 1, 'b'), (151, 'Kip swing + knees-to-chest — 4×5', 1, 'b'),
    (152, 'Hanging compression — 3×10', 1, 'b'), (153, 'Strict toes-to-eye-level — 3×5', 1, 'b'),
    (200, 'Knees-to-elbows — 4×6', 2, 'a'), (201, 'Strict TTB eccentric — 4×3', 2, 'a'),
    (202, 'Kip + high knee raise — 4×6', 2, 'a'), (203, 'V-ups — 3×15', 2, 'a'),
    (250, 'Toes-to-target — 5×5', 2, 'b'), (251, 'Alternating single-leg TTB — 4×6', 2, 'b'),
    (252, 'Hanging L-raise — 4×5', 2, 'b'), (253, 'Beat swing — 3×8', 2, 'b'),
    (300, 'EMOM 10: 3-5 TTB', 3, 'a'), (301, 'Beat swing reset — 3×6', 3, 'a'), (302, 'Strict knee raise — 3×10', 3, 'a'),
    (350, '10×2 linked TTB', 3, 'b'), (351, '5×3 TTB met 30 sec rust', 3, 'b'), (352, 'Lat pulldown/scap pull-up — 3×10', 3, 'b'),
    (400, '5×8 TTB — rust 60-90 sec', 4, 'a'), (401, 'Daarna 1 max-set', 4, 'a'),
    (450, '3 rondes: 12 TTB + 12 cal roeien', 4, 'b'), (451, '90 sec rust tussen rondes', 4, 'b')
  ) as v(sort_order, step_text, level_number, variant)
  where s.name = 'Toes-to-Bar'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

-- ---------- Double Unders: 4 niveaus (0-3) ----------
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Singles en rope control', '100 singles zonder misser, armen dicht langs het lichaam, 10 consistente hoge sprongen met thigh taps', 4, 3),
    (1, 'Eerste Double Unders', 'Min. 20 succesvolle losse DU''s, min. 7/10 succesvolle pogingen, geen double-bounce', 4, 3),
    (2, 'Korte sets', '10×10 DU met max. 2 missers totaal, 1 set van min. 30 ongebroken, constante reboundhoogte', 4, 3),
    (3, 'Volume en vermoeidheid', 'Elke ronde min. 30 DU in max. 2 sets, 1 set van 50 ongebroken na cardio, max. 10% missers', 4, 3)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Double Unders'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, v.level_number, v.variant from skills s
  cross join (values
    (0, '3×100 singles', 0, 'a'), (1, 'Penguin taps — 4×20', 0, 'a'),
    (2, 'Single-single-high jump — 5×10', 0, 'a'), (3, 'Wrist rotations — 3×30 sec', 0, 'a'),
    (50, '5×60 sec singles', 0, 'b'), (51, 'Speed steps — 4×30 sec', 0, 'b'),
    (52, 'Rope turns vanuit één hand — 3×30 per zijde', 0, 'b'), (53, 'Pogo jumps — 4×20', 0, 'b'),
    (100, 'Single-single-DU — 10×5 cycli', 1, 'a'), (101, 'DU singles — 30 pogingen', 1, 'a'),
    (102, 'Penguin double taps — 4×15', 1, 'a'), (103, 'Pogo jumps — 3×20', 1, 'a'),
    (150, '3 singles + 1 DU — 10 rondes', 1, 'b'), (151, '1 single + 1 DU — 10 rondes', 1, 'b'),
    (152, 'Rope timing drill — 5×20 sec', 1, 'b'), (153, 'Max DU singles — 5 pogingen', 1, 'b'),
    (200, '10×10 DU — rust 20-30 sec', 2, 'a'), (201, 'Daarna 3 max-sets', 2, 'a'),
    (250, 'EMOM 10: 15 DU', 2, 'b'), (251, '5 sets van 20 pogingen', 2, 'b'), (252, 'Single-DU overgang — 5×10', 2, 'b'),
    (300, '5 rondes: 8 cal bike + 30 DU', 3, 'a'), (301, '60 sec rust tussen rondes', 3, 'a'),
    (350, '4 rondes: 200 m run + 40 DU', 3, 'b'), (351, '90 sec rust tussen rondes', 3, 'b')
  ) as v(sort_order, step_text, level_number, variant)
  where s.name = 'Double Unders'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

-- ---------- Butterfly Pull-up: 4 niveaus (0-3) — nu een echte progressie, geen onderhoud meer ----------
insert into skill_levels (skill_id, level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  select s.id, v.level_number, v.name, v.pass_criteria_text, v.pass_quality_min, v.pass_sessions_min from skills s
  cross join (values
    (0, 'Trek- en schouderfundament', '5 strict pull-ups + 3×10 scap pull-ups + 3×10 ritmische beat swings', 4, 3),
    (1, 'Kipping volume', '10 ongebroken kipping pull-ups, kin duidelijk boven de bar, geen uncontrolled swing na de set', 4, 3),
    (2, 'Butterfly-cirkel', '8 sets van min. 3 gekoppelde reps, kin boven de bar bij min. 90%, geen abrupte val in de onderste positie', 4, 3),
    (3, 'Volume', '3×10 ongebroken, 1 set van 15, geen no-reps of gripverlies', 4, 2)
  ) as v(level_number, name, pass_criteria_text, pass_quality_min, pass_sessions_min)
  where s.name = 'Butterfly Pull-up'
  on conflict (skill_id, level_number) do update set
    name = excluded.name, pass_criteria_text = excluded.pass_criteria_text,
    pass_quality_min = excluded.pass_quality_min, pass_sessions_min = excluded.pass_sessions_min;

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, v.level_number, v.variant from skills s
  cross join (values
    (0, 'Strict pull-up — 5×3', 0, 'a'), (1, 'Scap pull-up — 3×10', 0, 'a'),
    (2, 'Hollow/arch — 3×20 sec', 0, 'a'), (3, 'Active hang — 3×30 sec', 0, 'a'),
    (50, 'Tempo strict pull-up — 4×3', 0, 'b'), (51, 'Chest-to-bar eccentric — 4×3', 0, 'b'),
    (52, 'Beat swing — 4×8', 0, 'b'), (53, 'Ring row — 3×12', 0, 'b'),
    (100, 'Kipping pull-ups — 5×5', 1, 'a'), (101, 'Kip swings — 3×10', 1, 'a'),
    (102, 'Lat engagement drill — 3×8', 1, 'a'), (103, 'Strict pull-ups — 3×3', 1, 'a'),
    (150, 'EMOM 10: 5 kipping pull-ups', 1, 'b'), (151, 'Chest-to-bar kip — 5×3', 1, 'b'),
    (152, 'Kip reset drill — 3×5', 1, 'b'), (153, 'Hollow rocks — 3×15', 1, 'b'),
    (200, 'Box-assisted butterfly circle — 5×5', 2, 'a'), (201, 'Butterfly singles — 10×2', 2, 'a'),
    (202, 'Small-circle drill — 4×6', 2, 'a'), (203, 'Strict pull-up — 3×5', 2, 'a'),
    (250, 'Feet-supported butterfly drill — 5×6', 2, 'b'), (251, '2-3 linked butterfly reps — 8 sets', 2, 'b'),
    (252, 'Beat swing vs. butterfly contrast drill — 3×5', 2, 'b'), (253, 'Scap pull-up — 3×10', 2, 'b'),
    (300, '5×8 butterfly pull-ups — rust 60-90 sec', 3, 'a'), (301, 'Daarna 1 max-set', 3, 'a'),
    (350, 'EMOM 10: 6-8 butterfly pull-ups', 3, 'b'), (351, '3×5 kipping chest-to-bar', 3, 'b'), (352, '3×5 strict pull-ups', 3, 'b')
  ) as v(sort_order, step_text, level_number, variant)
  where s.name = 'Butterfly Pull-up'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

-- ---------- Strength & Mobility: zelfde ene niveau, nu met Training A/B(/C) i.p.v. één lijst ----------
delete from skill_exercises where skill_id in (select id from skills where name in ('Strength', 'Mobility'));

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, 0, v.variant from skills s
  cross join (values
    (0, 'Front squat — 5×5', 'a'), (1, 'Weighted pull-up — 5×5', 'a'), (2, 'Romanian deadlift — 4×8', 'a'),
    (3, 'Strict press — 4×6', 'a'), (4, 'Core carry — 3×40 m', 'a'),
    (50, 'Back squat — 5×3', 'b'), (51, 'Deadlift — 5×3', 'b'), (52, 'Push press/push jerk — 5×3', 'b'),
    (53, 'Tempo strict pull-up — 4×5', 'b'), (54, 'Single-leg accessory — 3×8 per zijde', 'b'),
    (100, 'Snatch complex — 5 sets', 'c'), (101, 'Clean & jerk complex — 5 sets', 'c'), (102, 'Front squat — 4×3', 'c'),
    (103, 'Snatch pull/clean pull — 4×3', 'c'), (104, 'Overhead stability — 3 sets', 'c')
  ) as v(sort_order, step_text, variant)
  where s.name = 'Strength'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

insert into skill_exercises (skill_id, sort_order, step_text, level_number, variant)
  select s.id, v.sort_order, v.step_text, 0, v.variant from skills s
  cross join (values
    (0, 'Banded external rotation — 2×15-20', 'a'), (1, 'Face pull — 3×15', 'a'), (2, 'Scap push-up — 3×12', 'a'),
    (3, 'Dead hang — 2×45 sec', 'a'), (4, 'Thoracic extension — 2×60 sec', 'a'), (5, 'Lat stretch — 2×45 sec per zijde', 'a'),
    (6, 'Wrist extension rocks — 2×15', 'a'),
    (50, 'Ankle dorsiflexion rocks — 3×10 per zijde', 'b'), (51, 'Couch stretch — 2×60 sec per zijde', 'b'),
    (52, '90/90 hip rotations — 2×10', 'b'), (53, 'Cossack squat — 3×6 per zijde', 'b'), (54, 'Goblet squat hold — 3×30 sec', 'b'),
    (55, 'Adductor rock-back — 2×12', 'b'), (56, 'Calf eccentric — 3×10 per zijde', 'b'),
    (100, 'German hang preparation (voeten op vloer) — 3×20 sec', 'c'), (101, 'False-grip wrist mobilization — 2×10', 'c'),
    (102, 'Ring support scap drill — 3×8', 'c'), (103, 'Hollow-to-arch flow — 3×8', 'c'),
    (104, 'Wall-facing handstand line hold — 3×20 sec', 'c'), (105, 'Forearm extensor stretch — 2×45 sec', 'c')
  ) as v(sort_order, step_text, variant)
  where s.name = 'Mobility'
  on conflict (skill_id, sort_order) do update set step_text = excluded.step_text, level_number = excluded.level_number, variant = excluded.variant;

-- ---------- Bijgewerkte RX-doelen + veelgemaakte fouten ----------
update skills set target_value = 5, target_unit = 'ongebroken reps',
  goal_text = '5 ongebroken RMU. 15 geldige RMU als 5-4-3-2-1, max 90 sec rust tussen sets.',
  common_mistakes_text = 'Te vroeg optrekken. Ringen van het lichaam wegduwen. Overmatig kippen zonder trekhoogte. Handen tijdens turnover opnieuw positioneren. Instabiele dip na de turnover.'
  where name = 'Ring Muscle-Up';
update skills set target_value = 25, target_unit = 'meter',
  goal_text = '25 meter ongebroken. 5×10m, telkens binnen 20 sec gestart en voltooid. Optioneel gevorderd: gecontroleerde 180°-draai.'
  where name = 'Handstand Walk';
update skills set target_value = 20, target_unit = 'ongebroken reps',
  goal_text = '20 ongebroken TTB. 50 reps als 15-15-10-10, max 30 sec rust.'
  where name = 'Toes-to-Bar';
update skills set target_value = 100, target_unit = 'ongebroken reps',
  goal_text = '100 ongebroken DU. 5 rondes van 50 DU + 10 burpees zonder een DU-set onder 25 reps.'
  where name = 'Double Unders';
update skills set target_value = 20, target_unit = 'ongebroken reps',
  goal_text = '20 ongebroken butterfly pull-ups. 50 reps over max 4 sets. Behoud daarnaast min. 5 strict pull-ups.',
  common_mistakes_text = 'Butterfly wordt vaak gebruikt om ontbrekende strict kracht te maskeren — strict pull-up-capaciteit blijft periodiek gecontroleerd (niveau 0-oefeningen), ook na het bereiken van RX.'
  where name = 'Butterfly Pull-up';

-- ---------- Strength: Tussenstap-tier tussen Near RX (Intermediate) en Sterk RX (RX) ----------
update benchmark_definitions set target_tussenstap = 160 where name = 'Back Squat';
update benchmark_definitions set target_tussenstap = 135 where name = 'Front Squat';
update benchmark_definitions set target_tussenstap = 200 where name = 'Deadlift';
update benchmark_definitions set target_tussenstap = 105 where name = 'Clean & Jerk';
update benchmark_definitions set target_tussenstap = 82.5 where name = 'Snatch';
update benchmark_definitions set target_tussenstap = 70 where name = 'Strict Press';
update benchmark_definitions set target_tussenstap = 90 where name = 'Push Press';
update benchmark_definitions set target_tussenstap = 102.5 where name = 'Push Jerk';
update benchmark_definitions set target_tussenstap = 30 where name = 'Weighted Pull-up';

-- ============ Migratie: Benchmark WODs (De Girls + bekende Hero WODs) ============
-- `benchmark_definitions` wordt hergebruikt als reference-lijst voor zowel krachtlifts als
-- named WODs (net als `skills` voor zowel skills als Strength/Mobility is hergebruikt). Alleen
-- via schema.sql gevuld/uitgebreid, geen client-insert policy — zie localfiles/todo.md.
alter table benchmark_definitions add column if not exists category text not null default 'strength'
  check (category in ('strength','wod'));
alter table benchmark_definitions add column if not exists workout_description text;
alter table benchmark_definitions add column if not exists score_type text not null default 'load'
  check (score_type in ('load','time','reps','rounds_reps'));

-- Reconciliatie: index.html loggen al `notes` op benchmarks (fatigue-confirmed) zonder dat de
-- kolom hier stond. `rx` is nieuw: of de gelogde score Rx of scaled was.
alter table benchmarks add column if not exists notes text;
alter table benchmarks add column if not exists rx boolean;

-- Alfabetisch op naam (sort_order) — de Girls/Hero-indeling wordt nergens als aparte
-- sectie getoond in de UI, dus a-z is hier gewoon de meest vindbare volgorde.
insert into benchmark_definitions (name, category, workout_description, score_type, unit, sort_order) values
  ('Angie', 'wod', '100 pull-ups, 100 push-ups, 100 sit-ups, 100 squats', 'time', 'tijd', 100),
  ('Annie', 'wod', '50-40-30-20-10 double-unders en sit-ups', 'time', 'tijd', 101),
  ('Barbara', 'wod', '5 ronden (3 min rust ertussen): 20 pull-ups, 30 push-ups, 40 sit-ups, 50 squats', 'time', 'tijd', 102),
  ('Chelsea', 'wod', 'EMOM 30 min: 5 pull-ups, 10 push-ups, 15 squats', 'reps', 'reps', 103),
  ('Cindy', 'wod', 'AMRAP 20 min: 5 pull-ups, 10 push-ups, 15 squats', 'rounds_reps', 'ronden+reps', 104),
  ('Diane', 'wod', '21-15-9 deadlifts (102/70 kg) en HSPU', 'time', 'tijd', 105),
  ('DT', 'wod', '5 ronden: 12 deadlifts, 9 hang power cleans, 6 push jerks (70/48 kg)', 'time', 'tijd', 106),
  ('Elizabeth', 'wod', '21-15-9 cleans (61/43 kg) en ring dips', 'time', 'tijd', 107),
  ('Eva', 'wod', '5 ronden: 800m run, 30 KB swings (32/24 kg), 30 pull-ups', 'time', 'tijd', 108),
  ('Fran', 'wod', '21-15-9 thrusters (43/29 kg) en pull-ups', 'time', 'tijd', 109),
  ('Grace', 'wod', '30 clean & jerks (61/43 kg)', 'time', 'tijd', 110),
  ('Helen', 'wod', '3 ronden: 400m run, 21 KB swings (24/16 kg), 12 pull-ups', 'time', 'tijd', 111),
  ('Isabel', 'wod', '30 snatches (61/43 kg)', 'time', 'tijd', 112),
  ('Jackie', 'wod', '1000m row, 50 thrusters (20 kg), 30 pull-ups', 'time', 'tijd', 113),
  ('JT', 'wod', '21-15-9 HSPU, ring dips, push-ups', 'time', 'tijd', 114),
  ('Karen', 'wod', '150 wall balls (9/6 kg)', 'time', 'tijd', 115),
  ('Kelly', 'wod', '5 ronden: 400m run, 30 box jumps, 30 wall balls', 'time', 'tijd', 116),
  ('Linda', 'wod', '10-9-8...1: deadlift (1,5×BW), bench (BW), clean (0,75×BW)', 'time', 'tijd', 117),
  ('Lynne', 'wod', '5 ronden max reps: bench press (BW), pull-ups', 'reps', 'reps', 118),
  ('Mary', 'wod', 'AMRAP 20 min: 5 HSPU, 10 pistols, 15 pull-ups', 'rounds_reps', 'ronden+reps', 119),
  ('Murph', 'wod', '1 mile run, 100 pull-ups, 200 push-ups, 300 squats, 1 mile run (met 9/6 kg vest)', 'time', 'tijd', 120),
  ('Nancy', 'wod', '5 ronden: 400m run, 15 overhead squats (43/29 kg)', 'time', 'tijd', 121),
  ('Nate', 'wod', 'AMRAP 20 min: 2 muscle-ups, 4 HSPU, 8 KB swings (32/24 kg)', 'rounds_reps', 'ronden+reps', 122),
  ('Nicole', 'wod', 'AMRAP 20 min: 400m run + max pull-ups per ronde', 'rounds_reps', 'ronden+reps', 123),
  ('Randy', 'wod', '75 power snatches (34/25 kg)', 'time', 'tijd', 124)
on conflict (name) do update set
  category = excluded.category, workout_description = excluded.workout_description,
  score_type = excluded.score_type, unit = excluded.unit, sort_order = excluded.sort_order;
