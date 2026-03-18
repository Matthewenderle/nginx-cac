# Introduction

This is the barest possible NGINX configuration and
[Docker](https://www.docker.com/) infrastructure I could create that would
enable developing a Web site that is protected using [client
TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security#Client-authenticated_TLS_handshake)
using the [DoD public key infrastructure
(PKI)](https://public.cyber.mil/pki-pke/admins/).

In other words, you can build CAC-protected web sites using NGINX as the SSL
termination point, starting from this baseline.

# Building

You should be on Linux, with the normal command line toolchain (shell,
coreutils, etc.), along with curl, openssl and zip.

Of course, you'll need Docker installed as well to actually build the Docker
image and launch new containers.

To build, just run `make`.

This will:

* Download the base Docker image (alpine),
* Generate a new self-signed SSL cert,
* Download the [DoD root
  certs](https://public.cyber.mil/pki-pke/pkipke-document-library/?_dl_facet_pkipke_type=popular-dod-certs)
  and wrap them into a single file (to serve as the trusted set of certificates
  that can sign certificates presented by the CAC-holding client during TLS
  session negotiation),
* Install the new client CA and the new self-signed cert into the Docker image,
* Install nginx and a simple config into the Docker image, along with a sample
  index.html.

By default the new Docker image is called "nginx-cac".

# Publishing To GHCR

This repository now supports publishing a container image to GitHub Container
Registry (GHCR) via GitHub Actions.

The workflow file is [`.github/workflows/publish-ghcr.yml`](.github/workflows/publish-ghcr.yml).

It runs when you push to `main`, push a version tag like `v1.2.3`, or run it
manually from the Actions tab.

The pushed image name is:

`ghcr.io/matthewenderle/nginx-cac`

Where `matthewenderle` is your GitHub user or org name.

If you push a tag like `v1.2.3`, the workflow also publishes
`ghcr.io/matthewenderle/nginx-cac:v1.2.3`.

## Apple Silicon (arm64) note

If `docker pull ghcr.io/matthewenderle/nginx-cac:latest` fails with:

`no matching manifest for linux/arm64/v8`

then the image tag you are pulling was published as `linux/amd64` only.

Immediate workaround (run the amd64 image under emulation):

`docker pull --platform=linux/amd64 ghcr.io/matthewenderle/nginx-cac:latest`

and when running:

`docker run --platform=linux/amd64 ghcr.io/matthewenderle/nginx-cac:latest`

If you are using Docker Compose, you can also set `DOCKER_DEFAULT_PLATFORM=linux/amd64` in your environment for that invocation.

# Running With Docker Compose

If you do not want local `make` dependencies, use the published GHCR image.

The included [`docker-compose.yml`](docker-compose.yml) uses:

`ghcr.io/matthewenderle/nginx-cac:latest`

Update `matthewenderle` in that file and then run:

`docker compose up -d`

By default this will use the image tag already present locally. To ensure you
are running the latest published GHCR image:

`docker compose pull && docker compose up -d`

If you are actively editing this repo and want Compose to rebuild using your
local files:

1) Generate the required cert files (see `make` in this repo), then

2) Run Compose with the build override:

`docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`

You can set defaults in a local `.env` file (used automatically by Docker
Compose), for example:

`NGINX_CAC_PORT=8443`
`POST_AUTH_REDIRECT_URI=/auth/success`
`POST_AUTH_PROXY_UPSTREAM=`

To override the externally exposed port, set `NGINX_CAC_PORT`:

`NGINX_CAC_PORT=9443 docker compose up -d`

To override the post-auth redirect URI, set `POST_AUTH_REDIRECT_URI`:

`POST_AUTH_REDIRECT_URI=/welcome docker compose up -d`

To proxy to another host after successful CAC/PIN auth and forward identity
headers, set `POST_AUTH_PROXY_UPSTREAM`:

`POST_AUTH_PROXY_UPSTREAM=https://upstream.example.mil docker compose up -d`

To control whether the CAC is re-checked on every request, set `RECHECK_CAC`
(default: `true`):

`RECHECK_CAC=false docker compose up -d`

When `RECHECK_CAC=true` (the default), nginx:
* Sets `keepalive_timeout 0` and `keepalive_requests 1` — **this is the critical
  setting.** As long as a TCP/TLS connection stays open, nginx does not repeat
  the TLS handshake between requests, so a removed CAC is invisible until the
  connection is torn down. Closing the connection after every response forces
  the browser to open a fresh connection (full TLS handshake, client cert
  re-verified) on the very next navigation.
* Disables TLS session tickets and the server-side session ID cache — prevents
  the browser from resuming a previously authenticated TLS session on a new
  connection (which would bypass the client-cert check even after you close the
  old connection).
* Adds `Cache-Control: no-store` — prevents the browser from serving a stale
  page from its HTTP cache without making a real request, which would avoid
  the connection+handshake entirely.

Combined, these two settings mean that every page load requires a fresh TLS
handshake. If the CAC is no longer present when that handshake is attempted,
the browser will be rejected.

### Asset-heavy apps (Nuxt, etc.) note

If you are proxying a modern SPA (Nuxt/Next/etc.) and see broken JS/CSS assets
through this nginx proxy path (for example Firefox `NS_ERROR_CORRUPTED_CONTENT`),
it can be caused by the strict `RECHECK_CAC=true` defaults closing the client
connection after every response.

Keep `RECHECK_CAC=true` but allow some connection reuse:

* `RECHECK_CAC_KEEPALIVE_TIMEOUT=65s`
* `RECHECK_CAC_KEEPALIVE_REQUESTS=1000`

Set `RECHECK_CAC=false` to disable these extra checks and restore default nginx
TLS session-caching behavior (useful in high-throughput scenarios where you
prefer to allow TLS session resumption).

## SSL inspection proxies (Menlo, etc.)

Client-certificate authentication (CAC / mTLS) happens during the TLS handshake.
If your network forces an SSL inspection proxy (for example Menlo) that
terminates TLS and re-issues a new TLS connection to your origin, the client
certificate will not reach this nginx instance.

If you cannot bypass SSL inspection for your domain, you can run nginx in a
compatibility mode that allows connections without a client certificate and
forwards explicit headers so the upstream app can detect the difference.

Environment variables:

* `REQUIRE_CLIENT_CERT` (default: `true`) — when set to `false`, nginx uses
  `ssl_verify_client optional`.
* `ENABLE_HTTP2` (default: `true`) — set to `false` to disable HTTP/2 on the
  client-facing connection (some TLS inspection proxies are unreliable with HTTP/2).
* `UPSTREAM_ACCEPT_ENCODING` (default: empty) — when set to `identity`, forces
  the upstream app to return uncompressed responses (mitigates proxies that
  corrupt `Content-Encoding` on JS/CSS assets).
* Upstream headers:
  * `X-Client-Verified` — `SUCCESS` when a client cert was verified, `NONE` when no cert was provided.
  * `X-Client-Cert-Present` — `1` when a client cert was presented, otherwise `0`.

Security note: with `REQUIRE_CLIENT_CERT=false` nginx will allow non-mTLS
connections. Your upstream must enforce authorization based on these headers if
you still need to distinguish CAC-authenticated users.

## Let's Encrypt (optional)

This repo can optionally obtain and renew real TLS certificates via Let's Encrypt
using a companion `certbot` container and the HTTP-01 challenge.

Requirements:

* A publicly reachable domain name pointing at this host.
* Port 80 on this host must be reachable from the internet (for HTTP-01).

Environment variables:

* `LE_DOMAIN` — the hostname to request a cert for (example: `example.com`).
* `LE_EMAIL` — email used for Let's Encrypt registration/expiry notices.
* Optional: `SERVER_NAME` (defaults to `LE_DOMAIN` when set).
* Optional: `SSL_CERTIFICATE` / `SSL_CERTIFICATE_KEY` (defaults to
  `/etc/letsencrypt/live/$LE_DOMAIN/fullchain.pem` and `privkey.pem` when
  `LE_DOMAIN` is set).

How to run:

1) Set `LE_DOMAIN` and `LE_EMAIL` in your `.env` (see `.env.example`).

2) Start with the profile enabled:

`docker compose --profile letsencrypt up -d`

3) After the first successful issuance, restart nginx so it loads the new cert:

`docker compose restart nginx-cac`

Notes:

* Renewals are attempted periodically by the `certbot` service. nginx must be
  reloaded/restarted to pick up renewed certificates.
* The default compose mapping exposes port 80 on the host via `NGINX_CAC_HTTP_PORT`.
  For real issuance this must be `80` (override the default `8080`) and not blocked by a firewall.
* On SELinux-enforcing hosts (Fedora/CentOS/RHEL/Rocky), bind mounts may need
  relabeling. If certbot can’t read/write the mounted directories, add `:Z` to
  the volume entries (example: `./letsencrypt:/etc/letsencrypt:Z`).

## `/auth/status` endpoint

nginx always exposes a lightweight `/auth/status` endpoint that it handles
**locally** (never proxied upstream, even in proxy mode).  Because
it is handled by nginx, it is useful for probing whether the current request
was backed by a verified client certificate.

Successful response when a client cert is verified (`200 OK`):
```json
{"verified":true,"clientCertPresent":1,"verify":"SUCCESS","dn":"CN=DOE.JOHN.1234567890,...","serial":"0A1B2C..."}
```

If no client certificate is provided (for example behind an SSL inspection proxy),
the response still returns `200` but reports `verified:false`.

### Nuxt 4 global route middleware

Client-side routers (Vue Router, NuxtLink) never make a new HTTP request for
page transitions, so nginx cannot re-check the CAC on navigation.  Add the
following global route middleware to your Nuxt 4 project to intercept every
client-side navigation, probe `/auth/status`, and fall back to a hard redirect
(which does trigger a full TLS handshake, and therefore a CAC re-check) if the
probe fails.

**`middleware/cac-auth.global.ts`**
```ts
export default defineNuxtRouteMiddleware(async (to) => {
  // Runs on the server during SSR — skip, nginx already enforced the TLS check.
  if (import.meta.server) return

  try {
    await $fetch('/auth/status')
  } catch {
    // TLS handshake failed (CAC removed) or network error.
    // Abort the router navigation and force a real page load so nginx can
    // reject the connection at the TLS layer and show the cert-required error.
    if (import.meta.client) {
      window.location.assign(to.fullPath)
    }
    return abortNavigation()
  }
})
```

> **How it works:** `$fetch('/auth/status')` opens a new TCP connection
> (because `keepalive_timeout 0` closes the previous one).  nginx requires a
> client certificate for that connection.  If the CAC is present the fetch
> succeeds silently and Vue Router completes the navigation normally.  If the
> CAC is absent the TLS handshake is rejected, `$fetch` throws, and
> `window.location.assign` triggers a hard browser navigation — which also
> fails at the TLS layer, showing the browser's "client certificate required"
> error.

## Local test upstream (included)

The included [docker-compose.yml](docker-compose.yml) now also starts a small `echo`
service you can use as a test upstream.

Run:

`POST_AUTH_PROXY_UPSTREAM=http://echo:80/ docker compose up -d`

Then browse to:

`https://localhost:$NGINX_CAC_PORT/`

After successful CAC auth, NGINX will proxy to the `echo` service and you should
see a response body that includes the request headers NGINX forwarded (including
`X-Subject-DN`, `X-Client-Verified`, and `X-Client-Serial`).

If proxy mode is enabled and `POST_AUTH_REDIRECT_URI` is an absolute URL,
startup will force redirect to `/auth/success` so this NGINX instance can
forward headers upstream.

When `POST_AUTH_PROXY_UPSTREAM` is set, the `/auth/success` endpoint will proxy
to that upstream and send these headers.

If you override `POST_AUTH_REDIRECT_URI` to a different path (for example,
`/index.html`), that path becomes the proxied endpoint instead.

* `X-Subject-DN`
* `X-Client-Verified`
* `X-Client-Serial`
* `X-Forwarded-Proto`
* `X-Forwarded-For`
* `X-Original-URI`

The proxy path enables TLS SNI automatically for HTTPS upstreams.

For debugging, responses include `X-Auth-Proxy-Mode: upstream` when upstream
proxy mode is active (or `local` when serving local content).

Note: forwarded identity headers are sent on the *server-to-server* request from
this NGINX instance to your upstream. You will not see them in the browser's
request headers panel; check upstream logs to confirm receipt.

Also note: a browser redirect (`302 Location: https://other-host/`) cannot
"carry" these headers into the next request, because the next request is a new
client-to-server request made by the browser. Use `POST_AUTH_PROXY_UPSTREAM` if
the upstream needs the identity headers.

To stop:

`docker compose down`

# Launching

From there you can run it by using `make run`.

This will start a new container based on the image built, exposing container
port 443 on host port 8443 by default.

To use a different host port:

`NGINX_CAC_PORT=9443 make run`

Use `docker ps` to ensure the new container is actually running.

# Testing

In my case I had Firefox already configured to be able to authenticate against
CAC-enabled websites, using PCSC Lite, the CACKey middleware, and by installing
the DoD root certs **and intermediate CA certs** into the NSS keystore.

With "real" CAC sites already working, testing for me was a matter of going to
`https://localhost:$NGINX_CAC_PORT/` (or `https://localhost:8443/` if you did
not override the default).

After successful CAC/PIN client authentication, NGINX now redirects `/` to
`/auth/success`.

If you want a different redirect URI, set `POST_AUTH_REDIRECT_URI` in `.env`
or in the shell before launching the container.

If `POST_AUTH_REDIRECT_URI` points to another host (absolute URL), the browser
will be redirected there but request headers from this server are not forwarded
by the redirect itself. Use `POST_AUTH_PROXY_UPSTREAM` if you need header
forwarding.

I believe at this point it should already ask for the CAC PIN (as part of SSL
mutual auth) and then show an error page that the site is untrusted.

After confirming a security exception for the NGINX server's self-signed
certificate (I made it a temporary exception but permanent should work as
well), Firefox reloaded the page and this time you should see "It works!".

If you look into the Developer Tools you should also see that NGINX has sent
back your Subject Name information as a server response header.

## Windows Testing

I've also tested exporting the created Docker image (using
`docker save nginx-cac:latest | gzip > nginx-cac.tar.gz`
on the Linux host and using `docker load` on a Win10 machine to import the
image).

The container ran fine on Windows and I was also able to test with Firefox,
Chrome, and Microsoft Edge (with success on all 3).

As with Linux, you need to make sure you've setup your smartcard infrastructure
(in my case I used OpenSC with Firefox) and that you've installed the DoD root
and intermediate certificates into each browser.

# Shutdown

Don't forget to shutdown the Docker container when you're done (Use `docker ps`
to find the short name of the running container and then `docker stop
$short-name` from there).

# Why?????

Because doing this all within DoD is so much harder than doing it in my off
time. :(
