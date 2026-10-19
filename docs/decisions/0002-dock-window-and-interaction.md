# ADR 0002 — Janela do dock: painel não ativador com interação centralizada

- Status: aceito
- Data: 2026-10-18

## Contexto

O dock precisa ficar acima das janelas comuns em todos os Spaces, nunca roubar o foco do app ativo, deixar
passar cliques nas áreas transparentes (a janela é mais alta que a barra, para caber a magnificação e o
rótulo) e não aparecer sobre apps em tela cheia ou jogos.

## Decisão

- `DockPanel` é um `NSPanel` com `[.borderless, .nonactivatingPanel]`, nível `kCGDockWindowLevel`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` e `canBecomeKey = false`.
  - Sem `.fullScreenAuxiliary`, o painel não entra nos Spaces de tela cheia.
  - Quando o app em primeiro plano cobre a tela inteira no Space atual (caso de jogos sem
    borda), o dock não se revela (opção "Não atrapalhar apps e jogos em tela cheia"). A checagem usa só os
    limites e o dono das janelas em `CGWindowListCopyWindowInfo`, o que não exige permissão.
- A janela começa com `ignoresMouseEvents = true`. Um monitor **global** de `mouseMoved` (eventos de mouse
  não exigem permissão de Acessibilidade) e um monitor local calculam se o ponteiro está na área
  interativa: a barra, ou a barra mais o espaço da magnificação enquanto ela está ativa. Só nesse caso a janela passa
  a receber eventos. O resultado é que as áreas transparentes nunca bloqueiam cliques em outros apps.
- Cliques, arrasto, menus contextuais e drops de arquivos são tratados por uma única `NSView`
  (`DockHostView`), com hit-testing feito sobre a geometria **apresentada**: o que se vê é o que se clica. A
  renderização é SwiftUI, sem animações implícitas; os valores de cada quadro vêm do motor de molas (ADR 0003).
- Os popovers que precisam de teclado (Agent Card) usam outro painel, `AnchoredPanel`, que pode se tornar
  key sem ativar o app de forma intrusiva.
- Para abrir e alternar apps, a decisão é `NSWorkspace.openApplication(at:configuration:)` com
  `activates = true`. Isso também envia o evento "reopen" que o Dock do sistema envia, e funciona com a
  ativação cooperativa do macOS 14+ (`NSRunningApplication.activate` falha silenciosamente quando o
  chamador não está ativo).

## Alternativas consideradas

- **Hit-test por transparência de pixel**: depende de detalhes do WindowServer e quebra com materiais.
- **Rastreamento via `NSTrackingArea`**: não recebe eventos quando o ponteiro está sobre pixels
  transparentes, o que faz a magnificação "piscar" nas bordas.
- **Event tap (`CGEventTap`)**: exige permissão de Acessibilidade/Input Monitoring só para mover o ponteiro.

## Consequências

- CPU ociosa perto de zero: o monitor global só faz trabalho quando o ponteiro está perto do dock, e o
  display link para quando as molas assentam (`scripts/benchmark.sh`: 0,15 % em média).
- O PulseDock é um app agente (`LSUIElement`). Ajustes e Mission Control mudam temporariamente a política
  de ativação para `.regular`, para ganhar menu e Cmd-Tab, e voltam a `.accessory` ao fechar.
