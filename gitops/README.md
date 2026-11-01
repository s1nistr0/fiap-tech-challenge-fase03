# gitops/

Fonte da verdade do que roda no cluster. O ArgoCD observa esta pasta e
reconcilia o estado do Kubernetes contra ela. Ninguém roda `kubectl apply`
aqui — a única exceção é `argocd/applications.yaml`, que é o bootstrap.

## Estrutura

```
base/00-namespaces.yaml   os 5 namespaces
argocd/applications.yaml  um Application por serviço (bootstrap, aplicado 1x)
<servico>/app.yaml        tudo daquele serviço junto, separado por ---
```

Um arquivo por serviço em vez de trinta arquivinhos: para entender o
evaluation-service inteiro, é um arquivo só.

| Pasta | Objetos no `app.yaml` |
|---|---|
| `auth-service/` | ConfigMap, Deployment, Service, Ingress |
| `flag-service/` | ConfigMap, Deployment, Service, Ingress |
| `targeting-service/` | ConfigMap, Deployment, Service, Ingress |
| `evaluation-service/` | ServiceAccount, ConfigMap, Deployment, Service, Ingress, HPA |
| `analytics-service/` | ServiceAccount, ConfigMap, Deployment, Service, Ingress, HPA |

## O que NÃO está aqui, e por quê

**Secret.** Nenhum. O repositório é público e os Secrets carregam senha de
banco. Eles são gerados por `scripts/gerar-secrets.sh`, que busca os valores
no AWS Secrets Manager e nas APIs de RDS, ElastiCache e SQS, e aplicados
fora da banda.

Se estivessem aqui como placeholder, o problema seria pior que o vazamento:
o ArgoCD com `selfHeal: true` reverteria o valor real para o placeholder na
reconciliação seguinte, e os pods cairiam em `CrashLoopBackOff`.

Os Deployments continuam referenciando o Secret por `secretRef` — o objeto
existe no cluster, só não no Git.

**Namespace dentro do `app.yaml`.** Ficam em `base/00-namespaces.yaml`,
aplicados antes de tudo, porque os Secrets precisam do namespace existindo.

## Quem edita a tag da imagem

O pipeline. O job `gitops` de cada workflow troca a tag em
`gitops/<servico>/app.yaml` por `v1.0.0-<7 primeiros do hash do commit>` e
commita com `[skip ci]` na mensagem, para não disparar a si mesmo em laço.

Editar a tag na mão aqui funciona, mas o próximo push no serviço sobrescreve.

## ServiceAccount e IRSA

Só `evaluation-service` e `analytics-service` têm ServiceAccount, porque são
os dois que falam com a AWS. A annotation `eks.amazonaws.com/role-arn`
amarra a service account a uma role com privilégio mínimo, e o Deployment
referencia por `serviceAccountName`.

Sem o `serviceAccountName`, o pod usa a service account `default`, que não
tem role nenhuma, e o SDK da AWS falha ao autenticar.

Os outros três só falam com PostgreSQL e não precisam de role.
