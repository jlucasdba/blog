---
title: "Hugo"
date: 2020-11-30T17:19:55-06:00
draft: false
---
I wanted to do a quick post about the blogging setup I'm using, and why I chose it. The purpose of this blog is to provide a place to do write-ups on topics of interest I run across in my work, and share them with the community. Github Pages seemed like a natural (and inexpensive!) hosting solution, given the target audience.

While I was researching hosting, the topic of static site generators came up. These tools are essentially static website compilers. You build your site out of component pieces (templates, static assets, markdown), and feed it into the site generator to generate a fully realized html site. The advantage of a setup like this is it provides a lot of flexibility with fairly minimal setup and maintenance. You don't need a database, and adding a new post is as simple as adding a new markdown file and rebuilding the site.

The site generator I'm using is called [Hugo](https://gohugo.io). It's a tool with a special emphasis on creating hierarchical pages of posted content - ideal for a blog. There's a large number of community-built themes available, and it's easy to override individual theme elements to customize for your needs. Deployment is just pushing a new compiled version of the site into a git repo.

There's a bit of a learning curve to be sure, but once it's up and running the maintenance is near zero. Definitely an option worth looking at, particularly for a blog or Github project site. 
