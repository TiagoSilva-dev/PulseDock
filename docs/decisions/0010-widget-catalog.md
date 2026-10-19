# ADR 0010 — Catálogo de widgets: só APIs públicas, permissões no contexto, zero custo parado

- Status: aceito
- Data: 2026-10-19

## Contexto

O PrimoDock anuncia 31 widgets (levantamento em `docs/research/competitive-analysis.md` §2.5). O PulseDock
tinha 5. O pedido foi trazer os melhores, criar algo original e, se possível, um widget do YouTube, sem
abrir mão das regras do produto: nada de APIs privadas, permissões só quando fazem sentido, privacidade
local e CPU ociosa abaixo de 1%.

## Decisão

### Catálogo (28 tipos, 7 categorias)

| Categoria | Widgets | Fonte dos dados |
| --- | --- | --- |
| Agentes de IA | **Agent Heartbeat**, **Pulse Buddy** (originais) | eventos aceitos pelo motor (`AgentHeartbeat`, só em memória) |
| Tempo | Relógio (fuso e analógico), Calendário, Timer, Cronômetro, Pomodoro, Contagem regressiva, Progresso do tempo | relógio do sistema; EventKit |
| Produtividade | Lembretes, Nota, Atalhos, Água, Quick Launch | EventKit; `/usr/bin/shortcuts`; dados locais |
| Arquivos | Downloads (ou outra pasta), Prateleira, AirDrop, Capturas de tela | `FileManager` + vnode; `NSSharingService`; Quick Look |
| Utilidades | Área de transferência, Conta-gotas, Emoji, Conversor | `NSPasteboard`; `NSColorSampler`; `Measurement` |
| Sistema | Saúde do Sistema, Rede, Bateria, Clima | Mach; `getifaddrs`; IOKit; Open-Meteo |
| Mídia | Tocando Agora, **Dock Cinema** (original, YouTube) | notificações distribuídas; player oficial do YouTube |

Ficaram de fora do PrimoDock: **Ventoinhas** (exige SMC/privilégios), **Trava do teclado** (exige
Monitoramento de Entrada para um ganho pequeno) e **GitHub** (exigiria ler credenciais do usuário). Ficam no
roadmap se houver uma API oficial com consentimento claro.

### Uso do Claude (2026-10-19, revisão desta decisão)

A primeira versão excluiu o widget por supor que exigiria ler credenciais. Não exige: o Claude Code entrega
oficialmente à **status line** (`code.claude.com/docs/en/statusline`) `rate_limits.five_hour` e `seven_day`
(percentual e `resets_at`, para Pro e Max), `spend_limit` (gateway), `cost.total_cost_usd` (estimativa a preço
de tabela) e `context_window`. Decisões:

- O helper ganha o modo `claude-statusline`. É a única exceção à regra "nada em stdout": a saída dele **é** a
  status line. Sem status line prévia, imprime uma linha compacta neutra (`Opus · ctx 8% · 5h 23% · 7d 41%`).
- O Claude Code tem **uma** `statusLine`. Se o usuário já tem uma, ela é preservada: o objeto original vai para
  `claude-statusline-chain.json` (0600) e o helper a executa com a mesma entrada; o comando original também
  fica como fallback do shell (`|| ( … )`), então sobrevive se o PulseDock for apagado sem desinstalar. A
  remoção devolve o objeto exato (testado).
- Sanitização por lista branca no helper (`StatusLineSanitizer`): título da sessão (gerado da conversa),
  `transcript_path`, PR, repositório e worktree são descartados.
- Honestidade: os números só mudam quando o Claude Code responde (o painel mostra a idade); janelas vencidas
  somem; o custo é rotulado "estimativa, não fatura"; sessões já abertas antes do PulseDock contam só a partir
  de quando foram vistas (o dia fica marcado como parcial). A **projeção** ("no ritmo atual, atinge o limite
  às 14:20") só aparece com ≥ 10 min e ≥ 1 ponto de crescimento observados na mesma janela, e só se vencer a
  renovação.
- Avisos nativos ao cruzar 80% e 95% (uma vez por janela), respeitando o horário de silêncio e desligáveis.
- Snapshots de uso não vão para o spool (ficam velhos em segundos) e são gravados no máximo 2×/min.

### Dock Cinema (YouTube)

- Usa o **player oficial incorporado** (IFrame Player API) no host de privacidade aprimorada
  `youtube-nocookie.com`, num `WKWebView` com armazenamento não persistente. O PulseDock **não** baixa nem
  extrai streams; vídeos cujo dono proíbe a incorporação mostram "Abrir no YouTube".
- O título vem do endpoint público oEmbed (sem chave, sem conta). Nada é contatado antes de o usuário
  adicionar um vídeo.
- Janela flutuante (picture in picture) que acompanha Spaces e apps em tela cheia, 16:9, redimensionável,
  sem roubar o foco. Os controles sobre o vídeo só capturam cliques na faixa superior e no aviso; o resto
  vai para os controles do próprio YouTube.
- **Diferencial**: quando surge um *novo* pedido de um agente (`attentionCount` aumenta), o vídeo pausa e
  o player diz qual agente precisa de você ("Codex · Aprovação necessária", com DEMO quando simulado).
  Opcionalmente, continua depois que todos os pedidos forem respondidos.
- **Vídeo aberto no navegador** (2026-10-19, opcional): não existe API pública para o "Tocando Agora" do
  sistema (MediaRemote é privado e, desde o macOS 15.4, restrito), então o Cinema usa o dicionário AppleScript
  oficial de cada navegador (Safari, Chrome, Brave, Edge, Vivaldi; Arc só a aba da frente; Firefox não tem
  dicionário). Desligado até o usuário pedir ("Detectar"), com o consentimento de Automação do macOS por
  navegador. O filtro roda **dentro** do script: URLs de abas que não são do YouTube não saem do `osascript`.
  Só navegadores já abertos são consultados (nunca abertos pelo PulseDock), ao abrir o painel e ao sair de um
  navegador, sem timer; nada é gravado. Ranking: aba selecionada, depois navegador usado por último, depois a
  janela da frente. "Continuar no Cinema" pausa a aba e continua do mesmo segundo **só** se o usuário ativou
  "Permitir JavaScript de Apple Events" no navegador; senão usa o `t=` do link ou o início. Não dá para saber
  se a aba está tocando sem esse JavaScript, então a interface diz "aberto no Chrome", nunca "assistindo".

### Agent Heartbeat e Pulse Buddy

- O Heartbeat desenha um ECG: um pico por intervalo com eventos reais (chamada de ferramenta, fim de turno,
  falha, pedido para você), colorido pelo tipo mais importante. **Silêncio é linha reta**: ausência de
  eventos nunca é desenhada como atividade (ADR 0005). O painel separa as sessões e traz o **Radar de
  Testes**: o último resultado de teste por projeto, a partir da mesma classificação literal de comandos
  (`ToolClassifier`). "Passou" só com código de saída 0; sem código, "terminou sem erro".
- O Pulse Buddy é um personagem original cujo humor é o estado agregado. Ele **não anima continuamente**:
  dá um pulinho (`keyframeAnimator`, cerca de 0,6 s) quando o humor muda e, enquanto um agente espera por
  você, a cada 4 s. A primeira versão balançava a 30 fps enquanto um agente trabalhava e custava **15% de
  CPU**; a versão final volta a 0,14% (medido com `scripts/benchmark.sh`).
- Dados simulados aparecem com o selo DEMO nos tiles e painéis (`Beat.isDemo`, `TestRun.isDemo`).

### Permissões e privacidade

- Calendário e Lembretes: EventKit, pedido só quando o usuário clica em "Permitir…" no painel; entitlement
  `com.apple.security.personal-information.calendars` para o hardened runtime.
- Pastas (Downloads, Mesa, Documentos): o macOS pergunta na primeira leitura; textos em `Info.plist`.
- **Área de transferência**: desde o macOS 15.4, ler o pasteboard sem um gesto de colar mostra um alerta.
  O widget só registra quando o usuário escolheu "Permitir Sempre" (`NSPasteboard.accessBehavior`); caso
  contrário explica e oferece um botão que faz uma única leitura iniciada pelo usuário. O histórico fica só
  na memória; tipos marcados como ocultos/transitórios (nspasteboard.org) nunca entram; só textos fixados
  persistem.
- Clima: Open-Meteo, com a cidade escolhida por nome; só as coordenadas da cidade são enviadas, nunca a
  localização do Mac. Atribuição exibida (CC BY 4.0).
- Painéis com campos de texto **não focam nenhum campo ao abrir**: um campo focado convidava o AutoFill do
  macOS a sobrepor sugestões (como códigos de verificação do Mensagens) ao painel.

### Arquitetura

- Lógica pura e testável em `WidgetCore` (timers com relógio injetado, Pomodoro, `TimeMath`, `YouTubeLink`,
  `OpenMeteo`, `UnitConverter`, `ClipboardPolicy`, `InterfaceCounters`, `EmojiCatalog`) e em
  `AgentCore/Presentation/AgentHeartbeat.swift`. Views e controladores em `PulseDockApp/Widgets/`.
- Um provedor por tipo, compartilhado entre posições, exceto fontes por posição (cidade, pasta). Provedores
  só trabalham com o widget no dock e o dock visível (a área de transferência continua ouvindo com o dock
  oculto, porque cópias continuam acontecendo).
- Opções por posição em `WidgetPlacement.options` (fuso, cidade, data…). Dados dos widgets (notas, água,
  fila do Cinema…) em `WidgetDataStore`, chave própria na tabela `settings`, para que digitar uma nota não
  reconstrua o dock.
- `Workspace.widgets` decodifica elemento a elemento (`LossyArray`): um widget desconhecido, criado por uma
  versão mais nova, é descartado sozinho em vez de apagar o ambiente inteiro.
- Quando o conteúdo passa da largura da tela, o dock **reduz o tamanho efetivo dos ícones** até caber (mínimo
  24 pt), como o Dock do macOS; o tamanho configurado volta quando houver espaço.
- Painéis medem o conteúdo (`fittingSize`) e usam o tamanho de cada widget como teto.

## Consequências

- 81 testes (eram 66): `WidgetCoreTests` (10) e `HeartbeatTests` (5).
- A revisão visual ao vivo cobriu todos os widgets exceto Downloads e Capturas de tela, cujo primeiro uso
  dispara pedidos de acesso a pastas do macOS (a lógica do `FolderWatcher` foi exercitada pelo build, não ao
  vivo nesta rodada).
- Calendário e Lembretes foram revisados no estado "antes da permissão"; a listagem real depende de o
  usuário conceder acesso.
