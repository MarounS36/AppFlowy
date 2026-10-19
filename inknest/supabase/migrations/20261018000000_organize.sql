create table organize_usage (
  user_uuid text not null, day date not null, count int not null default 0,
  primary key (user_uuid, day));
create table organize_allowlist (email text primary key);
alter table organize_usage enable row level security;
alter table organize_allowlist enable row level security;

-- ponytail: check-then-increment is not atomic across concurrent calls; limits can overshoot by a few. Use advisory locks if that matters.
create function organize_consume(p_user text, p_user_limit int, p_global_limit int)
returns text language plpgsql security definer set search_path = public as $$
declare used int;
begin
  select count into used from organize_usage where user_uuid = p_user and day = current_date;
  if coalesce(used, 0) >= p_user_limit then return 'user_limit'; end if;
  if (select coalesce(sum(count), 0) from organize_usage where day = current_date) >= p_global_limit
    then return 'global_limit'; end if;
  insert into organize_usage (user_uuid, day, count) values (p_user, current_date, 1)
    on conflict (user_uuid, day) do update set count = organize_usage.count + 1;
  return 'ok';
end $$;
revoke execute on function organize_consume(text, int, int) from public, anon, authenticated;
