#!/bin/bash
# user-data da instância do banco: instala o PostgreSQL e libera acesso só de dentro da VPC
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -y
apt-get -o DPkg::Lock::Timeout=600 install -y postgresql

PGV=$(ls /etc/postgresql)
CONF=/etc/postgresql/$PGV/main
sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$CONF/postgresql.conf"
echo "host supernoura supernoura __VPC_CIDR__ scram-sha-256" >> "$CONF/pg_hba.conf"
systemctl restart postgresql

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE USER supernoura WITH PASSWORD '__DB_PASS__';
CREATE DATABASE supernoura OWNER supernoura;
SQL

sudo -u postgres psql -d supernoura -v ON_ERROR_STOP=1 <<SQL
SET ROLE supernoura;
CREATE TABLE IF NOT EXISTS inscritos (
    id SERIAL PRIMARY KEY,
    nome VARCHAR(120) NOT NULL,
    email VARCHAR(160) NOT NULL,
    personagem VARCHAR(20) NOT NULL,
    notificacoes BOOLEAN NOT NULL DEFAULT TRUE,
    servidor VARCHAR(80),
    criado_em TIMESTAMP NOT NULL DEFAULT NOW()
);
SQL
