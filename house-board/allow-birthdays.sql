-- Lets housemates save birthdays.
-- save_doc deliberately allows only a short list of keys, so that housemates
-- can post but can't touch anything structural. This adds 'birthdays' to that
-- list and changes nothing else. Run once in Supabase -> SQL Editor.

create or replace function save_doc(p_code text, p_key text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (actor(p_code)).id is null then raise exception 'Please sign in again'; end if;
  if p_key not in ('progress', 'trips', 'notes', 'birthdays') then
    raise exception 'Only the manager can change that';
  end if;
  insert into docs (key, data, updated_at) values (p_key, p_data, now())
    on conflict (key) do update set data = excluded.data, updated_at = now();
end; $$;
