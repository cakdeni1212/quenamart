-- Quena Mart profile access baseline.
-- Execute manually in Supabase SQL Editor after reviewing current policies.
-- Signed-in users can read their own profile; profile role/status writes remain
-- an administrative operation.
begin;

alter table public.profiles enable row level security;

-- Remove existing policies so permissive policies cannot widen profile access.
do $$
declare
  existing_policy record;
begin
  for existing_policy in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
  loop
    execute format('drop policy %I on public.profiles', existing_policy.policyname);
  end loop;
end
$$;

revoke all on table public.profiles from public, anon, authenticated;
grant select on table public.profiles to authenticated;

create policy profiles_select_own
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

commit;
