# ToggleMaster — Tech Challenge Fase 3

Sistema de feature flags em 5 microsserviços, provisionado inteiro por IaC
(Infrastructure as Code), publicado por pipeline DevSecOps e entregue no
cluster por GitOps.

**Autor:** Guilherme da Silva Vicenti — RM375040

A Fase 2 entregou os microsserviços conteinerizados. A Fase 3 troca o
provisionamento manual por Terraform, o `docker build` local por um pipeline
no GitHub Actions com portão de segurança, e o `kubectl apply` por
reconciliação contínua via ArgoCD.

---

## Os serviços

| Serviço | Papel | Linguagem | Persistência |
|---|---|---|---|
| auth-service | Autenticação e chaves de API (Application Programming Interface) | Go | PostgreSQL |
| flag-service | Define as flags e o percentual de rollout | Python / Flask | PostgreSQL |
| targeting-service | Regras de segmentação de público | Python / Flask | PostgreSQL |
| evaluation-service | Responde verdadeiro ou falso em milissegundos | Go | Redis, produz no SQS |
| analytics-service | Consome a fila e contabiliza eventos | Python / Flask | SQS, DynamoDB |

A divisão de armazenamento atende três necessidades distintas: o PostgreSQL
guarda a verdade transacional, o Redis entrega velocidade no caminho quente da
avaliação, e o DynamoDB absorve o volume de eventos.

---

## As três camadas da Fase 3

**Terraform.** VPC (Virtual Private Cloud) com 4 subnets em 2 zonas de
disponibilidade e NAT (Network Address Translation) Gateway único, cluster EKS
(Elastic Kubernetes Service) 1.34 com 2 nós em subnets privadas, 3 instâncias
RDS (Relational Database Service) PostgreSQL, ElastiCache Redis, DynamoDB, SQS
(Simple Queue Service), 5 repositórios ECR (Elastic Container Registry),
Secrets Manager e as roles de IRSA (IAM Roles for Service Accounts). Estado
remoto em bucket S3 (Simple Storage Service) versionado e criptografado, com
trava por `use_lockfile`.

**Pipeline DevSecOps.** Cinco workflows no GitHub Actions, um por serviço,
encadeados por `needs:`:

```
build  ─┐
        ├─> seguranca ──> imagem ──> gitops
lint   ─┘
```

O job `seguranca` roda SCA (Software Composition Analysis) com `trivy fs` e
SAST (Static Application Security Testing) com `gosec` ou `bandit`. Reprova em
severidade CRITICAL **com correção publicada** — `ignore-unfixed: true`, porque
barrar o que não tem conserto gera ruído e leva equipes a desligar o portão.
O job `imagem` roda um segundo scan, agora sobre a imagem construída.

Como `imagem` e `gitops` declaram dependência de `seguranca`, uma reprovação os
deixa como *skipped*: a imagem vulnerável não é construída, não chega ao
registro e não chega perto do cluster.

**GitOps.** Cinco Applications do ArgoCD, um por serviço, com `prune: true` e
`selfHeal: true`. O job `gitops` do pipeline altera a tag da imagem no
manifesto e commita com `[skip ci]` — sem isso o commit dispararia o próprio
pipeline em laço. O ArgoCD detecta e reconcilia.

---

## Segurança

**Nenhuma credencial da AWS nos manifestos.** Cada service account está
amarrada por OIDC (OpenID Connect) a uma role com condição explícita de `sub`
igual a `system:serviceaccount:<namespace>:<service account>`. Permissões por
ARN (Amazon Resource Name) específica, nunca com curinga: a role do evaluation
só envia na fila; a do analytics só recebe da fila e grava no DynamoDB.

**Senhas geradas pelo Terraform** e guardadas no Secrets Manager. Nunca passam
por arquivo do repositório. Os Secrets do Kubernetes são montados em tempo de
execução pelo `scripts/gerar-secrets.sh`, a partir da API da AWS.

**Security Groups por identidade, não por endereço.** As portas 5432 e 6379
são liberadas a partir do Security Group dos nós, não de uma faixa de IP.

**Ações de terceiro fixadas por SHA** de 40 caracteres, não por tag móvel —
esses jobs têm acesso aos secrets da conta. Permissão `contents: read` no
nível do workflow, `contents: write` apenas no job que precisa commitar.

**Estado do Terraform nunca commitado.** O arquivo de estado e o de plano
contêm a senha do RDS em texto puro, e o repositório é público. O `.gitignore`
cobre `*.tfstate*`, `plano`, `plano-*` e `*.tfplan`.

---

## Estrutura

```
infra/                      terraform
├── versions.tf             provedores e backend s3
├── variables.tf            entradas parametrizaveis
├── vpc.tf · eks.tf         rede, cluster e grupo de nos
├── data-stores.tf          rds, redis, dynamodb, sqs, ecr, secrets
├── irsa.tf                 roles amarradas por oidc
├── outputs.tf              saidas consumidas pelos scripts
└── bootstrap.sh            cria o bucket do estado

.github/workflows/          cinco pipelines
gitops/
├── base/00-namespaces.yaml
├── argocd/applications.yaml
└── <servico>/app.yaml      um manifesto por servico
services/                   codigo dos cinco microsservicos
scripts/
├── pos-apply.sh            cluster utilizavel apos o terraform
├── gerar-secrets.sh        secrets a partir do secrets manager
├── teardown.sh             desmonte na ordem correta
├── varredura-orfaos.sh     conferencia de recursos remanescentes
└── gerar-pdf.sh            relatorio em pdf a partir do markdown
docs/                       relatorio, custos, desafios, roteiro
```

---

## Como executar

Pré-requisitos: AWS CLI autenticada, Terraform 1.10 ou superior, `kubectl`,
`helm`, Docker, `gh`.

```bash
# 1. conferir se a versao do kubernetes esta no suporte padrao
#    versao fora dele custa cerca de 5x mais por hora no control plane
aws eks describe-cluster-versions --region us-east-1 \
  --query 'clusterVersions[?versionStatus==`STANDARD_SUPPORT`].clusterVersion'

# 2. bucket do estado remoto (precisa existir antes do terraform)
cd infra && ./bootstrap.sh

# 3. infraestrutura (20 a 25 minutos)
terraform init
terraform plan -out=plano
terraform apply plano

# 4. imagens no registro
#    repositorio ECR recriado nasce vazio: os pipelines reconstroem
for s in auth flag targeting evaluation analytics; do
  gh workflow run ci-$s-service.yml
done

# 5. cluster utilizavel
cd .. && git pull           # traz os commits de tag feitos pelos pipelines
./scripts/pos-apply.sh
```

O `pos-apply.sh` é idempotente. Ele aponta o `kubectl` para o cluster, confere
que o ECR tem as imagens que os manifestos pedem, instala o ArgoCD e o
ingress-nginx, cria namespaces e Secrets, aplica o schema dos três bancos — o
RDS entrega banco vazio, sem o gancho de inicialização que a imagem do
PostgreSQL tem — registra os Applications e gera a chave de serviço do
evaluation-service.

### Acessar o ArgoCD

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Usuário `admin` em `https://localhost:8080`.

### O único `kubectl apply` do projeto

```bash
kubectl apply -f gitops/argocd/applications.yaml
```

É o bootstrap do GitOps, aplicado uma vez: alguém precisa dizer ao ArgoCD onde
olhar. Daí em diante nenhum deploy passa por `kubectl`.

### Teardown — a ordem importa

```bash
./scripts/teardown.sh
./scripts/varredura-orfaos.sh
```

O Terraform não conhece os recursos que o Kubernetes criou na AWS, e o Load
Balancer do ingress-nginx é o maior deles. Rodar `terraform destroy` direto
trava: a VPC recusa ser apagada por ter um Load Balancer dentro, e ele fica
órfão cobrando. O script remove os Applications, remove os Ingress, desinstala
os charts, **espera o Load Balancer sumir da AWS** consultando a API em laço, e
só então chama o destroy.

A varredura confere 14 categorias de recurso que costumam escapar, incluindo
Elastic IPs não associados e volumes EBS (Elastic Block Store) em `available` —
os dois cobram justamente quando estão ociosos.

---

## Decisões e trade-offs

| Decisão | Alternativa ideal | Motivo |
|---|---|---|
| NAT Gateway único | Um por zona de disponibilidade | Custo. Foi o maior item isolado da conta. Ponto único de falha assumido. |
| Access key para o GitHub Actions | OIDC com role federada | Tempo. O código do provedor está escrito como próximo passo. |
| Trava do estado por `use_lockfile` | Tabela DynamoDB dedicada | Operador único, sem concorrência. |
| `gitops/` no mesmo repositório | Repositório separado | Permitido pelo enunciado. Evita token entre repositórios. |
| ArgoCD por Helm, fora do Terraform | Provider do Terraform | Mais rápido de depurar. |
| RDS sem backup, sem snapshot final, sem proteção contra remoção | O oposto dos três | Ambiente descartável. As linhas estão marcadas no código. |

---

## Custos

US$ 2,40 no total. O dia seguinte ao desmonte custou zero — confirmação de que
o teardown removeu tudo. O NAT Gateway sozinho respondeu por US$ 0,49, acima do
control plane do EKS.

Detalhamento em [`docs/CUSTOS.md`](docs/CUSTOS.md).

---

## Documentação

| Documento | Conteúdo |
|---|---|
| [`docs/RELATORIO.md`](docs/RELATORIO.md) | Relatório da entrega |
| [`docs/DESAFIOS-ENCONTRADOS.md`](docs/DESAFIOS-ENCONTRADOS.md) | Cada problema enfrentado, com sintoma, causa e correção |
| [`docs/CUSTOS.md`](docs/CUSTOS.md) | Custo medido, por serviço e por tipo de uso |
| [`docs/ROTEIRO-VIDEO.md`](docs/ROTEIRO-VIDEO.md) | Roteiro e narração do vídeo |
