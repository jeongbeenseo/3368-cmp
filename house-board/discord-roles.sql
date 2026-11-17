-- ===========================================================================
-- Discord, part 4: Cindy makes everyone's role
--
-- In #verification, Cindy's "Get my role" button asks for a first name and a
-- colour, then creates a role with that name and colour and gives it to them.
-- Only people who have linked their House Board account can do this.
--
-- Run once in Supabase -> SQL Editor (after discord.sql). Safe to re-run.
-- ===========================================================================

-- The Discord role Cindy made for each member, so changing your colour later
-- edits the same role instead of making a new one.
alter table members add column if not exists discord_role_id text unique;

-- Who a Discord account belongs to. Server only.
create or replace function discord_member(p_discord_id text)
returns table (id uuid, name text, role text, discord_role text, discord_role_id text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return query select m.id, m.name, m.role, m.discord_role, m.discord_role_id from members m
   where m.discord_id = p_discord_id and m.status = 'active';
end; $$;

-- Remember the role Cindy made. Refuses a role that already belongs to
-- someone else, so nobody can take over a housemate's role. Server only.
create or replace function discord_set_role(p_discord_id text, p_role_name text, p_role_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  if exists (select 1 from members where discord_role_id = p_role_id and discord_id is distinct from p_discord_id) then
    raise exception 'That role belongs to someone else';
  end if;
  update members set discord_role = p_role_name, discord_role_id = p_role_id where discord_id = p_discord_id;
end; $$;

-- The other housemates' roles, so a new role can copy their permissions and
-- channel access. Housemates only: not the manager, landlord, guests or basement.
-- Server only.
create or replace function discord_house_roles(p_except text)
returns table (discord_role_id text, role_name text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return query select m.discord_role_id, coalesce(m.discord_role, split_part(m.name, ' ', 1))
    from members m
   where m.status = 'active' and m.role = 'member' and m.discord_id is not null
     and m.discord_id is distinct from p_except
   order by m.discord_role_id is null, m.created_at;
end; $$;

-- Is this role someone else's? Server only.
create or replace function discord_role_taken(p_role_id text, p_discord_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return exists (select 1 from members where discord_role_id = p_role_id and discord_id is distinct from p_discord_id);
end; $$;

-- Linking now also returns the role Cindy made, if there is one.
drop function if exists discord_link(text, text, text);
create function discord_link(p_code text, p_discord_id text, p_discord_name text)
returns table (name text, role text, discord_role text, discord_role_id text)
language plpgsql security definer set search_path = public as $$
declare me members;
begin
  if not is_server() then raise exception 'Not allowed'; end if;

  if (select count(*) from sign_in_log where not ok and at > now() - interval '5 minutes') > 20 then
    raise exception 'Too many failed sign-ins just now. Try again in five minutes.';
  end if;

  select * into me from members m where m.code = p_code and m.status = 'active';
  insert into sign_in_log (ok) values (me.id is not null);
  if me.id is null then raise exception 'Your House Board sign-in has expired. Sign in again.'; end if;

  update members set discord_id = null, discord_name = null
   where discord_id = p_discord_id and id <> me.id;
  update members set discord_id = p_discord_id, discord_name = p_discord_name where id = me.id;

  return query select me.name, me.role, me.discord_role, me.discord_role_id;
end; $$;

revoke execute on function discord_member(text)                    from public, anon, authenticated;
revoke execute on function discord_set_role(text, text, text)      from public, anon, authenticated;
revoke execute on function discord_role_taken(text, text)          from public, anon, authenticated;
revoke execute on function discord_house_roles(text)               from public, anon, authenticated;
revoke execute on function discord_link(text, text, text)          from public, anon, authenticated;
grant  execute on function discord_member(text)                    to service_role;
grant  execute on function discord_set_role(text, text, text)      to service_role;
grant  execute on function discord_role_taken(text, text)          to service_role;
grant  execute on function discord_house_roles(text)               to service_role;
grant  execute on function discord_link(text, text, text)          to service_role;

select name, discord_name, discord_role, discord_role_id from members where discord_id is not null order by name;
