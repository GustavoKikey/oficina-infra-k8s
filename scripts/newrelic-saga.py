#!/usr/bin/env python3
"""
Painel e alertas da saga no New Relic, como código (fase 4).

Cria ou atualiza:

  * o dashboard "Oficina — Saga (fase 4)", com duas páginas:
      - Saga: OS abertas, sagas concluídas/compensadas/em falha, motivos de
        compensação, pagamentos, duração das fases e a DLQ do RabbitMQ;
      - Rastreamento: spans e latência por serviço, erros — a porta de
        entrada para o distributed tracing de um fluxo inteiro;
  * a policy de alertas "Oficina — Saga", com as condições que pedem uma
    pessoa (saga em FALHA, mensagem na DLQ, pico de compensação, falha de
    integração).

Mesmo modelo dos scripts da fase 3 (tech-challenge-15SOAT/scripts/fase-3):
as consultas ficam versionadas junto do código que produz as métricas.

Nomes das métricas: nascem pontuados no Micrometer ("oficina.saga.concluidas")
e chegam pelo endpoint Prometheus raspado pelo agente do cluster, com ponto
virando underscore e sufixo por tipo (oficina_saga_concluidas_total). O que
identifica o serviço nas métricas é o label do Kubernetes
`app_kubernetes_io_name`; nos spans (OTLP), é `service.name`.

Uso:
    export NEW_RELIC_API_KEY=NRAK-...      # chave de USUÁRIO, não a de ingestão
    export NEW_RELIC_ACCOUNT_ID=1234567
    python scripts/newrelic-saga.py hom
"""
import json
import os
import sys
import urllib.request

API = "https://api.newrelic.com/graphql"
NOME = "Oficina — Saga (fase 4)"
POLICY = "Oficina — Saga"

SERVICOS = "app_kubernetes_io_name IN ('oficina-os', 'oficina-execucao', 'oficina-billing')"
OS = "app_kubernetes_io_name = 'oficina-os'"
EXECUCAO = "app_kubernetes_io_name = 'oficina-execucao'"
BILLING = "app_kubernetes_io_name = 'oficina-billing'"
RABBIT = "app_kubernetes_io_name = 'rabbitmq'"
SPANS = "service.name LIKE 'oficina-%'"

CHAVE = ""
CONTA = 0


def graphql(consulta, variaveis=None):
    corpo = {"query": consulta}
    if variaveis:
        corpo["variables"] = variaveis
    req = urllib.request.Request(
        API,
        data=json.dumps(corpo).encode(),
        headers={"Content-Type": "application/json", "API-Key": CHAVE},
    )
    with urllib.request.urlopen(req, timeout=90) as r:
        resposta = json.load(r)
    if resposta.get("errors"):
        raise SystemExit("GraphQL: " + json.dumps(resposta["errors"], ensure_ascii=False)[:800])
    return resposta["data"]


def widget(titulo, viz, consulta, coluna, linha, largura=4, altura=3):
    return {
        "title": titulo,
        "layout": {"column": coluna, "row": linha, "width": largura, "height": altura},
        "visualization": {"id": viz},
        "rawConfiguration": {
            "nrqlQueries": [{"accountId": CONTA, "query": consulta}],
            "platformOptions": {"ignoreTimeRange": False},
        },
    }


def markdown(texto, coluna, linha, largura=12, altura=1):
    return {
        "title": "",
        "layout": {"column": coluna, "row": linha, "width": largura, "height": altura},
        "visualization": {"id": "viz.markdown"},
        "rawConfiguration": {"text": texto},
    }


def paginas(cluster):
    saga = [
        markdown(
            "### Saga orquestrada da OS\n"
            "OS Service orquestra; Execução e Billing participam (RabbitMQ). "
            "Uma saga termina **CONCLUIDA**, **COMPENSADA** (rollback feito) ou em **FALHA** "
            "(precisa de uma pessoa: `POST /admin/sagas/{osId}/reprocessar`). "
            f"Cluster `{cluster}`.",
            1, 1,
        ),
        widget("OS abertas", "viz.billboard",
               f"SELECT sum(oficina_os_abertas_total) AS 'OS abertas' FROM Metric WHERE {OS}", 1, 2, 3),
        widget("Sagas concluídas", "viz.billboard",
               f"SELECT sum(oficina_saga_concluidas_total) AS 'Concluídas' FROM Metric WHERE {OS}", 4, 2, 3),
        widget("Sagas compensadas", "viz.billboard",
               f"SELECT sum(oficina_saga_compensadas_total) AS 'Compensadas' FROM Metric WHERE {OS}", 7, 2, 3),
        widget("Sagas em FALHA", "viz.billboard",
               f"SELECT sum(oficina_saga_falhas_total) AS 'Em falha' FROM Metric WHERE {OS}", 10, 2, 3),
        widget("Desfecho das sagas ao longo do tempo", "viz.line",
               "SELECT sum(oficina_os_abertas_total) AS 'Abertas', "
               "sum(oficina_saga_concluidas_total) AS 'Concluídas', "
               "sum(oficina_saga_compensadas_total) AS 'Compensadas', "
               f"sum(oficina_saga_falhas_total) AS 'Falha' FROM Metric WHERE {OS} TIMESERIES",
               1, 5, 6),
        widget("Compensações por motivo", "viz.pie",
               f"SELECT sum(oficina_saga_compensadas_total) FROM Metric WHERE {OS} FACET motivo",
               7, 5, 3),
        widget("Falhas por passo da saga", "viz.bar",
               f"SELECT sum(oficina_saga_falhas_total) FROM Metric WHERE {OS} FACET passo",
               10, 5, 3),
        widget("Pagamentos por resultado (Billing)", "viz.bar",
               f"SELECT sum(oficina_pagamentos_total) FROM Metric WHERE {BILLING} FACET status",
               1, 8, 4),
        widget("Duração média por fase da OS (s)", "viz.bar",
               "SELECT sum(oficina_os_fase_duracao_seconds_sum) / sum(oficina_os_fase_duracao_seconds_count) "
               f"FROM Metric WHERE {OS} FACET fase",
               5, 8, 4),
        widget("Duração média por etapa na Execução (s)", "viz.bar",
               "SELECT sum(oficina_execucao_etapa_duracao_seconds_sum) / "
               f"sum(oficina_execucao_etapa_duracao_seconds_count) FROM Metric WHERE {EXECUCAO} FACET etapa",
               9, 8, 4),
        widget("Mensagens prontas por fila (RabbitMQ)", "viz.line",
               f"SELECT max(rabbitmq_queue_messages_ready) FROM Metric WHERE {RABBIT} FACET queue TIMESERIES",
               1, 11, 6),
        widget("DLQ — mensagens rejeitadas", "viz.table",
               f"SELECT latest(rabbitmq_queue_messages_ready) AS 'Na DLQ' FROM Metric "
               f"WHERE {RABBIT} AND queue LIKE '%.dlq' FACET queue",
               7, 11, 3),
        widget("Falhas de integração", "viz.bar",
               f"SELECT sum(oficina_integracao_falhas_total) FROM Metric WHERE {SERVICOS} "
               "FACET app_kubernetes_io_name, integracao",
               10, 11, 3),
    ]
    rastreamento = [
        markdown(
            "### Fluxos distribuídos\n"
            "Uma ação (abrir a OS, concluir o diagnóstico, pagar) e tudo o que ela dispara nos três "
            "serviços ficam num **único trace**: o outbox guarda o `traceparent` e a publicação "
            "continua o trace original. Abra um trace em *APM & Services → Distributed tracing* "
            "filtrando por `service.name LIKE 'oficina-%'`.",
            1, 1,
        ),
        widget("Spans por serviço", "viz.line",
               f"SELECT count(*) FROM Span WHERE {SPANS} FACET service.name TIMESERIES", 1, 2, 6),
        widget("Mensageria: publicações e consumos", "viz.bar",
               f"SELECT count(*) FROM Span WHERE {SPANS} AND (name LIKE '% publish' OR name LIKE '% receive') "
               "FACET service.name, name",
               7, 2, 6),
        widget("Latência HTTP (p95, ms) por serviço", "viz.line",
               f"SELECT percentile(duration.ms, 95) FROM Span WHERE {SPANS} AND span.kind = 'server' "
               "FACET service.name TIMESERIES",
               1, 5, 6),
        widget("Spans com erro", "viz.table",
               f"SELECT count(*) FROM Span WHERE {SPANS} AND otel.status_code = 'ERROR' "
               "FACET service.name, name LIMIT 20",
               7, 5, 6),
        widget("Traces que atravessaram mais de um serviço", "viz.billboard",
               f"SELECT uniqueCount(trace.id) FROM Span WHERE {SPANS} AND span.kind IN ('producer', 'consumer')",
               1, 8, 4),
        widget("Logs de erro (os três serviços)", "viz.table",
               "SELECT timestamp, service.name, message FROM Log WHERE level = 'ERROR' "
               "AND service.name LIKE 'oficina-%' LIMIT 20",
               5, 8, 8),
    ]
    return [{"name": "Saga", "widgets": saga}, {"name": "Rastreamento", "widgets": rastreamento}]


def condicoes():
    return [
        {
            # O estado que existe para chamar uma pessoa (saga.md §3): sem
            # resposta de um participante ou estorno que não sai — dinheiro
            # preso ou peça bloqueada.
            "name": "Saga em FALHA - requer acao manual",
            "nrql": f"SELECT sum(oficina_saga_falhas_total) FROM Metric WHERE {OS}",
            "threshold": 0.0,
            "duracao": 60,
        },
        {
            # Mensagem que esgotou as retentativas (ADR 010): algo que a saga
            # mandou ou recebeu não foi processado.
            "name": "Mensagem na DLQ",
            "nrql": f"SELECT max(rabbitmq_queue_messages_ready) FROM Metric WHERE {RABBIT} AND queue LIKE '%.dlq'",
            "threshold": 0.0,
            "duracao": 300,
        },
        {
            # Compensar é o caminho previsto, não erro — mas muitas em pouco
            # tempo indicam um participante com problema (estoque, Mercado Pago).
            "name": "Compensacoes acima do normal",
            "nrql": f"SELECT sum(oficina_saga_compensadas_total) FROM Metric WHERE {OS}",
            "threshold": 5.0,
            "duracao": 900,
        },
        {
            "name": "Falha de integracao (RabbitMQ, Mercado Pago, e-mail)",
            "nrql": f"SELECT sum(oficina_integracao_falhas_total) FROM Metric WHERE {SERVICOS}",
            "threshold": 3.0,
            "duracao": 300,
        },
    ]


def corpo_condicao(c):
    return {
        "name": c["name"],
        "enabled": True,
        "nrql": {"query": c["nrql"]},
        "signal": {"aggregationWindow": 60, "aggregationMethod": "EVENT_FLOW", "aggregationDelay": 120},
        "terms": [{
            "threshold": c["threshold"],
            "thresholdOccurrences": "AT_LEAST_ONCE",
            "thresholdDuration": c["duracao"],
            "operator": "ABOVE",
            "priority": "CRITICAL",
        }],
        "expiration": {"closeViolationsOnExpiration": True, "expirationDuration": 3600},
        "violationTimeLimitSeconds": 86400,
    }


def encontrar_dashboard():
    dados = graphql(
        '{ actor { entitySearch(query: "type = \'DASHBOARD\'") '
        "{ results { entities { guid name } } } } }"
    )
    for e in dados["actor"]["entitySearch"]["results"]["entities"]:
        if e["name"] == NOME:  # as páginas vêm como "Nome / Página"
            return e["guid"]
    return None


def dashboard(cluster):
    corpo = {
        "name": NOME,
        "description": f"Tech Challenge fase 4 — saga e rastreamento distribuído, cluster {cluster}",
        "permissions": "PUBLIC_READ_WRITE",
        "pages": paginas(cluster),
    }
    guid = encontrar_dashboard()
    if guid:
        r = graphql(
            "mutation($guid: EntityGuid!, $d: DashboardInput!) { "
            "dashboardUpdate(guid: $guid, dashboard: $d) { errors { description type } } }",
            {"guid": guid, "d": corpo},
        )
        erros = r["dashboardUpdate"]["errors"]
    else:
        r = graphql(
            "mutation($conta: Int!, $d: DashboardInput!) { "
            "dashboardCreate(accountId: $conta, dashboard: $d) "
            "{ entityResult { guid } errors { description type } } }",
            {"conta": CONTA, "d": corpo},
        )
        erros = r["dashboardCreate"]["errors"]
        guid = (r["dashboardCreate"].get("entityResult") or {}).get("guid")
    if erros:
        raise SystemExit("Dashboard falhou: " + json.dumps(erros, ensure_ascii=False)[:800])
    print(f"dashboard OK — https://one.newrelic.com/redirect/entity/{guid}")


def alertas():
    dados = graphql(
        "{ actor { account(id: %d) { alerts { policiesSearch { policies { id name } } } } } }" % CONTA
    )
    politicas = dados["actor"]["account"]["alerts"]["policiesSearch"]["policies"]
    politica = next((p for p in politicas if p["name"] == POLICY), None)
    if politica is None:
        r = graphql(
            "mutation($c: Int!, $p: AlertsPolicyInput!) { alertsPolicyCreate(accountId: $c, policy: $p) { id } }",
            {"c": CONTA, "p": {"name": POLICY, "incidentPreference": "PER_CONDITION"}},
        )
        policy_id, existentes = r["alertsPolicyCreate"]["id"], []
    else:
        policy_id = politica["id"]
        r = graphql(
            '{ actor { account(id: %d) { alerts { nrqlConditionsSearch'
            '(searchCriteria: {policyId: "%s"}) { nrqlConditions { id name } } } } } }' % (CONTA, policy_id)
        )
        existentes = r["actor"]["account"]["alerts"]["nrqlConditionsSearch"]["nrqlConditions"]

    # Recria em vez de atualizar: alertsNrqlConditionStaticUpdate falha com
    # SERVER_ERROR em condição criada por outra via (lição da fase 3).
    for c in existentes:
        graphql("mutation($c: Int!, $id: ID!) { alertsConditionDelete(accountId: $c, id: $id) { id } }",
                {"c": CONTA, "id": c["id"]})
    for d in condicoes():
        graphql(
            "mutation($c: Int!, $p: ID!, $cond: AlertsNrqlConditionStaticInput!) { "
            "alertsNrqlConditionStaticCreate(accountId: $c, policyId: $p, condition: $cond) { id } }",
            {"c": CONTA, "p": policy_id, "cond": corpo_condicao(d)},
        )
        print(f"  alerta: {d['name']}")
    print(f"policy OK — '{POLICY}' ({policy_id})")


if __name__ == "__main__":
    ambiente = sys.argv[1] if len(sys.argv) > 1 else "hom"
    cluster = os.environ.get("CLUSTER", f"oficina-{ambiente}")
    CHAVE = os.environ.get("NEW_RELIC_API_KEY", "")
    conta = os.environ.get("NEW_RELIC_ACCOUNT_ID", "")
    if not CHAVE or not conta:
        raise SystemExit("Defina NEW_RELIC_API_KEY (chave de usuário, NRAK-...) e NEW_RELIC_ACCOUNT_ID.")
    CONTA = int(conta)
    dashboard(cluster)
    alertas()
