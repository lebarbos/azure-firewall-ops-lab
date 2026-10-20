# Guia do aluno — como o HTML é montado

O guia publicado é **um único arquivo**, `docs/index.html`, autocontido (CSS, JS e SVG embutidos, sem CDN, sem fonte externa). Ele funciona no GitHub Pages e aberto direto do disco (`file://`).

Ninguém edita `docs/index.html` à mão. A fonte fica em `guide/src/` e o `guide/build.py` monta o arquivo.

```bash
python3 guide/build.py          # gera docs/index.html
python3 guide/build.py --check  # sai com código 1 se docs/index.html estiver desatualizado
```

O build usa **só a biblioteca padrão do Python 3.9+** e é **determinístico**: a mesma fonte gera o mesmo arquivo, byte a byte (sem data/hora no HTML).

## Estrutura

```text
guide/
├── build.py
├── README.md                 este arquivo (a especificação)
└── src/
    ├── _layout.html          casca da página (arquivos com "_" não são partials)
    ├── 00-inicio.html  …  12-creditos.html
    └── assets/
        ├── styles.css
        ├── app.js
        ├── arquitetura.svg
        └── processamento.svg
```

## Partials e seções

Os partials são os arquivos `guide/src/[0-9][0-9]-*.html`, concatenados em ordem alfabética. Partial ausente é ignorado (o build não falha), para que o guia possa ser escrito por partes.

Cada partial contém **exatamente uma** seção de primeiro nível:

```html
<section class="chapter" id="ex1" data-title="Ex1 · Observabilidade e primeiras regras">
  <h2>Ex1 · Observabilidade e primeiras regras</h2>
  …
</section>
```

| Arquivo | `id` da seção | `data-title` (menu lateral) |
|---|---|---|
| `00-inicio.html` | `inicio` | Início |
| `01-arquitetura.html` | `arquitetura` | Arquitetura |
| `02-conceitos.html` | `conceitos` | Conceitos |
| `03-ex0.html` | `ex0` | Ex0 · Preparação e deploy |
| `04-ex1.html` | `ex1` | Ex1 · Observabilidade e primeiras regras |
| `05-ex2.html` | `ex2` | Ex2 · Precedência das regras |
| `06-ex3.html` | `ex3` | Ex3 · Policy pai e filhas |
| `07-ex4.html` | `ex4` | Ex4 · Policy Analytics |
| `08-ex5.html` | `ex5` | Ex5 · Alertas de métrica |
| `09-ex6.html` | `ex6` | Ex6 · TLS, URL e IDPS (opcional) |
| `10-cleanup.html` | `cleanup` | Cleanup verificado |
| `11-kql.html` | `kql` | Referência KQL |
| `12-troubleshooting.html` | `troubleshooting` | Troubleshooting |
| `13-creditos.html` | `creditos` | Créditos e licenças |

Capítulos de referência (`inicio`, `arquitetura`, `conceitos`, `kql`, `troubleshooting`, `creditos`) declaram `data-progress="off"` na `<section>`. Nesses capítulos, `article.step` serve só de layout: o JavaScript não cria a caixa "Concluído" e eles não entram no contador de progresso. Só os exercícios (`ex0`–`ex6`) e o `cleanup` contam.

### Menu lateral

O `build.py` gera o menu lateral **no build** (funciona sem JavaScript):

- um item por seção (`id` + `data-title`);
- um subitem para **todo elemento dentro da seção que tenha `id` e `data-nav`**, na ordem em que aparece.

### Âncoras

- Seção: o `id` da tabela acima.
- Passo: `<seção>-<n>` → `ex1-1`, `ex1-2`, `ex3-5`.
- Experimento do Ex2: `ex2-e1` … `ex2-e4`.
- Troubleshooting: `ts-<tema>` → `ts-quota`, `ts-cse`.
- Âncoras são **estáveis**: o progresso do aluno fica salvo por `id`. Não renomeie depois de publicado.

## Placeholders

O `build.py` resolve os placeholders abaixo. Placeholder desconhecido, caminho inexistente no contrato ou arquivo ausente **faz o build falhar** com `arquivo:linha`.

| Placeholder | Vira |
|---|---|
| `{{c.<caminho>}}` | Valor de `lab.contract.json` pelo caminho com pontos (`{{c.names.fwNs}}` → `fw-fwlab-ns`; `{{c.rcg.wlA.priority}}` → `200`; índice numérico em listas: `{{c.regions.0}}`). Listas de escalares viram texto separado por `, `. Objeto → erro. O valor é escapado para HTML |
| `{{kql:<stem>}}` | Bloco completo com o conteúdo de `queries/<stem>.kql` (escapado), legenda com o nome do arquivo e botão Copiar. Use **sozinho numa linha**, fora de `<p>` e de `<pre>` |
| `{{svg:<nome>}}` | Conteúdo inline de `guide/src/assets/<nome>.svg` |
| `{{nav}}` `{{content}}` `{{css}}` `{{js}}` | Só no `_layout.html` |

Para escrever `{{` literal no texto, use `&#123;&#123;`.

## Componentes

### Passo (anatomia obrigatória)

```html
<article class="step" id="ex1-1" data-nav="1.1 Diagnostic settings">
  <h3>1.1 · Configurar os diagnostic settings</h3>
  <p class="what"><strong>O que:</strong> uma linha.</p>
  <div class="why"><p><strong>Por que:</strong> o conceito, curto.</p></div>
  <div class="portal">
    <h4>Portal</h4>
    <ol>
      <li>Abra <span class="path">Firewalls › {{c.names.fwNs}} › Monitoring › Diagnostic settings</span>.</li>
      <li>Clique em <span class="ui">+ Add diagnostic setting</span>.</li>
    </ol>
  </div>
  <details class="cli">
    <summary>CLI</summary>
    <pre class="code" data-lang="bash"><code>az network firewall show -g {{c.names.rg}} -n {{c.names.fwNs}} -o table</code></pre>
  </details>
  <div class="verify"><p><strong>Verifique:</strong> resultado esperado.</p></div>
</article>
```

- **O que / Por que / Portal / CLI / Verifique**, nessa ordem. O bloco Portal fica sempre visível; o CLI fica recolhido.
- Sem equivalente no CLI: `<details class="cli"><summary>CLI</summary><p class="no-cli">Sem equivalente direto no CLI: motivo.</p></details>`.
- O JavaScript acrescenta a cada `.step` e `.experiment` um checkbox de "concluído" (salvo no `localStorage`).

### Experimento (Ex2 e Ex3)

```html
<article class="experiment" id="ex2-e1" data-nav="E1 · Ordem entre RCGs">
  <h3>E1 · Ordem entre Rule Collection Groups</h3>
  <div class="predict">
    <p class="predict-title">Previsão</p>
    <p>A pergunta que o aluno responde <em>antes</em> de testar.</p>
  </div>
  <!-- passos de teste: mesmos blocos .portal / details.cli / .verify -->
  <details class="answer">
    <summary>Ver resposta</summary>
    <p>Resultado, explicação e a consulta que prova.</p>
    {{kql:ex2-precedencia}}
  </details>
</article>
```

O JavaScript acrescenta ao `.predict` um campo de texto para o aluno registrar a previsão (salvo no `localStorage`).

### Blocos de código

```html
<pre class="code" data-lang="bash"><code>…</code></pre>
```

| `data-lang` | Rótulo exibido | Onde roda |
|---|---|---|
| `bash` | Cloud Shell · Bash | Azure Cloud Shell |
| `powershell` | VM · PowerShell | Dentro da VM (RDP pelo Bastion) |
| `kql` | KQL · Log Analytics | `law-fwlab` › Logs |
| `json` | JSON | — |
| `text` | Saída esperada | — |

O JavaScript acrescenta o botão **Copiar** a todo `pre.code`. Dentro de `<code>`, escape `<` `>` `&` como `&lt;` `&gt;` `&amp;`.

### Outros

| Elemento | Marcação |
|---|---|
| Caminho no Portal | `<span class="path">Blade › Menu › Item</span>` (separador `›`) |
| Rótulo de botão/campo | `<span class="ui">Save</span>` |
| Callout | `<div class="callout note">` (ou `tip`, `warn`, `danger`) com `<p class="callout-title">Título</p>` como primeiro filho |
| Checkpoint | `<div class="checkpoint" id="ex1-c1" data-nav="Checkpoint C1">` com o comando `./scripts/checkpoint.sh C1` e o que ele verifica |
| Duração | `<p class="meta">⏱ 75 min · Checkpoint C1</p>` logo abaixo do `<h2>` |
| Tabela | `<table class="data">` com `<thead>` |
| Diagrama | `<figure class="diagram">{{svg:arquitetura}}<figcaption>…</figcaption></figure>` |
| Link para a documentação | `<a href="https://learn.microsoft.com/…" target="_blank" rel="noopener">texto</a>` (links externos são permitidos; **recursos** externos não) |

## Estilo do texto

- Português do Brasil, segunda pessoa ("você"), frases curtas. Rótulos do Portal **em inglês, exatamente como aparecem na tela**.
- Cada exercício abre com objetivo, duração, o que você vai aprender e o checkpoint anterior exigido; e fecha com o checkpoint e um quadro "O que você aprendeu".
- Comandos de dentro da VM: sempre `Invoke-WebRequest … -UseBasicParsing` e `curl.exe` (no Windows PowerShell 5.1, `curl` é alias de `Invoke-WebRequest`).
- Comandos do Cloud Shell: autocontidos (cada bloco calcula o que precisa, por exemplo `PIP=$(az network public-ip show … --query ipAddress -o tsv)`), sem depender de variável criada em outro bloco. Nomes vêm de `{{c.…}}`.
- Para rodar um comando dentro da VM a partir do Cloud Shell, use `az vm run-command invoke … --command-id RunPowerShellScript --scripts '…' --query "value[0].message" -o tsv`, com **aspas simples** em volta do PowerShell (o Bash não expande `$` dentro delas).
- Nada de nome de cliente, IP público real, ID de assinatura/tenant ou e-mail real.

## Restrições verificadas pelos testes

- Nenhum `{{` restante no HTML gerado.
- Nenhum recurso externo: sem `<link href="http…">`, `<script src=…>`, `@import`, `url(http…)` ou `<img src="http…">`.
- Todo `href="#…"` do menu aponta para um `id` existente; `id` não se repete.
- Todo `{{kql:…}}` existe em `queries/`.
- Nomes e prioridades do guia batem com `lab.contract.json`.
