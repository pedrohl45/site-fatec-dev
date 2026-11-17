# app principal do Flask: cria o app, as rotas e a conexão com o PostgreSQL
import os
import socket

import psycopg2
from dotenv import load_dotenv
from flask import Flask, flash, redirect, render_template, request, url_for

load_dotenv()  # lê o arquivo .env (DB_HOST, DB_USER...) que fica só no servidor, fora do git

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY", "troque-essa-chave")  # precisa disso pro flash() funcionar

# nome da máquina que respondeu, aparece no rodapé pra ver o load balance funcionando
SERVIDOR = os.getenv("SERVER_NAME_LABEL", socket.gethostname())


def conectar():
    """Abre uma conexão com o PostgreSQL que roda na instância do banco."""
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "supernoura"),
        user=os.getenv("DB_USER", "supernoura"),
        password=os.getenv("DB_PASSWORD", ""),
        connect_timeout=5,
    )


def criar_tabela():
    """Cria a tabela de inscritos se ela ainda não existir."""
    with conectar() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS inscritos (
                id SERIAL PRIMARY KEY,
                nome VARCHAR(120) NOT NULL,
                email VARCHAR(160) NOT NULL,
                personagem VARCHAR(20) NOT NULL,
                notificacoes BOOLEAN NOT NULL DEFAULT TRUE,
                servidor VARCHAR(80),
                criado_em TIMESTAMP NOT NULL DEFAULT NOW()
            )
            """
        )


@app.context_processor
def dados_globais():
    # tudo que voltar daqui fica disponível em todos os templates
    return {"servidor": SERVIDOR}


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/sasaki")
def sasaki():
    return render_template("sasaki.html")


@app.route("/yamada")
def yamada():
    return render_template("yamada.html")


@app.route("/cadastro", methods=["GET", "POST"])
def cadastro():
    if request.method == "POST":
        nome = request.form.get("nome", "").strip()
        email = request.form.get("email", "").strip()
        personagem = request.form.get("personagem", "outro")
        notificacoes = request.form.get("notificacoes") == "on"  # checkbox só vem no form se tiver marcado

        if not nome or not email:
            flash("Preencha nome e e-mail.", "warning")
            return redirect(url_for("cadastro"))

        try:
            criar_tabela()
            with conectar() as conn, conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO inscritos (nome, email, personagem, notificacoes, servidor) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    (nome, email, personagem, notificacoes, SERVIDOR),
                )
            flash("✅ Cadastro realizado com sucesso! Você receberá as novidades no seu e-mail.", "success")
        except psycopg2.Error as erro:
            app.logger.error("Erro ao gravar no banco: %s", erro)
            flash("❌ Não deu pra salvar agora, o banco de dados não respondeu. Tente de novo.", "danger")

        # redirect depois do POST pra não reenviar o form se der F5
        return redirect(url_for("cadastro"))

    # GET: mostra o form e quantos já se cadastraram
    total = None
    try:
        criar_tabela()
        with conectar() as conn, conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM inscritos")
            total = cur.fetchone()[0]
    except psycopg2.Error as erro:
        app.logger.error("Erro ao contar inscritos: %s", erro)

    return render_template("cadastro.html", total=total)


if __name__ == "__main__":
    # 0.0.0.0 = aceita conexão de fora (não só localhost), na porta 5000 liberada no Security Group
    app.run(host="0.0.0.0", port=5000)
