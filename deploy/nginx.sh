#!/bin/bash
# user-data do load balancer: nginx distribuindo as requisições entre as 3 instâncias web
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -y
apt-get -o DPkg::Lock::Timeout=600 install -y nginx

cat > /etc/nginx/sites-available/supernoura <<'NGINX'
# round-robin entre as 3 instâncias; se uma cair, o nginx tira ela da roda e manda pras outras
upstream site_flask {
    server __WEB1__:5000 max_fails=1 fail_timeout=10s;
    server __WEB2__:5000 max_fails=1 fail_timeout=10s;
    server __WEB3__:5000 max_fails=1 fail_timeout=10s;
}

server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://site_flask;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 2s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/supernoura /etc/nginx/sites-enabled/supernoura
nginx -t
systemctl restart nginx
