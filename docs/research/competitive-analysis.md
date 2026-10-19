# Investigação competitiva e de integrações — PulseDock

Data da investigação: 2026-10-18
Ambiente: macOS 27.0.1 (26A434), Apple M1 Pro, Xcode 27.1, Swift 6.4, Claude Code 2.1.302.

Este documento registra o que foi observado, de onde veio cada evidência, como interpretamos e o que o
PulseDock fará de forma original. Nada aqui é código, asset ou texto copiado de outro produto.

## 1. Escopo e limites da investigação

| Fonte | Método | Situação |
| --- | --- | --- |
| Site público do PrimoDock (dock.oprimo.dev) | Leitura do HTML público | Feito |
| EULA do PrimoDock (dock.oprimo.dev/eula) | Leitura | Feito |
| PrimoDock.app 0.12.0 instalado em `/Applications` | Somente metadados declarativos: `Info.plist`, entitlements (`codesign -d`), lista de frameworks vinculados (`otool -L`), estrutura de pastas do bundle | Feito |
| Binário do PrimoDock (desmontagem/decompilação) | REA + Hopper/Ghidra/IDA | **Não realizado** (ver 1.1) |
| Execução observada do PrimoDock | Capturas de tela | Não realizado. A Gravação de Tela foi liberada depois (2026-10-18), mas executar o PrimoDock (um substituto de Dock) altera o ambiente do usuário e pode exigir licença; fica a critério do usuário |
| AgentDock (github.com/jstarfruits/AgentDock) | README público | Feito |
| Hooks do Claude Code | Documentação oficial `code.claude.com/docs/en/hooks.md` (versão atual) | Feito |
| Codex: hooks, `notify`, app-server | Documentação oficial `developers.openai.com/codex/*.md` + schemas gerados em `openai/codex/codex-rs/hooks/schema/generated` | Feito |

### 1.1 Por que o REA não foi usado contra o PrimoDock

1. **Licença**: o EULA do PrimoDock lista como proibido "fazer engenharia reversa além do que a lei brasileira
   permite expressamente". Desmontar o binário para estudar a implementação de UI de um produto concorrente
   não se enquadra nas exceções expressas da Lei 9.609/98. O próprio REA exige que o alvo seja analisado com
   autorização (`DISCLAIMER.md`, seção de licença do README).
2. **Pré-requisitos ausentes**: REA exige Node.js 22.19+, 24.11+ ou 26+ (o ambiente tem Node 20.20.2) e um
   motor nativo (Hopper, Ghidra ou IDA), nenhum instalado. `npx rea-agents setup` também registra um servidor MCP
   no Claude Code/Codex, o que exige reiniciar o agente.
3. **Necessidade**: os comportamentos de que o PulseDock precisa são implementáveis com APIs públicas do macOS
   e documentação oficial; não precisamos de equivalência com uma implementação privada.

Recomendação: manter o REA disponível para alvos que o usuário possua ou esteja autorizado a examinar (por
exemplo, protótipos internos ou componentes open source). A instalação depende de aprovação explícita e da
atualização do Node.

## 2. PrimoDock — descobertas

Cada item segue o formato: comportamento → fonte → hipótese → confiança → limitações → alternativa PulseDock.

### 2.1 App nativo, sem sandbox, distribuído fora da App Store
- **Observado**: universal (x86_64 + arm64), `LSMinimumSystemVersion` 14.0, `LSUIElement = true`,
  `com.apple.security.app-sandbox = false`, hardened runtime, Developer ID, notarização "stapled".
- **Fonte**: `Info.plist`, `codesign -dvv`, `lipo -archs`. O FAQ do site diz que o sandbox das lojas "proíbe o
  que o PrimoDock precisa fazer para desenhar o próprio Dock".
- **Hipótese**: janelas flutuantes globais, Apple Events e leitura de preferências de outros domínios exigem
  ausência de sandbox.
- **Confiança**: alta.
- **Alternativa PulseDock**: mesma classe de distribuição (Developer ID + notarização, fora da App Store),
  app agente (`LSUIElement`), alvo macOS 15+ conforme a especificação.

### 2.2 Stack: Swift + SwiftUI + AppKit com Observation
- **Observado**: vincula SwiftUI, AppKit, `libswiftObservation`, QuartzCore, CoreImage, Metal (via libswiftMetal).
- **Fonte**: `otool -L` do executável principal.
- **Hipótese**: UI declarativa em SwiftUI com modelos `@Observable`, AppKit para janelas e efeitos.
- **Confiança**: alta para a stack; baixa para a divisão interna de responsabilidades.
- **Alternativa PulseDock**: mesma família de tecnologia (é a recomendada pela Apple). A arquitetura interna é
  própria: renderização SwiftUI com geometria calculada por um motor de layout determinístico e interação
  centralizada em AppKit (ver `docs/architecture/overview.md`).

### 2.3 Atualizações via Sparkle
- **Observado**: `Sparkle.framework`, `SUFeedURL`, `SUPublicEDKey`, `SUScheduledCheckInterval`.
- **Confiança**: alta.
- **Alternativa PulseDock**: Sparkle é o padrão de mercado para apps fora da App Store. Fica para a Fase 7, com
  justificativa registrada em ADR; não entra no MVP.

### 2.4 Ambientes (workspaces) que movem janelas
- **Observado**: o site diz que, ao trocar de ambiente, "as janelas dos outros ambientes saem da frente e
  voltam quando você voltar"; ambientes seguem o Foco do macOS (`NSFocusStatusUsageDescription`, framework
  Intents).
- **Hipótese**: ocultação de apps (`NSRunningApplication.hide`) ou manipulação de janelas via Acessibilidade;
  leitura do estado de Foco via `INFocusStatusCenter`.
- **Confiança**: média para a mecânica.
- **Limitações**: sem observação em execução.
- **Alternativa PulseDock**: a especificação pede que a primeira versão troque somente o ambiente visual do
  dock (ícones, ordem, tema, widgets, filtros de IA), sem manipular janelas de terceiros. A integração com Foco
  e Spaces fica documentada como investigação futura.

### 2.5 Widgets "vivos" (31) em tiles quadrados ou faixas largas
- **Observado**: o site descreve tiles que desenham estado no próprio dock e abrem um painel nativo ao clicar;
  "um quadrado quando é um número, uma faixa larga quando tem mais o que dizer". Inclui música (Music e Spotify),
  bateria, atividade (CPU/memória), relógio, calendário, lembretes, GitHub, "Uso do Claude" (quota do plano).
- **Fonte**: site; `NSAppleEventsUsageDescription` cita Music e Spotify; EventKit e IOKit vinculados.
- **Hipótese**: Now Playing via Apple Events (sem framework privado MediaRemote); bateria e ventoinhas via
  IOKit/SMC; um helper privilegiado (LaunchDaemon `fan-helper`) para controlar ventoinhas.
- **Confiança**: alta para Apple Events em Music/Spotify; média para o restante.
- **Alternativa PulseDock**: framework interno de widgets com tamanhos compacto e expandido, estado vazio,
  limites de consumo e atualização reativa. MVP com 5 widgets (Relógio, System Health, Now Playing, Quick
  Launch, AI Activity). Now Playing usa as notificações distribuídas que Music e Spotify publicam (sem
  permissão) para informação e Apple Events só para os controles, com aviso contextual. Nada de helper
  privilegiado.

- **Atualização (2026-10-19)**: o PulseDock passou a ter 28 tipos de widget, cobrindo 25 dos 31 do PrimoDock
  com APIs públicas, mais três originais (Dock Cinema, Agent Heartbeat, Pulse Buddy). Decisões, exclusões e
  permissões no ADR 0010.

### 2.6 O widget de IA do PrimoDock mede quota, não estado de agentes
- **Observado**: "Uso do Claude: quanto do seu plano do Claude já foi, e quando ele zera". Não há menção a
  sessões, ferramentas, permissões ou subagentes.
- **Confiança**: alta (texto do site).
- **Oportunidade PulseDock**: este é o diferencial central. O PulseDock acompanha estado observável de sessões
  (trabalhando, aguardando você, falha, concluído, desatualizado) a partir de eventos oficiais, com retorno à
  sessão de origem. Não há concorrência direta nesse ponto dentro de um dock.
- **Atualização (2026-10-19)**: o PulseDock também tem **Uso do Claude** (limites de 5 h e semanal com
  renovação, custo estimado do dia, contexto por sessão), lido da status line oficial do Claude Code, sem
  credenciais, e com projeção de esgotamento e avisos em 80%/95%, que o PrimoDock não anuncia.

### 2.7 Temas
- **Observado**: Native ("o vidro do macOS"), Midnight ("vidro escuro… borda clara"), Rocket, Aqua Shelf, Neon,
  Canarinho, Paper, Floating e temas sazonais animados.
- **Confiança**: alta.
- **Observação de produto**: o PrimoDock já usa o nome **"Midnight"**. A especificação do PulseDock também pede
  um tema "Midnight". É uma palavra genérica, mas vale considerar um nome distinto (por exemplo "Graphite") antes
  do lançamento comercial. **Decisão do usuário**; por ora mantemos o nome da especificação.
- **Alternativa PulseDock**: três temas completos (Native Glass, Midnight, Aurora). A identidade do Aurora é a
  iluminação que responde aos estados dos agentes, algo que o PrimoDock não faz.

### 2.8 Material "igual ao nativo"
- **Observado**: "Liquid Glass" e "o vidro do macOS, sem tirar nem pôr".
- **Hipótese**: `NSGlassEffectView` / `glassEffect` (macOS 26+) com fallback `NSVisualEffectView` para macOS 14–15.
- **Confiança**: média.
- **Alternativa PulseDock**: material próprio "Pulse Glass" sobre APIs nativas: `NSGlassEffectView` no macOS 26+
  e `NSVisualEffectView` (`.behindWindow`) no macOS 15, com realce superior, borda hairline, compensação de
  contraste e degradação para opaco com Reduzir Transparência. Sem captura de tela para desfoque.

### 2.9 Retorno ao Dock original ao sair, inclusive em fechamento inesperado
- **Observado**: FAQ: "É só sair do PrimoDock: o Dock do Mac ou a barra do Windows voltam exatamente como
  estavam, mesmo se ele fechar de repente."
- **Hipótese**: ocultação por `autohide` e/ou `autohide-delay` alto, restaurada ao sair; para crashes, um
  processo vigia (os "Slot" helpers ou o próprio launchd).
- **Confiança**: baixa para o mecanismo de crash.
- **Alternativa PulseDock**: Replacement Mode usa apenas o `autohide` oficial do Dock, alterado pela suíte de
  scripting do System Events com consentimento. É seguro em crash: o Dock do macOS continua acessível na borda.
  O ajuste opcional de atraso (`autohide-delay`) só é aplicado com aviso explícito, tem restauração automática
  ao sair e na próxima abertura, e um botão "Restaurar Dock original" no menu e em Configurações.

### 2.10 Helpers "Slot" (12 apps-stub)
- **Observado**: `Contents/Helpers/PrimoDock Slot N.app`, cada um com `CFBundleName = "Collection"`, executável
  `PrimoDockSlot` e chave `PrimoDockSlot = N`.
- **Hipótese**: dar a coleções de apps uma identidade de app real (ícone próprio, presença no Cmd-Tab ou no
  Dock do sistema).
- **Confiança**: baixa.
- **Alternativa PulseDock**: coleções do Quick Launch são itens internos do dock com painel próprio; não
  criamos bundles-stub.

### 2.11 Pré-visualização de janelas
- **Observado**: ScreenCaptureKit vinculado.
- **Hipótese**: miniaturas de janelas, que exigem permissão de Gravação de Tela.
- **Confiança**: média.
- **Alternativa PulseDock**: a especificação proíbe prometer pré-visualização sem implementar as permissões. Na
  primeira versão: lista de janelas (títulos via Acessibilidade, opcional e contextualizada), contagem de janelas
  sem permissão e restauração de minimizadas. Miniaturas ficam como fase futura, opt-in.

### 2.12 Atalhos globais e mascote
- **Observado**: Carbon vinculado; "troca com um atalho, a roda do mouse ou as bolinhas na barra"; mascote
  animado conforme a carga do sistema.
- **Hipótese**: `RegisterEventHotKey` (Carbon) para atalhos globais, que não exige Acessibilidade.
- **Confiança**: média.
- **Alternativa PulseDock**: atalhos globais via Carbon para Privacy Mode e troca de workspace. Sem mascote: a
  "vida" do PulseDock vem do Ambient AI (estado real dos agentes), não de decoração.

### 2.13 Multi-monitor e ocultação automática
- **Observado**: "O Dock fica na tela dele, mesmo com telas empilhadas e ocultar automaticamente".
- **Confiança**: alta para a existência do recurso.
- **Alternativa PulseDock**: escolha de monitor (principal, específico por UUID estável do display, ou seguir o
  cursor), reposicionamento em `didChangeScreenParametersNotification`, zona de revelação por monitor e supressão
  de revelação sobre apps em tela cheia ou jogos.

### 2.14 Modelo comercial
- **Observado**: licença vitalícia (R$ 34,90), 7 dias de teste, Mac + PC na mesma licença, compra em grupo.
- **Relevância**: referência de preço para o mercado brasileiro. Fora do escopo técnico do MVP.

## 3. AgentDock — monitoramento de sessões (referência)

- **O que faz**: app de barra de menus com painel flutuante que classifica sessões em "precisa de atenção",
  "rodando" e "ocioso", com retorno ao app ou workspace.
- **Fontes de dados**: `~/.claude/sessions/*.json` + transcripts `~/.claude/projects/**/*.jsonl`;
  `~/.codex/sessions/.../rollout-*.jsonl`; `~/.claude/ide/*.lock`.
- **Mecânica**: polling a cada 3 segundos e inferência a partir de transcripts. Detecção precisa de permissões
  pendentes está fora de escopo, segundo o próprio README.
- **Lições aproveitadas**:
  1. Assinatura com identidade estável evita perder permissões de TCC a cada rebuild. Assinatura ad-hoc muda o
     cdhash e revoga Acessibilidade e Automação.
  2. Agrupar sessões com atenção pendente antiga ("Stalled") evita poluição.
  3. Retorno ao app só eleva janelas existentes; nunca abre janelas novas às cegas.
- **Onde o PulseDock vai além**:
  - Orientado a eventos (hooks oficiais), sem polling de transcripts e sem ler conteúdo de conversa.
  - Permissões pendentes detectadas no instante do `PermissionRequest`, não por heurística.
  - Turno, sessão e tarefa separados; subagentes; falhas de ferramenta; `StopFailure`; estado `stale` explícito.
  - O registro local `~/.claude/sessions/<pid>.json` (formato não documentado, observado nesta versão) é
    usado apenas como **descoberta e liveness** (pid, sessionId, cwd, nome), com confiança "inferida", nunca como
    fonte de estado.

## 4. Superfícies de integração verificadas

### 4.1 Claude Code (2.1.302) — hooks oficiais
- Eventos relevantes e campos confirmados na documentação atual: `SessionStart` (`source`, `model?`,
  `session_title?`), `SessionEnd` (`reason`), `UserPromptSubmit` (`prompt`), `PreToolUse`
  (`tool_name`, `tool_input`, `tool_use_id`), `PermissionRequest` (sem `tool_use_id`; `permission_suggestions`),
  `PostToolUse` (`tool_response`, `duration_ms?`), `PostToolUseFailure` (`error`, `is_interrupt?`),
  `PostToolBatch`, `PermissionDenied` (só em auto mode), `Notification` (`notification_type`, `message`,
  `title?`), `SubagentStart`/`SubagentStop` (`agent_id`, `agent_type`), `TaskCreated`/`TaskCompleted`
  (`task_id`, `task_subject`), `Stop` (`background_tasks`, `session_crons`), `StopFailure` (`error` enum).
- Campos comuns: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`,
  `agent_id`/`agent_type` em subagentes.
- Fatos que moldam o design:
  - `Stop` **não** dispara em interrupção pelo usuário. O PulseDock trata um novo `UserPromptSubmit` com turno
    aberto como interrupção inferida e usa liveness do processo.
  - `Notification/permission_prompt` só chega após ~6 s; `PermissionRequest` é o sinal imediato.
  - Exit code 0 sem stdout = sem efeito. Em `UserPromptSubmit` e `SessionStart`, stdout vira contexto do
    modelo: o helper **nunca** escreve em stdout.
  - Hooks rodam sem terminal controlador; o helper descobre TTY e app hospedeiro pela cadeia de processos.
  - Edições diretas nos arquivos de settings são recarregadas automaticamente.
  - `SessionEnd` tem orçamento total de 1,5 s.

### 4.2 Codex — três mecanismos oficiais
1. **Hooks** (habilitados por padrão; exigem revisão/confiança do usuário em `/hooks`): `SessionStart`,
   `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse` (inclusive Bash com exit
   ≠ 0), `SubagentStart`/`SubagentStop`, `Stop`, **`Interrupt`**, `PreCompact`/`PostCompact`. Eventos de turno
   trazem `turn_id`. Schemas exatos baixados do repositório oficial.
2. **`notify`** (`config.toml`): programa externo recebe um JSON no último argumento; hoje só
   `agent-turn-complete` (`thread-id`, `turn-id`, `cwd`, `input-messages`, `last-assistant-message`). Informa
   apenas conclusão de turno.
3. **App-server** (JSON-RPC 2.0 via stdio JSONL): `thread/start`, `turn/start`, `turn/interrupt`; notificações
   `turn/started`, `turn/completed` (`completed|interrupted|failed`), `item/started|completed`,
   `turn/plan/updated`, `thread/status/changed` (`activeFlags: waitingOnApproval`); aprovações via requisições
   do servidor `item/commandExecution/requestApproval` e `item/fileChange/requestApproval` com decisões
   `accept|acceptForSession|decline|cancel`.
- **Implicação**: Observe Mode = hooks (contínuo, com limitações documentadas) e `notify` como fallback
  (somente conclusão de turno). Managed Mode = app-server, só para sessões iniciadas pelo PulseDock. Uma conexão
  nova ao app-server não observa processos `codex` independentes.

## 5. Síntese de oportunidades

1. Dock nativo com acabamento de primeira linha **e** consciência de agentes. Nenhuma referência combina os dois.
2. Estados confiáveis acima de efeitos: cada rótulo exibido vem de um evento concreto, com origem e confiança.
3. Atenção priorizada: uma aprovação pendente nunca fica escondida atrás de sessões trabalhando.
4. Retorno à sessão correta: identificação por cadeia de processos, TTY e app hospedeiro, com seleção de aba
   no Terminal.app quando a Automação é permitida.
5. Privacidade por padrão: sanitização na borda (no helper), sem prompts, conteúdo de arquivos ou saída de
   comandos.
