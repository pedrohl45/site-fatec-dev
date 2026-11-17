#!/bin/bash
# Cria a infra da atividade na AWS (rodar no terminal do AWS Academy Learner Lab ou no CloudShell):
#   1 instância PostgreSQL + 3 instâncias Flask + 1 nginx fazendo load balance
# Uso: bash deploy/criar-infra.sh
set -euo pipefail
shopt -s inherit_errexit

NOME=${NOME:-pedro}
TIPO=${TIPO:-t3.medium}      # 2 vCPU / 4 GB
CHAVE=${CHAVE:-vockey}       # key pair que já vem no Learner Lab
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)

aleatorio() { openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

existe=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=webServer-$NOME-*,dbServer-$NOME,loadBalancer-$NOME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
if [ "$existe" != "0" ]; then
  echo "Já existem instâncias da atividade ($existe). Apague antes de rodar de novo." >&2
  exit 1
fi

echo ">> Procurando a AMI do Ubuntu 24.04..."
AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
        --query Parameter.Value --output text 2>/dev/null) || \
AMI=$(aws ec2 describe-images --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].CidrBlock' --output text)
echo "   AMI=$AMI  VPC=$VPC ($CIDR)"

criar_sg() {  # nome descricao -> id (reaproveita se já existir)
  local id
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC" \
         --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ]; then
    id=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC" --query GroupId --output text)
  fi
  echo "$id"
}
liberar() {  # sg porta origem(cidr ou sg)
  if [[ $3 == sg-* ]]; then
    aws ec2 authorize-security-group-ingress --group-id "$1" --protocol tcp --port "$2" --source-group "$3" >/dev/null 2>&1 || true
  else
    aws ec2 authorize-security-group-ingress --group-id "$1" --protocol tcp --port "$2" --cidr "$3" >/dev/null 2>&1 || true
  fi
}

echo ">> Security Groups..."
SG_WEB=$(criar_sg "web-$NOME-sg" "Flask: SSH e porta 5000")
SG_DB=$(criar_sg "db-$NOME-sg" "PostgreSQL: SSH e 5432 so das instancias web")
SG_LB=$(criar_sg "lb-$NOME-sg" "Nginx load balancer: SSH e HTTP")
liberar "$SG_WEB" 22 0.0.0.0/0;  liberar "$SG_WEB" 5000 0.0.0.0/0
liberar "$SG_DB" 22 0.0.0.0/0;   liberar "$SG_DB" 5432 "$SG_WEB"
liberar "$SG_LB" 22 0.0.0.0/0;   liberar "$SG_LB" 80 0.0.0.0/0

criar_instancia() {  # nome sg arquivo-user-data -> instance id
  aws ec2 run-instances --image-id "$AMI" --instance-type "$TIPO" --key-name "$CHAVE" \
    --security-group-ids "$2" --user-data "file://$3" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=10,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$1}]" \
    --query 'Instances[0].InstanceId' --output text
}
ip_privado() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text; }
ip_publico() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

DB_PASS=$(aleatorio)
SECRET_KEY=$(aleatorio)

echo ">> Banco de dados (dbServer-$NOME)..."
sed -e "s|__VPC_CIDR__|$CIDR|" -e "s|__DB_PASS__|$DB_PASS|" "$DIR/db.sh" > "$TMP/db.sh"
ID_DB=$(criar_instancia "dbServer-$NOME" "$SG_DB" "$TMP/db.sh")
DB_IP=$(ip_privado "$ID_DB")
echo "   $ID_DB  ip privado $DB_IP"

IDS_WEB=(); IPS_WEB=()
for i in 1 2 3; do
  echo ">> Site Flask (webServer-$NOME-$i)..."
  sed -e "s|__DB_IP__|$DB_IP|" -e "s|__DB_PASS__|$DB_PASS|" -e "s|__SECRET_KEY__|$SECRET_KEY|" \
      -e "s|__NOME__|webServer-$NOME-$i|" "$DIR/web.sh" > "$TMP/web$i.sh"
  id=$(criar_instancia "webServer-$NOME-$i" "$SG_WEB" "$TMP/web$i.sh")
  IDS_WEB+=("$id"); IPS_WEB+=("$(ip_privado "$id")")
  echo "   $id  ip privado ${IPS_WEB[-1]}"
done

echo ">> Load balancer nginx (loadBalancer-$NOME)..."
sed -e "s|__WEB1__|${IPS_WEB[0]}|" -e "s|__WEB2__|${IPS_WEB[1]}|" -e "s|__WEB3__|${IPS_WEB[2]}|" \
    "$DIR/nginx.sh" > "$TMP/nginx.sh"
ID_LB=$(criar_instancia "loadBalancer-$NOME" "$SG_LB" "$TMP/nginx.sh")
echo "   $ID_LB"

echo ">> Esperando as instâncias ligarem..."
aws ec2 wait instance-running --instance-ids "$ID_DB" "${IDS_WEB[@]}" "$ID_LB"

SAIDA=~/infra-$NOME.txt
{
  echo "Load balancer (link de entrega): http://$(ip_publico "$ID_LB")"
  for i in 0 1 2; do echo "webServer-$NOME-$((i+1)): http://$(ip_publico "${IDS_WEB[$i]}"):5000"; done
  echo "dbServer-$NOME: publico $(ip_publico "$ID_DB") / privado $DB_IP"
  echo "Senha do Postgres (usuario supernoura): $DB_PASS"
} | tee "$SAIDA"
rm -rf "$TMP"
echo
echo "Pronto. Os sites levam uns 3-5 minutos pra terminar de instalar depois que a máquina liga."
echo "Esses dados ficaram salvos em $SAIDA"
