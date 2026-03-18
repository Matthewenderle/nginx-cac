#!/bin/sh
set -eu

# Default post-auth redirect URI unless caller provides one.
: "${POST_AUTH_REDIRECT_URI:=/auth/success}"
: "${POST_AUTH_PROXY_UPSTREAM:=}"
export POST_AUTH_REDIRECT_URI

if [ -n "$POST_AUTH_PROXY_UPSTREAM" ]; then
  cat > /tmp/post-auth-location.conf <<EOF
    location = /auth/success {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Original-URI \$request_uri;
        proxy_set_header X-Subject-DN \$ssl_client_s_dn;
        proxy_set_header X-Client-Verified \$ssl_client_verify;
        proxy_set_header X-Client-Serial \$ssl_client_serial;
        proxy_pass ${POST_AUTH_PROXY_UPSTREAM};
    }
EOF
else
  cat > /tmp/post-auth-location.conf <<'EOF'
    location = /auth/success {
        try_files /index.html =404;
        ssi on;
    }
EOF
fi

sed "/__POST_AUTH_TARGET_LOCATION__/r /tmp/post-auth-location.conf" /etc/nginx/http.d/default.conf.template \
  | sed "/__POST_AUTH_TARGET_LOCATION__/d" \
  | envsubst '${POST_AUTH_REDIRECT_URI}' \
  > /etc/nginx/http.d/default.conf

exec /usr/sbin/nginx -g 'daemon off;'