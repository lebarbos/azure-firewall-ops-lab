# Azure Firewall — laboratório de operação

Laboratório prático, em português, para quem **opera** o Azure Firewall no dia a dia. O aluno cria regras, prova o efeito de cada mudança com KQL, organiza policies em hierarquia pai/filha, configura observabilidade e alertas e, opcionalmente, ativa TLS inspection e IDPS.

> [!WARNING]
> **Custo real.** O ambiente custa **≈ US$ 4/hora** (dois Azure Firewall Premium, um hub de Virtual WAN, Bastion, duas VMs e Policy Analytics). Se ficar ligado por engano, são **≈ US$ 106/dia**. O cleanup verificado no fim do guia é **obrigatório**.

## O que você vai praticar

| Exercício | Tema |
|---|---|
| Ex0 | Preflight (região e SKU), deploy da base e validação |
| Ex1 | Diagnostic settings, Policy Analytics, IP Groups, primeiras regras de rede (E-W) e de aplicação (N-S), KQL e workbook |
| Ex2 | Precedência: Rule Collection Group × Rule Collection × tipo de regra (Network → Application) |
| Ex3 | Firewall Manager: policy pai e filhas, herança e guardrails |
| Ex4 | Policy Analytics: regras pouco usadas, principais fluxos e análise de uma regra |
| Ex5 | Alertas de métrica com Action Group |
| Ex6 | *(opcional)* TLS inspection, filtragem de URL, web categories e IDPS |

## Arquitetura (resumo)

- **Secured Virtual WAN hub** com um Azure Firewall Premium que inspeciona o tráfego **leste-oeste** entre as spokes (Routing Intent apenas para tráfego privado).
- **VNet norte-sul fora do Virtual WAN**, com um segundo Azure Firewall Premium pareado diretamente às spokes. Uma UDR `0.0.0.0/0` nas spokes envia a saída para a Internet por esse firewall.
- **Duas spokes**, cada uma com uma VM Windows Server 2022 (IIS), sem IP público.
- **Azure Bastion** (Basic) na VNet norte-sul para acesso administrativo e um **Log Analytics workspace** para os logs estruturados.

O guia traz o diagrama completo, a tabela de rotas efetivas e a ordem de processamento das regras.

## Como começar

1. Abra o **guia do aluno**: <https://lebarbos.github.io/azure-firewall-ops-lab/> (ou `docs/index.html` deste repositório, que funciona offline).
2. No [Azure Cloud Shell](https://shell.azure.com) (Bash):

   ```bash
   az bicep install
   git clone https://github.com/lebarbos/azure-firewall-ops-lab.git
   cd azure-firewall-ops-lab
   ./scripts/preflight.sh
   ./scripts/deploy.sh
   ```

3. Siga o guia a partir do **Ex0**.

**Pré-requisitos:** uma assinatura Azure própria (por exemplo, uma conta de avaliação) com permissão de *Owner* ou *Contributor*, e um navegador. Nada precisa ser instalado na sua máquina.

## Estrutura do repositório

| Caminho | Conteúdo |
|---|---|
| `lab.contract.json` | Fonte única de nomes, endereços e prioridades (usada pelo Bicep, pelo guia e pelos scripts) |
| `infra/` | Base em Bicep (`main.bicep` + módulos) |
| `guest/` | Script de bootstrap das VMs |
| `scripts/` | Preflight, deploy, checkpoints e cleanup (Bash, para o Cloud Shell) |
| `queries/` | Consultas KQL usadas nos exercícios |
| `guide/` | Fonte do guia (partials HTML + `build.py`) |
| `docs/` | Guia gerado (`index.html`), publicado no GitHub Pages |
| `tests/` | Testes do guia, do contrato e dos scripts (com `az` simulado, sem acessar o Azure) |

## Licença

[MIT](LICENSE). Atribuições de terceiros em [NOTICE.md](NOTICE.md).

Este é um material de treinamento, não um produto. Ele cria recursos com configurações simplificadas (sem zonas de disponibilidade, VMs com senha, certificado autoassinado no Ex6) que **não** devem ser usadas em produção.
