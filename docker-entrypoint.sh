#!/bin/sh
set -eu

# Default post-auth redirect URI unless caller provides one.
: "${POST_AUTH_REDIRECT_URI:=/auth/success}"
: "${POST_AUTH_PROXY_UPSTREAM:=}"

# Optional Let's Encrypt integration. If LE_DOMAIN is set and the caller did not
# override certificate paths, default to the standard Certbot live paths.
: "${LE_DOMAIN:=}"
: "${LE_EMAIL:=}"

if [ -z "${SERVER_NAME:-}" ]; then
  if [ -n "$LE_DOMAIN" ]; then
    SERVER_NAME="$LE_DOMAIN"
  else
    SERVER_NAME=localhost
  fi
fi

: "${SSL_CERTIFICATE:=}"
: "${SSL_CERTIFICATE_KEY:=}"
if [ -z "$SSL_CERTIFICATE" ] && [ -n "$LE_DOMAIN" ]; then
  SSL_CERTIFICATE="/etc/letsencrypt/live/${LE_DOMAIN}/fullchain.pem"
fi
if [ -z "$SSL_CERTIFICATE_KEY" ] && [ -n "$LE_DOMAIN" ]; then
  SSL_CERTIFICATE_KEY="/etc/letsencrypt/live/${LE_DOMAIN}/privkey.pem"
fi

# If we defaulted to Let's Encrypt paths but the cert hasn't been issued yet,
# fall back to the self-signed cert shipped in the image so nginx can boot and
# serve the HTTP-01 challenge.
if [ -n "$LE_DOMAIN" ]; then
  if [ ! -f "$SSL_CERTIFICATE" ] || [ ! -f "$SSL_CERTIFICATE_KEY" ]; then
    echo "LE_DOMAIN is set (${LE_DOMAIN}) but certificate files are missing; using bundled self-signed cert until certbot issues a real cert" >&2
    SSL_CERTIFICATE=/etc/nginx/certificate.pem
    SSL_CERTIFICATE_KEY=/etc/nginx/key.pem
  fi
fi

# Default back to the self-signed cert shipped in the image.
: "${SSL_CERTIFICATE:=/etc/nginx/certificate.pem}"
: "${SSL_CERTIFICATE_KEY:=/etc/nginx/key.pem}"

export SERVER_NAME SSL_CERTIFICATE SSL_CERTIFICATE_KEY

# CAC / client certificate handling.
# Default behavior remains strict: require a valid client cert.
# Set REQUIRE_CLIENT_CERT=false to allow non-mTLS connections (nginx will request
# a client cert but not require one).
: "${REQUIRE_CLIENT_CERT:=true}"
: "${SSL_VERIFY_CLIENT:=}"
if [ -z "$SSL_VERIFY_CLIENT" ]; then
  if [ "$REQUIRE_CLIENT_CERT" = "true" ]; then
    SSL_VERIFY_CLIENT=on
  else
    SSL_VERIFY_CLIENT=optional
  fi
fi

export SSL_VERIFY_CLIENT

# HTTP/2 can be problematic behind some TLS-intercepting proxies.
: "${ENABLE_HTTP2:=true}"
: "${HTTP2_DIRECTIVE:=}"
if [ -z "$HTTP2_DIRECTIVE" ]; then
  if [ "$ENABLE_HTTP2" = "true" ]; then
    HTTP2_DIRECTIVE='http2 on;'
  else
    HTTP2_DIRECTIVE=''
  fi
fi

# Some SSL inspection proxies corrupt compressed JS/CSS responses (mismatched
# Content-Encoding). In compatibility mode, default to requesting uncompressed
# upstream responses.
: "${UPSTREAM_ACCEPT_ENCODING:=}"
if [ -z "$UPSTREAM_ACCEPT_ENCODING" ] && [ "$REQUIRE_CLIENT_CERT" != "true" ]; then
  UPSTREAM_ACCEPT_ENCODING=identity
fi

export HTTP2_DIRECTIVE UPSTREAM_ACCEPT_ENCODING

upstream_accept_encoding_directive=""
if [ -n "$UPSTREAM_ACCEPT_ENCODING" ]; then
  upstream_accept_encoding_directive="        proxy_set_header Accept-Encoding \"$UPSTREAM_ACCEPT_ENCODING\";"
fi

post_auth_target_path="$POST_AUTH_REDIRECT_URI"

# Determine whether the caller provided a path redirect ("/foo") vs an absolute URL.
is_path_redirect=0
case "$POST_AUTH_REDIRECT_URI" in
  /*)
    is_path_redirect=1
    ;;
esac

# If a path redirect is used, normalize it to avoid redirect loops.
if [ "$is_path_redirect" -eq 1 ]; then
  if [ "$post_auth_target_path" = "/" ]; then
    post_auth_target_path="/auth/success"
  fi
fi

post_auth_proxy_hostport=""
post_auth_proxy_host=""
if [ -n "$POST_AUTH_PROXY_UPSTREAM" ]; then
  # Extract host[:port] from e.g. https://enderle.io or https://enderle.io:8443/path
  post_auth_proxy_hostport=$(printf '%s' "$POST_AUTH_PROXY_UPSTREAM" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#')
  post_auth_proxy_host=$(printf '%s' "$post_auth_proxy_hostport" | sed -E 's#:.*$##')
fi

# If proxy mode is enabled, we must keep redirect local so this nginx instance
# can forward CAC-derived headers upstream.
if [ -n "$POST_AUTH_PROXY_UPSTREAM" ]; then
  case "$POST_AUTH_REDIRECT_URI" in
    http://*|https://*)
      echo "POST_AUTH_PROXY_UPSTREAM is set, forcing POST_AUTH_REDIRECT_URI=/auth/success so headers can be forwarded" >&2
      POST_AUTH_REDIRECT_URI=/auth/success
      post_auth_target_path="/auth/success"
      ;;
  esac

  # Proxy mode requires that we keep the redirect local (path-based), otherwise
  # the browser would bypass this proxy and no headers would be forwarded.
  POST_AUTH_REDIRECT_URI="$post_auth_target_path"
elif [ "$is_path_redirect" -eq 1 ]; then
  # Local mode: still avoid loops like "/" -> "/".
  POST_AUTH_REDIRECT_URI="$post_auth_target_path"
fi

export POST_AUTH_REDIRECT_URI

if [ -n "$POST_AUTH_PROXY_UPSTREAM" ]; then
  echo "Starting in proxy mode: POST_AUTH_PROXY_UPSTREAM=${POST_AUTH_PROXY_UPSTREAM} (host=${post_auth_proxy_host})" >&2

  # In proxy mode, do not force "/" -> post-auth redirect; let the upstream app
  # decide what to do for "/" and other routes like "/dashboard".
  : > /tmp/root-location.conf

  cat > /tmp/main-location.conf <<EOF
    location / {
        add_header X-Auth-Proxy-Mode upstream always;
        resolver 127.0.0.11 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
        resolver_timeout 5s;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Force upstream virtual-host/SNI (important for CDNs like Cloudflare).
        proxy_set_header Host \$host;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Original-URI \$request_uri;

    $upstream_accept_encoding_directive

        # CAC / client-cert identity headers for the upstream.
        proxy_set_header X-Subject-DN \$ssl_client_s_dn;
        proxy_set_header X-Client-Verified \$ssl_client_verify;
        proxy_set_header X-Client-Serial \$ssl_client_serial;
        proxy_set_header X-Client-Cert-Present \$client_cert_present;

        # Backward-compatible aliases (older versions of this image used these names).
        proxy_set_header X-SSL-User-DN \$ssl_client_s_dn;
        proxy_set_header X-SSL-Authenticated \$ssl_client_verify;
        proxy_set_header X-SSL-Client-Serial \$ssl_client_serial;

        set \$post_auth_proxy_upstream "${POST_AUTH_PROXY_UPSTREAM}";
        proxy_pass \$post_auth_proxy_upstream;
    }
EOF

  cat > /tmp/post-auth-location.conf <<EOF
    location = ${post_auth_target_path} {
        add_header X-Auth-Proxy-Mode upstream always;
        resolver 127.0.0.11 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
        resolver_timeout 5s;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Force upstream virtual-host/SNI (important for CDNs like Cloudflare).
        proxy_set_header Host \$host;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Original-URI \$request_uri;

    $upstream_accept_encoding_directive

        # CAC / client-cert identity headers for the upstream.
        proxy_set_header X-Subject-DN \$ssl_client_s_dn;
        proxy_set_header X-Client-Verified \$ssl_client_verify;
        proxy_set_header X-Client-Serial \$ssl_client_serial;
        proxy_set_header X-Client-Cert-Present \$client_cert_present;

        # Backward-compatible aliases (older versions of this image used these names).
        proxy_set_header X-SSL-User-DN \$ssl_client_s_dn;
        proxy_set_header X-SSL-Authenticated \$ssl_client_verify;
        proxy_set_header X-SSL-Client-Serial \$ssl_client_serial;

        set \$post_auth_proxy_upstream "${POST_AUTH_PROXY_UPSTREAM}";
        proxy_pass \$post_auth_proxy_upstream;
    }
EOF
else
  echo "Starting in local mode (no upstream proxy)" >&2

  cat > /tmp/root-location.conf <<'EOF'
    # After successful client-cert auth, redirect root to a dedicated URI.
    location = / {
        return 302 $post_auth_redirect_uri;
    }
EOF

  cat > /tmp/main-location.conf <<'EOF'
    location / {
        autoindex on;
        ssi on;
    }
EOF

  cat > /tmp/post-auth-location.conf <<'EOF'
    location = __POST_AUTH_TARGET_PATH__ {
        add_header X-Auth-Proxy-Mode local always;
        try_files /index.html =404;
        ssi on;
    }
EOF
  # Substitute the target path placeholder (kept out of the single-quoted heredoc).
  sed -i "s|__POST_AUTH_TARGET_PATH__|${post_auth_target_path}|g" /tmp/post-auth-location.conf
fi

# RECHECK_CAC (default: true) — disable TLS session resumption and browser caching so the
# client certificate is re-checked on every new request rather than being carried over from
# a cached TLS session.
: "${RECHECK_CAC:=true}"
: "${RECHECK_CAC_KEEPALIVE_TIMEOUT:=0}"
: "${RECHECK_CAC_KEEPALIVE_REQUESTS:=1}"
if [ "$RECHECK_CAC" = "true" ]; then
  cat > /tmp/recheck-cac.conf <<'EOF'
    # Disable TLS session tickets (RFC 5077) and server-side session ID cache so the
    # browser cannot resume a previous TLS session that had a valid client cert.
    ssl_session_tickets off;
    ssl_session_cache   off;

    # Keepalive behavior (defaults are strict: close after every response).
    # If you see broken/partial JS/CSS assets through a proxy path, increase
    # RECHECK_CAC_KEEPALIVE_TIMEOUT (example: 65s) and RECHECK_CAC_KEEPALIVE_REQUESTS
    # (example: 1000) to allow connection reuse.
    keepalive_timeout  ${RECHECK_CAC_KEEPALIVE_TIMEOUT};
    keepalive_requests ${RECHECK_CAC_KEEPALIVE_REQUESTS};

    # Prevent the browser HTTP cache from serving stale pages without hitting
    # the network (and therefore without triggering a new TLS handshake).
    add_header Cache-Control "no-store" always;
EOF
else
  : > /tmp/recheck-cac.conf
fi

# /auth/status — a minimal endpoint nginx handles directly (never proxied upstream).
# Calling it from client-side code forces a new TCP+TLS handshake (keepalive_timeout 0)
# which re-checks the CAC.  If the card is absent the TLS handshake fails and the fetch
# throws a network error, which the caller can treat as "session expired".
cat > /tmp/auth-status-location.conf <<'EOF'
    location = /auth/status {
        add_header Content-Type  "application/json" always;
        add_header Cache-Control "no-store"          always;
    return 200 "{\"verified\":$auth_verified,\"clientCertPresent\":$client_cert_present,\"verify\":\"$ssl_client_verify\",\"dn\":\"$ssl_client_s_dn\",\"serial\":\"$ssl_client_serial\"}";
    }
EOF

sed "/__POST_AUTH_TARGET_LOCATION__/r /tmp/post-auth-location.conf" /etc/nginx/http.d/default.conf.template \
  | sed "/__POST_AUTH_TARGET_LOCATION__/d" \
  | sed "/__ROOT_LOCATION__/r /tmp/root-location.conf" \
  | sed "/__ROOT_LOCATION__/d" \
  | sed "/__AUTH_STATUS_LOCATION__/r /tmp/auth-status-location.conf" \
  | sed "/__AUTH_STATUS_LOCATION__/d" \
  | sed "/__MAIN_LOCATION__/r /tmp/main-location.conf" \
  | sed "/__MAIN_LOCATION__/d" \
  | sed "/__RECHECK_CAC_SETTINGS__/r /tmp/recheck-cac.conf" \
  | sed "/__RECHECK_CAC_SETTINGS__/d" \
  | envsubst '${POST_AUTH_REDIRECT_URI} ${SERVER_NAME} ${SSL_CERTIFICATE} ${SSL_CERTIFICATE_KEY} ${SSL_VERIFY_CLIENT} ${HTTP2_DIRECTIVE}' \
  > /etc/nginx/http.d/default.conf

exec /usr/sbin/nginx -g 'daemon off;'
