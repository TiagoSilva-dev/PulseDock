# ADR 0006 — Replacement Mode só por mecanismos documentados e reversíveis

- Status: aceito
- Data: 2026-10-18

## Contexto

O usuário pode querer usar o PulseDock como dock principal. O Dock do macOS é um processo do sistema
protegido. A especificação proíbe hacks privados, manipulação do SIP e encerramento contínuo do processo
Dock, e exige que o usuário consiga voltar ao Dock original com facilidade.

## Decisão

- **Companion Mode** (padrão): nenhuma alteração no sistema. O PulseDock fica logo acima do Dock do macOS
  quando ele está visível embaixo (usa o `visibleFrame` da tela).
- **Replacement Mode** (assistente com consentimento explícito):
  1. Antes de qualquer mudança, um **ponto de restauração** guarda os valores atuais (`autohide`,
     `autohide-delay`) nas configurações do PulseDock.
  2. O ocultamento automático é ativado pela suíte de scripting documentada do **System Events**
     (`dock preferences`), que aplica a mudança na hora, sem reiniciar o Dock. O macOS pede o
     consentimento de Automação uma vez (`NSAppleEventsUsageDescription` no `Info.plist`).
  3. Opcional, com caixa de seleção própria: atrasar o aparecimento do Dock do macOS (`autohide-delay`). Isso
     exige **uma** reinicialização do Dock por ação explícita do usuário, nunca em loop.
- **Restauração**: voltar para Companion, ou usar Avançado › Restaurar o Dock do macOS ou o menu da
  barra de menus, reaplica exatamente os valores do ponto de restauração.
- Se o macOS negar a Automação, o PulseDock explica onde autorizar e não tenta alternativas.

## Consequências

- O Dock do macOS continua existindo (aparece na borda da tela). Isso é intencional e documentado.
- Nada disso foi executado no Mac de desenvolvimento sem pedido do usuário: o fluxo é coberto pela lógica de
  `SystemDockController` e precisa de validação manual (ver `docs/testing.md`).
