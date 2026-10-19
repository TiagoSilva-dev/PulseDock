# Roadmap

Legenda: ✅ concluído e verificado · ◐ implementado, com validação pendente · ⏳ não iniciado

## Fases do MVP

| Fase | Situação | Notas |
| --- | --- | --- |
| 0 — Discovery e viabilidade | ✅ | `docs/research/competitive-analysis.md`, arquitetura, matriz de compatibilidade, riscos, tokens. O REA não foi usado: licença do alvo + pré-requisitos ausentes (documentado). Wireframes substituídos por capturas reais da implementação (`docs/screenshots/`) |
| 1 — Dock nativo funcional | ✅ | Abre e alterna apps reais, fixa/desafixa, arrastar e soltar, magnificação, auto-hide, menu contextual, ajustes, persistência. Em uso contínuo durante o desenvolvimento |
| 2 — Agent Pulse e dados simulados | ✅ | Modelo de eventos, máquina de estados, ilha, card, timeline, modo Demo marcado (selo DEMO, nunca gravado) |
| 3 — Claude Code real | ✅ / ◐ | Instalador reversível, helper, socket, spool, subagentes, falhas e compactação validados ao vivo. Pendente ao vivo: permissão, duas sessões simultâneas, `StopFailure` (roteiro em `docs/testing.md`) |
| 4 — Codex real | ◐ | Observe Mode (hooks e notify) e Managed Mode (app-server) implementados contra schemas e protocolo oficiais. Pendente: Codex instalado para o teste ponta a ponta |
| 5 — AI Mission Control | ✅ | Filtros, projetos, busca, período, ordenação, timeline agrupada, observabilidade por integração, privacidade |
| 6 — Premium Polish | ◐ | Duas rodadas de revisão com capturas reais (escuro e claro, pt-BR e inglês). Pendente: revisão do material do macOS 15, do onboarding e com VoiceOver |
| 7 — Estabilidade e distribuição | ◐ | 66 testes, benchmark, suspensão/retomada, build universal, ZIP + DMG, assinatura/notarização por script, desinstalação. Pendente: credenciais Developer ID, multi-monitor físico, Mac Intel real, auditoria de acessibilidade, relatório de falhas local |

## Próximas tarefas recomendadas (em ordem)

1. **Roteiro manual do Claude Code** (`docs/testing.md` §4.1): duas sessões, permissão, Esc, terminal fechado.
2. **Codex real**: instalar, confiar nos hooks e rodar os três modos (§4.2).
3. **Developer ID + notarização** com `scripts/package.sh`; instalar em outro Mac.
4. **Testes de snapshot das views** (ilha nos cinco modos, card, Mission Control) para pegar regressões
   visuais como as corrigidas nesta rodada.
5. **Acessibilidade**: VoiceOver na ilha, no card e no Mission Control; navegação completa por teclado no
   dock (hoje: card e janelas).
6. **Relatório de falhas local e opcional**: na próxima abertura, detectar um relatório novo em
   `~/Library/Logs/DiagnosticReports` e oferecer exportá-lo sanitizado (nada é enviado).
7. **Pré-visualização de janelas** com ScreenCaptureKit, opcional e com permissão explícita (hoje: títulos e
   restauração via Acessibilidade).
8. Posições laterais do dock (esquerda/direita).
9. Atualizações assinadas (Sparkle 2, com chaves EdDSA), se a distribuição direta for confirmada.

## Visão futura (não bloqueia o MVP)

| Ideia | Preparação já existente | O que falta |
| --- | --- | --- |
| AI Command Center | Managed Mode do Codex (app-server) inicia e controla threads | Generalizar para outros provedores com APIs de controle oficiais |
| Smart Workflows | Eventos normalizados e persistidos | Motor de regras local (por exemplo, "quando os testes passarem, notifique") |
| Remote Companion | Envelope versionado e independente de transporte | Transporte autenticado e criptografado entre máquinas; modelo de ameaça próprio |
| Mobile Companion / Wearables | Agregado de prioridade (`AggregateSummary`) | Canal seguro + app/complicação; notificações resumidas |
| Plugin SDK | Normalizador `BridgeEnvelope → [AgentEvent]` + instaladores sobre `ConfigFileEditor` | API pública estável, versionamento e isolamento de plugins |
| Workspace Automation | Ambientes com tema, widgets e filtros | Gatilhos (app ativo, projeto do agente), sem manipular janelas sem consentimento |
| Agent Analytics | Histórico local de turnos, falhas e atenção | Painel de métricas locais (tempo ativo, intervenções), com controles de privacidade |

Cada item exige seu próprio documento de viabilidade antes da implementação.
