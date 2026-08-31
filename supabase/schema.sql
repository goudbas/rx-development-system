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
    execute format('create policy "owner_select" on %I for select using (auth.uid() = user_id)', t);
    execute format('create policy "owner_insert" on %I for insert with check (auth.uid() = user_id)', t);
    execute format('create policy "owner_update" on %I for update using (auth.uid() = user_id)', t);
    execute format('create policy "owner_delete" on %I for delete using (auth.uid() = user_id)', t);
  end loop;
end $$;

-- skills is reference data: readable by any logged-in user, not writable from the client
alter table skills enable row level security;
create policy "skills_read" on skills for select using (auth.role() = 'authenticated');
