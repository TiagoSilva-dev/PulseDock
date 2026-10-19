# ADR 0003 — Magnificação por integral de densidade, com alvo de clique estável

- Status: aceito
- Data: 2026-10-18

## Contexto

A especificação pede magnificação orgânica: o ícone sob o cursor cresce, os vizinhos crescem em proporção
à distância, com interpolação contínua e mola, **sem** que a área clicável mude de forma abrupta. Nas
implementações ingênuas, que escalam cada ícone pela distância e recalculam o layout, o ícone sob o
cursor "foge" dele e o clique cai no vizinho.

## Decisão

`DockRendering/Magnification.swift` define a densidade de magnificação como um sino de cosseno elevado,
centrado no cursor:

```
m(t) = 1 + k · (1 + cos(π t / R)) / 2   para |t| < R; senão 1      (k = escala máxima − 1)
```

A posição visual de cada ponto da barra é a integral da densidade, ancorada no cursor:
`V(u) = x + ∫ₓᵘ m(t) dt`. A antiderivada é analítica, sem amostragem.

- `V` é monotônica e fixa o ponto sob o cursor. Por isso o item desenhado sob o ponteiro é **sempre** o
  item cujo slot-base contém o ponteiro: hit-testing estável por construção.
- A largura visual de cada slot é a integral sobre o slot; a escala do ícone é a média da densidade no slot.
  Assim não há sobreposição nem buracos.
- Itens de largura fixa (ilha Agent Pulse, widgets, divisores) não ampliam, mas são deslocados pela mesma
  integral.
- Movimento: a posição do cursor passa por uma mola rápida e criticamente amortecida
  (`MotionSprings.pointer`, resposta de 0,09 s), e a amplitude por uma mola levemente subamortecida ao
  entrar e sair (`MotionSprings.magnification`, 0,22 s / 0,86). Um `FrameDriver` (display link) roda só
  enquanto alguma mola não assentou.
- Com Reduzir Movimento, as molas viram transições quase instantâneas (`MotionSprings.reduced`), e a
  magnificação continua funcional.

## Consequências

- A barra se alarga durante a magnificação, como no Dock do sistema. A janela reserva largura para o
  crescimento máximo (`Magnification.maximumGrowth`).
- As invariantes são testadas em `Tests/DockRenderingTests/MagnificationTests.swift`: sem ponteiro ou
  amplitude não há magnificação; o item sob o ponteiro permanece sob ele (alvo de clique estável); os slots
  nunca se sobrepõem e mantêm a ordem; o pico de escala é o máximo configurado e o crescimento é limitado;
  os vizinhos crescem menos com a distância; as molas assentam no alvo com a precisão definida.
