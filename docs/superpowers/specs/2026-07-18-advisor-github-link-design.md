# Design — Advisor incremento 2: vínculo projeto→repo do GitHub

Data: 2026-07-18
Status: aprovado (aguardando plano de implementação)

## Propósito

Estender o módulo advisor de IA (opt-in, read-only) do Prumo para injetar
issues abertas de repositórios do GitHub na priorização do todo.txt. Cada
repositório é vinculado a **um projeto** do Prumo (o `+tag` do todo.txt), não ao
Prumo inteiro — mantendo a priorização limpa e por contexto. Voltado a uso solo.

## Restrições herdadas (do incremento 1)

- Advisor **desligado por padrão** (`advisor = on` para habilitar); núcleo do
  Prumo funciona sem IA e sem GitHub.
- **Read-only**: imprime sugestão; nunca escreve no todo.txt nem no GitHub.
- GitHub é acessado reusando o **`gh` já logado** (decisão do usuário) — sem
  OAuth próprio. Shell-out via `Command`, como o `curl` do incremento 1.

## Arquitetura

Dois comandos sob o advisor:

1. **`prumo advisor link`** — setup interativo do vínculo projeto→repo.
2. **`prumo advisor prioritize [+projeto]`** — comando existente, agora injeta
   as issues abertas dos repos vinculados como tarefas sintéticas sob o projeto
   correto, alimentando o mesmo prompt de priorização.

Nenhuma mudança no núcleo nem quando o advisor está off.

## Componentes

### Config — persistência do vínculo

Espelha o padrão de chave-pontuada já usado pelos `filters`. Cada vínculo é uma
linha no config.toml:

```
advisor_link.prumo = wolffness/prumo
advisor_link.casa  = wolffness/casa-infra
```

- No `Config`: novo campo `advisor_links: Vec<(String, String)>` — pares
  `(projeto, "owner/repo")`. Round-trip de serialização como os `filters`.
- Adicionar um projeto = adicionar uma linha; os demais vínculos não são
  tocados. Re-vincular o mesmo projeto sobrescreve o valor anterior.

### `prumo advisor link` — seleção interativa

1. Executa `gh repo list --limit 100 --json nameWithOwner` (reusa `gh` logado).
2. Imprime a lista **numerada** dos repos; lê o número escolhido no stdin.
3. Pergunta o nome do projeto (`+tag`, ex.: `prumo`) no stdin.
4. Grava o par em `advisor_links` e confirma na saída.

Falhas tratadas: `gh` não instalado ou não autenticado → mensagem clara
(`instale o gh` / `gh auth login`) e sai com código ≠ 0 **sem gravar** nada.
Número inválido / projeto vazio → erro amigável, sem gravar.

### Injeção na priorização

Para cada projeto vinculado (ou apenas o `+projeto` pedido):

- `gh issue list --repo <owner/repo> --state open --json number,title` — todas
  as issues abertas (uso solo: sem filtro de assignee).
- Cada issue vira uma linha sintética:
  `(?) <título> +<projeto> gh:<owner>/<repo>#<número>`
- As linhas sintéticas entram junto das tarefas locais daquele projeto no
  prompt de priorização existente.
- O prompt ganha uma frase explicando que itens marcados `gh:` vêm do GitHub e
  ainda **não estão** no todo.txt.
- Permanece read-only: nada é escrito em disco nem no GitHub.

### Escopo e degradação

- `prumo advisor prioritize` (sem argumento): todos os projetos vinculados +
  todas as tarefas locais.
- `prumo advisor prioritize +projeto`: só as tarefas locais desse projeto + as
  issues do repo vinculado a ele.
- `gh` ausente / deslogado no momento do prioritize → **avisa no stderr e
  segue** apenas com as tarefas locais (não trava o advisor).

## Tratamento de erros (resumo)

| Situação | Comportamento |
|---|---|
| advisor off | mensagem do incremento 1, sai (inalterado) |
| `gh` ausente/deslogado no `link` | erro claro, sai sem gravar |
| `gh` ausente/deslogado no `prioritize` | avisa, prioriza só o local |
| número/projeto inválido no `link` | erro amigável, sem gravar |
| repo sem issues abertas | injeta nada para aquele projeto, sem erro |

## Testes (sem rede)

- Round-trip de `advisor_links` no config (parse + serialize).
- Montagem das linhas sintéticas a partir de um JSON de issues fixo.
- Merge de tarefas locais + linhas do GitHub para um projeto.
- Isolamento do shell-out ao `gh` (injetável/mockável, como o `curl` já é),
  para os testes rodarem offline.

## Fora de escopo (YAGNI)

- PRs aguardando review e filtro por assignee (uso solo dispensa).
- Escrita de volta no GitHub ou no todo.txt.
- Múltiplos repos por projeto (um repo por projeto por ora).
- Corpo/labels da issue no prompt (só número + título no incremento 2).
