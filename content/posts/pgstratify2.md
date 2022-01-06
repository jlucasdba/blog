---
title: "pgstratify, Part 2"
date: 2022-01-05T17:53:07-06:00
draft: false
---
In my last post I talked about my new tool, pgstratify. I started writing this post to go over pgstratify use-cases, but it ended up being all about the details of autovacuuming instead. The use-cases will have to wait for Part 3. Note that I'm turning autovacuum on and off here for illustration purposes. Obviously don't do this in a production database.

So to start with, we create a small test table and insert some rows into it:
```postgres
create table vactest(id integer, t text);
CREATE TABLE
insert into vactest (id, t) select generate_series(1,10000),'foo';
INSERT 0 10000
```

Now we have a table with 10000 rows. Let's look at what postgres knows about it:
```postgres
select relname, n_dead_tup, n_mod_since_analyze from pg_stat_all_tables where relname='vactest';
 relname | n_dead_tup | n_mod_since_analyze 
---------+------------+--------------------
 vactest |          0 |               10000

select relname, reltuples from pg_class where relname='vactest';
 relname | reltuples 
---------+-----------
 vactest |         0
```
These are the values autovacuum looks at to determine what needs to be done for a table. (Actually in newer postgres releases, it also looks at rows inserted, but I'm going to leave that aside for now.) `n_dead_tup` is the number of updated/deleted tuples in the table that have not yet been vacuumed. `n_mod_since_analyze` is the tuples updated/deleted/inserted since the last analyze. Autovacuum can decide to VACUUM, ANALYZE, or VACUUM ANALYZE based on these stats. `reltuples`, from `pg_class` is 0 because the table hasn't been analyzed yet. Normally autovacuum will run analyze and keep this reasonably up to date.

So autovacuum has two parameters for vacuum (`autovacuum_vacuum_threshold`, `autovacuum_vacuum_scale_factor`) and two for analyze (`autovacuum_analyze_threshold`, `autovacuum_analyze_scale_factor`). It evaluates a vacuum is needed if `n_dead_tup > (autovacuum_vacuum_threshold + (autovacuum_vacuum_scale_factor * reltuples))`, and an analyze is needed if `n_mod_since_analyze > (autovacuum_analyze_threshold + (autovacuum_analyze_scale_factor * reltuples))`. The defaults for both threshold parameters are 50. The default for vacuum scale factor is .2 and the default for analyze scale factor is .1. So here `n_dead_tup` is 0 so it won't vacuum, but `n_mod_since_analyze` is 10000 so it will analyze.

After turning autovacuum back on temporarily we see this in the log:
```
LOG:  automatic analyze of table "stratify.public.vactest" system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.01 s
```

And if we re-run our previous queries we see the statistics have been updated:
```postgres
select relname, n_dead_tup, n_mod_since_analyze from pg_stat_all_tables where relname='vactest';
 relname | n_dead_tup | n_mod_since_analyze 
---------+------------+---------------------
 vactest |          0 |                   0

select relname, reltuples from pg_class where relname='vactest';
 relname | reltuples 
---------+-----------
 vactest |     10000
```

So now we have a clean table with no dead tuples. However you still might want to manually vacuum this table at least once. Here's why:
```
vacuum verbose vactest;
INFO:  vacuuming "public.vactest"
INFO:  "vactest": found 0 removable, 10000 nonremovable row versions in 45 out of 45 pages

vacuum verbose vactest;
INFO:  vacuuming "public.vactest"
INFO:  "vactest": found 0 removable, 56 nonremovable row versions in 1 out of 45 pages
```

The first vacuum run scans all 45 pages in the table because they are new and have never previously been vacuumed. The second vacuum run only has to examine 1 page, because the postgres visibility map tracks whether pages have been modified since they were last vacuumed. Postgres can skip known-clean pages for a speedup. For large tables, this optimization is an important factor in keeping your vacuum run times down.

Now we'll create some dead tuples.
```postgres
update vactest set t='bar' where id%3=0;
UPDATE 3333

select relname, n_dead_tup, n_mod_since_analyze from pg_stat_all_tables where relname='vactest';
 relname | n_dead_tup | n_mod_since_analyze 
---------+------------+---------------------
 vactest |       3333 |                3333
```

We've modified over 20% of the rows in the table, so autovacuum will trigger a vacuum run now.
```
LOG:  automatic vacuum of table "stratify.public.vactest": index scans: 0
        pages: 0 removed, 59 remain, 0 skipped due to pins, 0 skipped frozen
        tuples: 3333 removed, 10000 remain, 0 are dead but not yet removable, oldest xmin: 3745637
        buffer usage: 144 hits, 0 misses, 1 dirtied
        avg read rate: 0.000 MB/s, avg write rate: 9.753 MB/s
        system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
```

So the autovacuum output doesn't actually reflect the speedup from skipping known-vacuumed pages, but it does take advantage of it. The other important factor in how long vacuum takes to run is the number of dead tuples that need to be removed. This is especially true when indexes are involved, because the dead tuples have to be stored in memory, and each index on the table has to be scanned to clean up the corresponding index entries.

So now let's setup a more realistic example and try to demonstrate:
```postgres
stratify=# create table vactest(id integer, t text);
CREATE TABLE
stratify=# insert into vactest (id, t) select generate_series(1,50000000),'foo';
INSERT 0 50000000
stratify=# alter table vactest add constraint pk_vactest primary key (id);
ALTER TABLE
stratify=# create index idx01_vactest on vactest (t);
CREATE INDEX
```

So now we have a table with 50000000 rows, and a couple of indexes. I've analyzed and vacuumed the table. I'm going to update 20% of the table, which would be the threshold to trigger an autovacuum with scale factor .2:
```postgres
update vactest set t='bar' where id%5=0;
UPDATE 10000000
```

I'm going to manually vacuum so we can get more detail about what is happening, but I'm going to set `vacuum_cost_delay=2` to throttle my manual vacuum the same way autovacuum is throttled by default. `vacuum_cost_limit` is still set to `200`, which is also the default.
```postgres
vacuum verbose vactest;
INFO:  vacuuming "public.vactest"
INFO:  scanned index "pk_vactest" to remove 10000000 row versions
DETAIL:  CPU: user: 5.37 s, system: 0.99 s, elapsed: 132.77 s
INFO:  scanned index "idx01_vactest" to remove 10000000 row versions
DETAIL:  CPU: user: 5.58 s, system: 1.19 s, elapsed: 135.31 s
INFO:  "vactest": removed 10000000 row versions in 221239 pages
DETAIL:  CPU: user: 1.95 s, system: 1.34 s, elapsed: 172.68 s
INFO:  index "pk_vactest" now contains 50000000 row versions in 274193 pages
DETAIL:  10000000 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  index "idx01_vactest" now contains 50000000 row versions in 163110 pages
DETAIL:  10000000 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  "vactest": found 10000000 removable, 50000000 nonremovable row versions in 265487 out of 265487 pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 3745654
There were 0 unused item identifiers.
Skipped 0 pages due to buffer pins, 0 frozen pages.
0 pages are entirely empty.
CPU: user: 16.75 s, system: 5.33 s, elapsed: 607.10 s.
INFO:  vacuuming "pg_toast.pg_toast_94097"
INFO:  index "pg_toast_94097_index" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  "pg_toast_94097": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 3745654
There were 0 unused item identifiers.
Skipped 0 pages due to buffer pins, 0 frozen pages.
0 pages are entirely empty.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
VACUUM
```

This took around 5 minutes, but of course this is a dev system that is totally idle, the rows aren't very large, there's minimal TOAST involved, and there's not really that many indexes. Vacuum times can get really out of hand when there's more going on.

Now we'll do the same thing, but with only 99 dead tuples:
```postgres
update vactest set t='bar' where id<100;
UPDATE 99
stratify=# vacuum verbose vactest;
INFO:  vacuuming "public.vactest"
INFO:  scanned index "pk_vactest" to remove 85 row versions
DETAIL:  CPU: user: 0.90 s, system: 0.20 s, elapsed: 14.49 s
INFO:  scanned index "idx01_vactest" to remove 85 row versions
DETAIL:  CPU: user: 0.76 s, system: 0.35 s, elapsed: 17.22 s
INFO:  "vactest": removed 85 row versions in 2 pages
DETAIL:  CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
INFO:  index "pk_vactest" now contains 50000000 row versions in 274193 pages
DETAIL:  85 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  index "idx01_vactest" now contains 50000000 row versions in 163111 pages
DETAIL:  85 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  "vactest": found 99 removable, 935 nonremovable row versions in 5 out of 265487 pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 3745655
There were 34 unused item identifiers.
Skipped 0 pages due to buffer pins, 0 frozen pages.
0 pages are entirely empty.
CPU: user: 1.67 s, system: 0.56 s, elapsed: 31.71 s.
INFO:  vacuuming "pg_toast.pg_toast_94097"
INFO:  index "pg_toast_94097_index" now contains 0 row versions in 1 pages
DETAIL:  0 index row versions were removed.
0 index pages have been deleted, 0 are currently reusable.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  "pg_toast_94097": found 0 removable, 0 nonremovable row versions in 0 out of 0 pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 3745655
There were 0 unused item identifiers.
Skipped 0 pages due to buffer pins, 0 frozen pages.
0 pages are entirely empty.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
VACUUM
```

This took about 30 seconds.

So really all of this is to illustrate why vacuuming more often (but not *too* often) is better than waiting for many dead tuples to stack up. And why the default percentage-based scale factor settings don't scale well to large tables. The more dead tuples there are in a table, the longer they take to clean up.

Of course, this is actually a bad example in a sense - if you update 20% of a table in a single transaction, all those dead tuples will be generated before autovacuum has a chance to clean it up. Setting a lower autovacuum threshold won't help you. Most OLTP usage patterns don't look like this however. And for things like bulk data updates you should absolutely consider making manual vacuuming part of the process and consider that part of the operation time.

Next post will be about how pgstratify can help you set more appropriate thresholds for your large tables.
