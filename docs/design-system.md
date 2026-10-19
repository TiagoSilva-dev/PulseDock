# Design system do PulseDock

Direção: **Quiet Luxury + macOS Native + Ambient Intelligence**. Elegância, profundidade, precisão e
inteligência discreta. O dock é bonito quando nenhum agente está rodando; a luz aparece só quando há algo
a dizer.

Código: `Sources/DockRendering/` (`DesignTokens.swift`, `Theme.swift`, `PulseGlass.swift`, `Motion.swift`,
`Spring.swift`, `Magnification.swift`, `AccessibilityOptions.swift`).

## 1. Geometria (`DockMetrics`)

Toda medida deriva do tamanho do ícone (Ajustes › Aparência › Tamanho, 40–80 pt), para que o dock fique
proporcional em qualquer tamanho e escala de tela.

| Token | Fórmula | Padrão (ícone 54 pt) | Especificação |
| --- | --- | --- | --- |
| Ícone | escolha do usuário (32–96) | 54 pt | 52–58 pt |
| Espaçamento entre ícones | 0,185 × ícone, 7–14 | 10 pt | 8–12 pt |
| Padding horizontal | 0,30 × ícone, 12–22 | 16 pt | 14–18 pt |
| Padding vertical | 0,185 × ícone, 7–14 | 10 pt | 9–12 pt |
| Altura da barra | ícone + 2 × padding vertical | **74 pt** | ≈ 74 pt |
| Canto externo | 0,44 × ícone, 16–32 | 24 pt | 22–26 pt |
| Magnificação máxima | escolha do usuário (1,1–2,0) | 1,45× | 1,45× |
| Raio de influência | 2,7 slots | 172 pt | — |
| Divisor | 1 pt, baixo contraste | 1 pt | 1 pt |
| Indicador de execução | 0,075 × ícone (mín. 3) | 4 pt | — |
| Margem inferior | escolha do usuário (0–40) | 6 pt | configurável |
| Popovers | `PanelMetrics.cornerRadius` | 20 pt | ≈ 20 pt |
| Ícones pequenos | `PanelMetrics.smallIcon` | 18 pt | 16–20 pt |

Espaçamento "Compacto / Padrão / Confortável" ajusta o espaçamento derivado.

## 2. Tipografia (`PulseTypography`)

San Francisco (fonte do sistema) em tudo, para que localização, acessibilidade e renderização sejam nativas.

| Token | Uso | Fonte |
| --- | --- | --- |
| `dockLabel` | rótulo flutuante do ícone | 12,5 pt medium |
| `island` | texto da ilha | 12 pt medium |
| `islandSecondary` | linha secundária da Quick Peek | 11,5 pt regular |
| `panelTitle` | títulos de painéis ("Atividade de IA") | 14 pt semibold |
| `panelHeadline` | agente · projeto | 13 pt semibold |
| `panelBody` | atividade | 12,5 pt regular |
| `panelCaption` | metadados, tempo, origem | 11 pt regular |
| `badge` | contadores | 10 pt bold rounded |
| `mono` | comandos e arquivos | 11,5 pt monospaced |

Números em colunas usam `monospacedDigit`. Datas e números seguem o `Locale` do usuário.

## 3. Material: Pulse Glass (`PulseGlassSurface`)

- **macOS 26+**: Liquid Glass nativo do SwiftUI (`glassEffect`, variante `regular` ou `clear`, com tinta do
  tema). Amostra o conteúdo atrás da janela pelo próprio sistema, sem captura de tela.
- **macOS 15**: `NSVisualEffectView` com `blendingMode = .behindWindow` e o material legado do tema, mais uma
  tinta sutil.
- **Camadas comuns**: borda de 1 pt com gradiente (realce superior `borderTop`, base `borderBottom`), brilho
  superior discreto (`highlight`) e sombra única com direção consistente (para baixo; raio 14–16 pt,
  deslocamento 5–6 pt).
- **Transparência** (Ajustes › Aparência › Material): Translúcida (vidro `clear`), Padrão ou Opaca.
- **Reduzir Transparência** (sistema): sempre `opaqueFill`, sem desfoque.
- **Aumentar Contraste**: borda de 1,5 pt em alto contraste, sempre visível.
- **Legibilidade de conteúdo** (`Legibility.content`): painéis, Quick Peek e rótulos ganham uma camada
  adaptativa entre o vidro e o conteúdo (branco 62 % no modo claro, preto 30 % no escuro; menos com
  "Translúcida"). O Liquid Glass escurece sozinho sobre janelas escuras, mas o conteúdo desenhado acima dele
  mantém as cores da aparência da interface. Sem essa camada, texto escuro ficaria sobre vidro escurecido.
  A barra do dock usa `Legibility.bar` (só o vidro).
- Os painéis ancorados não usam *vibrancy*, para que chips e linhas coloridas mantenham as cores exatas do tema.
- Avançado › Compatibilidade › "Usar o material do macOS 15" força o caminho legado para validação visual.

## 4. Temas (`Theme`)

| | Native Glass (padrão) | Midnight | Aurora |
| --- | --- | --- | --- |
| Ideia | linguagem nativa do macOS | vidro grafite para quem vive no modo escuro | vidro com acentos azul/violeta/ciano |
| Aparência | segue o sistema | sempre escura | segue o sistema |
| Vidro | `regular`, sem tinta | `regular` + tinta grafite 58 % | `regular` + tinta violeta 10 % |
| Legado (macOS 15) | `.popover` | `.hudWindow` | `.fullScreenUI` |
| Reflexos | equilibrados | quase imperceptíveis | suaves, frios |
| Indicadores | padrão | mais definidos | padrão |
| Luz ambiente da ilha | 25 % | 45 % | 100 %, com gradiente de acento |
| Tons de estado | dinâmicos (claro/escuro) | fixos, para fundo escuro | dinâmicos: variantes luminosas no escuro, saturadas no claro |

A luz da Aurora responde aos estados dos agentes **só na região da ilha** (§12.4 da especificação): nunca
ilumina o dock inteiro nem fica acesa sem motivo. Cada ambiente pode usar seu próprio tema (por padrão,
Criativo = Aurora, Foco = Midnight).

## 5. Linguagem dos estados

Cor + símbolo + texto, nunca só cor (a interface funciona com "Diferenciar sem cor").

| Estado | Tom | Símbolo (SF Symbols) | Texto pt-BR |
| --- | --- | --- | --- |
| Trabalhando | azul (`working`) + onda animada | `circle.dotted` | Trabalhando / atividade concreta |
| Precisa de você | âmbar (`attention`) + borda âmbar na ilha | `exclamationmark.circle.fill` | Aprovação necessária, Pergunta para você… |
| Concluído | verde momentâneo (`success`) | `checkmark.circle.fill` | Turno finalizado |
| Falha | vermelho controlado (`failure`) | `xmark.octagon.fill` | O turno falhou, Limite de uso atingido… |
| Interrompido | neutro | `pause.circle` | Interrompido |
| Ocioso | neutro (`idle`) | `circle` | Ocioso |
| Sem atualizações | cinza discreto (`unknown`) | `clock.badge.questionmark` | Sem atualizações há N min |
| Desconhecido | cinza discreto | `questionmark.circle` | Estado desconhecido |
| Não conectado | cinza apagado (`offline`) | `bolt.horizontal.circle` | Não conectado |

Estados **inferidos** levam um "?" no chip, com a explicação no tooltip. Sessões de demonstração levam
sempre o selo roxo **DEMO**.

### Ilha Agent Pulse: anatomia

`[monogramas dos agentes] [marca de estado] [Agente · atividade] [+N] [DEMO]`

- Monogramas originais (`Cl`, `Cx`), sem logotipos de terceiros. Os sobrepostos ganham um anel na cor da
  cápsula, e o de maior prioridade fica por cima.
- Largura medida do conteúdo real, máximo de 360 pt (o texto trunca no fim), animada por mola.
- Modos: compacto (só indicador e contador), atividade, atenção, conclusão (alguns segundos, depois volta ao
  agregado) e falha.

## 6. Movimento (`Motion`, `MotionSprings`)

| Classe | Duração | Uso |
| --- | --- | --- |
| Micro feedback | 130 ms | toque, pressão, toggles |
| Hover / magnificação | 180 ms | entrada/saída da magnificação, rótulos |
| Painéis | 270 ms | Agent Card, Quick Peek, menus de widgets |
| Troca de ambiente | 330 ms | workspace, tema |
| Pulsação ambiente | 2,0 s (respiração) | **só** em atividade ou atenção |

Molas físicas (resposta / amortecimento): ponteiro 0,09 s / 1,0 · magnificação 0,22 s / 0,86 · ilha
0,34 s / 0,84 · auto-hide 0,30 s / 0,94 · reordenação 0,24 s / 0,84 · pressão 0,14 s / 0,72.

- **Reduzir Movimento**: as molas viram transições de 80 ms sem oscilação, a respiração some e as
  mudanças de conteúdo usam fade curto. Tudo continua funcional.
- Ajustes › Aparência › Animações desliga o movimento por completo.
- O display link só roda enquanto há molas em movimento; animações fora da tela não consomem nada.

## 7. Ícone do app

Original, desenhado em CoreGraphics (`scripts/make-icon.swift`): fundo noturno, barra de vidro e uma linha
de pulso com gradiente ciano-violeta. Exportado como `.icns` em todos os tamanhos.

## 8. Checklist de acabamento (aplicado na revisão visual de 2026-10-18)

- Texto da ilha nunca truncado por erro de medição: a largura vem da medição do conteúdo real.
- Monogramas legíveis quando sobrepostos.
- Card: uma ideia por linha (agente · projeto + estado; atividade; detalhe em mono; metadados).
- Foco de teclado visível só quando o teclado é usado.
- Projetos com o mesmo nome distinguidos pela pasta pai; projetos de demonstração marcados.
- Plurais e números localizados ("1 turno", "0,12 s").
- Sem marcas de passo densas em sliders; rodapés de seção alinhados à esquerda; barra lateral sem truncar
  em pt-BR.
