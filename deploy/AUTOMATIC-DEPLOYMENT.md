# Automatic deployment after a merged PR

Changes reach `main` through pull requests. GitHub Actions builds and starts the containers on GitHub's own runner and checks the homepage, assets, response header, and 404 page. The same checks run again on the merged `main` commit.

Every two minutes, a timer on the home server checks the latest `main` workflow run. When it succeeds, the server fetches that exact commit, builds the homepage, validates Caddy, and replaces the homepage and gateway containers. The Cloudflare tunnel is left running. A failed or unfinished GitHub run does not deploy. If the server-side checks fail, the updater attempts to restore the previous checkout and homepage image and reports failure in its journal.

This is an outbound pull deployment: GitHub performs the checks; the home server applies the successful revision. It needs no self-hosted Actions runner, GitHub token, SSH secret in GitHub, or inbound firewall rule. GitHub shows the build result; the server journal shows the actual deployment result. Allow two minutes plus build time after the merged commit's checks pass. Recreating the gateway causes a brief interruption; this is not a zero-downtime deployment.

## One-time server installation

Requirements: Linux with systemd, Git, curl, Python 3, `flock`, Docker Engine, and the Compose plugin. The login user must be able to run Docker. Install into `~/canwemakeit`; the supplied service uses this location.

Run as the normal server user, after this change has merged:

```sh
git clone https://github.com/ganroman/canwemakeit.git ~/canwemakeit
cd ~/canwemakeit
docker compose up -d --build --wait --wait-timeout 120 homepage gateway
bash deploy/check-site.sh
mkdir -p ~/.config/systemd/user
cp deploy/canwemakeit-update.service deploy/canwemakeit-update.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now canwemakeit-update.timer
sudo loginctl enable-linger "$USER"
systemctl --user start canwemakeit-update.service
```

If the checkout already exists, reuse it rather than running `git clone` again. Resolve any local changes before updating it. `enable-linger` keeps the user service running after logout and starts it after reboot. The timer only starts one deployment at a time; `flock` also prevents overlapping manual runs.

The initial `compose up` boots the checked-out version manually; subsequent updates require a successful GitHub `push` run on `main`. Follow the main README's Cloudflare instructions to expose the site at `https://canwemakeit.tech`. Automation can run before the domain is connected, but it does not create a Cloudflare tunnel or DNS record.

Do not edit tracked files directly on the server. The updater refuses to overwrite local changes. Keep the tunnel token under ignored `secrets/`. The checkout is left at the deployed commit, in Git's detached-HEAD state, to identify the exact version running.

## Check what is running

```sh
systemctl --user status canwemakeit-update.timer
journalctl --user -u canwemakeit-update.service -n 80 --no-pager
cat ~/canwemakeit/.deploy/deployed-sha
cd ~/canwemakeit
docker compose ps
bash deploy/check-site.sh
```

The SHA file is written only after the server's checks succeed. A green GitHub run alone does not prove the home server has deployed it. No polling request contains a credential; the public API's anonymous rate limit applies (normally 60 requests per hour per IP, with this timer using about 30). If GitHub or the network is unavailable, the running containers stay in place and the timer tries again later.

To retry immediately: `systemctl --user start canwemakeit-update.service`.

To pause deployments: `systemctl --user stop canwemakeit-update.timer`.

For a durable rollback, revert the faulty change through a PR. Its successful merge deploys automatically. The updater retains the previous homepage image as `canwemakeit-homepage:previous`; automatic rollback is best-effort and assumes the change does not rename services or alter the deployment architecture. It does not undo external database changes. This site has no database.

Service and timer unit changes require copying the updated units into `~/.config/systemd/user/` and running `systemctl --user daemon-reload` again. The tracked updater and site-check scripts update with the checkout. Docker image updates happen during a deployment build; there is no separate scheduled base-image updater.
