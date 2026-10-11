-- =====================================================================
-- DESIGN VOTE PORTAL  -  database setup (Supabase / Postgres)
-- Run this whole file once in: Supabase > SQL Editor > New query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

-- People allowed to open the admin dashboard (by login email)
create table if not exists admin_users (
  email text primary key
);

-- Every design / article picture you upload
create table if not exists designs (
  id            uuid primary key default gen_random_uuid(),
  code          text,                       -- your article / SKU code (private, never shown to customers)
  title         text,                       -- optional name shown to customers
  category      text,                       -- optional (e.g. "Lawn", "Kurta", "Abaya")
  image_path    text not null,              -- path inside the 'designs' storage bucket
  status        text not null default 'active'
                check (status in ('active','hidden','approved','in_production','rejected')),
  hidden_reason text,                       -- 'auto' when the portal hid it, 'manual' when you did
  locked        boolean not null default false,  -- true = you decided; auto-hide will never touch it
  love_count    int not null default 0,
  must_count    int not null default 0,     -- "must have" super-votes
  pass_count    int not null default 0,
  created_at    timestamptz not null default now()
);

-- One row per anonymous visitor
create table if not exists voters (
  id          uuid primary key,             -- generated in the visitor's browser
  created_at  timestamptz not null default now(),
  user_agent  text,
  name        text,
  contact     text,                         -- WhatsApp number or email (given to claim reward)
  reward_code text,
  claimed_at  timestamptz
);
create unique index if not exists voters_contact_uniq on voters (contact) where contact is not null;

-- One row per vote (a visitor can vote on a design only once)
create table if not exists votes (
  voter_id   uuid not null references voters(id) on delete cascade,
  design_id  uuid not null references designs(id) on delete cascade,
  vote       text not null check (vote in ('love','must','pass')),
  created_at timestamptz not null default now(),
  primary key (voter_id, design_id)
);
create index if not exists votes_design_idx on votes (design_id);

-- Single settings row
create table if not exists settings (
  id                 int primary key default 1 check (id = 1),
  min_votes_to_hide  int     not null default 30,    -- need at least this many votes before auto-hide can happen
  hide_pass_rate     numeric not null default 0.70,  -- hide when this share (0-1) of voters passed
  reward_enabled     boolean not null default true,
  reward_code        text    not null default 'VOTE10',
  reward_text        text    not null default '10% off your next order',
  reward_min_votes   int     not null default 15     -- votes a visitor must cast to unlock the reward
);
insert into settings (id) values (1) on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2. SECURITY
-- Customers (anonymous) can NOT read or write tables directly.
-- They only talk to the three safe functions below.
-- ---------------------------------------------------------------------

alter table admin_users enable row level security;
alter table designs     enable row level security;
alter table voters      enable row level security;
alter table votes       enable row level security;
alter table settings    enable row level security;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admin_users where lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));
$$;

-- Admin-only access to the raw tables (for the dashboard)
drop policy if exists admin_all_designs on designs;
create policy admin_all_designs on designs for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists admin_read_voters on voters;
create policy admin_read_voters on voters for select to authenticated using (is_admin());

drop policy if exists admin_read_votes on votes;
create policy admin_read_votes on votes for select to authenticated using (is_admin());

drop policy if exists admin_all_settings on settings;
create policy admin_all_settings on settings for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists admin_read_admins on admin_users;
create policy admin_read_admins on admin_users for select to authenticated using (is_admin());

-- ---------------------------------------------------------------------
-- 3. CUSTOMER-FACING FUNCTIONS (these never return vote counts)
-- ---------------------------------------------------------------------

-- Deck for one visitor: active designs they have not voted on yet, in random order
create or replace function get_deck(p_voter uuid)
returns table (id uuid, title text, category text, image_path text)
language sql volatile security definer set search_path = public as $$
  select d.id, d.title, d.category, d.image_path
  from designs d
  where d.status = 'active'
    and not exists (select 1 from votes v where v.voter_id = p_voter and v.design_id = d.id)
  order by random();
$$;

-- Safe settings the front end may know about (no secrets: the code itself is not included)
create or replace function get_public_settings()
returns table (reward_enabled boolean, reward_text text, reward_min_votes int)
language sql stable security definer set search_path = public as $$
  select reward_enabled, reward_text, reward_min_votes from settings where id = 1;
$$;

-- Record one vote, update totals, and auto-hide the design if customers clearly don't want it
create or replace function cast_vote(p_voter uuid, p_design uuid, p_vote text, p_ua text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  d designs%rowtype;
  inserted int;
  total int;
begin
  if p_vote not in ('love','must','pass') then
    raise exception 'invalid vote';
  end if;

  insert into voters (id, user_agent) values (p_voter, left(p_ua, 300)) on conflict (id) do nothing;

  insert into votes (voter_id, design_id, vote) values (p_voter, p_design, p_vote)
  on conflict (voter_id, design_id) do nothing;
  get diagnostics inserted = row_count;
  if inserted = 0 then return; end if;   -- duplicate vote, ignore

  update designs set
    love_count = love_count + (p_vote = 'love')::int,
    must_count = must_count + (p_vote = 'must')::int,
    pass_count = pass_count + (p_vote = 'pass')::int
  where id = p_design
  returning * into d;

  select * into s from settings where id = 1;
  total := d.love_count + d.must_count + d.pass_count;

  if d.status = 'active' and not d.locked
     and total >= s.min_votes_to_hide
     and (d.pass_count::numeric / total) >= s.hide_pass_rate then
    update designs set status = 'hidden', hidden_reason = 'auto' where id = p_design;
  end if;
end;
$$;

-- Unlock the thank-you reward. One reward per WhatsApp number / email.
create or replace function claim_reward(p_voter uuid, p_contact text, p_name text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  n int;
  c text := nullif(trim(p_contact), '');
  existing uuid;
begin
  select * into s from settings where id = 1;
  if not s.reward_enabled then return json_build_object('ok', false, 'error', 'rewards_off'); end if;
  if c is null or length(c) < 6 then return json_build_object('ok', false, 'error', 'bad_contact'); end if;

  select count(*) into n from votes where voter_id = p_voter;
  if n < s.reward_min_votes then return json_build_object('ok', false, 'error', 'not_enough_votes'); end if;

  -- same number/email already used on another device? give the same code, but do not create a second lead
  select id into existing from voters where contact = c and id <> p_voter;
  if existing is not null then
    return json_build_object('ok', true, 'code', s.reward_code, 'text', s.reward_text, 'repeat', true);
  end if;

  update voters set contact = c, name = left(p_name, 100), reward_code = s.reward_code, claimed_at = now()
  where id = p_voter;

  return json_build_object('ok', true, 'code', s.reward_code, 'text', s.reward_text, 'repeat', false);
end;
$$;

revoke all on function get_deck(uuid) from public;
revoke all on function get_public_settings() from public;
revoke all on function cast_vote(uuid, uuid, text, text) from public;
revoke all on function claim_reward(uuid, text, text) from public;
grant execute on function get_deck(uuid) to anon, authenticated;
grant execute on function get_public_settings() to anon, authenticated;
grant execute on function cast_vote(uuid, uuid, text, text) to anon, authenticated;
grant execute on function claim_reward(uuid, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. IMAGE STORAGE
-- Public bucket (so pictures load fast); only admins can upload/delete.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('designs', 'designs', true)
on conflict (id) do nothing;

drop policy if exists "designs_admin_write" on storage.objects;
create policy "designs_admin_write" on storage.objects for insert to authenticated
  with check (bucket_id = 'designs' and is_admin());

drop policy if exists "designs_admin_update" on storage.objects;
create policy "designs_admin_update" on storage.objects for update to authenticated
  using (bucket_id = 'designs' and is_admin());

drop policy if exists "designs_admin_delete" on storage.objects;
create policy "designs_admin_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'designs' and is_admin());

-- ---------------------------------------------------------------------
-- 5. LAST STEP (do this yourself): register your admin email.
--    1) Supabase > Authentication > Users > Add user (your email + a strong password)
--    2) Run this line with YOUR email:
--
--    insert into admin_users (email) values ('you@yourdomain.com');
-- ---------------------------------------------------------------------
