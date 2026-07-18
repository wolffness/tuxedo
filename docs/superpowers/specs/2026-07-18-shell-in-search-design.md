# Design — Mini-terminal no campo `/` (prefixo `!`)

Data: 2026-07-18
Status: aprovado

## Propósito

Permitir rodar comandos de shell esporádicos sem sair do Prumo: no campo de
busca (`/`), digitar `! <comando>` e apertar Enter suspende o TUI, roda o
comando com terminal real (teclado + saída), e volta ao app recarregando
mudanças. Motivador: `! prumo advisor link` (comando interativo) de dentro do
app.

## Abordagem

Padrão `:!` do vim/lazygit — handoff de terminal, reusando o mecanismo que o
Prumo **já tem** para o editor externo (`open_path_in_editor` +
`pending_editor_path`). Comandos interativos exigem o terminal real; capturar
saída num painel quebraria o caso motivador, então não é usado.

## Componentes

### 1. Gatilho no `handle_search` (`src/main.rs:987`)

No `Enter`:
- Se `app.draft.text().trim_start()` começa com `!`: extrai o comando (após o
  `!`, aparado). Se vazio, apenas volta ao `Mode::Normal` sem fazer nada.
  Senão, `app.queue_shell(cmd)`, volta ao `Normal`, limpa draft e search.
- Caso contrário: comportamento atual de busca (commit, `cursor = 0`).

Enquanto o texto começa com `!`, o `handle_search` **não** chama `set_search`
(evita filtrar a lista à toa). Demais teclas continuam editando o draft.

### 2. Estado no `App` (`src/app/mod.rs`)

Espelha `pending_editor_path`:
- Campo `pending_shell: Option<String>` (init `None`).
- `pub fn queue_shell(&mut self, cmd: String)` → seta.
- `pub fn take_pending_shell(&mut self) -> Option<String>` → `.take()`.

O `App` só enfileira; não toca no terminal (mantém-se puro e testável).

### 3. Execução no loop principal (`src/main.rs:254`)

Após `take_pending_editor_path`, adicionar:
```rust
if let Some(cmd) = app.take_pending_shell() {
    run_shell_command(app, &cmd)?;
}
```

`run_shell_command` espelha `open_path_in_editor` (`src/main.rs:318`):
- `DisableMouseCapture` + `ratatui::restore()`.
- `std::process::Command::new("sh").arg("-c").arg(cmd).status()` — stdio
  herdado (interativos funcionam).
- Pausa: imprime `\n[prumo] aperte Enter para voltar…` e lê uma linha do stdin
  (raw mode desabilitado → modo cozido, Enter serve).
- Restaura: `enable_raw_mode` + `EnableMouseCapture` + `EnterAlternateScreen`
  (mesma sequência do editor).
- `flash`: `comando concluído` ou `comando falhou (exit N)` conforme o status.

### 4. Recarregar ao voltar

- `check_external_changes()` (existente) recarrega o todo.txt se o comando o
  alterou.
- Recarrega o config explicitamente a partir de `app.config_path` (via
  `Config::load_strict` + `app.reload_config`) para refletir na hora um
  `advisor_link` recém-gravado, sem depender do watcher.
- `dirty = true` força o redraw.

### 5. Rótulo `SHELL` no status (`src/ui/status.rs:20`)

Em `Mode::Search`, se o draft começa com `!`, o rótulo mostra `SHELL` em vez de
`BUSCA`/`SEARCH` — dica visual de que Enter vai executar. Traduzido via
`brand::tr` (mantém snapshots em inglês).

## Segurança / escopo

App pessoal single-user; a entrada roda **qualquer** comando via `sh -c`
(pipes, `git status`, etc.), sem sanitização artificial. Sem superfície de rede
nessa entrada.

## Tratamento de erros

| Situação | Comportamento |
|---|---|
| `!` vazio | volta ao Normal, nada roda |
| comando sai ≠ 0 | saída já visível; flash `comando falhou (exit N)` |
| `sh` indisponível | flash com o erro; TUI restaurado normalmente |
| status Err (spawn) | flash com o erro; TUI restaurado |

## Testes

- Unitário no `App`/`handle_search`: `! cmd` + Enter enfileira `pending_shell`
  e sai do Search sem virar filtro; Enter com texto normal segue como busca e
  **não** enfileira; `!` vazio não enfileira.
- Rótulo `SHELL`: helper puro que decide o rótulo a partir do texto do draft.
- `run_shell_command` (handoff de terminal) é fino e verificado manualmente,
  como o `open_path_in_editor` de hoje (não testável em unit test).

## Fora de escopo (YAGNI)

- Embutir um emulador de terminal/PTY num painel do TUI.
- Histórico de comandos, autocomplete de shell.
- Captura de saída para painel (quebraria comandos interativos).
