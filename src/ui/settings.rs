use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::brand::tr;
use crate::ui::header;

pub fn render(frame: &mut Frame, area: Rect, app: &App) {
    let theme = app.theme();
    super::fill_bg(frame, area, Style::default().bg(theme.bg));

    let [header_area, _sp, body_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(1),
    ])
    .areas(area);

    header::render(
        frame,
        header_area,
        theme,
        header::HeaderProps {
            title: Some(tr("settings", "configurações")),
            // title: None,
            // file: "settings",
            count: app.tasks().len(),
            sort: app.sort_label(),
            filter: None,
        },
    );

    let mut lines: Vec<Line> = Vec::new();
    let density = match app.prefs.density {
        crate::app::Density::Compact => tr("compact", "compacta"),
        crate::app::Density::Comfortable => tr("comfortable", "confortável"),
        crate::app::Density::Cozy => tr("cozy", "espaçosa"),
    };
    let on = |b: bool| {
        if b {
            tr("on", "ativado")
        } else {
            tr("off", "desativado")
        }
    };

    let config_path = app
        .config_path
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| tr("(unavailable)", "(indisponível)").into());

    let items: &[(&str, Option<String>)] = &[
        (tr("FILES", "ARQUIVOS"), None),
        (
            tr("  todo file", "  arquivo de tarefas"),
            Some(app.file_path.display().to_string()),
        ),
        (
            tr("  config file", "  arquivo de config"),
            Some(config_path),
        ),
        ("", Some("".into())),
        (tr("DISPLAY", "EXIBIÇÃO"), None),
        (
            tr("  theme", "  tema"),
            Some(format!(
                "{} ▾  ({})",
                theme.name,
                tr("T to cycle", "T alterna")
            )),
        ),
        (
            tr("  density", "  densidade"),
            Some(format!(
                "{} ▾  ({})",
                density,
                tr("D to cycle", "D alterna")
            )),
        ),
        (
            tr("  line numbers", "  números de linha"),
            Some(format!(
                "{}  ({})",
                on(app.prefs.layout.line_num),
                tr("L to toggle", "L alterna")
            )),
        ),
        (
            tr("  status bar", "  barra de status"),
            Some(on(app.prefs.layout.status_bar).into()),
        ),
        (
            tr("  filter sidebar", "  sidebar de filtro"),
            Some(format!(
                "{}  ({})",
                on(app.prefs.layout.left),
                tr("[ to toggle", "[ alterna")
            )),
        ),
        (
            tr("  detail sidebar", "  sidebar de detalhe"),
            Some(format!(
                "{}  ({})",
                on(app.prefs.layout.right),
                tr("] to toggle", "] alterna")
            )),
        ),
        (
            tr("  show done in list", "  concluídas na lista"),
            Some(format!(
                "{}  ({})",
                on(app.prefs.show_done),
                tr("H to toggle", "H alterna")
            )),
        ),
        (
            tr("  show future in list", "  futuras na lista"),
            Some(format!(
                "{}  ({})",
                on(app.prefs.show_future),
                tr("F to toggle", "F alterna")
            )),
        ),
        ("", Some("".into())),
        (tr("BEHAVIOR", "COMPORTAMENTO"), None),
        (
            tr("  default sort", "  ordenação padrão"),
            Some(format!(
                "{} ({})",
                app.sort_label(),
                tr("s to cycle", "s alterna")
            )),
        ),
        ("", Some("".into())),
        (tr("KEYBINDINGS", "ATALHOS"), None),
        (
            "  ",
            Some(
                tr(
                    "press ? for the full list",
                    "pressione ? para a lista completa",
                )
                .into(),
            ),
        ),
    ];

    for (k, v) in items {
        match v {
            None => {
                lines.push(Line::from(vec![
                    Span::raw(" "),
                    Span::styled(
                        k.to_string(),
                        Style::default()
                            .fg(theme.accent)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]));
            }
            Some(val) if k.is_empty() => {
                lines.push(Line::raw(" "));
                let _ = val;
            }
            Some(val) => {
                let mut padded = k.to_string();
                let len = padded.chars().count();
                if len < 30 {
                    padded.push_str(&" ".repeat(30 - len));
                }
                lines.push(Line::from(vec![
                    Span::raw(" "),
                    Span::styled(padded, Style::default().fg(theme.fg)),
                    Span::styled(val.clone(), Style::default().fg(theme.dim)),
                ]));
            }
        }
    }

    let para = Paragraph::new(lines).style(Style::default().bg(theme.bg).fg(theme.fg));
    frame.render_widget(para, body_area);
}
