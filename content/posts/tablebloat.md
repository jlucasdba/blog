---
title: "Postgres Table Bloat"
date: 2020-11-25T11:29:05-06:00
draft: true
---

One of the things DBAs coming from other database systems (like Oracle) need to be aware of when coming to Postgres is how Postgres manages changed data. This is covered in depth in a lot of other places, so I won't repeat in too much detail. The short version is that when a row is updated or deleted, Postgres maintains the old version of that row within the table data file. Visibility of the old version to concurrent transactions is controlled by transaction id. Eventually, when the old row versions are no longer needed, they are garbage collected by the table vacuum process.

This is different than a system like Oracle, where old data is written to a separate space (undo), referenced when needed, and discarded when no longer needed. Both approaches have positives and negatives. Postgres' advantage is that transaction rollbacks are fast. The data is still in the datafiles, so a rollback is simply a question of manipulating transaction ids. In an undo-based system, rollbacks can take a very long time if a lot of data has to be copied back out of undo. The disadvantage is that heavily written tables in Postgres can become physically very large, even if the number of live rows is relatively small. This is often referred to as "table bloat". Vacuuming more frequently can help, but may not eliminate the problem. It's possible to wind up with large empty spaces in undo-based systems, but this really only happens as a result of large-scale deletes, and the effect is not really cumulative like it can be in Postgres. 

We can illustrate this with a simple example. Note that I've disabled autovacuum for this example. Please don't do that in live systems.

First we setup some standard extensions we're going to use for this example:
```
postgres=# create extension pgstattuple;
CREATE EXTENSION
postgres=# create extension pageinspect;
CREATE EXTENSION
```

Then we create a test table and insert some data into it:
```
postgres=# create table testtab (id int);
CREATE TABLE
postgres=# insert into testtab select generate_series(1,2000);
INSERT 0 2000
```

Postgres datafiles are laid out in terms of 8k (by default) pages. To get an visualize what's going on at the page level, we can use a query like this. This is a really simple case because our data is all ints. We can see postgres can store 226 rows per page.
```
postgres=# with pageinfo as (select * from (select generate_series::int as pagenum from generate_series(0,(select (pg_relation_size/(select setting from pg_settings where name='block_size')::int)-1 from pg_relation_size('testtab')))) pages, heap_page_items(get_raw_page('testtab',pages.pagenum)))
select p1.pagenum, coalesce(p2.c,0) as c from (select distinct pagenum from pageinfo) p1 left join (select pagenum,count(*) as c from pageinfo where lp_len > 0 group by pagenum) p2 on p1.pagenum=p2.pagenum order by p1.pagenum;
 pagenum |  c  
---------+-----
       0 | 226
       1 | 226
       2 | 226
       3 | 226
       4 | 226
       5 | 226
       6 | 226
       7 | 226
       8 | 192
(9 rows)
```

Now what happens if we delete half the rows? We see the number of rows in the pages doesn't change, because even after deletion, the old row versions are still present.
```
postgres=# delete from testtab where id between 1001 and 2000;
DELETE 1000
postgres=# with pageinfo as (select * from (select generate_series::int as pagenum from generate_series(0,(select (pg_relation_size/(select setting from pg_settings where name='block_size')::int)-1 from pg_relation_size('testtab')))) pages, heap_page_items(get_raw_page('testtab',pages.pagenum)))
select p1.pagenum, coalesce(p2.c,0) as c from (select distinct pagenum from pageinfo) p1 left join (select pagenum,count(*) as c from pageinfo where lp_len > 0 group by pagenum) p2 on p1.pagenum=p2.pagenum order by p1.pagenum;
 pagenum |  c  
---------+-----
       0 | 226
       1 | 226
       2 | 226
       3 | 226
       4 | 226
       5 | 226
       6 | 226
       7 | 226
       8 | 192
(9 rows)
```

But if we vacuum the table, we can see the number of rows goes down. In fact, we'll see the number of pages in the table actually goes down as well. Vacuum is able to completely drop **empty** pages from the end of a table. Note the "truncated 9 to 5 pages" in the output. It is not able to drop empty pages in the middle, as we'll see soon.
```
postgres=# vacuum verbose testtab;
INFO:  vacuuming "public.testtab"
INFO:  "testtab": removed 1000 row versions in 5 pages
INFO:  "testtab": found 1000 removable, 1000 nonremovable row versions in 9 out of 9 pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 20635
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins, 0 frozen pages.
0 pages are entirely empty.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
INFO:  "testtab": truncated 9 to 5 pages
DETAIL:  CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.02 s
VACUUM
postgres=# with pageinfo as (select * from (select generate_series::int as pagenum from generate_series(0,(select (pg_relation_size/(select setting from pg_settings where name='block_size')::int)-1 from pg_relation_size('testtab')))) pages, heap_page_items(get_raw_page('testtab',pages.pagenum)))
select p1.pagenum, coalesce(p2.c,0) as c from (select distinct pagenum from pageinfo) p1 left join (select pagenum,count(*) as c from pageinfo where lp_len > 0 group by pagenum) p2 on p1.pagenum=p2.pagenum order by p1.pagenum;
 pagenum |  c  
---------+-----
       0 | 226
       1 | 226
       2 | 226
       3 | 226
       4 |  96
(5 rows)
```

So now we reinsert our deleted rows, and delete all but the last one. As expected, we're back to 9 pages.
```
postgres=# insert into testtab select generate_series(1001,2000);
INSERT 0 1000
postgres=# delete from testtab where id between 1001 and 1999;
DELETE 999
postgres=# with pageinfo as (select * from (select generate_series::int as pagenum from generate_series(0,(select (pg_relation_size/(select setting from pg_settings where name='block_size')::int)-1 from pg_relation_size('testtab')))) pages, heap_page_items(get_raw_page('testtab',pages.pagenum)))
select p1.pagenum, coalesce(p2.c,0) as c from (select distinct pagenum from pageinfo) p1 left join (select pagenum,count(*) as c from pageinfo where lp_len > 0 group by pagenum) p2 on p1.pagenum=p2.pagenum order by p1.pagenum;
 pagenum |  c  
---------+-----
       0 | 226
       1 | 226
       2 | 226
       3 | 226
       4 | 226
       5 | 226
       6 | 226
       7 | 226
       8 | 192
(9 rows)
```

And finally we vacuum again. This time we can see that we are left with one half filled page, three empty pages, and a last page with a single row in it. Even though we deleted rows, our table size does not decrease.
```
postgres=# vacuum verbose testtab;
INFO:  vacuuming "public.testtab"
INFO:  "testtab": removed 999 row versions in 5 pages
INFO:  "testtab": found 999 removable, 1001 nonremovable row versions in 9 out of 9 pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 20638
There were 0 unused item pointers.
Skipped 0 pages due to buffer pins, 0 frozen pages.
0 pages are entirely empty.
CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s.
VACUUM
postgres=# with pageinfo as (select * from (select generate_series::int as pagenum from generate_series(0,(select (pg_relation_size/(select setting from pg_settings where name='block_size')::int)-1 from pg_relation_size('testtab')))) pages, heap_page_items(get_raw_page('testtab',pages.pagenum)))
select p1.pagenum, coalesce(p2.c,0) as c from (select distinct pagenum from pageinfo) p1 left join (select pagenum,count(*) as c from pageinfo where lp_len > 0 group by pagenum) p2 on p1.pagenum=p2.pagenum order by p1.pagenum;
 pagenum |  c  
---------+-----
       0 | 226
       1 | 226
       2 | 226
       3 | 226
       4 |  96
       5 |   0
       6 |   0
       7 |   0
       8 |   1
(9 rows) 
```

In a small example like this, this doesn't matter much. But at scale, all those empty pages still have to be checked during operations like sequential scans. They can have a significant performance impact. That empty space can be re-used for new data, so it's not all bad news. Still, this is something every admin or developer working with postgres needs to be cognizant of.

So what are the takeaways here?
1. Vacuum early, vacuum often. The more often you vacuum, the less chance you have for dead rows to stack up. Of course, vacuuming also has a cost, so you can't do it **too** much. But vacuum actually gets more expensive the more rows it needs to remove, so on balance it's better to do it too often than not often enough.
2. Depending on your usage pattern, it may make sense to have your application code explicitly vacuum after large modification operations. This won't fit every environment well, but taking vacuum into consideration in your workflows may be beneficial, rather than just relying on autovacuum to clean up.
3. In the case of really large data modifications, it may make sense to completely rebuild the table with VACUUM FULL. This will rewrite all the pages and compact the empty space. However it's also expensive and requires an exclusive lock. Plus it really only makes sense to do if the large-scale modification is an unusual circumstance. If you're just going to create a bunch of empty pages again immediately, there isn't any point.
