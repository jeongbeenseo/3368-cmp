-- Basement A, B and C instead of one "Basement" unit.
-- Run once in Supabase -> SQL Editor. Safe to re-run.
-- Anyone already in "Basement" moves to Basement A automatically
-- (members follow unit renames).
update units set name = 'Basement A', sort = 20
 where name = 'Basement' and not exists (select 1 from units where name = 'Basement A');
insert into units (name, sort) values ('Basement A', 20), ('Basement B', 21), ('Basement C', 22)
on conflict (name) do nothing;

select name, sort from units order by sort;
