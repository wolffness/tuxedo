# Advisor incremento 2 — vínculo projeto→repo GitHub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Injetar issues abertas de repositórios do GitHub — cada um vinculado a um projeto (`+tag`) do todo.txt — na priorização do advisor, reusando o `gh` já logado, read-only.

**Architecture:** Novo campo `advisor_links` no `Config` (pares projeto→repo, serializados como `advisor_link.<project> = owner/repo`, espelhando os `filters`). Novo módulo `src/advisor/github.rs` com parte pura (parse de saída do `gh` + montagem de linhas sintéticas) isolada do shell-out. O `advise` passa a receber uma lista de linhas prontas; `cmd_advisor` monta linhas locais + do GitHub e trata degradação. Novo comando `prumo advisor link` (interativo) grava o vínculo.

**Tech Stack:** Rust, `std::process::Command` (shell-out a `gh` com `--template`, sem serde), config chave-valor próprio, testes `cargo test`.

---

### Task 1: Config — campo `advisor_links` (parse + serialize)

**Files:**
- Modify: `src/config.rs` (struct em ~52-60, `parse` em ~183-197, `serialize` em ~240-242, teste default em ~299-308)
- Test: `src/config.rs` (módulo de teste existente)

- [ ] **Step 1: Add the field to the struct**

Em `src/config.rs`, após `pub advisor_model: Option<String>,` (linha ~59), adicionar:

```rust
    /// Vínculos projeto→repo do advisor. Cada par `(projeto, "owner/repo")`
    /// liga um projeto do todo.txt a um repositório do GitHub. Serializado
    /// uma linha por par como `advisor_link.<projeto> = <owner/repo>`.
    pub advisor_links: Vec<(String, String)>,
```

- [ ] **Step 2: Write the failing round-trip test**

No módulo de teste, adicionar `advisor_links` ao `Config` construído no teste de round-trip (bloco ~299-308), logo após `advisor_model: None,`:

```rust
            advisor_links: vec![
                ("prumo".into(), "wolffness/prumo".into()),
                ("casa".into(), "wolffness/casa-infra".into()),
            ],
```

E um teste dedicado novo no mesmo módulo:

```rust
    #[test]
    fn advisor_links_round_trip_and_upsert() {
        let s = "advisor_link.prumo = wolffness/prumo\n\
                 advisor_link.casa = wolffness/casa-infra\n\
                 advisor_link.prumo = wolffness/prumo-2\n";
        let c = parse(s);
        // Última ocorrência vence, posição da primeira preservada (como filters).
        assert_eq!(
            c.advisor_links,
            vec![
                ("prumo".to_string(), "wolffness/prumo-2".to_string()),
                ("casa".to_string(), "wolffness/casa-infra".to_string()),
            ]
        );
        // Serialize → parse é idempotente.
        assert_eq!(parse(&serialize(&c)).advisor_links, c.advisor_links);
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cargo test --lib config`
Expected: FAIL — `advisor_links` não existe / não é parseado.

- [ ] **Step 4: Implement parse**

Em `parse`, logo ANTES do braço `_ if k.strip_prefix("filter.")` (~188), adicionar:

```rust
            _ if k
                .strip_prefix("advisor_link.")
                .is_some_and(|n| !n.trim().is_empty()) =>
            {
                let name = k.strip_prefix("advisor_link.").expect("checked above").trim();
                let repo = v.trim().to_string();
                match c.advisor_links.iter_mut().find(|(n, _)| n.as_str() == name) {
                    Some((_, r)) => *r = repo,
                    None => c.advisor_links.push((name.to_string(), repo)),
                }
            }
```

- [ ] **Step 5: Implement serialize**

Em `serialize`, após o bloco `advisor_model` (~258-260), adicionar:

```rust
    for (project, repo) in &c.advisor_links {
        let _ = writeln!(out, "advisor_link.{project} = {repo}");
    }
```

E garantir que o `Config::default()` inicialize `advisor_links: Vec::new()` (adicionar o campo no `impl Default`/`Default::default` — procurar onde os outros campos default são zerados; se usa `#[derive(Default)]` para `Vec`, nada a fazer).

- [ ] **Step 6: Run tests to verify they pass**

Run: `cargo test --lib config`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/config.rs
git commit -m "feat(advisor): persist project->repo GitHub links in config"
```

---

### Task 2: `github.rs` — parte pura (parse + linha sintética)

**Files:**
- Create: `src/advisor/github.rs`
- Modify: `src/advisor/mod.rs` (adicionar `pub mod github;` no topo)
- Test: `src/advisor/github.rs` (módulo de teste no próprio arquivo)

- [ ] **Step 1: Create the module with pure functions**

Criar `src/advisor/github.rs`:

```rust
//! Integração GitHub do advisor: puxa issues abertas de repos vinculados a
//! projetos do todo.txt e as transforma em linhas sintéticas para a
//! priorização. A parte pura (parse da saída do `gh` + montagem das linhas)
//! fica isolada do shell-out para os testes rodarem offline.

use std::process::Command;

use anyhow::{Result, anyhow};

/// Uma linha da lista de repos vinda de `gh repo list ... --template`.
/// Descarta linhas vazias e apara espaços.
pub fn parse_repo_list(stdout: &str) -> Vec<String> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Parseia a saída `<número>\t<título>` (uma issue por linha) de
/// `gh issue list ... --template`. Linhas sem tab ou com número inválido são
/// ignoradas (forgiving).
pub fn parse_issue_tsv(stdout: &str) -> Vec<(u64, String)> {
    stdout
        .lines()
        .filter_map(|line| {
            let (num, title) = line.split_once('\t')?;
            let num = num.trim().parse::<u64>().ok()?;
            let title = title.trim();
            if title.is_empty() {
                return None;
            }
            Some((num, title.to_string()))
        })
        .collect()
}

/// Monta a linha sintética de uma issue, no formato todo.txt:
/// `(?) <título> +<projeto> gh:<owner/repo>#<número>`. O marcador `(?)` e o
/// token `gh:` deixam claro que o item vem do GitHub e não está no todo.txt.
pub fn synthetic_line(project: &str, repo: &str, number: u64, title: &str) -> String {
    format!("(?) {title} +{project} gh:{repo}#{number}")
}

/// Todas as linhas sintéticas para um repo/projeto a partir da saída crua do
/// `gh issue list`.
pub fn synthetic_lines(stdout: &str, project: &str, repo: &str) -> Vec<String> {
    parse_issue_tsv(stdout)
        .into_iter()
        .map(|(n, t)| synthetic_line(project, repo, n, &t))
        .collect()
}
```

- [ ] **Step 2: Register the module**

Em `src/advisor/mod.rs`, no topo (após o doc-comment, antes de `use`), adicionar:

```rust
pub mod github;
```

- [ ] **Step 3: Write the failing tests**

No fim de `src/advisor/github.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_repo_list_dropping_blanks() {
        let out = "wolffness/prumo\n\n  wolffness/casa-infra  \n";
        assert_eq!(
            parse_repo_list(out),
            vec!["wolffness/prumo".to_string(), "wolffness/casa-infra".to_string()]
        );
    }

    #[test]
    fn parses_issue_tsv_and_skips_malformed() {
        let out = "12\tArrumar o parser NL\nsem-tab\n7\t  Publicar release  \nx\tnúmero inválido\n";
        assert_eq!(
            parse_issue_tsv(out),
            vec![(12, "Arrumar o parser NL".to_string()), (7, "Publicar release".to_string())]
        );
    }

    #[test]
    fn builds_synthetic_line() {
        assert_eq!(
            synthetic_line("prumo", "wolffness/prumo", 12, "Arrumar o parser NL"),
            "(?) Arrumar o parser NL +prumo gh:wolffness/prumo#12"
        );
    }

    #[test]
    fn synthetic_lines_maps_all_issues() {
        let out = "12\tA\n7\tB\n";
        assert_eq!(
            synthetic_lines(out, "prumo", "wolffness/prumo"),
            vec![
                "(?) A +prumo gh:wolffness/prumo#12".to_string(),
                "(?) B +prumo gh:wolffness/prumo#7".to_string(),
            ]
        );
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --lib advisor::github`
Expected: PASS (as funções puras já foram escritas no Step 1).

- [ ] **Step 5: Commit**

```bash
git add src/advisor/github.rs src/advisor/mod.rs
git commit -m "feat(advisor): pure GitHub issue parsing and synthetic todo lines"
```

---

### Task 3: `github.rs` — shell-out ao `gh`

**Files:**
- Modify: `src/advisor/github.rs`

- [ ] **Step 1: Add the gh runner and wrappers**

Adicionar em `src/advisor/github.rs`, após `synthetic_lines`:

```rust
/// Executa um subcomando do `gh` já autenticado, devolvendo o stdout. Isola o
/// shell-out (como o `curl` do incremento 1) para o resto do módulo ficar puro.
fn gh(args: &[&str]) -> Result<String> {
    let out = Command::new("gh")
        .args(args)
        .output()
        .map_err(|e| anyhow!("não encontrei o `gh` no PATH ({e}). Instale o GitHub CLI e rode `gh auth login`."))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!("`gh {}` falhou: {}", args.join(" "), err.trim()));
    }
    String::from_utf8(out.stdout).map_err(|e| anyhow!("saída do gh não é UTF-8: {e}"))
}

/// Lista os repos da conta logada como `owner/repo`, um por linha.
pub fn list_repos() -> Result<Vec<String>> {
    let out = gh(&[
        "repo", "list", "--limit", "100",
        "--json", "nameWithOwner",
        "--template", "{{range .}}{{.nameWithOwner}}{{\"\\n\"}}{{end}}",
    ])?;
    Ok(parse_repo_list(&out))
}

/// Linhas sintéticas das issues abertas de um repo vinculado ao `project`.
pub fn open_issue_lines(repo: &str, project: &str) -> Result<Vec<String>> {
    let out = gh(&[
        "issue", "list", "--repo", repo, "--state", "open",
        "--json", "number,title",
        "--template", "{{range .}}{{.number}}{{\"\\t\"}}{{.title}}{{\"\\n\"}}{{end}}",
    ])?;
    Ok(synthetic_lines(&out, project, repo))
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cargo build`
Expected: compila sem erros (as funções puras já são exercidas pelos testes da Task 2; os wrappers são finos e verificados manualmente por serem I/O).

- [ ] **Step 3: Commit**

```bash
git add src/advisor/github.rs
git commit -m "feat(advisor): shell out to gh for repo list and open issues"
```

---

### Task 4: `advise` recebe linhas prontas + filtro por projeto

**Files:**
- Modify: `src/advisor/mod.rs` (`advise` ~80-96, `build_prompt` ~98-116)
- Test: `src/advisor/mod.rs` (módulo de teste existente)

- [ ] **Step 1: Add local_lines helper and refactor advise/build_prompt**

Substituir a função `advise` e `build_prompt` em `src/advisor/mod.rs` por:

```rust
/// Linhas de tarefas locais abertas (raw), opcionalmente filtradas a um
/// `+project`. É a base da priorização, à qual o chamador anexa linhas do
/// GitHub antes de chamar [`advise`].
pub fn local_lines(tasks: &[Task], project: Option<&str>) -> Vec<String> {
    tasks
        .iter()
        .filter(|t| !t.done)
        .filter(|t| match project {
            Some(p) => t.projects.iter().any(|proj| proj == p),
            None => true,
        })
        .map(|t| t.raw.clone())
        .collect()
}

/// Roda uma requisição do advisor sobre `lines` (tarefas locais + itens do
/// GitHub já montados), devolvendo a sugestão do modelo como texto. O chamador
/// imprime; nada é escrito em disco.
pub fn advise(cfg: &AdvisorConfig, kind: Task_, lines: &[String]) -> Result<String> {
    if !cfg.enabled {
        bail!(
            "advisor is off. Enable it in config.toml with `advisor = on`, \
             then set `advisor_backend = ollama` (default) or `claude`."
        );
    }
    if lines.is_empty() {
        return Ok("Nenhuma tarefa aberta para priorizar.".to_string());
    }
    let prompt = build_prompt(kind, lines);
    match cfg.backend {
        Backend::Ollama => call_ollama(&cfg.model, &prompt),
        Backend::Claude => call_claude(&cfg.model, &prompt),
    }
}

fn build_prompt(kind: Task_, lines: &[String]) -> String {
    let list = lines
        .iter()
        .enumerate()
        .map(|(i, l)| format!("{}. {}", i + 1, l))
        .collect::<Vec<_>>()
        .join("\n");
    match kind {
        Task_::Prioritize => format!(
            "Você é um assistente de produtividade para uma pessoa com TDAH/TEA \
             que trabalha sozinha. Abaixo está a lista de tarefas todo.txt em aberto. \
             Itens marcados com `(?)` e um token `gh:owner/repo#N` são issues abertas \
             do GitHub que ainda NÃO estão no todo.txt — considere-as na priorização.\n\n\
             {list}\n\n\
             Escolha as 3 tarefas mais importantes para fazer AGORA, em ordem, \
             equilibrando urgência (datas `due:`) e esforço. Para cada uma, uma \
             linha curta com o porquê. Seja objetivo e não invente tarefas que \
             não estejam na lista. Responda em português."
        ),
    }
}
```

Nota: `use crate::todo::Task;` já está no topo do arquivo (mantém).

- [ ] **Step 2: Write the failing test for local_lines**

Adicionar ao módulo de teste em `src/advisor/mod.rs`:

```rust
    #[test]
    fn local_lines_filters_done_and_project() {
        use crate::todo::parse_line;
        let tasks: Vec<Task> = [
            "(A) Escrever plano +prumo",
            "x Concluída +prumo",
            "Comprar pão +casa",
        ]
        .iter()
        .filter_map(|l| parse_line(l))
        .collect();

        // Sem filtro: só as abertas (2).
        assert_eq!(local_lines(&tasks, None).len(), 2);
        // Filtrado a +prumo: só a aberta desse projeto.
        assert_eq!(
            local_lines(&tasks, Some("prumo")),
            vec!["(A) Escrever plano +prumo".to_string()]
        );
    }
```

- [ ] **Step 3: Run tests to verify they pass and old ones still compile**

Run: `cargo test --lib advisor`
Expected: PASS. (Se algum teste antigo chamava `advise(cfg, kind, tasks)`, ajustar para a nova assinatura — verificar com o compilador.)

- [ ] **Step 4: Commit**

```bash
git add src/advisor/mod.rs
git commit -m "feat(advisor): advise over prebuilt lines with project filtering"
```

---

### Task 5: `cmd_advisor` — parsing de projeto + injeção do GitHub + degradação

**Files:**
- Modify: `src/cmd/mod.rs` (`cmd_advisor` ~589-620)

- [ ] **Step 1: Rewrite cmd_advisor**

Substituir `cmd_advisor` em `src/cmd/mod.rs` por:

```rust
/// `advisor <sub> [+projeto]`: opt-in AI suggestion sobre o todo file + issues
/// do GitHub vinculadas. Read-only — imprime a sugestão; nunca escreve. Off a
/// menos que `advisor = on`.
fn cmd_advisor(store: &Store, pos: &[String]) -> i32 {
    use crate::advisor::{self, AdvisorConfig, Task_, github};

    // Separa o subcomando do filtro `+projeto` (qualquer ordem).
    let mut sub = "prioritize";
    let mut project: Option<&str> = None;
    for p in pos {
        if let Some(pj) = p.strip_prefix('+') {
            project = Some(pj);
        } else {
            sub = p;
        }
    }

    if sub == "link" {
        return cmd_advisor_link();
    }

    let kind = match sub {
        "prioritize" | "pri" | "priorizar" => Task_::Prioritize,
        other => {
            eprintln!(
                "{}: unknown advisor command: {other} (try `prioritize` or `link`)",
                crate::brand::app_name()
            );
            return 2;
        }
    };

    let cfg = crate::config::Config::load();
    let advisor_cfg = AdvisorConfig::resolve(
        cfg.advisor.unwrap_or(false),
        cfg.advisor_backend.as_deref(),
        cfg.advisor_model.as_deref(),
    );

    // Tarefas locais + issues do GitHub dos repos vinculados (respeitando o
    // filtro de projeto). Falha no gh degrada: avisa e segue só com o local.
    let mut lines = advisor::local_lines(store.tasks(), project);
    for (proj, repo) in &cfg.advisor_links {
        if project.is_some_and(|p| p != proj.as_str()) {
            continue;
        }
        match github::open_issue_lines(repo, proj) {
            Ok(mut gh_lines) => lines.append(&mut gh_lines),
            Err(e) => eprintln!(
                "{}: aviso: não consegui puxar issues de {repo}: {e}",
                crate::brand::app_name()
            ),
        }
    }

    match advisor::advise(&advisor_cfg, kind, &lines) {
        Ok(text) => {
            println!("{text}");
            0
        }
        Err(e) => {
            eprintln!("{}: {e}", crate::brand::app_name());
            1
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cargo build`
Expected: erro apontando `cmd_advisor_link` não definido → resolvido na Task 6. Até lá, pode comentar a linha `return cmd_advisor_link();` OU implementar a Task 6 antes de compilar. Recomendado: seguir direto para a Task 6 e compilar ao fim dela.

- [ ] **Step 3: Commit (após Task 6 compilar)**

Adiado — commitado junto da Task 6.

---

### Task 6: `prumo advisor link` — fluxo interativo + upsert testável

**Files:**
- Modify: `src/cmd/mod.rs` (nova função `cmd_advisor_link` + helper `upsert_link`)

- [ ] **Step 1: Add upsert helper with a failing test**

Adicionar em `src/cmd/mod.rs` (perto de `cmd_advisor`):

```rust
/// Insere ou atualiza o vínculo `projeto → repo` na lista, preservando a
/// posição da primeira ocorrência (mesma semântica dos filters).
fn upsert_link(links: &mut Vec<(String, String)>, project: &str, repo: &str) {
    match links.iter_mut().find(|(p, _)| p == project) {
        Some((_, r)) => *r = repo.to_string(),
        None => links.push((project.to_string(), repo.to_string())),
    }
}
```

E no módulo de teste de `src/cmd/mod.rs` (criar `#[cfg(test)] mod tests` se não houver, ou usar o existente):

```rust
    #[test]
    fn upsert_link_adds_then_updates_in_place() {
        let mut links = vec![("prumo".to_string(), "wolffness/prumo".to_string())];
        upsert_link(&mut links, "casa", "wolffness/casa");
        upsert_link(&mut links, "prumo", "wolffness/prumo-2");
        assert_eq!(
            links,
            vec![
                ("prumo".to_string(), "wolffness/prumo-2".to_string()),
                ("casa".to_string(), "wolffness/casa".to_string()),
            ]
        );
    }
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `cargo test --lib cmd::`
Expected: PASS para `upsert_link_adds_then_updates_in_place`.

- [ ] **Step 3: Add the interactive command**

Adicionar em `src/cmd/mod.rs`:

```rust
/// `advisor link`: setup interativo do vínculo projeto→repo. Lista os repos da
/// conta (via `gh`), lê a escolha e o nome do projeto no stdin, e grava no
/// config. Não escreve nada se o `gh` falhar ou a entrada for inválida.
fn cmd_advisor_link() -> i32 {
    use std::io::{self, Write};

    let repos = match crate::advisor::github::list_repos() {
        Ok(r) if !r.is_empty() => r,
        Ok(_) => {
            eprintln!("{}: nenhum repositório encontrado na sua conta.", crate::brand::app_name());
            return 1;
        }
        Err(e) => {
            eprintln!("{}: {e}", crate::brand::app_name());
            return 1;
        }
    };

    println!("Repositórios da sua conta:");
    for (i, r) in repos.iter().enumerate() {
        println!("{:>3}. {}", i + 1, r);
    }
    print!("Número do repositório para vincular: ");
    let _ = io::stdout().flush();

    let mut buf = String::new();
    if io::stdin().read_line(&mut buf).is_err() {
        eprintln!("{}: não consegui ler a entrada.", crate::brand::app_name());
        return 1;
    }
    let idx = match buf.trim().parse::<usize>() {
        Ok(n) if (1..=repos.len()).contains(&n) => n - 1,
        _ => {
            eprintln!("{}: número inválido.", crate::brand::app_name());
            return 2;
        }
    };
    let repo = repos[idx].clone();

    print!("Projeto do Prumo (o +tag, sem o +) para ligar a {repo}: ");
    let _ = io::stdout().flush();
    let mut proj = String::new();
    if io::stdin().read_line(&mut proj).is_err() {
        eprintln!("{}: não consegui ler a entrada.", crate::brand::app_name());
        return 1;
    }
    let project = proj.trim().trim_start_matches('+');
    if project.is_empty() {
        eprintln!("{}: nome de projeto vazio; nada gravado.", crate::brand::app_name());
        return 2;
    }

    let mut cfg = crate::config::Config::load();
    upsert_link(&mut cfg.advisor_links, project, &repo);
    if let Err(e) = cfg.save() {
        eprintln!("{}: não consegui salvar o config: {e}", crate::brand::app_name());
        return 1;
    }
    println!("Vinculado: +{project} → {repo}");
    0
}
```

- [ ] **Step 4: Build and run the full suite**

Run: `cargo build && cargo test`
Expected: compila; toda a suíte passa (~569 testes: os anteriores + os novos desta série).

- [ ] **Step 5: Commit**

```bash
git add src/cmd/mod.rs
git commit -m "feat(advisor): interactive 'advisor link' and GitHub injection in prioritize"
```

---

### Task 7: Docs — README (PT-BR) + verificação manual

**Files:**
- Modify: `README.md` (seção do advisor)

- [ ] **Step 1: Document the new command**

Na seção do advisor no `README.md`, acrescentar (em PT-BR), descrevendo:
- `prumo advisor link` — vincula um repo do GitHub a um projeto (usa o `gh` logado).
- `prumo advisor prioritize [+projeto]` — inclui as issues abertas dos repos vinculados; sem argumento cobre todos os projetos, com `+projeto` restringe a um.
- Nota: requer `gh auth login`; o advisor continua opt-in e read-only.

Texto a inserir (ajustar ao redor conforme a seção existente):

```markdown
### Vincular um repositório do GitHub a um projeto

O advisor pode considerar issues abertas do GitHub junto das suas tarefas.
Cada repositório é ligado a **um projeto** (o `+tag` do todo.txt), mantendo a
priorização por contexto.

```bash
prumo advisor link                 # lista seus repos (via gh) e liga um a um projeto
prumo advisor prioritize           # prioriza todos os projetos + issues vinculadas
prumo advisor prioritize +prumo    # só o projeto +prumo e seu repo
```

Requer o [GitHub CLI](https://cli.github.com) autenticado (`gh auth login`).
Continua opt-in (`advisor = on`) e read-only: nada é escrito no todo.txt nem no
GitHub. Se o `gh` não estiver disponível, o `prioritize` avisa e segue só com
as tarefas locais.
```

- [ ] **Step 2: Manual verification (real gh, no assertions in suite)**

Run:
```bash
cargo build
# habilitar no config: advisor = on
target/debug/prumo advisor link          # escolher um repo e um projeto
grep advisor_link ~/.config/tuxedo/config.toml
target/debug/prumo advisor prioritize +<projeto>   # com Ollama ou ANTHROPIC_API_KEY
```
Expected: o link aparece no config; o prioritize inclui linhas `gh:...#N` na sugestão. Sem `gh` logado, aparece o aviso e a priorização usa só o local.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document advisor link + GitHub-aware prioritize (pt-BR)"
```

---

## Notas de verificação

- **Cobertura do spec:** vínculo persistente (Task 1), seleção interativa da lista (Task 6), item = todas as issues abertas (Task 3, sem `--assignee`), injeção sob o `+projeto` certo (Tasks 2/4/5), escopo todos-vs-`+projeto` (Task 5), degradação sem `gh` (Task 5), read-only (nenhuma escrita fora do config no `link`), testes offline (Tasks 1/2/4/6). PRs/assignee e múltiplos repos por projeto ficam fora (YAGNI, conforme spec).
- **Sem rede nos testes:** todo teste unitário exercita parte pura; os wrappers do `gh` e o fluxo interativo do `link` são I/O verificados manualmente (Step 7.2).
- **Contagem de testes:** rodar `cargo test` completo ao fim; se o total divergir do esperado, investigar antes de commitar (pode indicar teste antigo quebrado pela nova assinatura de `advise`).
