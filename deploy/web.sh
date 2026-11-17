#!/bin/bash
# user-data das 3 instâncias web: clona o repo, cria o venv e sobe o Flask com gunicorn na porta 5000
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -y
apt-get -o DPkg::Lock::Timeout=600 upgrade -y
apt-get -o DPkg::Lock::Timeout=600 install -y python3-venv python3-pip git

cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/pedrohl45/site-fatec-dev.git
cd site-fatec-dev
sudo -u ubuntu python3 -m venv .venv
sudo -u ubuntu .venv/bin/pip install -r requirements.txt

# .env com os dados do banco (não vai pro git)
cat > .env <<ENV
DB_HOST=__DB_IP__
DB_PORT=5432
DB_NAME=supernoura
DB_USER=supernoura
DB_PASSWORD=__DB_PASS__
SECRET_KEY=__SECRET_KEY__
SERVER_NAME_LABEL=__NOME__
ENV
chown ubuntu:ubuntu .env
chmod 600 .env

# serviço do systemd: o site continua no ar depois de fechar o SSH e volta sozinho se a máquina reiniciar
cat > /etc/systemd/system/supernoura.service <<UNIT
[Unit]
Description=Site Flask Super no Ura (gunicorn)
After=network-online.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/site-fatec-dev
ExecStart=/home/ubuntu/site-fatec-dev/.venv/bin/gunicorn --workers 2 --bind 0.0.0.0:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now supernoura
