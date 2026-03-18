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

`ghcr.io/<owner>/nginx-cac`

Where `<owner>` is your GitHub user or org name.

If you push a tag like `v1.2.3`, the workflow also publishes
`ghcr.io/<owner>/nginx-cac:v1.2.3`.

# Running With Docker Compose

If you do not want local `make` dependencies, use the published GHCR image.

The included [`docker-compose.yml`](docker-compose.yml) uses:

`ghcr.io/<owner>/nginx-cac:latest`

Update `<owner>` in that file and then run:

`docker compose up -d`

By default this will use the image tag already present locally. To ensure you
are running the latest published GHCR image:

`docker compose pull && docker compose up -d`

If you are actively editing this repo and want Compose to rebuild using your
local files:

`docker compose up -d --build`

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
