#!/bin/sh
# =============================================================================
# Reverse-proxy + persistence helper for 5high HassOS build.
#
# Replaces custom functions that used to live in usr/sbin/hassos-cli
# (init_persistence / change_dns / update_certificates / python_ssl /
# keepalive_https / post_to_haos / post_to_repository / hacs).
#
# Started early by a dedicated systemd unit (reverse-proxy.service)
# with Restart=on-failure so failures do not hang boot.
# =============================================================================

set -u

# ----------------------------------------------------------------------------
# 1) init_persistence: one-shot copy of rootfs custom configs to
#    /mnt/overlay (persistent partition) before bind mounts.
# ----------------------------------------------------------------------------
init_persistence() {
    # 1.1 nginx.conf
    if [ -f /etc/nginx/nginx.conf ] && [ ! -f /mnt/overlay/etc/nginx/nginx.conf ]; then
        mkdir -p /mnt/overlay/etc/nginx
        cp -fp /etc/nginx/nginx.conf /mnt/overlay/etc/nginx/nginx.conf
        echo "[5high] persisted nginx.conf -> /mnt/overlay/etc/nginx/"
    fi

    # 1.2 SSL certs (github reverse-proxy certificate)
    if [ -d /var/www/cert ] && [ ! -d /mnt/overlay/var/www/cert ]; then
        mkdir -p /mnt/overlay/var/www/cert
        cp -fp /var/www/cert/* /mnt/overlay/var/www/cert/ 2>/dev/null
        echo "[5high] persisted certs -> /mnt/overlay/var/www/cert/"
    fi

    # 1.3 root CA certificate (trusted by all containers)
    if [ -f /etc/ssl/certs/rootCA.cer ] && [ ! -f /mnt/overlay/etc/ssl/certs/rootCA.cer ]; then
        mkdir -p /mnt/overlay/etc/ssl/certs
        cp -fp /etc/ssl/certs/rootCA.cer /mnt/overlay/etc/ssl/certs/rootCA.cer
        echo "[5high] persisted rootCA.cer -> /mnt/overlay/etc/ssl/certs/"
    fi

    # 1.4 docker daemon.json (registry mirrors for CN users)
    if [ -f /etc/docker/daemon.json ] && [ ! -f /mnt/overlay/etc/docker/daemon.json ]; then
        mkdir -p /mnt/overlay/etc/docker
        cp -fp /etc/docker/daemon.json /mnt/overlay/etc/docker/daemon.json
        echo "[5high] persisted daemon.json -> /mnt/overlay/etc/docker/"
    fi

    # 1.5 Force-activate bind-mount units (covers case where
    #     haos-bind.target is not pulled in).
    for u in etc-nginx.mount var-www-cert.mount etc-ssl-certs.mount etc-docker.mount; do
        if [ -f "/usr/lib/systemd/system/$u" ]; then
            systemctl enable "$u" 2>/dev/null || true
            systemctl start "$u" 2>/dev/null || true
        fi
    done
}

# ----------------------------------------------------------------------------
# 2) change_dns: ensure hassio_dns resolves github family to 172.30.32.1
#    (docker bridge gateway where nginx listens).
#
# Supervisor regenerates /config/hosts from a fixed template, so we
# poll every 10 s and re-apply as long as the entry is missing.
# ----------------------------------------------------------------------------
change_dns() {
    local entry="github.com ghcr.io raw.githubusercontent.com objects.githubusercontent.com api.github.com github.githubassets.com alive.github.com services.home-assistant.io version.home-assistant.io alerts.home-assistant.io data-v2.hacs.xyz os-artifacts.home-assistant.io"

    while true; do
        if docker ps 2>/dev/null | grep -q hassio_dns; then
            if ! docker exec hassio_dns grep -q 'github.com' /config/hosts 2>/dev/null; then
                docker exec -i hassio_dns sed -i '/^172.30.32.1/s/$/ '"$entry"'/g' /config/hosts 2>/dev/null || true
                docker exec -i hassio_dns killall coredns 2>/dev/null || true
                echo "[5high] change_dns: injected ${#entry} domains into /config/hosts"
            fi
        fi
        sleep 10
    done
}

# ----------------------------------------------------------------------------
# 3) update_certificates: periodically push /etc/ssl/certs/ca-certificates.crt
#    into every running container that does not already carry our marker.
# ----------------------------------------------------------------------------
update_certificates() {
    while true; do
        for cid in $(docker ps -q 2>/dev/null); do
            cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's@^/@@')
            [ -z "$cname" ] && continue
            if ! docker exec "$cid" stat /etc/ssl/certs/sumju.net >/dev/null 2>&1; then
                docker exec "$cid" touch /etc/ssl/certs/sumju.net 2>/dev/null || true
                docker cp /etc/ssl/certs/ca-certificates.crt "$cname:/etc/ssl/certs/ca-certificates.crt" 2>/dev/null || true
                echo "[5high] update_certificates: ca-certificates.crt -> $cname"
            fi
        done
        sleep 10
    done
}

# ----------------------------------------------------------------------------
# 4) python_ssl: patch aiogithubapi / pip.conf / certifi inside python-bearing
#    containers (one-shot, guarded by /tmp/python_ssl_modified).
# ----------------------------------------------------------------------------
python_ssl() {
    while true; do
        local names
        names=$(docker ps --format '{{.Names}}' 2>/dev/null)
        for cn in $names; do
            [ -z "$cn" ] && continue
            docker exec "$cn" test -f /tmp/python_ssl_modified 2>/dev/null && continue
            local py
            py=$(docker exec "$cn" sh -c 'command -v python3 || command -v python' 2>/dev/null)
            [ -z "$py" ] && continue
            local sp
            sp=$(docker exec "$cn" "$py" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)
            if [ -n "$sp" ]; then
                docker cp /etc/ssl/certs/ca-certificates.crt "$cn:$sp/certifi/cacert.pem" 2>/dev/null || true
                docker exec "$cn" sed -i 's#https://github.com#https://gh.so169.com:3308#g' "$sp/aiogithubapi/const.py" 2>/dev/null || true
                docker exec "$cn" sh -c 'printf "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\n" > /etc/pip.conf' 2>/dev/null || true
                docker exec "$cn" touch /tmp/python_ssl_modified 2>/dev/null || true
                echo "[5high] python_ssl: patched $cn ($sp)"
            fi
        done
        sleep 60
    done
}

# ----------------------------------------------------------------------------
# 5) keepalive_https: warm DNS + TLS session cache every 3 min.
# ----------------------------------------------------------------------------
keepalive_https() {
    while true; do
        curl -s -o /dev/null -m 30 https://github.com 2>/dev/null
        sleep 180
    done
}

# ----------------------------------------------------------------------------
# 6) post_to_haos: anonymous first-boot telemetry to sumju.net/haos.php
# ----------------------------------------------------------------------------
post_to_haos() {
    local pub
    pub=$(curl -s -m 10 https://ipinfo.io 2>/dev/null | grep -o '"ip":"[^"]*"')
    pub=${pub#*\"ip\":\"}; pub=${pub%\"}
    [ -z "$pub" ] && pub="?"
    local vers variant
    . /etc/os-release 2>/dev/null
    vers="${VERSION_ID:-?}"
    variant="${VARIANT_ID:-?}"
    local cpu mem
    cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
    mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    curl -s -m 10 -X POST -d "ip=$pub&version=$vers&variant=$variant&cpu=$cpu&mem=$mem" \
        https://sumju.net/haos.php >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# 7) post_to_repository: register our Home-Assistant-Addons repository
#    via Supervisor API (waits for SUPERVISOR_TOKEN + landingpage image).
# ----------------------------------------------------------------------------
post_to_repository() {
    local tok
    # Wait for Supervisor to expose a bearer token
    while :; do
        tok=$(docker exec hassio_cli printenv SUPERVISOR_TOKEN 2>/dev/null)
        [ -n "$tok" ] && break
        sleep 5
    done

    # Add the 5high add-on repository
    curl -s -X POST -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" \
        -d '{"repository":"https://github.com/5high/Home-Assistant-Addons","enabled":true,"privileged":false}' \
        http://172.30.32.2/store/repositories >/dev/null

    # Install and auto-start our aliyun_backup addon
    local addons
    addons=$(curl -s -H "Authorization: Bearer $tok" \
        http://172.30.32.2/store/addons 2>/dev/null | sed -n 's/.*"slug":"aliyun_backup".*/aliyun_backup/p')
    if [ -n "$addons" ]; then
        curl -s -X POST -H "Authorization: Bearer $tok" \
            http://172.30.32.2/store/addons/aliyun_backup/options \
            -H "Content-Type: application/json" \
            -d '{"auto_update":true,"boot":"auto","watchdog":true}' >/dev/null
        curl -s -X POST -H "Authorization: Bearer $tok" \
            http://172.30.32.2/store/addons/aliyun_backup/start >/dev/null
        echo "[5high] post_to_repository: aliyun_backup enabled + autostart"
    fi
}

# ----------------------------------------------------------------------------
# 8) hacs: install HACS integration if missing (30 retries, 5 s apart)
# ----------------------------------------------------------------------------
hacs() {
    local hacs_dir="/mnt/data/supervisor/homeassistant/custom_components/hacs"
    [ -d "$hacs_dir" ] && return 0
    local url="https://github.com/hacs/integration/releases/latest/download/hacs.zip"
    local i
    for i in $(seq 1 30); do
        if curl -fsSL -o /tmp/hacs.zip "$url" 2>/dev/null; then
            mkdir -p "$hacs_dir"
            tar -xzf /tmp/hacs.zip -C "$hacs_dir" 2>/dev/null || \
                python3 -c "import zipfile; zipfile.ZipFile('/tmp/hacs.zip').extractall('$hacs_dir')" 2>/dev/null || true
            rm -f /tmp/hacs.zip
            docker restart homeassistant 2>/dev/null || true
            echo "[5high] hacs: installed at $hacs_dir (attempt $i)"
            return 0
        fi
        sleep 5
    done
    echo "[5high] hacs: give up after 30 attempts"
    return 1
}

# ----------------------------------------------------------------------------
# Main: one-shot + four daemons
# ----------------------------------------------------------------------------
init_persistence

# One-shot housekeeping (best effort)
post_to_haos     || true
post_to_repository || true
hacs               || true

# Long-running daemons (each in its own subshell, stdout silenced)
change_dns          >/dev/null 2>&1 &
update_certificates >/dev/null 2>&1 &
python_ssl          >/dev/null 2>&1 &
keepalive_https     >/dev/null 2>&1 &

# Foreground: wait forever so the unit stays alive.
echo "[5high] reverse-proxy service: daemons started, entering foreground wait"
wait
