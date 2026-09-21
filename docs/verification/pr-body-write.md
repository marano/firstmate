# Verification: naming the repository on a GitHub call

Measured 2026-09-21 with `gh` 2.100.0 and `gh-axi` 0.1.35 on macOS 25.3.0.
Refresh with `FM_PR_BODY_WRITE_LIVE_E2E=1 bash tests/fm-pr-body-write-live-e2e.test.sh`, which performs a real repository-scoped body write and fails naming the refusal below.

## Why the guarantee exists

`gh` resolves a call that does not name a repository from the checkout's git remotes.
A checkout that carries a second GitHub remote can therefore resolve to a repository the account cannot write, and the write is refused as a permissions error that is true of the resolved repository and false of the intended one.
Naming the repository is what makes the call reach the intended repository, on reads as well as writes.

## A checkout with two GitHub remotes resolves to the other one

The remotes in this checkout, and the absence of a configured default:

```
$ git remote -v
no-mistakes	/Users/marano/.no-mistakes/repos/2d7095a62a33.git (fetch)
no-mistakes	/Users/marano/.no-mistakes/repos/2d7095a62a33.git (push)
origin	git@github.com:marano/firstmate.git (fetch)
origin	git@github.com:marano/firstmate.git (push)
upstream	git@github.com:kunchenguid/firstmate.git (fetch)
upstream	git@github.com:kunchenguid/firstmate.git (push)

$ gh repo set-default --view
X No default remote repository has been set. To learn more about the default repository, run: gh repo set-default --help
```

An unnamed read then returns a different repository's pull request, silently and with exit status 0:

```
$ gh pr view 30 --json number,title,url
{"number":30,"title":"feat(supervision): token-efficient sub-supervisor (closes #27)","url":"https://github.com/kunchenguid/firstmate/pull/30"}
```

`GH_DEBUG=api` shows the resolution itself, before any permission is consulted:

```
GraphQL variables: {"owner":"kunchenguid","pr_number":30,"repo":"firstmate"}
```

The account's own permissions are not involved.
Against the intended repository the same viewer may update the same pull request:

```
$ gh api graphql -f query='query{repository(owner:"marano",name:"firstmate"){pullRequest(number:30){viewerCanUpdate viewerDidAuthor}}}'
{"data":{"repository":{"pullRequest":{"viewerCanUpdate":true,"viewerDidAuthor":true}}}}
```

## The named route succeeds

Both the wrapper's route and the REST route succeed once the repository is named, from the same environment and the same credential:

```
$ gh pr edit 30 --repo marano/firstmate --body-file <body>   # exit 0
$ gh api -X PATCH repos/marano/firstmate/pulls/30 -F body=@<body> --jq .number
30
```

## Reading a body back as data

`--template` returns the body's exact bytes; `--jq` appends one newline that the body does not have, so a read-edit-write round trip grows the body on every pass.

```
$ gh api repos/marano/firstmate/pulls/30 --template '{{.body}}' | wc -c
   17275
$ gh api repos/marano/firstmate/pulls/30 --jq .body | wc -c
   17276
```

## Wrapper note

`gh-axi` 0.1.35 resolves the repository itself in the order `-R/--repo` flag, then `GH_REPO`, then `git remote get-url origin`, but it forwards `--repo` to `gh` only for the first two.
An unnamed `gh-axi` call therefore leaves `gh` to resolve the repository independently, and the two can disagree: `gh-axi` reports against `origin` while `gh` acts on whatever it resolved.
Naming the repository, or exporting `GH_REPO`, makes both agree.
