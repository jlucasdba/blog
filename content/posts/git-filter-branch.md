---
title: "Git filter-branch"
date: 2020-12-08T20:06:11-06:00
draft: false
---
Let's talk about one of the less-understood git commands for a minute: git filter-branch. What do you do if some element exists in your git repository that you need to expunge? Say a password, or a sensitive email address. Well, ideally you should change the password or the email address, because rewriting git history is not something you should undertake lightly. But, if you're a brave soul who ignores the warning signs, and ventures down the dark path, filter-branch is what you use.

If you're at all familiar with git, every commit depends on all the previous gits before it. You can't change an old commit without also rewriting any newer commits. And that's exactly what filter-branch does. It walks through the entire commit history of a branch, applies a filter at each step, and creates new commits from the filtered result.

Here's a really simple example. 

```
* commit c36d131655f4e73ca4101674dde213a0f7a0794c (HEAD, origin/master, origin/HEAD, master)
| Author: James Lucas <sensitive.email>
| Date:   Mon Dec 7 15:16:43 2020 -0600
| 
|     Second commit.
|  
* commit 8fa4b4ae6a4e0abcc2d643988467ef11a91d2844
  Author: James Lucas <sensitive.email>
  Date:   Mon Dec 7 15:16:32 2020 -0600
  
      First commit.
```

Oops. We used an email address we shouldn't have. Maybe a personal email instead of a work email. Filter-branch has a number of different filters. For rewriting metadata info like author email, the one you want is the **env-filter**. You provide a block to be executed for each processed commit (which might be a complex script in and of itself), and the environment variables set at the end are used to rewrite the commit metadata. (There's a list of available filters and how to use them in the [git-filter-branch man page](https://git-scm.com/docs/git-filter-branch)). So in our example, we want to set the GIT_AUTHOR_EMAIL variable, to change the author email to something else.  So our command looks like this:

```
git filter-branch --env-filter 'export GIT_AUTHOR_EMAIL="public.email"' master
Rewrite c36d131655f4e73ca4101674dde213a0f7a0794c (2/2)
Ref 'refs/heads/master' was rewritten
```

And the resulting log looks like

```
* commit 575c0793decabdf517eb611bbd74a6cfeeb14b88 (HEAD, master)
| Author: James Lucas <public.email>
| Date:   Mon Dec 7 15:16:43 2020 -0600
| 
|     Second commit.
|  
* commit af3db6517ddf3437878b7b4ab9dcda13dc5bd427
  Author: James Lucas <public.email>
  Date:   Mon Dec 7 15:16:32 2020 -0600
  
      First commit.
  
* commit c36d131655f4e73ca4101674dde213a0f7a0794c (origin/master, origin/HEAD, refs/original/refs/heads/master)
| Author: James Lucas <sensitive.email>
| Date:   Mon Dec 7 15:16:43 2020 -0600
| 
|     Second commit.
|  
* commit 8fa4b4ae6a4e0abcc2d643988467ef11a91d2844
  Author: James Lucas <sensitive.email>
  Date:   Mon Dec 7 15:16:32 2020 -0600
  
      First commit.
```

Okay, something strange happened here.  We got our new commits, and our master branch is pointing at the rewritten commit history. But there's a parallel commit history in the log as well, with our old commits. This represents two things. The first is a remote branch (origin/master), which we'll get to in a minute. The other is that filter-branch marks your old commit history for you as a backup. This is pretty important, because complex filter situations can be very easy to mess up. This backup history gives you an opportunity to compare the old and new commits, and fallback if something has gone wrong. If you're confident everything is okay, you can remove the backup history with

```
git update-ref -d refs/original/refs/heads/master
```

Now, let's talk about our remote branch on origin. I mentioned before that filter-branch is dangerous, and here's why. In a local repository, with no connection to anything else, rewriting commits isn't really a big deal. But as soon as you start thinking about distributed operations, rewriting history gets messy. As the log above shows, you've just rewritten your entire commit history with new commits. If you try to push these to a remote repository (for example, github), the new commits have no common history with your old commits. They represent a completely parallel history. Normally git will reject a push in a situation like this. This is where `git push --force` (another dangerous command) comes into the picture. You can tell git to ignore the normal safety rules, and overwrite any previous commits in the remote branch. But then any other child repos of your remote will also be out of sync, and need to be re-cloned, or at least carefully cleaned up. Any branches other developers are working on will need to be rebased. And if everyone's not very careful, there's a pretty good chance of developers working on another repository accidentally reintroducing the element you were trying to get rid of in the first place.

In a distributed project, you should absolutely try to avoid rewrites like this if you can help it. Doubly so if the project is public. **Be very careful what you commit, and be even more careful what you push.** But sometimes we all mess up, and git filter-branch is there for the worst of those cases.
