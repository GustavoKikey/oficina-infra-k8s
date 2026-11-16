# oficina-infra-k8s

**Plataforma** da oficina na AWS: rede, cluster Kubernetes (EKS) e o **RabbitMQ** que os
microsserviços usam — e os **scripts de operação** do ambiente inteiro. Nasceu na fase 3
(repositório 2 dos 4); na fase 4 passou a servir os três microsserviços.

```
[oficina-infra-k8s]  ->  infra/ de cada serviço  ->  deploy (cd.yml)  ->  oficina-auth-lambda
  rede, EKS, RabbitMQ     bancos e tabela             OS, Execução,        login do cliente
                                                      Billing
```

Arquitetura do sistema e decisões de implantação:
[oficina-os-service/docs/fase-4](https://github.com/GustavoKikey/oficina-os-service/tree/main/docs/fase-4)
(em especial o [ADR 012](https://github.com/GustavoKikey/oficina-os-service/blob/main/docs/fase-4/adr/adr-012-implantacao-na-aws.md)).

## O que provisiona

| Recurso | Observação |
| --- | --- |
| Security group do cluster | Saída liberada (pull de imagem, OTLP, Mercado Pago, DynamoDB) |
| Security group dos bancos | Só aceita 5432 dos nós do cluster; sem saída. Usado pelos dois RDS (OS e Execução) |
| Security group da Lambda | **Sem internet**: só a porta 80 dentro da VPC, para o LB interno do OS Service |
| Cluster EKS + node group | `t3.medium`, **3 nós** (teto de 5 para o HPA); logs de `api` e `audit` no CloudWatch |
| Addon metrics-server | Pré-requisito do HPA |
| Credenciais do RabbitMQ | Admin + **um usuário por serviço**, geradas pelo Terraform, no Secrets Manager |
| RabbitMQ no cluster ([`k8s/rabbitmq/`](k8s/rabbitmq/)) | StatefulSet de uma réplica, filas quorum, métricas Prometheus por fila, Job que cria os usuários |

**A VPC não é criada** — a default é reaproveitada: subnets privadas exigiriam NAT Gateway ou
VPC endpoints, cobrados por hora, e o isolamento vem dos security groups.

## Contrato publicado no SSM (`/oficina/{env}/...`)

| Parâmetro | Consumido por |
| --- | --- |
| `rede/vpc-id`, `rede/vpc-cidr`, `rede/subnet-ids` | Lambda, bancos dos serviços |
| `rede/sg-banco-id` | `infra/` do OS e da Execução |
| `rede/sg-lambda-id` | Lambda |
| `eks/cluster-name`, `eks/endpoint` | `cd.yml` dos serviços, scripts |
| `mensageria/secret-arn`, `mensageria/host` | `scripts/plataforma-k8s.sh` |

## Operação do ambiente

Sequência de uma sessão do Learner Lab:

```
liga o lab -> diagnostico -> (bootstrap, 1x) -> renovar-secrets -> aplicar -> usa -> destruir
```

| Script | Quando | O que faz |
| --- | --- | --- |
| [`diagnostico-lab.sh`](scripts/diagnostico-lab.sh) | Sempre primeiro | Confere credenciais, roles do lab, serviços e o que já está ligado. Somente leitura |
| [`bootstrap.sh SUFIXO`](scripts/bootstrap.sh) | Uma vez por conta | Bucket S3 e tabela DynamoDB do state do Terraform (já existem desde a fase 3) |
| [`renovar-secrets.sh USUARIO`](scripts/renovar-secrets.sh) | A cada sessão | Reenvia as credenciais de 4h aos 5 repositórios (e, se exportados, `NEW_RELIC_LICENSE_KEY` e `MP_ACCESS_TOKEN`) |
| [`aplicar.sh hom`](scripts/aplicar.sh) | Para subir tudo | Plataforma → bancos dos serviços → **CD dos três serviços** (OS primeiro) → Lambda, e imprime os endereços |
| [`liberar-meu-ip.sh`](scripts/liberar-meu-ip.sh) | Ao usar / trocar de rede | Abre os 3 load balancers públicos para o seu IP (`--fechar` tranca) |
| [`observabilidade.sh hom`](scripts/observabilidade.sh) | Depois de aplicar | Agente do New Relic no cluster (métricas, logs, eventos) |
| [`newrelic-saga.py hom`](scripts/newrelic-saga.py) | Uma vez por conta New Relic | Painel "Oficina — Saga (fase 4)" e os alertas da saga |
| [`plataforma-k8s.sh hom`](scripts/plataforma-k8s.sh) | Chamado pelo `aplicar.sh` e pelo workflow | Namespace, Secrets do RabbitMQ, o broker e os usuários |
| [`destruir.sh hom`](scripts/destruir.sh) | **Antes de fechar o lab** | Ordem inversa; apaga antes os load balancers do Kubernetes, que senão travariam a rede |

Os scripts esperam os repositórios clonados lado a lado:

```
pasta/
├── oficina-infra-k8s/        ← este
├── oficina-os-service/
├── oficina-execucao-service/
├── oficina-billing-service/
└── oficina-auth-lambda/
```

**Custo:** ~US$ 0,36 por hora de ambiente ligado (EKS, 3 nós, 2 RDS, 4 load balancers) —
cerca de US$ 1,50 por sessão de 4 horas. Por isso o `destruir.sh` ao fim de cada sessão:
esquecido ligado, o ambiente consome ~US$ 9 por dia.

## CI/CD

[`terraform.yml`](.github/workflows/terraform.yml):

| Gatilho | O que roda |
| --- | --- |
| PR e push na `main` | fmt, validate, tflint, kubeconform (`k8s/`), sintaxe dos scripts |
| PR | `terraform plan` comentado no PR — pulado com aviso se a sessão do lab estiver fechada |
| *Run workflow* | `terraform apply` + plataforma no cluster, no ambiente escolhido |

Fase 4: o apply deixou de ser automático no merge. A infraestrutura sobe quando alguém vai
usá-la; o que é contínuo é o deploy dos serviços.

## Tecnologias

Terraform ~> 1.9 · AWS provider ~> 5.70 · Amazon EKS · RabbitMQ 4.3 · GitHub Actions
