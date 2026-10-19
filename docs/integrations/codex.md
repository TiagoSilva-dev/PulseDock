# Integração com o Codex

Status: **implementada e validada contra os schemas e o protocolo oficiais**. Ainda **não** foi testada com o
Codex real, porque o Codex CLI não está instalado no Mac de desenvolvimento (decisão do usuário em
2026-10-18). Ver os critérios de aceitação na seção 6.

O Codex tem três mecanismos oficiais com observabilidade muito diferente (ADR 0007). A UI sempre diz qual
está em uso e o que ele **não** consegue ver.

| Modo | Mecanismo | O que o PulseDock vê | Ações |
| --- | --- | --- | --- |
| Observe (hooks) | `~/.codex/hooks.json` | sessão, prompt (sem texto), ferramentas, pedidos de aprovação, subagentes, interrupções, fim de turno | navegar até a sessão (Smart Return) |
| Observe (notify) | `notify` em `~/.codex/config.toml` | **só o fim de cada turno** | navegar até a sessão |
| Managed | `codex app-server` (JSON-RPC por stdio) | threads iniciadas pelo PulseDock: turnos, itens, plano, aprovações | aprovar/recusar **conforme a API**, interromper o turno |

## 1. Observe Mode com hooks (preferido)

Ajustes › Agentes de IA › Codex › **Conectar com Hooks…**

- Mescla handlers do PulseDock em `~/.codex/hooks.json` (respeitando `CODEX_HOME`), com prévia, backup e
  preservação de hooks de terceiros, como no Claude Code.
- Eventos: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`,
  `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt`, `PreCompact`, `PostCompact`.
- **Confiança**: o Codex só executa hooks novos depois que o usuário os revisa com `/hooks`. Até o
  primeiro evento chegar, o chip mostra "confie nos hooks no Codex" e os Ajustes explicam o passo.
- Ferramentas do Codex: `apply_patch` vira "Editando código" e guarda **só os nomes dos arquivos**;
  comandos em forma de `argv` são juntados e então sanitizados como no Claude Code.
- `Interrupt` vira turno `interrupted` (confirmado), sem precisar de inferência.

## 2. Observe Mode com `notify` (alternativa)

Ajustes › Agentes de IA › Codex › Mais › **Usar notify (só fim de turno)…**

- O Codex aceita **um** programa em `notify`. Se já existir um, o PulseDock o guarda em
  `codex-notify-chain.json` e o helper **repassa** cada notificação a ele, então a integração existente
  continua funcionando. A desinstalação restaura a linha original.
- Só é editado automaticamente um `notify = [...]` de **uma linha** no nível superior; outros formatos são
  reportados para edição manual (teste "Multi-line notify arrays are left for manual editing").
- Conteúdo da conversa (`input-messages`, `last-assistant-message`) é descartado no helper.
- A UI marca a sessão como "só fim de turno" e nunca mostra "Trabalhando" entre as notificações: o estado
  fica desconhecido até o próximo `agent-turn-complete`.

## 3. Managed Mode (app-server)

Ajustes › Agentes de IA › Codex › **Iniciar uma Tarefa Gerenciada do Codex…** (escolher pasta e prompt).

- `CodexManagedService` inicia `codex app-server`, faz o handshake `initialize` → `initialized` e chama
  `thread/start` e `turn/start`.
- Notificações mapeadas: `thread/started`, `turn/started`, `item/started`, `item/completed`,
  `turn/plan/updated` (progresso verificável por etapas), `turn/completed` e `thread/closed`.
- Pedidos do servidor: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
  `item/permissions/requestApproval` e `item/tool/requestUserInput`. O Agent Card mostra comando, motivo,
  diretório e permissões, e oferece **só** as decisões que o pedido declara (por exemplo, aprovar, aprovar
  nesta sessão, recusar, cancelar o turno). Nada é aprovado sem clique; sandbox e política de aprovação do
  usuário ficam com o Codex.
- **Interromper**: `turn/interrupt`, disponível só para threads que o PulseDock iniciou.
- Uma conexão ao app-server **não** observa sessões abertas em terminais; para elas, use o Observe Mode.

## 4. Privacidade

Mesmo sanitizador do Claude Code (ver `docs/privacy.md`). No Managed Mode, o PulseDock envia ao Codex o
prompt digitado pelo usuário, mas **não** o grava: o histórico guarda só metadados.

## 5. Limitações conhecidas

- Sem o Codex instalado aqui, a compatibilidade depende dos schemas oficiais de 2026-10. Mudanças de versão
  do Codex podem exigir ajustes no normalizador (o envelope guarda o nome do evento original para
  diagnóstico).
- `notify` não tem início de turno: o tempo de atividade de sessões só com notify é desconhecido.
- Smart Return para sessões do Codex depende da cadeia de processos capturada pelo helper (hooks/notify).
  Sessões do Managed Mode não têm terminal de origem: "Abrir sessão" leva à pasta do projeto, e o
  acompanhamento fica no Agent Card e no Mission Control.

## 6. Critérios de aceitação (independentes)

| Modo | Critério | Situação |
| --- | --- | --- |
| Observe/hooks | Instalação mescla e desinstala sem perdas | ✅ teste "hooks.json install merges with existing hooks and uninstalls cleanly" |
| Observe/hooks | Eventos oficiais (inclusive falha de Bash e `Interrupt`) normalizam corretamente | ✅ "Codex hook events normalise, including Bash failures and interrupts" |
| Observe/hooks | Sessão real exibida após `/hooks` | ⏳ requer o Codex instalado |
| Observe/notify | Só fim de turno, sem conteúdo | ✅ "notify reports turn completion only and drops conversation content" |
| Observe/notify | Encadeia e restaura o notify anterior | ✅ "notify install chains the previous command and uninstall restores it" |
| Observe/notify | Tarefa real representada sem atividade inventada | ⏳ requer o Codex instalado |
| Managed | Protocolo mapeado; aprovações carregam as decisões da API | ✅ "App-server traffic maps to events; approvals carry their decisions" |
| Managed | Tarefa real com aprovação respondida pelo Agent Card | ⏳ requer o Codex instalado e login |

Roteiro para fechar os itens ⏳: `docs/testing.md`, seção "Codex real".
