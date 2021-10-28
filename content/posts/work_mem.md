---
title: "Postgres work_mem"
date: 2021-10-27T19:55:05-05:00
draft: false
---

As a followup to the post I did a while back about postgres' shared_buffers setting, I think it's also worth talking about the work_mem setting. Shared_buffers controls the size of the shared memory pool common to all backend server processes. Work_mem controls the amount of process local memory used by backend server processes for executing query operations. The main operations that use work_mem are sorts and hash joins.

From here on I'm only going to talk about sorts, but the same principles apply to hash joins as well. Sorted data has to be stored somewhere while the sort is going on. Work_mem sets how much memory a postgres backend is allowed to use for this intermediate storage. If work_mem is large enough to hold whatever is being sorted, then the sort will be done in memory. If not, the sort data will spill to temporary files on disk. Because disk access is much slower than memory access, that usually means a performance hit.

Here's a really simple example:
```
create table example as select generate_series(1,100000)::int as id;
SELECT 1000000
```

First we create a table with a million rows.

```
set work_mem = '4MB';
```

We set work_mem to 4MB, which is the default.

```
explain (analyze,verbose) select id from example order by id;
                                                          QUERY PLAN                                                           
-------------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=127757.34..130257.34 rows=1000000 width=4) (actual time=171.411..241.930 rows=1000000 loops=1)
   Output: id
   Sort Key: example.id
   Sort Method: external merge  Disk: 13800kB
   ->  Seq Scan on public.example  (cost=0.00..14425.00 rows=1000000 width=4) (actual time=0.106..64.594 rows=1000000 loops=1)
         Output: id
 Planning Time: 0.184 ms
 Execution Time: 268.075 ms
(8 rows)
```

Now we do a sorted sequential scan on the table. As you can see from the plan, it does the sort on disk, using about 14MB of space.

```
set work_mem = '128MB';
```

Now we set work_mem to 128MB and try again.

```
explain (analyze,verbose) select id from example order by id;
                                                          QUERY PLAN                                                           
-------------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=114082.84..116582.84 rows=1000000 width=4) (actual time=139.981..173.605 rows=1000000 loops=1)
   Output: id
   Sort Key: example.id
   Sort Method: quicksort  Memory: 71452kB
   ->  Seq Scan on public.example  (cost=0.00..14425.00 rows=1000000 width=4) (actual time=0.142..64.266 rows=1000000 loops=1)
         Output: id
 Planning Time: 0.131 ms
 Execution Time: 199.461 ms
(8 rows)
```

This time we see that the sort was done in memory, and used about 72MB. It also ran about 60ms faster. This is an important point to keep in mind - the space needed for in-memory and disk-based sorts is not the same. The data written to temp files on disk is compressed. This does make setting work_mem more difficult, because just looking at how much space an operation on disk is using won't tell you how much the equivalent in-memory operation would need.

Sizing work_mem appropriately is tricky. The setting is per sort/hash operation, *not* per session. A single query execution might perform many sorts and allocate many work_mem sized memory buffers. So to size work_mem for a whole server, you need to know not only how many active sessions you expect to have executing queries simultaneously, but also how many sort/hash operations they might each be executing.

The default setting of 4MB is very conservative on modern hardware, and will force sort operations to disk on all but the smallest tables, so it's worth considering increasing.

As a very rough starting point on a dedicated server, I'd propose a formula like `(physical_ram * .25) / (expected_active_sessions * expected_sorts_per_session)`.  So if you have a server with 64GB of RAM, and you expect 40 active sessions and an average of 2 concurrent sorts per session, you might set work_mem to around 200MB. Take this with a huge grain of salt though. There's a lot of assumptions being made here, and there's really no substitute for performance testing your workload. The larger you make work_mem, the more chance you run of a runaway spike in session activity causing your server to run out of RAM, so it's usually best to err on the side of caution unless you understand your workload very well.

One other thing to keep in mind is that unlike shared_buffers, work_mem can be set per-session. The server level setting is just a default. So an application might have its own ideas about how much memory it should be using, and set work_mem on its own before executing a big query. As a DBA there's often not a lot you can do about this beyond educating your users or developers, but it's definitely something to be aware of. If you see sessions using an unexpected amount of memory for sorts, this might be what's going on.
