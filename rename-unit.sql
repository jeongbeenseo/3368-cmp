-- Room A is Ground A, not Upper A.
-- Run this once in Supabase → SQL Editor. The members table references
-- units(name) with "on update cascade", so anyone living there follows
-- automatically — no need to touch their row.
update units set name = 'Ground A' where name = 'Upper A';

-- check it worked:
select name, sort from units order by sort;
