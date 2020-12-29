---
title: "Postgres shared_buffers"
date: 2020-12-31T13:51:29-06:00
draft: false
---

Let's talk about shared_buffers in postgres. Postgres has very good documentation, but the tuning of this important parameter is one area where the documentation is unfortunately a bit vague.

When postgres starts up, it grabs a chunk of memory that is shared between all backend server processes. Shared_buffers controls the size of this shared memory pool. Every page the database reads or writes passes through this shared memory.

Everytime the database reads a page from disk, it's stored in these shared buffers. Depending on factors we'll go into later, it may be cached in memory for a longer or shorter period of time, but it will always be stored at least briefly. Cacheing is important because even fast SSDs are slower than RAM. The less often the database has to perform disk access, the better its performance will be.

Similarly, everytime the database writes a page, it's stored in the shared buffers. Writes are written to WAL immediately, but writes to table datafiles are held in memory so that disk io can (ideally) be spread out over time. This also has the added benefit that this recently written page is available in memory if it needs to be read again quickly.

At this point, you may think, "Great, I'll just make shared_buffers the same size as my RAM, give all the memory to postgres to manage, and call it a day." Well, not so fast. For one thing, the operating system and any other processes on the system need memory to operate too. For another, postgres backend processes use per-process, non-shared memory as well. Operations like in-memory sorts are done in memory allocated to the individual backend processes, not the shared buffers. So there also needs to be memory available for these processes.

The other thing to consider is that postgres is designed to rely on the filesystem cache provided by the operating system. You'll see this mentioned in various sources online, but here's what it means in practice. Scans of large tables do not cache their pages in the shared buffers. Any scan larger than 25% of the shared_buffers size instead allocates a small ring buffer in the buffer pool, reads pages into that, and immediately cycles them out as new pages are loaded in. This is to avoid a single large scan evicting everything else from the shared buffers. This does mean that the pages from those large scans don't remain cached. But, postgres is counting on the fact that those large table pages are (hopefully) also being cached by the operating system, so repeated reads should still avoid expensive disk accesses. The more memory you allocate to shared_buffers, the less memory the operating system has to cache files.

Similarly, bulk write operations like COPY or CREATE TABLE AS SELECT also use a somewhat larger ring buffer for their page writes to avoid evicting the entire buffer cache.

There's one final, related factor to consider, which is the double-cacheing effect. We've established that both postgres and the operating system are cacheing pages. In many cases they will both be cacheing the **same** pages. To some extent this is unavoidable, as maintaining data in shared buffers is necessary. But the larger your shared_buffers area is, the more memory capacity you are likely to be wasting by cacheing data at both the postgres and operating system level.

Most recommendations you'll see online are that a good starting point for shared_buffers on a dedicated database server is 25% of your RAM. For some workloads it may be advantageous to go as high as 40%, but probably not more than about 8GiB.

This is good starting advice, but let's try to dig a little deeper.

Cases for having a larger shared_buffers:
* If your workload is write heavy, more shared_buffers is probably helpful. You have more room to cache writes in memory before they have to be flushed to disk.
* If you've increased max_wal_size and/or checkpoint_timeout, you probably also want to increase shared_buffers. Increasing these settings means your checkpoints are farther apart. That means (assuming the same level of traffic) more writes between checkpoints, so it's advantageous to also have more memory to buffer them in.
* If you have a lot of small tables, or at least a small subset of active data that you mostly do indexed lookups on, you may want to increase shared_buffers. The best case scenario is that all of your frequently read data can be fully cached in shared buffers, and you never need to read from disk at all once the cache is populated. Can be difficult in practice though, unless your working set is small, or you have a whole lot of memory.

Cases for having a smaller shared_buffers:
* If you have a lot of large tables that you scan frequently, you probably want a lower shared_buffers. This may seem counterintuitive, but the pages read during these large scans won't be cached by postgres anyway, so better to leave as much room as possible for the operating system cache.
* If you do a lot of bulk load operations, these are also processed using a ring buffer and pushed immediately to storage, so a large shared_buffers setting won't help here either.

So based on these points, write heavy OLTP workloads with a relatively small active dataset will probably benefit from a larger setting for shared_buffers. And OLAP workloads with a lot of bulk writes and large table scans won't benefit much, and should use a smaller shared_buffers setting to avoid wasting memory.

Of course the tricky part is that many database workloads don't fall neatly into one of these two categories. In that case you have to compromise. The only way to know for sure is going to be to test how postgres behaves under your specific workload. Hopefully understanding these fundamentals will at least help you make more informed tuning choices.

In any case, the more RAM you have available on your database server the better. Even if you don't allocate it explicitly to shared_buffers, it can still be used for operating system cacheing, and that will have benefits as well.

Special shoutout to Hironobu Suzuki's online book [The Internals of PostgreSQL](http://www.interdb.jp/pg/index.html), which went a long way towards helping me understand postgres's memory management. Recommended reading.
