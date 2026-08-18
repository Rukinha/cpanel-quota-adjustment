#!/bin/bash

# ============================================================
# AJUSTE DE QUOTAS CPANEL
#
# Regra padrão:
#   Conta limitada = uso atual + 1 GB
#   Conta ilimitada = NÃO ALTERAR
#   Mínimo = 1 GB
#
# Com --incluir-ilimitadas:
#   Conta ilimitada = passa a ter quota de uso atual + 1 GB
#
# Sem parâmetro:
#   SIMULAÇÃO
#
# --apply:
#   ALTERAÇÃO REAL
#
# --incluir-ilimitadas:
#   Inclui contas atualmente ilimitadas no ajuste
#
# --usuarios=user1,user2:
#   Processa SOMENTE as contas informadas
#
# --limit=N:
#   Processa apenas as N primeiras contas encontradas
#
# Também calcula:
#   - espaço total do servidor
#   - espaço usado
#   - espaço livre
#   - impacto total das quotas
#   - quota total antes/depois
# ============================================================

set -u

WHMAPI="/usr/local/cpanel/bin/whmapi1"
LOG="/var/log/ajuste_quotas.log"

# 1 GB em blocos de 1 KiB
ONE_GB_BLOCKS=1048576

if [ "$EUID" -ne 0 ]; then
    echo "ERRO: execute como root."
    exit 1
fi

if [ ! -x "$WHMAPI" ]; then
    echo "ERRO: $WHMAPI não encontrado."
    exit 1
fi

APPLY=0
USUARIOS=""
LIMIT=0
INCLUIR_ILIMITADAS=0

for ARG in "$@"; do
    case "$ARG" in
        --apply)
            APPLY=1
            ;;

        --incluir-ilimitadas)
            INCLUIR_ILIMITADAS=1
            ;;

        --usuarios=*)
            USUARIOS="${ARG#--usuarios=}"
            ;;

        --limit=*)
            LIMIT="${ARG#--limit=}"
            ;;

        *)
            echo "AVISO: argumento desconhecido ignorado: $ARG"
            ;;
    esac
done

echo
echo "============================================================"
echo " AJUSTE DE QUOTAS cPANEL"
echo "============================================================"
echo

if [ "$APPLY" -eq 1 ]; then
    echo "MODO: ALTERAÇÃO"
    echo "ATENÇÃO: as quotas serão modificadas."
else
    echo "MODO: SIMULAÇÃO"
    echo "Nenhuma quota será modificada."
    echo
    echo "Para aplicar posteriormente:"
    echo "  $0 --apply"
fi

if [ "$INCLUIR_ILIMITADAS" -eq 1 ]; then
    echo
    echo "ILIMITADAS: INCLUÍDAS"
    echo "Contas ilimitadas receberão quota de uso atual + 1 GB."
else
    echo
    echo "ILIMITADAS: IGNORADAS"
    echo "Use --incluir-ilimitadas para incluí-las."
fi

if [ -n "$USUARIOS" ]; then
    echo
    echo "TESTE: processando apenas os usuários: $USUARIOS"
elif [ "$LIMIT" -gt 0 ] 2>/dev/null; then
    echo
    echo "TESTE: processando apenas as primeiras $LIMIT contas"
fi

echo

# ============================================================
# ESPAÇO FÍSICO DO SERVIDOR
# ============================================================

echo "============================================================"
echo " ESPAÇO DO SERVIDOR"
echo "============================================================"

df -h / | awk '
NR==1 {
    printf "%-12s %-12s %-12s %-12s %-10s\n",
           "TOTAL", "USADO", "LIVRE", "DISPONÍVEL", "USO"
}
NR==2 {
    printf "%-12s %-12s %-12s %-12s %-10s\n",
           $2, $3, $4, $4, $5
}
'

read TOTAL_KB USED_KB FREE_KB < <(
    df -Pk / | awk 'NR==2 {print $2, $3, $4}'
)

echo

# ============================================================
# CONSULTA USO DAS CONTAS
# ============================================================

TMP_USAGE="/tmp/cpanel_usage_$$.json"
TMP_ACCOUNTS="/tmp/cpanel_accounts_$$.json"

"$WHMAPI" \
    --output=json \
    get_disk_usage \
    cache_mode=off > "$TMP_USAGE"

if [ $? -ne 0 ] || [ ! -s "$TMP_USAGE" ]; then
    echo "ERRO ao consultar uso de disco."
    rm -f "$TMP_USAGE" "$TMP_ACCOUNTS"
    exit 1
fi

# ============================================================
# CONSULTA CONTAS E DOMÍNIOS
# ============================================================

"$WHMAPI" \
    --output=json \
    listaccts \
    want=user,domain,disklimit > "$TMP_ACCOUNTS"

if [ $? -ne 0 ] || [ ! -s "$TMP_ACCOUNTS" ]; then
    echo "ERRO ao consultar contas."
    rm -f "$TMP_USAGE" "$TMP_ACCOUNTS"
    exit 1
fi

# ============================================================
# PROCESSAMENTO
# ============================================================

python3 - "$TMP_USAGE" "$TMP_ACCOUNTS" "$APPLY" "$ONE_GB_BLOCKS" "$LOG" "$FREE_KB" "$USUARIOS" "$LIMIT" "$INCLUIR_ILIMITADAS" <<'PY'

import json
import sys
import subprocess
from datetime import datetime

usage_file = sys.argv[1]
accounts_file = sys.argv[2]
apply = int(sys.argv[3])
one_gb = int(sys.argv[4])
log_file = sys.argv[5]
server_free_kb = int(sys.argv[6])
usuarios_filtro_raw = sys.argv[7] if len(sys.argv) > 7 else ""
limit_filtro = int(sys.argv[8]) if len(sys.argv) > 8 and sys.argv[8].isdigit() else 0
incluir_ilimitadas = int(sys.argv[9]) if len(sys.argv) > 9 else 0

usuarios_filtro = set(
    u.strip()
    for u in usuarios_filtro_raw.split(",")
    if u.strip()
)

with open(usage_file, encoding="utf-8") as f:
    usage_data = json.load(f)

with open(accounts_file, encoding="utf-8") as f:
    accounts_data = json.load(f)

# ------------------------------------------------------------
# Conversões
# ------------------------------------------------------------

def gb(blocks):
    return blocks / 1024 / 1024

def mb(blocks):
    return blocks / 1024

def format_size(blocks):

    if blocks is None:
        return "ILIMITADA"

    value_gb = gb(blocks)

    if value_gb >= 1:
        return f"{value_gb:.2f} GB"

    return f"{mb(blocks):.2f} MB"

# ------------------------------------------------------------
# USO DAS CONTAS
# ------------------------------------------------------------

usage_accounts = {}

for item in usage_data.get("data", {}).get("accounts", []):

    user = item.get("user")

    if not user:
        continue

    try:
        used = int(item.get("blocks_used", 0))
    except:
        used = 0

    raw_limit = item.get("blocks_limit")

    if raw_limit is None:
        limit = None
    else:
        try:
            limit = int(raw_limit)
        except:
            limit = None

    usage_accounts[user] = {
        "used": used,
        "limit": limit
    }

# ------------------------------------------------------------
# FILTRO DE TESTE
# ------------------------------------------------------------

if usuarios_filtro:

    nao_encontrados = usuarios_filtro - set(usage_accounts.keys())

    usage_accounts = {
        user: info
        for user, info in usage_accounts.items()
        if user in usuarios_filtro
    }

    if nao_encontrados:
        print(
            "AVISO: usuário(s) não encontrado(s): "
            + ", ".join(sorted(nao_encontrados))
        )
        print()

elif limit_filtro > 0:

    usage_accounts = dict(
        list(usage_accounts.items())[:limit_filtro]
    )

# ------------------------------------------------------------
# DOMÍNIOS
# ------------------------------------------------------------

domains = {}

for account in accounts_data.get("data", {}).get("acct", []):

    user = account.get("user")

    if not user:
        continue

    domains[user] = account.get("domain", "-")

# ------------------------------------------------------------
# CABEÇALHO
# ------------------------------------------------------------

print()
print(
    f"{'USUÁRIO':<18}"
    f"{'DOMÍNIO':<40}"
    f"{'USO ATUAL':>14}"
    f"{'QUOTA ATUAL':>14}"
    f"{'NOVA QUOTA':>14}"
    f"  STATUS"
)

print("-" * 115)

# ------------------------------------------------------------
# TOTAIS
# ------------------------------------------------------------

total_current_quota = 0
total_new_quota = 0

contas_alteradas = 0
contas_aumentadas = 0
contas_reduzidas = 0
contas_iguais = 0
contas_ilimitadas = 0
contas_ilimitadas_incluidas = 0
erros = 0

timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

with open(log_file, "a", encoding="utf-8") as log:

    log.write("\n")
    log.write("=" * 115 + "\n")
    log.write(f"Execução: {timestamp}\n")
    log.write(
        f"Modo: {'ALTERAÇÃO' if apply else 'SIMULAÇÃO'}\n"
    )
    log.write(
        f"Incluir ilimitadas: {'SIM' if incluir_ilimitadas else 'NÃO'}\n"
    )
    log.write("=" * 115 + "\n")

    for user, info in usage_accounts.items():

        used = info["used"]
        current_limit = info["limit"]

        domain = domains.get(user, "-")

        # ----------------------------------------------------
        # ILIMITADA
        # ----------------------------------------------------

        if current_limit is None:

            contas_ilimitadas += 1

            # Se não estiver habilitado, ignora
            if not incluir_ilimitadas:

                print(
                    f"{user:<18}"
                    f"{domain:<40}"
                    f"{format_size(used):>14}"
                    f"{'ILIMITADA':>14}"
                    f"{'ILIMITADA':>14}"
                    f"  IGNORADA - ILIMITADA"
                )

                log.write(
                    f"[IGNORADA - ILIMITADA] "
                    f"{user} | {domain} | "
                    f"Uso={format_size(used)}\n"
                )

                continue

            # Se habilitado, transforma em quota
            new_limit = used + one_gb

            if new_limit < one_gb:
                new_limit = one_gb

            # Como a quota anterior era ilimitada,
            # não entra no total de quota anterior.
            total_new_quota += new_limit

            contas_ilimitadas_incluidas += 1
            contas_aumentadas += 1

            status = "ILIMITADA -> LIMITAR"

            print(
                f"{user:<18}"
                f"{domain:<40}"
                f"{format_size(used):>14}"
                f"{'ILIMITADA':>14}"
                f"{format_size(new_limit):>14}"
                f"  {status}"
            )

            # ------------------------------------------------
            # SIMULAÇÃO
            # ------------------------------------------------

            if not apply:

                log.write(
                    f"[SIMULAÇÃO - ILIMITADA] "
                    f"{user} | {domain} | "
                    f"Uso={format_size(used)} | "
                    f"NovaQuota={format_size(new_limit)} | "
                    f"Ação=LIMITAR\n"
                )

                continue

            # ------------------------------------------------
            # ALTERAÇÃO REAL
            # ------------------------------------------------

            result = subprocess.run(
                [
                    "/usr/local/cpanel/bin/whmapi1",
                    "--output=json",
                    "editquota",
                    f"user={user}",
                    f"quota={new_limit // 1024}"
                ],
                capture_output=True,
                text=True
            )

            try:

                response = json.loads(result.stdout)

                success = (
                    response
                    .get("metadata", {})
                    .get("result") == 1
                )

            except:

                success = False

            if success:

                print(
                    f"  -> ALTERADA: "
                    f"ILIMITADA -> {format_size(new_limit)}"
                )

                log.write(
                    f"[ALTERADA - ILIMITADA] "
                    f"{user} | {domain} | "
                    f"Uso={format_size(used)} | "
                    f"Anterior=ILIMITADA | "
                    f"Nova={format_size(new_limit)}\n"
                )

                contas_alteradas += 1

            else:

                print("  -> ERRO")

                log.write(
                    f"[ERRO - ILIMITADA] "
                    f"{user} | {domain} | "
                    f"Resposta={result.stdout.strip()} "
                    f"{result.stderr.strip()}\n"
                )

                erros += 1

            continue

        # ----------------------------------------------------
        # CONTAS LIMITADAS
        # ----------------------------------------------------

        new_limit = used + one_gb

        # Mínimo de 1 GB
        if new_limit < one_gb:
            new_limit = one_gb

        total_current_quota += current_limit
        total_new_quota += new_limit

        # ----------------------------------------------------
        # CLASSIFICAÇÃO
        # ----------------------------------------------------

        if new_limit == current_limit:

            status = "SEM ALTERAÇÃO"
            contas_iguais += 1

        elif new_limit > current_limit:

            status = "AUMENTAR"
            contas_aumentadas += 1

        else:

            status = "REDUZIR"
            contas_reduzidas += 1

        print(
            f"{user:<18}"
            f"{domain:<40}"
            f"{format_size(used):>14}"
            f"{format_size(current_limit):>14}"
            f"{format_size(new_limit):>14}"
            f"  {status}"
        )

        # ----------------------------------------------------
        # SIMULAÇÃO
        # ----------------------------------------------------

        if not apply:

            log.write(
                f"[SIMULAÇÃO] "
                f"{user} | {domain} | "
                f"Uso={format_size(used)} | "
                f"QuotaAtual={format_size(current_limit)} | "
                f"NovaQuota={format_size(new_limit)} | "
                f"Ação={status}\n"
            )

            continue

        # ----------------------------------------------------
        # SEM ALTERAÇÃO
        # ----------------------------------------------------

        if new_limit == current_limit:

            log.write(
                f"[SEM ALTERAÇÃO] "
                f"{user} | {domain} | "
                f"Quota={format_size(current_limit)}\n"
            )

            continue

        # ----------------------------------------------------
        # ALTERAÇÃO REAL
        # ----------------------------------------------------

        result = subprocess.run(
            [
                "/usr/local/cpanel/bin/whmapi1",
                "--output=json",
                "editquota",
                f"user={user}",
                f"quota={new_limit // 1024}"
            ],
            capture_output=True,
            text=True
        )

        try:

            response = json.loads(result.stdout)

            success = (
                response
                .get("metadata", {})
                .get("result") == 1
            )

        except:

            success = False

        if success:

            print(
                f"  -> ALTERADA: "
                f"{format_size(current_limit)} "
                f"-> {format_size(new_limit)}"
            )

            log.write(
                f"[ALTERADA] "
                f"{user} | {domain} | "
                f"Uso={format_size(used)} | "
                f"Anterior={format_size(current_limit)} | "
                f"Nova={format_size(new_limit)} | "
                f"Ação={status}\n"
            )

            contas_alteradas += 1

        else:

            print("  -> ERRO")

            log.write(
                f"[ERRO] "
                f"{user} | {domain} | "
                f"Resposta={result.stdout.strip()} "
                f"{result.stderr.strip()}\n"
            )

            erros += 1

# ============================================================
# IMPACTO DAS QUOTAS
# ============================================================

quota_difference = total_new_quota - total_current_quota

print()
print("=" * 115)
print(" IMPACTO DAS QUOTAS")
print("=" * 115)

print(
    f"Quota total atual   : {format_size(total_current_quota)}"
)

print(
    f"Quota total nova    : {format_size(total_new_quota)}"
)

if quota_difference > 0:

    print(
        f"Quota adicional     : +{format_size(quota_difference)}"
    )

elif quota_difference < 0:

    print(
        f"Quota liberada      : {format_size(abs(quota_difference))}"
    )

else:

    print("Variação de quota   : 0")

# ============================================================
# ESPAÇO FÍSICO DO SERVIDOR
# ============================================================

print()
print("=" * 115)
print(" ESPAÇO FÍSICO DO SERVIDOR")
print("=" * 115)

print(
    f"Espaço livre atual  : {server_free_kb / 1024 / 1024:.2f} GB"
)

print(
    f"Espaço livre físico após ajuste: "
    f"{server_free_kb / 1024 / 1024:.2f} GB"
)

print()
print(
    "OBS: alterar quotas não cria nem remove arquivos."
)
print(
    "Portanto, o espaço físico livre do servidor permanece igual"
)
print(
    "imediatamente após o ajuste."
)

# ============================================================
# RESUMO
# ============================================================

print()
print("=" * 115)
print(" RESUMO")
print("=" * 115)

print(f"Contas analisadas       : {len(usage_accounts)}")
print(f"Ilimitadas encontradas  : {contas_ilimitadas}")
print(f"Ilimitadas incluídas    : {contas_ilimitadas_incluidas}")
print(f"Seriam aumentadas       : {contas_aumentadas}")
print(f"Seriam reduzidas        : {contas_reduzidas}")
print(f"Sem alteração           : {contas_iguais}")

if apply:
    print(f"Alteradas               : {contas_alteradas}")

print(f"Erros                   : {erros}")
print(f"Log                     : {log_file}")

PY

rm -f "$TMP_USAGE" "$TMP_ACCOUNTS"

echo
echo "Concluído."
echo