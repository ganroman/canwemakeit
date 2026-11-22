# Can we make it

A small, responsive front page for **canwemakeit.tech**, with space for software prototypes at `/p2d/`, `/findra/`, and future paths. Plain HTML and CSS; no Node install, JavaScript, analytics, or external font service required. The two prototype cards are explicitly marked **Planned**. They do not claim the apps are deployed.

## How requests reach your home server

```text
Visitor → HTTPS → Cloudflare → encrypted tunnel to your home server
                                      ↓
                              cloudflared container
                                      ↓
                                Caddy gateway
                                 ├─ /          → homepage container (Nginx)
                                 ├─ /p2d/*     → P2D container (when connected)
                                 └─ /findra/*  → Findra container (when connected)
```

The homepage has its own container. Caddy is a small web gateway that chooses the container based on the URL path. Cloudflare Tunnel connects out from your server, so you do **not** need a public home IP address, router port forwarding, or dynamic DNS. This also works behind carrier-grade NAT. Cloudflare provides the visitor-facing HTTPS certificate; plain HTTP is used only between containers on the server.

DNS maps the hostname, not paths. Create one tunnel route for `canwemakeit.tech`; Caddy handles `/p2d/` and `/findra/`. The server must stay powered on and connected to the internet.

## 1. Prepare the home server

These instructions assume a Linux home server with Docker Engine and the Docker Compose plugin installed. x86-64 and ARM64 are supported by the selected image families. For a NAS, use its Compose/Container Manager support and equivalent file paths. Install Docker using the [official instructions for your operating system](https://docs.docker.com/engine/install/), then check:

```sh
docker version
docker compose version
```

Both must work; `docker version` must show a reachable **Server**, not just a client. Use `sudo docker ...` where your installation requires it.

Copy this directory onto the server. For example, run this **from your Mac in this project directory**, replacing `YOUR_USER` and `YOUR_SERVER`:

```sh
ssh YOUR_USER@YOUR_SERVER 'mkdir -p ~/canwemakeit'
rsync -av --exclude='.git' --exclude='secrets/' --exclude='.env*' ./ YOUR_USER@YOUR_SERVER:~/canwemakeit/
ssh YOUR_USER@YOUR_SERVER
cd ~/canwemakeit
```

A Git repository has been initialized locally on `main`. No remote repository is required for this copy-based deployment. You can also commit the files, push to your own Git remote, and clone that repository on the server later.

## 2. Start and check the homepage

On the **home server**, in `~/canwemakeit`:

```sh
docker compose config --quiet
docker compose up -d --build
docker compose ps
curl -fsS http://127.0.0.1:8080/healthz
curl -I http://127.0.0.1:8080/
```

Expect `ok` from the health check and HTTP `200` from the homepage. This starts only the homepage and gateway. The tunnel is optional until step 3, so no tunnel token is needed yet. The gateway listens on **127.0.0.1:8080** only; the homepage container has no published host port. If 8080 is already in use, change the host-side port in `compose.yaml`.

To preview from your Mac without exposing a LAN port, open another terminal on the Mac:

```sh
ssh -N -L 8080:127.0.0.1:8080 YOUR_USER@YOUR_SERVER
```

Then visit **http://localhost:8080**. Keep that SSH connection running while previewing.

For a design-only preview on any computer with Python, use `python3 -m http.server 8765 --directory public` and open http://localhost:8765. This does not test Nginx, Caddy, the custom 404 response, or the tunnel.

## 3. Connect Cloudflare

1. Confirm `canwemakeit.tech` is an active zone in your Cloudflare account.
2. Open [Cloudflare Zero Trust](https://one.dash.cloudflare.com/), find **Networks → Connectors / Tunnels**, and create a **Cloudflared** tunnel called `canwemakeit-homeserver`. Dashboard labels can change; follow [Cloudflare's remotely managed tunnel guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/).
3. Choose the Docker connector instructions. Copy just the tunnel token from the generated command. Do not run the generated command: Compose manages this connector for you.
4. On the home server, save the token using an editor, rather than putting it into shell history or Git:

   ```sh
   install -d -m 700 secrets
   nano secrets/cloudflare_tunnel_token
   chmod 644 secrets/cloudflare_tunnel_token
   ```

   Paste only the token, on one line, and save. The `secrets` directory is accessible only to its owner. The file itself must be readable by the non-root cloudflared process after Docker mounts it into the container. Compose mounts the file as a secret; local Compose secrets are files, not an encrypted vault. The entire directory's contents are ignored by Git and excluded from the image build.

5. Start the tunnel:

   ```sh
   docker compose --profile public config --quiet
   docker compose --profile public up -d --build
   docker compose logs --tail=50 tunnel
   ```

6. In the tunnel dashboard, add a **published application / public hostname** route:

   | Setting | Value |
   | --- | --- |
   | Subdomain | Leave empty |
   | Domain | `canwemakeit.tech` |
   | Path | Leave empty — all paths go to Caddy |
   | Service type | HTTP |
   | Service URL | `gateway:80` |

   `gateway` is the Compose service name. Do not enter `localhost`, which would point at the tunnel container itself. The dashboard normally creates the DNS record automatically. If an existing A, AAAA, or CNAME record at the apex conflicts, review it and replace only the conflicting web record. Keep mail records and unrelated subdomains. For manual DNS setup, the proxied CNAME target is the tunnel's actual `<TUNNEL-UUID>.cfargotunnel.com`; Cloudflare supports flattening this record at the apex.

7. Confirm the tunnel is **Healthy**, enable Cloudflare's **Always Use HTTPS** for the zone, and visit **https://canwemakeit.tech**. If you also want `www.canwemakeit.tech`, add a second tunnel hostname with the same destination; it is not included automatically.

The home server needs outbound access for Cloudflare Tunnel (port 7844 over UDP for QUIC or TCP for HTTP/2), plus ordinary DNS and HTTPS access. No inbound router rule is needed. The tunnel token, hostname route, and DNS changes must be created in your own Cloudflare account; they are not provisioned by these project files.

## 4. Connect a prototype under a path

For example, to make **https://canwemakeit.tech/p2d/** reach a P2D container:

1. Start this project's stack first; it creates the Docker network `canwemakeit_proxy`.
2. In the P2D project's Compose file, attach its web service to that network. Merge this into its existing setup, preserving any networks needed for databases or other dependencies:

   ```yaml
   services:
     p2d:
       # Keep the app's actual build/image, environment, and other settings.
       networks:
         default: {}
         canwemakeit:
           aliases: [p2d]

   networks:
     canwemakeit:
       external: true
       name: canwemakeit_proxy
   ```

   The app must listen on `0.0.0.0` inside its container. It needs no published host port for Caddy to reach it. Use a unique alias per app. The snippets assume port **3000**; replace it with the app's actual listening port.

3. Configure the app's public base path as **`/p2d`**. A page loaded at `/p2d/` must request `/p2d/assets/...` and `/p2d/api/...`, rather than `/assets/...` or `/api/...`. Configure the router, build asset paths, API URLs, redirects, WebSocket URLs, and authentication callback URLs accordingly. Vite uses `base: '/p2d/'`; Next.js uses `basePath: '/p2d'`. Framework-specific behavior matters: check the app's own deployment documentation.
4. Uncomment the P2D block in `deploy/Caddyfile`:

   ```caddyfile
   redir /p2d /p2d/ 308
   handle /p2d/* {
       reverse_proxy p2d:3000
   }
   ```

   This preserves the prefix: `/p2d/example` reaches the upstream as `/p2d/example`. If the backend explicitly expects `/example` while its browser-facing URLs still use `/p2d/`, use `handle_path /p2d/*` instead. Prefix stripping alone cannot fix an app that hardcodes root-relative URLs.

5. Recreate the gateway to load the edited file (also works with editors that replace the mounted file):

   ```sh
   docker compose run --rm --no-deps gateway caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   docker compose up -d --force-recreate gateway
   curl -I https://canwemakeit.tech/p2d
   curl -I https://canwemakeit.tech/p2d/
   ```

   Expect a redirect to `/p2d/`, then the app's normal response. Check its assets, nested pages, API requests, and login flow in a browser too.

6. Update its card in `public/index.html`: change “Planned” and “Not live yet”, replace the placeholder description, and add a real `<a href="/p2d/">Open prototype</a>` link. Rebuild the homepage as below.

Repeat with the alias `findra`, base path `/findra`, and the Findra Caddy block. Until enabled, both paths return a real HTTP 404 with the project's “Nothing here. Yet.” page. They do not silently show the homepage.

Apps under these paths share a browser origin. Use a subdomain instead if an app cannot support a path prefix or needs separate browser storage and security boundaries. Put Cloudflare Access in front of private prototypes; publishing a tunnel route does not add authentication to an app.

## Updates and troubleshooting

After copying updated homepage files onto the server:

```sh
docker compose up -d --build homepage
```

To update base images and restart the public stack:

```sh
docker compose --profile public pull
docker compose build --pull homepage
docker compose --profile public up -d
```

Nginx and Caddy use version-family tags; cloudflared uses its upstream `latest` tag. These tags can change. After your first successful deployment, pin approved image versions or digests if you want fully repeatable releases. Updates are manual; no automatic updater is installed.

Useful checks:

```sh
docker compose --profile public ps
docker compose logs --tail=100 homepage gateway
docker compose --profile public logs --tail=100 tunnel
curl -I https://canwemakeit.tech/
```

| Symptom | Check |
| --- | --- |
| Docker cannot connect / Compose is missing | Start Docker and install its Compose plugin before deploying. |
| Cloudflare tunnel is offline | Token file contents and permissions, tunnel logs, and outbound port 7844. |
| Cloudflare 502 | Route service must be `http://gateway:80`; check gateway and homepage containers. |
| Homepage works, prototype returns 404 | Its Caddy route is still disabled or the app's base path is wrong. |
| Prototype returns 502 | App network alias, internal port, and whether it listens on `0.0.0.0`. |
| Prototype HTML loads but styling/login breaks | Asset paths, API URLs, redirects, cookie paths, and callback configuration. |

To stop all three services: `docker compose --profile public down`. This also removes the shared proxy network when it has no other attached containers. If separate prototype containers still use it, Docker keeps that network until they are disconnected. Avoid `down` for routine homepage updates.

## Files

- `public/`: homepage, local stylesheet, favicon, and 404 page.
- `Dockerfile`: the homepage image, using unprivileged Nginx on port 8080.
- `deploy/nginx.conf`: static file serving, response headers, and health check.
- `deploy/Caddyfile`: routing from public paths to containers.
- `compose.yaml`: homepage, gateway, optional tunnel, and shared proxy network.
- `secrets/`: ignored local tunnel token; never commit its contents.
