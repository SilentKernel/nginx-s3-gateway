# GitLab CI setup for nginx-s3-gateway-docker

The nightly build runs on the shared amd64 VM runner `base-images-amd64` (shell executor), set up
once for every base image: see `../frankenphp-docker/docs/runner.md` (VM, packages, classic image
store, housekeeping cron). This project only needs the steps below.

## 1. Project

- GitLab project `silent/nginx-s3-gateway-docker` (private), **CI/CD enabled** (Settings > General >
  Visibility, project features, permissions > CI/CD; our GitLab disables it on new projects).
- Remote: `git remote add gitlab git@git.developpeur-freelance.io:silent/nginx-s3-gateway-docker.git`
  (`origin` stays the GitHub fork of nginx/nginx-s3-gateway).
- **Settings > Repository > Protected branches**: `main` protected (only maintainers push), since a
  push to `main` publishes the image.

## 2. Runner

On runner `base-images-amd64` (Admin or any of its projects > Settings > CI/CD > Runners): add the tag
**`nginx-s3-amd64`** (keep the others), then **Enable for this project** in this project's
Settings > CI/CD > Runners > Project runners. `concurrent = 1` on the VM queues it with the other
nightlies; the `build` job also takes the `nginx-s3-gateway` resource group.

Outbound HTTPS needed on top of the other projects: `nginx.org` (njs/xslt packages),
`hub.docker.com` (tag lookup), Docker Hub registry (pulls only: `nginx`, `pgsty/minio`,
`aquasec/trivy`).

## 3. CI/CD variables (Settings > CI/CD > Variables)

| Variable | Flags | Value |
|---|---|---|
| `NTFY_TOPIC` | protected | `gitlab-ci-alert-x564789` (unset = no notifications) |
| `NTFY_TOKEN` | protected, masked | ntfy access token, if the server requires one |

No Docker Hub variables: the image is published to our registry only.

## 4. Schedule

**Build > Pipeline schedules > New schedule**: `45 5 * * *`, timezone Europe/Paris, branch `main`
(after frankenphp-docker 05:00 and ruby-docker 05:30). Its owner gets GitLab's failure e-mails too.

## 5. Registry cleanup

**Settings > Packages and registries > Cleanup policies**: disabled; the whole GitLab is cleaned by
`~/Dropbox/Scripts/clean-registry.sh`. Its `KEEP_REGEX` must protect the moving tag
(`1\.30-unprivileged`, plus `latest` already there), and `PRUNE_VERSION_REGEX` should list
`silent/nginx-s3-gateway-docker` so a `1.30.x-unprivileged` tag is kept only while one of its dated
tags is.

## 6. First run

Push `main` to `gitlab`, then Build > Pipelines > **Run pipeline** on `main`. Nothing is published
yet, so the first build has no regression baseline (Trivy reports only); the next nights compare
with the published image.
