#!/bin/sh
set -eu

# Default post-auth redirect URI unless caller provides one.
: "${POST_AUTH_REDIRECT_URI:=/auth/success}"
: "${POST_AUTH_PROXY_UPSTREAM:=}"

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
  cat > /tmp/post-auth-location.conf <<EOF
    location = ${post_auth_target_path} {
        add_header X-Auth-Proxy-Mode upstream always;
        resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
        resolver_timeout 5s;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Force upstream virtual-host/SNI (important for CDNs like Cloudflare).
        proxy_set_header Host ${post_auth_proxy_host};
        proxy_ssl_server_name on;
        proxy_ssl_name ${post_auth_proxy_host};

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Original-URI \$request_uri;

        # CAC / client-cert identity headers for the upstream.
        proxy_set_header X-Subject-DN \$ssl_client_s_dn;
        proxy_set_header X-Client-Verified \$ssl_client_verify;
        proxy_set_header X-Client-Serial \$ssl_client_serial;

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

sed "/__POST_AUTH_TARGET_LOCATION__/r /tmp/post-auth-location.conf" /etc/nginx/http.d/default.conf.template \
  | sed "/__POST_AUTH_TARGET_LOCATION__/d" \
  | envsubst '${POST_AUTH_REDIRECT_URI}' \
  > /etc/nginx/http.d/default.conf

exec /usr/sbin/nginx -g 'daemon off;'