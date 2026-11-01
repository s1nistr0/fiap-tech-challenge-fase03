# ToggleMaster — Tech Challenge Fase 3

Sistema de feature flags em 5 microsserviços, provisionado inteiro por IaC (Infrastructure as Code), publicado por pipeline DevSecOps e entregue no cluster por GitOps.

**Autor:** Guilherme Vicenti — RM375040

Este repositório é a Fase 3 do Tech Challenge. A Fase 2 entregou os microsserviços conteinerizados e os manifestos do Kubernetes. A Fase 3 troca o provisionamento manual por Terraform, o `docker build` local por um pipeline no GitHub Actions com portão de segurança, e o `kubectl apply` por reconciliação contínua via ArgoCD.

---

## 1. O que o sistema faz

O ToggleMaster decide, em tempo de execução, se uma funcionalidade está ligada para um usuário específico. Quem escreve a flag não é quem a avalia: a definição e as regras ficam em serviços separados do serviço que responde `true`/`false` no caminho quente.

| Serviço | Responsabilidade | Linguagem | Porta | Armazenamento |
|---|---|---|---|---|
| auth-service | Autenticação: emite e valida API key (Application Programming Interface key) | Go | 8001 | PostgreSQL |
| flag-service | Define a flag e o percentual de rollout | Python/Flask | 8002 | PostgreSQL |
| targeting-service | Regras de quem entra no rollout | Python/Flask | 8003 | PostgreSQL |
| evaluation-service | Responde true/false em milissegundos (caminho quente) | Go | 8004 | Redis + produz no SQS (Simple Queue Service) |
| analytics-service | Consome a fila e grava os eventos | Python/Flask | 8005 | SQS (Simple Queue Service) + DynamoDB |

Cada serviço vive no seu próprio namespace do Kubernetes: `auth`, `flags`, `targeting`, `evaluation`, `analytics`.

### A regra mnemônica dos dados

Três tecnologias de armazenamento porque são três problemas diferentes:

- **RDS (Relational Database Service) é a verdade** — a definição da flag e as regras de targeting, com consistência transacional.
- **Redis é a velocidade** — cache do evaluation-service, que é chamado em todo request do cliente final.
- **DynamoDB é o volume** — um item por avaliação, escrita intensiva, sem necessidade de join.

### Fluxo de uma requisição

```
                      Internet
                          |
                 Network Load Balancer
                          |
                  ingress-nginx (nginx)
         /auth  /flags  /rules  /evaluate  /analytics
            |      |       |        |          |
            v      v       v        v          v
         auth    flag  targeting  evaluation  analytics
         :8001  :8002   :8003      :8004       :8005
            |      |       |        |  |          |
            |      |       |        |  |          |
            |      |       |        |  +--> SQS --+
            |      |       |        |             |
            |      |       |        +--> Redis    +--> DynamoDB
            |      |       |          (cache)
            +------+-------+
                   |
            RDS PostgreSQL
         (3 instâncias, uma por serviço)
```

O evaluation-service consulta o Redis primeiro. No cache MISS ele chama flag-service e targeting-service, calcula a decisão, grava no cache com TTL (Time To Live) curto e responde. O evento da decisão é publicado de forma assíncrona na fila SQS (Simple Queue Service), que o analytics-service consome e grava no DynamoDB — o caminho quente não espera a escrita analítica.

---

## 2. Arquitetura na AWS

Tudo abaixo é criado pelo Terraform em `infra/`. Nada é clicado no console.

### Rede

| Item | Valor |
|---|---|
| VPC (Virtual Private Cloud) | `10.0.0.0/16` |
| Subnets públicas | `10.0.1.0/24` (us-east-1a), `10.0.2.0/24` (us-east-1b) |
| Subnets privadas | `10.0.11.0/24` (us-east-1a), `10.0.12.0/24` (us-east-1b) |
| NAT (Network Address Translation) Gateway | 1, compartilhado entre as duas zonas de disponibilidade |
| DNS (Domain Name System) | hostnames e suporte habilitados na VPC (Virtual Private Cloud) |

As subnets públicas levam a tag `kubernetes.io/role/elb` e as privadas `kubernetes.io/role/internal-elb`, que é como o controlador de serviço do Kubernetes descobre onde pode criar Load Balancer.

### Computação

| Item | Configuração |
|---|---|
| Cluster EKS (Elastic Kubernetes Service) | `togglemaster`, Kubernetes 1.34, endpoint público habilitado |
| Node group gerenciado | 2x `t3.medium` ON_DEMAND, min 2 / desejado 2 / max 4, nas subnets privadas |
| Addons do cluster | coredns, kube-proxy, vpc-cni, eks-pod-identity-agent, metrics-server |
| IRSA (IAM Roles for Service Accounts) | habilitado (`enable_irsa = true`) |

O `metrics-server` entra como addon do EKS (Elastic Kubernetes Service) porque o cluster não o traz de fábrica, e sem ele o HPA (Horizontal Pod Autoscaler) lê `cpu: <unknown>` e nunca escala. Junto com ele vai uma regra extra no Security Group dos nós liberando a porta 10251 a partir do Security Group do control plane — sem essa regra o APIService de métricas fica em `FailedDiscoveryCheck`.

### Armazenamento e mensageria

| Recurso | Configuração |
|---|---|
| RDS (Relational Database Service) PostgreSQL | 3 instâncias `db.t3.micro`, engine 16, 20 GB gp3, storage criptografado, `publicly_accessible = false` |
| ElastiCache Redis | 1 nó `cache.t3.micro`, engine 7.1, criptografia em trânsito e em repouso habilitadas |
| DynamoDB | tabela `ToggleMasterAnalytics`, partition key `event_id` (String), PAY_PER_REQUEST, criptografia habilitada |
| SQS (Simple Queue Service) | 1 fila Standard `togglemaster-events`, visibility timeout 30s, retenção 24h, SSE gerenciada |
| ECR (Elastic Container Registry) | 5 repositórios `togglemaster/<servico>`, com `scan_on_push` e `force_delete` |

As três instâncias de RDS (Relational Database Service) saem de um único bloco com `for_each` sobre um map: adicionar um quarto banco é adicionar uma linha, não copiar 25 linhas de HCL (HashiCorp Configuration Language).

O `scan_on_push` no ECR (Elastic Container Registry) é defesa em profundidade: o pipeline já escaneia a imagem antes do push, mas um CVE (Common Vulnerabilities and Exposures) publicado depois aparece no registro.

---

## 3. Estrutura do repositório

```
.
├── infra/                      terraform: toda a infraestrutura da AWS
│   ├── versions.tf             versões, providers e backend S3 (Simple Storage Service)
│   ├── variables.tf            região, nome, versão do kubernetes, CIDRs, map de bancos
│   ├── vpc.tf                  módulo da VPC (Virtual Private Cloud), subnet groups e Security Groups
│   ├── eks.tf                  módulo do EKS (Elastic Kubernetes Service), addons e node group
│   ├── data-stores.tf          RDS, Redis, DynamoDB, SQS, ECR e os segredos
│   ├── irsa.tf                 roles de IRSA (IAM Roles for Service Accounts) do evaluation e do analytics
│   ├── outputs.tf              endpoints, URLs do ECR e ARNs das roles
│   └── bootstrap.sh            cria o bucket do estado remoto antes do primeiro init
├── services/                   código dos 5 microsserviços, Dockerfiles e schema SQL
├── gitops/                     estado desejado do cluster — o que o ArgoCD reconcilia
│   ├── base/00-namespaces.yaml os 5 namespaces
│   ├── argocd/applications.yaml os 5 Applications do ArgoCD
│   └── <servico>/app.yaml      ConfigMap, Deployment, Service, Ingress, HPA e ServiceAccount
├── .github/workflows/          5 pipelines de CI (Continuous Integration), um por serviço
├── scripts/
│   ├── pos-apply.sh            o que acontece depois do apply: ArgoCD, ingress, secrets, schema
│   ├── gerar-secrets.sh        gera os Secrets do Kubernetes a partir da AWS
│   └── teardown.sh             derruba o ambiente na ordem correta
└── docker-compose.yml          ambiente local da Fase 2, para desenvolvimento
```

Cada serviço tem um único arquivo `app.yaml` com todos os seus objetos separados por `---`, em vez de seis arquivos pequenos: para entender um serviço inteiro, é um arquivo só.

---

## 4. Como o pipeline funciona

Cinco workflows, um por serviço, em `.github/workflows/ci-<servico>.yml`. O gatilho tem `paths`, então mexer no flag-service não dispara os cinco pipelines. `pull_request` roda build, lint e segurança; só `push` na `main` constrói e publica imagem.

Os cinco jobs, na ordem:

| # | Job | O que faz | Depende de |
|---|---|---|---|
| 1 | `build` | compila e roda teste unitário | — |
| 2 | `lint` | análise estática de qualidade | — |
| 3 | `seguranca` | SCA (Software Composition Analysis) + SAST (Static Application Security Testing) | `build`, `lint` |
| 4 | `imagem` | build da imagem, scan do contêiner, push para o ECR (Elastic Container Registry) | `seguranca` |
| 5 | `gitops` | atualiza a tag da imagem no manifesto e commita | `imagem` |

### O portão de segurança

O encadeamento por `needs:` é o ponto central. O job `seguranca` declara `needs: [build, lint]`, e os jobs `imagem` e `gitops` declaram `needs` apontando para ele. **Se o `seguranca` falha por vulnerabilidade CRÍTICA, os jobs `imagem` e `gitops` não são executados — não é que falhem depois de rodar, é que nem são agendados.** Nenhuma imagem vulnerável chega ao ECR (Elastic Container Registry) e nenhum commit de deploy chega ao `gitops/`.

Ferramentas, por tipo de análise:

| Etapa | Ferramenta | O que procura |
|---|---|---|
| SCA (Software Composition Analysis) | Trivy em modo `fs` (filesystem) | vulnerabilidade nas dependências de terceiros |
| SAST (Static Application Security Testing) em Go | gosec, `-severity high` | vulnerabilidade no código que escrevemos |
| SAST (Static Application Security Testing) em Python | bandit, `-lll` | mesma coisa, nos três serviços Flask |
| Scan do contêiner | Trivy em modo `image` | CVE (Common Vulnerabilities and Exposures) do sistema operacional base, que o scan de filesystem não vê |

Os dois passos do Trivy rodam com `severity: CRITICAL`, `exit-code: '1'` e `ignore-unfixed: true`. O `ignore-unfixed` descarta CVE (Common Vulnerabilities and Exposures) sem correção publicada: um portão que não pode ser atendido é um portão que alguém desliga na primeira sexta-feira.

O bandit roda em `-lll` (apenas severidade HIGH, o topo da escala dele) porque em `-ll` os três serviços Python barram por dois falso positivos: f-string de SQL (Structured Query Language) que interpola lista branca com valores parametrizados, e bind em `0.0.0.0`, que é requisito de contêiner.

O gosec é instalado com `go install` em vez de usar a action: a action roda a partir da raiz do repositório, e num monorepo não existe `go.mod` na raiz. Instalado na mão, ele roda dentro do módulo e encontra os pacotes.

### Cadeia de suprimentos e permissões

As actions de terceiro estão fixadas em SHA (Secure Hash Algorithm) de commit, não em tag móvel — `aquasecurity/trivy-action@a9c7b0f...` e `golangci/golangci-lint-action@8564da7...`. Tag é um ponteiro que o mantenedor pode mover; SHA não se move. As actions mantidas pelo GitHub e pela AWS (`actions/checkout`, `actions/setup-go`, `actions/setup-python`, `aws-actions/configure-aws-credentials`, `aws-actions/amazon-ecr-login`) seguem em tag de major.

O workflow declara `permissions: contents: read` no topo. Escrita é concedida **apenas** no job `gitops`, com `permissions: contents: write` local, porque ele é o único que commita. Se um passo de build for comprometido por uma dependência maliciosa, ele não consegue escrever no repositório.

---

## 5. Como o GitOps funciona

**O CI (Continuous Integration) não faz deploy.** Ele faz duas coisas: empurra a imagem para o ECR (Elastic Container Registry) com a tag `v1.0.0-<7 primeiros caracteres do hash do commit>`, e commita essa tag no manifesto em `gitops/<servico>/app.yaml`. Quem aplica no cluster é o ArgoCD.

A tag carrega o hash do commit de propósito: dada uma imagem rodando em produção, dá para chegar ao commit exato que a originou.

O job `gitops` usa `sed` para trocar a tag no manifesto e, em seguida, confere com `grep` que a troca aconteceu. `sed` que não casa não dá erro, só não faz nada — sem a conferência o pipeline ficaria verde sem ter feito deploy. A mensagem do commit automático leva `[skip ci]` para não disparar o próprio pipeline em laço. Como os cinco pipelines podem terminar juntos e empurrar na `main` ao mesmo tempo, o push tenta `git pull --rebase` até três vezes antes de desistir.

Do outro lado, os cinco Applications em `gitops/argocd/applications.yaml` amarram uma pasta do repositório a um namespace do cluster:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```

- **`prune: true`** — objeto removido do Git é removido do cluster. Sem isso o Git vira só "o que adicionar", nunca "o que remover", e o cluster acumula recursos que ninguém declarou mais.
- **`selfHeal: true`** — mudança feita na mão com `kubectl` é desfeita pelo ArgoCD. É o que torna o Git a fonte da verdade de verdade: editar o número de réplicas no cluster não dura, o reconciliador traz de volta ao que está declarado.

---

## 6. Segurança

### IRSA (IAM Roles for Service Accounts)

O ponto do enunciado sobre credenciais em arquivos de texto está resolvido na raiz. Dois serviços falam com a AWS, e nenhum dos dois carrega credencial.

A service account do pod recebe um token curto assinado pelo provedor OIDC (OpenID Connect) do cluster; o STS (Security Token Service) valida esse token e devolve credencial temporária. O SDK (Software Development Kit) da AWS resolve isso sozinho. **Não existe `AWS_ACCESS_KEY_ID` nem `AWS_SECRET_ACCESS_KEY` em nenhum manifesto do `gitops/`.**

A amarração é feita pela condição `sub` na política de confiança da role:

```hcl
condition {
  test     = "StringEquals"
  variable = "${module.eks.oidc_provider}:sub"
  values   = ["system:serviceaccount:evaluation:evaluation-sa"]
}
```

Isso trava a role em **um** namespace e **uma** service account. Um pod em outro namespace do mesmo cluster não assume a role. Sem essa condição, qualquer pod do cluster poderia.

Privilégio mínimo de verdade, em ARNs (Amazon Resource Name) específicas e nunca em `*`:

| Role | Permissões | Recurso |
|---|---|---|
| `togglemaster-evaluation-irsa` | `sqs:SendMessage`, `sqs:GetQueueUrl`, `sqs:GetQueueAttributes` | ARN da fila |
| `togglemaster-analytics-irsa` | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueUrl`, `sqs:GetQueueAttributes` | ARN da fila |
| `togglemaster-analytics-irsa` | `dynamodb:PutItem`, `GetItem`, `Query`, `Scan`, `DescribeTable` | ARN da tabela |

O evaluation-service só manda na fila: se o pod for comprometido, o atacante não lê nem apaga mensagem, e não toca no DynamoDB. O analytics-service recebe e apaga (apagar é parte do consumo no SQS — a mensagem só sai de vez com `DeleteMessage` depois de processada) e grava no DynamoDB, mas não tem `SendMessage`, porque não é produtor. Os outros três serviços só falam com PostgreSQL, então não têm role nenhuma.

### Senhas

Geradas pelo Terraform com `random_password` e guardadas no AWS Secrets Manager (`togglemaster/rds` e `togglemaster/auth-master-key`). Ninguém digita, ninguém commita, ninguém precisa saber qual é.

A senha é gerada com `special = false` de propósito: ela entra dentro de uma URL (Uniform Resource Locator) de conexão `postgres://user:senha@host`, e um `#` ou `/` ali corta a string no parser do driver. 32 caracteres alfanuméricos já dão entropia de sobra.

Os outputs do Terraform expõem apenas o **nome** do segredo, nunca o valor: output não-sensitive vai para o log do terminal e para o log do CI (Continuous Integration). Para ler a senha:

```bash
aws secretsmanager get-secret-value --secret-id togglemaster/rds
```

### Os Secrets do Kubernetes não estão no Git

Isso é decisão, não esquecimento. **O repositório é público.** Os Secrets são gerados por `scripts/gerar-secrets.sh`, que consulta o Secrets Manager e as APIs (Application Programming Interface) de RDS, ElastiCache e SQS para montar os valores reais, e são aplicados fora da banda:

```bash
./scripts/gerar-secrets.sh | kubectl apply -f -
```

Se estivessem no Git como placeholder, haveria um problema pior que o vazamento: o ArgoCD com `selfHeal: true` reverteria o valor real para o placeholder na próxima reconciliação, e os pods cairiam em `CrashLoopBackOff` — as três aplicações com banco encerram o processo se não conseguirem conectar.

O script também não chuta valores. Ele consulta `TransitEncryptionEnabled` do Redis na API (Application Programming Interface) para decidir entre `redis://` e `rediss://`, em vez de deixar o esquema chumbado: se a configuração mudar no Terraform, o script acompanha.

O caminho completo em produção seria o **External Secrets Operator**: um controlador no cluster que lê o Secrets Manager e materializa o Secret do Kubernetes continuamente. Aí o Git declararia a referência ao segredo, não o segredo, e a geração fora da banda deixaria de existir.

### Security Groups

As portas 5432 (PostgreSQL) e 6379 (Redis) são liberadas a partir do **Security Group dos nós do EKS (Elastic Kubernetes Service)**, não de um bloco CIDR (Classless Inter-Domain Routing):

```hcl
ingress {
  description     = "postgres a partir dos nos do eks"
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [module.eks.node_security_group_id]
}
```

A diferença é conceitual: isso autoriza uma **identidade**, não um endereço de rede. Se a faixa da subnet mudar, a regra continua correta; e nada que não seja um nó do cluster alcança o banco, mesmo estando na mesma VPC (Virtual Private Cloud). Os bancos estão em subnet privada e com `publicly_accessible = false`.

### Bucket do estado do Terraform

O `terraform.tfstate` guarda a senha do RDS (Relational Database Service) em texto puro dentro dele. Criptografia ali não é enfeite. O `infra/bootstrap.sh` cria o bucket com:

- versionamento habilitado — se o estado corromper, dá para voltar na versão anterior do objeto;
- criptografia padrão AES256 (Advanced Encryption Standard, 256 bits) com bucket key;
- bloqueio público total (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`).

O `.gitignore` bloqueia `*.tfstate`, `*.tfvars`, `.terraform/` e o arquivo de plano — o plano tem o estado inteiro embutido, com a senha dentro.

---

## 7. Como executar

Pré-requisitos: AWS CLI (Command Line Interface) autenticada, Terraform >= 1.10, `kubectl`, `helm`, Docker.

### 7.1 Conferir a versão do Kubernetes

Versão fora do suporte padrão custa cerca de cinco vezes mais por hora no control plane.

```bash
aws eks describe-cluster-versions --region us-east-1 \
  --query 'clusterVersions[?versionStatus==`STANDARD_SUPPORT`].clusterVersion'
```

Se `1.34` não estiver na lista, ajustar `var.versao_kubernetes` em `infra/variables.tf`.

### 7.2 Bucket do estado remoto

Ovo e galinha: o backend S3 (Simple Storage Service) declarado em `versions.tf` precisa do bucket existindo antes do primeiro `terraform init`. Por isso esta etapa é shell e não Terraform.

```bash
cd infra
chmod +x bootstrap.sh && ./bootstrap.sh
```

### 7.3 Provisionar a infraestrutura

```bash
terraform init
terraform plan -out=plano
terraform apply plano          # 20 a 25 minutos
```

Ao terminar:

```bash
terraform output                                  # endpoints, urls do ecr, arns das roles
aws eks update-kubeconfig --region us-east-1 --name togglemaster
kubectl get nodes                                 # 2 nós Ready
```

### 7.4 Preparar o cluster

O Terraform entrega a infraestrutura; o `scripts/pos-apply.sh` entrega o cluster utilizável — e é idempotente, rodar de novo não quebra nada.

```bash
./scripts/pos-apply.sh
```

Ele executa, na ordem:

1. aponta o `kubectl` para o cluster;
2. instala o ArgoCD via Helm;
3. instala o ingress-nginx como `LoadBalancer` do tipo NLB (Network Load Balancer) — sem controlador, um objeto Ingress é só um registro no etcd e o ArgoCD deixa o Application em `Progressing` para sempre;
4. cria os namespaces e aplica os Secrets gerados;
5. aplica o schema dos três bancos (o RDS entrega banco vazio, e os bancos só aceitam conexão dos nós, então o `psql` roda de dentro do cluster);
6. aplica os Applications do ArgoCD;
7. gera a API key (Application Programming Interface key) de serviço do evaluation-service, que só existe depois do auth-service estar no ar, e regera o Secret.

Para fazer as etapas na mão, o essencial é:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace --wait

# senha inicial do admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# interface
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### 7.5 O único `kubectl apply` do projeto

```bash
kubectl apply -f gitops/argocd/applications.yaml
```

Esse comando é o **bootstrap do GitOps** e é aplicado uma vez só: alguém precisa dizer ao ArgoCD onde olhar. Daí para frente nenhum deploy passa por `kubectl` — o CI (Continuous Integration) commita a tag no `gitops/`, o ArgoCD detecta e reconcilia.

### 7.6 Conferir

```bash
kubectl get applications -n argocd     # os 5 Synced / Healthy
kubectl get pods -A
kubectl get hpa -A                     # TARGETS com percentual, não <unknown>

LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl "http://$LB/auth/health"
curl "http://$LB/evaluate?user_id=u1&flag_name=enable-new-dashboard"
```

### 7.7 Teardown — a ordem importa

O Terraform **não conhece** os recursos que o Kubernetes criou na AWS, e o Load Balancer do ingress-nginx é o maior deles. Rodando `terraform destroy` direto, ele tenta apagar a VPC (Virtual Private Cloud), a VPC recusa porque tem um Load Balancer dentro, e o destroy trava depois de uns 20 minutos — com o Load Balancer órfão cobrando por hora.

```bash
./scripts/teardown.sh
```

O script remove os Applications (senão o ArgoCD recria os Deployments enquanto se apaga), remove os Ingress, desinstala ingress-nginx e ArgoCD, **espera o Load Balancer sumir da AWS** consultando a API (Application Programming Interface) em laço, e só então roda `terraform destroy`.

Varredura final no console, porque o destroy às vezes deixa coisa para trás: EC2 (Elastic Compute Cloud) → Instances, Volumes, Elastic IPs, Load Balancers · VPC (Virtual Private Cloud) · CloudWatch Log Groups · ECR (Elastic Container Registry) · Secrets Manager.

---

## 8. Decisões técnicas e trade-offs

| Decisão | Motivo | Em produção |
|---|---|---|
| NAT (Network Address Translation) Gateway único, compartilhado entre as duas zonas de disponibilidade | Custo. É o maior item isolado da conta e cobra por hora mesmo sem tráfego | Um por zona de disponibilidade. Com um só, a queda daquela zona corta a saída para a internet de todas as subnets privadas |
| Lock do estado via `use_lockfile` no backend S3 (Simple Storage Service), sem tabela DynamoDB | Recurso nativo a partir do Terraform 1.10, e não há concorrência neste cenário — um operador, uma máquina | Tabela DynamoDB ou o lockfile do S3 (Simple Storage Service) continuam válidos; o que muda é que com equipe o lock passa a ser obrigatório na prática, não opcional |
| Módulos oficiais da comunidade para VPC (Virtual Private Cloud) e EKS (Elastic Kubernetes Service) | `terraform-aws-modules/vpc` e `terraform-aws-modules/eks` resolvem tabela de rotas, tags de subnet, OIDC (OpenID Connect) provider e Security Groups do control plane. Reescrever isso é reintroduzir bugs já corrigidos | O mesmo, com a versão travada e um fork interno auditado se houver requisito de cadeia de suprimentos |
| Credencial do GitHub Actions por access key de usuário IAM (Identity and Access Management) restrito ao ECR (Elastic Container Registry) | Mais rápido de montar e depurar dentro do prazo. A permissão é mínima: apenas ECR | OIDC (OpenID Connect) federado com role assumida por `sts:AssumeRoleWithWebIdentity` e condição no `sub` do repositório. Elimina credencial de longa duração. Mapeado como próximo passo |
| ArgoCD e ingress-nginx instalados via Helm no script de pós-apply, não via provider Terraform | Mais rápido de depurar, e desacopla o ciclo de vida do add-on do ciclo de vida da infraestrutura | Bootstrap do ArgoCD por Terraform ou por um Application "app of apps", com os add-ons também sob GitOps |
| `backup_retention_period = 0`, `skip_final_snapshot = true`, `deletion_protection = false` no RDS (Relational Database Service) | O ambiente é descartável e provisionado por código. Essas três linhas existem para o destroy rodar limpo e não deixar snapshot cobrando | Exatamente o oposto: retenção >= 7 dias, snapshot final habilitado, proteção contra exclusão ligada |
| Redis com 1 nó e `automatic_failover_enabled = false` | Sem réplica não há para onde fazer failover. Decisão de custo, igual ao NAT (Network Address Translation) Gateway único | Replication group com réplica em outra zona de disponibilidade e failover automático |
| `ignore-unfixed: true` no Trivy | Portão que não pode ser atendido é portão que alguém desliga. CVE (Common Vulnerabilities and Exposures) sem correção publicada não tem ação possível no build | O mesmo, somado a um processo de exceção com prazo para CVE (Common Vulnerabilities and Exposures) sem fix |
| `lint` com `--exit-zero` no Python | Quem bloqueia o deploy é o portão de segurança, não estilo de código | Lint bloqueante, depois de um passe de formatação no código base |
| Um arquivo `app.yaml` por serviço, em vez de Kustomize ou Helm chart | Para um ambiente só, overlay é indireção sem ganho. O `sed` do pipeline atua num único ponto previsível | Kustomize com overlay por ambiente, ou Helm chart com values por ambiente, e a tag atualizada pelo ArgoCD Image Updater |

---

## 9. Custos

Com tudo ligado, o ambiente custa aproximadamente **US$ 0,33 por hora**, o que daria cerca de **US$ 240 por mês** se ficasse ligado o mês inteiro.

Maiores itens, em ordem de peso:

| Item | Observação |
|---|---|
| Control plane do EKS (Elastic Kubernetes Service) | preço fixo por hora de cluster, independente de carga |
| 2 nós EC2 (Elastic Compute Cloud) `t3.medium` | cobrados por hora de instância ligada |
| NAT (Network Address Translation) Gateway | **cobra por hora mesmo sem tráfego**, além do custo por GB processado |
| 3 instâncias RDS (Relational Database Service) `db.t3.micro` | três instâncias porque são três bancos independentes |
| Network Load Balancer do ingress-nginx | criado pelo Kubernetes, não pelo Terraform — e é por isso que o teardown tem ordem |

O ponto que importa: **o ambiente é provisionado e destruído por código, não mantido ligado.** O número de US$ 240 por mês é a projeção de um cenário que não acontece — o ciclo real é `terraform apply`, demonstrar, `teardown.sh`. Infraestrutura ligada sem uso é só prejuízo, e o NAT (Network Address Translation) Gateway cobra por hora mesmo parado.
