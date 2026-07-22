//! Dispatch de agentes a partir do Kanban: dado um card (repo + issue +
//! Agent), busca o entry prompt na issue, resolve o diretório local do repo
//! e dispara `herdr agent start issue-<n>` — o herdr é o terminal do
//! usuário, então a execução nasce visível e supervisionável.

use std::path::PathBuf;
use std::process::Command;

use anyhow::{Result, anyhow};

use super::kanban::KanbanCard;

/// Máximo de agentes despachados simultaneamente (decisão do usuário).
pub const MAX_DISPATCHED: usize = 3;

/// Nome do agente herdr para uma issue (`issue-<n>`).
pub fn agent_name(number: u64) -> String {
    format!("issue-{number}")
}

/// Extrai o bloco ```text da seção `## Entry prompt` do body de uma issue.
/// O contrato de tarefa (brain/templates/issue-tarefa.md) garante a seção.
pub fn extract_entry_prompt(body: &str) -> Option<String> {
    let section = body.split("## Entry prompt").nth(1)?;
    let fence = section.split("```text").nth(1)?;
    let prompt = fence.split("```").next()?.trim();
    (!prompt.is_empty()).then(|| prompt.to_string())
}

/// Argv do agente: sonnet/opus/fable → `claude --model <x>`; codex → `codex`;
/// sem agente definido → `claude` (modelo default).
pub fn agent_argv(agent: &str, prompt: &str) -> Vec<String> {
    match agent {
        "codex" => vec!["codex".into(), prompt.into()],
        "sonnet" | "opus" | "fable" => vec![
            "claude".into(),
            "--model".into(),
            agent.into(),
            prompt.into(),
        ],
        _ => vec!["claude".into(), prompt.into()],
    }
}

/// Diretório local de um repo `owner/nome`: procura por `nome` (case-
/// insensitive) dentro de `$PRUMO_REPOS_DIR` (default `~/Documents/Projetos`).
pub fn repo_dir(repo: &str) -> Result<PathBuf> {
    let name = repo.rsplit('/').next().unwrap_or(repo);
    let base = std::env::var("PRUMO_REPOS_DIR").map(PathBuf::from).unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_default();
        PathBuf::from(home).join("Documents/Projetos")
    });
    find_dir_case_insensitive(&base, name).ok_or_else(|| {
        anyhow!(
            "repo `{repo}` não encontrado em {} (defina PRUMO_REPOS_DIR)",
            base.display()
        )
    })
}

/// Primeiro subdiretório de `base` cujo nome bate com `name` ignorando caixa.
fn find_dir_case_insensitive(base: &std::path::Path, name: &str) -> Option<PathBuf> {
    let entries = std::fs::read_dir(base).ok()?;
    let wanted = name.to_lowercase();
    entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| {
            p.is_dir()
                && p.file_name()
                    .map(|f| f.to_string_lossy().to_lowercase() == wanted)
                    .unwrap_or(false)
        })
}

/// Busca o entry prompt da issue via `gh`.
pub fn fetch_entry_prompt(repo: &str, number: u64) -> Result<String> {
    let num = number.to_string();
    let body = super::github::gh(&[
        "issue", "view", &num, "-R", repo, "--json", "body", "--jq", ".body",
    ])?;
    extract_entry_prompt(&body).ok_or_else(|| {
        anyhow!("issue {repo}#{number} sem seção `## Entry prompt` com bloco ```text")
    })
}

/// Executa um subcomando do `herdr`, devolvendo o stdout (espelha o `gh`).
pub(crate) fn herdr(args: &[&str]) -> Result<String> {
    let out = Command::new("herdr").args(args).output().map_err(|e| {
        anyhow!("não encontrei o `herdr` no PATH ({e}). O dispatch requer o herdr.")
    })?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!("`herdr {}` falhou: {}", args.join(" "), err.trim()));
    }
    String::from_utf8(out.stdout).map_err(|e| anyhow!("saída do herdr não é UTF-8: {e}"))
}

/// Quantos agentes `issue-*` estão ativos no herdr. Contagem por substring
/// no JSON do `agent list` — os agentes despachados são sempre nomeados
/// `issue-<n>`, e o campo `name` só existe para agentes nomeados.
pub fn dispatched_count() -> Result<usize> {
    let out = herdr(&["agent", "list"])?;
    Ok(out.matches("\"name\":\"issue-").count())
}

/// O agente `issue-<n>` já existe no herdr?
pub fn is_dispatched(number: u64) -> bool {
    herdr(&["agent", "get", &agent_name(number)]).is_ok()
}

/// Estado do agente `issue-<n>` no herdr (`working`/`blocked`/`idle`/...),
/// ou `None` se não existe (ou o herdr está indisponível).
pub fn agent_status(number: u64) -> Option<String> {
    let out = herdr(&["agent", "get", &agent_name(number)]).ok()?;
    extract_agent_status(&out)
}

/// Extrai o primeiro `"agent_status":"<x>"` de um JSON do herdr.
pub fn extract_agent_status(json: &str) -> Option<String> {
    let rest = json.split("\"agent_status\":\"").nth(1)?;
    let status = rest.split('"').next()?;
    (!status.is_empty()).then(|| status.to_string())
}

/// Dispara o agente do card: `herdr agent start issue-<n> --cwd <repo dir>
/// --no-focus -- <argv do agente>`. O chamador decide fila/estado.
pub fn dispatch(card: &KanbanCard) -> Result<()> {
    let prompt = fetch_entry_prompt(&card.repo, card.number)?;
    let dir = repo_dir(&card.repo)?;
    let name = agent_name(card.number);
    let argv = agent_argv(&card.agent, &prompt);
    let dir_s = dir.to_string_lossy().to_string();
    let mut args: Vec<&str> = vec!["agent", "start", &name, "--cwd", &dir_s, "--no-focus", "--"];
    args.extend(argv.iter().map(|s| s.as_str()));
    herdr(&args)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_entry_prompt_block() {
        let body = "## Objetivo\nx\n\n## Entry prompt\n```text\nLeia a issue.\nFaça y.\n```\n\n## Fechamento\n";
        assert_eq!(
            extract_entry_prompt(body).as_deref(),
            Some("Leia a issue.\nFaça y.")
        );
    }

    #[test]
    fn entry_prompt_missing_or_empty_is_none() {
        assert_eq!(extract_entry_prompt("## Objetivo\nsem prompt"), None);
        assert_eq!(extract_entry_prompt("## Entry prompt\n```text\n\n```"), None);
    }

    #[test]
    fn maps_agents_to_argv() {
        assert_eq!(agent_argv("codex", "p"), vec!["codex", "p"]);
        assert_eq!(agent_argv("opus", "p"), vec!["claude", "--model", "opus", "p"]);
        assert_eq!(agent_argv("", "p"), vec!["claude", "p"]);
        assert_eq!(agent_argv("sem agente", "p"), vec!["claude", "p"]);
    }

    #[test]
    fn finds_dir_ignoring_case() {
        let base = std::env::temp_dir().join(format!("prumo-dispatch-test-{}", std::process::id()));
        let dir = base.join("MeuRepo");
        std::fs::create_dir_all(&dir).unwrap();
        let found = find_dir_case_insensitive(&base, "meurepo").unwrap();
        assert_eq!(found, dir);
        assert!(find_dir_case_insensitive(&base, "outro").is_none());
        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn agent_name_format() {
        assert_eq!(agent_name(42), "issue-42");
    }

    #[test]
    fn extracts_agent_status_from_json() {
        let json = r#"{"result":{"agent":{"agent_status":"working","name":"issue-2"}}}"#;
        assert_eq!(extract_agent_status(json).as_deref(), Some("working"));
        assert_eq!(extract_agent_status("{}"), None);
    }
}
