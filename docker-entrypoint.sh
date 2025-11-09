#!/bin/sh
set -eu

SERVER_NAME="${SERVER_NAME:-www.example.com}"
LOG_LEVEL="${LOG_LEVEL:-info}"
TZ="${TZ:-Asia/Shanghai}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-512M}"
ENABLE_FFMPEG="${ENABLE_FFMPEG:-false}"

HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

ENABLE_HTTPS="${ENABLE_HTTPS:-false}"
FORCE_HTTPS="${FORCE_HTTPS:-false}"
CERT_FILE="${CERT_FILE:-/etc/ssl/certs/server.crt}"
KEY_FILE="${KEY_FILE:-/etc/ssl/private/server.key}"

echo 'Updating configurations'

# Check and install ffmpeg if ENABLE_FFMPEG is set to true
if [ "$ENABLE_FFMPEG" = "true" ]; then
    echo "Using USTC mirror for package installation..."
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories
    if ! apk info ffmpeg > /dev/null 2>&1; then
        echo "Installing ffmpeg..."
        apk add --no-cache ffmpeg
    else
        echo "ffmpeg is already installed."
    fi
else
    echo "Skipping ffmpeg installation."
fi

# If https is enabled, certificate files must exist
if [ "$ENABLE_HTTPS" = "true" ]; then
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo "ERROR: ENABLE_HTTPS=true but certificate files not found!"
        echo "CERT_FILE=$CERT_FILE"
        echo "KEY_FILE=$KEY_FILE"
        echo "Please mount certificates with -v."
        exit 1
    fi
fi

echo "Generating Nginx configuration..."

# Common locations config
cat <<'EOF' > /etc/nginx/common-locations.conf
autoindex off;

location ^~ /data/ {
    deny all;
}
location ^~ /data/icon/ {
    allow all;
}

location = /tv.m3u { rewrite ^ /index.php?type=m3u&$query_string last; }
location = /tv.txt { rewrite ^ /index.php?type=txt&$query_string last; }
location = /t.xml { rewrite ^ /index.php?type=xml&$query_string last; }
location = /t.xml.gz { rewrite ^ /index.php?type=gz&$query_string last; }

location ~ \.php$ {
    include fastcgi_params;
    fastcgi_pass 127.0.0.1:9000;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_index index.php;
}
EOF


# Build Nginx server blocks
if [ "$ENABLE_HTTPS" = "true" ]; then

    # HTTP server
    if [ "$FORCE_HTTPS" = "true" ]; then
        # 80 redirect to https
        cat <<EOF > /etc/nginx/http.d/default.conf
server {
    listen ${HTTP_PORT};
    server_name ${SERVER_NAME};

    return 301 https://\$host\$request_uri;
}
EOF
    else
        # Normal http
        cat <<EOF > /etc/nginx/http.d/default.conf
server {
    listen ${HTTP_PORT};
    server_name ${SERVER_NAME};
    root /htdocs;

    include /etc/nginx/common-locations.conf;

    access_log /dev/null;
    error_log /dev/stderr ${LOG_LEVEL};
}
EOF
    fi

    # HTTPS server block
    cat <<EOF >> /etc/nginx/http.d/default.conf

server {
    listen ${HTTPS_PORT} ssl;
    server_name ${SERVER_NAME};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};

    root /htdocs;

    include /etc/nginx/common-locations.conf;

    access_log /dev/null;
    error_log /dev/stderr ${LOG_LEVEL};
}
EOF

else

    # HTTP only
    cat <<EOF > /etc/nginx/http.d/default.conf
server {
    listen ${HTTP_PORT};
    server_name ${SERVER_NAME};
    root /htdocs;

    include /etc/nginx/common-locations.conf;

    access_log /dev/null;
    error_log /dev/stderr ${LOG_LEVEL};
}
EOF

fi


# Modify php memory limit, timezone and file size limit
sed -i "s/memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT}/" /etc/php83/php.ini
sed -i "s#^;date.timezone =\$#date.timezone = \"${TZ}\"#" /etc/php83/php.ini
sed -i "s/upload_max_filesize = .*/upload_max_filesize = 100M/" /etc/php83/php.ini
sed -i "s/post_max_size = .*/post_max_size = 100M/" /etc/php83/php.ini
sed -i 's/^user = .*/user = nginx/' /etc/php83/php-fpm.d/www.conf
sed -i 's/^group = .*/group = nginx/' /etc/php83/php-fpm.d/www.conf

# Modify system timezone
if [ -e /etc/localtime ]; then rm -f /etc/localtime; fi
ln -s /usr/share/zoneinfo/${TZ} /etc/localtime

echo 'Running cron.php, php-fpm and nginx'

# Change ownership of /htdocs
chown -R nginx:nginx /htdocs

# Change session directory permissions
chmod 1733 /tmp

# Start cron.php if exists
if [ -f /htdocs/cron.php ]; then
    cd /htdocs
    su -s /bin/sh -c "php cron.php &" "nginx"
fi

# Start services
memcached -u nobody -d
php-fpm83 -D
exec nginx -g 'daemon off;'