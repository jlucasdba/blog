---
title: "pgstratify"
date: 2022-01-04T23:14:00-06:00
draft: true
---
I wanted to share a project I've been working on the last few weeks, called pgstratify. This was written in equal parts to provide a tool I thought would be useful for postgres DBAs, and as an exercise to teach myself Go. I feel like it succeeded pretty well on both fronts.

The core idea of pgstratify is to help a DBA manage the storage parameters on individual tables in the database. Specifically the ones that determine when a table is due for autovacuum.

The default autovacuum setup for postgres is percentage-based. When 20% of the rows in a table have been modified, a vacuum pass is triggered. This works fine for small tables, but it doesn't scale very well to large ones. You could reduce the percentage to say, 5%. But that means you spend cycles vacuuming all your tables more often, and it still doesn't really address the scalability problem. Ideally for big tables you probably want to set a hard threshold, where once the table reaches a certain size, autovacuum stops being percentage-based, and instead triggers every time a specific number of rows have been modified. You can do this already with storage parameters, but they need to be manually set on each table with ALTER TABLE.

Enter pgstratify. With pgstratify, the idea is to divide your tables into two or more size categories (or strata, if you prefer), and apply different sets of storage parameters to them. Every time pgstratify is run, it scans the database for tables that are out of sync with the parameter rules you've defined, and brings everything in line.

So if you setup pgstratify to run say, once every hour, if a table crosses the size limit you've defined, its storage parameters will be modified to set hard autovacuum threshold. You won't have to manually intervene at all. It works the other way too - if the table size goes back down, the parameters will be reverted. The general idea is you'd use the system-level settings for average tables, and pgstratify will only really need to work on the outliers.

As far as the "learning Go" part, I already had some experience, but this was the first decent-sized project I'd tried to take on. I spent way more time plumbing out basic functionality than I would have with something like Python, and I feel like only part of that was because I didn't know what I was doing. This is a pretty verbose language. I'm still not totally sold on the error handling model, although it did at least bother me less as time went by. I do think the language has a lot of good ideas, and this probably won't be the last project I use it on. Getting near-C performance in a language with a lot of modern conveniences is certainly appealing.

I put a lot of work into developing pgstratify, and I hope it will be useful to people. I might do another post in the near future with some usage examples. In the meantime, feel free to check out the [git repo](https://github.com/jlucasdba/pgstratify).
