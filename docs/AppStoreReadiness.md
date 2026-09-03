# Caminho pra Mac App Store

Plano — **não implementado ainda**, só documentado pra quando for pedido.
Distribuição via Developer ID (GitHub Releases, fora da App Store) e
distribuição via **Mac App Store** têm requisitos bem diferentes; isso
aqui cataloga o que muda pra cada feature do app.

## A diferença principal: App Sandbox

Todo app na Mac App Store precisa rodar com `com.apple.security.app-sandbox`
habilitado — um perímetro de permissões explícitas (entitlements) em vez do
acesso livre que um app fora da App Store tem hoje. Cada feature abaixo
precisa ser revisada:

| Feature | Hoje (sem sandbox) | Sob App Sandbox | Risco |
|---|---|---|---|
| MQTT pra impressora (porta 8883, IP arbitrário na LAN) | Socket TCP livre | `com.apple.security.network.client` | Baixo — entitlement padrão, sem restrição prática |
| 3 servidores HTTP locais (loopback, `NWListener`) | Livre | `com.apple.security.network.server` | Baixo — só localhost, entitlement padrão resolve |
| Descoberta SSDP (multicast em 239.255.255.250) | Livre | Mesmo entitlement de network client, mas multicast sob sandbox tem histórico de comportamento inconsistente em alguns macOS | **Médio** — precisa testar de verdade; scan ativo (`LanCertificateScanner`) já é o fallback caso SSDP falhe |
| Controle do Music.app via Apple Events | `NSAppleEventsUsageDescription` + prompt do sistema | `com.apple.security.automation.apple-events` (já adicionado em `OBSAssistants.entitlements` — funciona igual sob hardened runtime **e** sob sandbox) | Baixo — já preparado |
| Captura de áudio do Music.app (ScreenCaptureKit) | Permissão de Gravação de Tela (TCC) | Mesma permissão TCC — nenhum entitlement de sandbox documentado como obrigatório, mas **a revisão da Apple pode questionar** "grava áudio de outro app" | **Médio** — risco de review, não técnico |
| Mute local via Core Audio Process Tap (`AudioHardwareCreateProcessTap`, macOS 14.2+) | Livre | API pública, mas relativamente nova e de baixo nível — comportamento sob sandbox não documentado por nós ainda | **Médio** — precisa testar num build sandboxed de verdade |
| Pasta de projetos do Bambu Studio (`.3mf`, caminho arbitrário escolhido pelo usuário) | Caminho salvo como string simples | Precisa virar **security-scoped bookmark** (`NSOpenPanel` + `startAccessingSecurityScopedResource`) — senão o acesso à pasta não sobrevive a um relaunch | **Alto** — muda código (`AppSettings.studioProjectFolderPath` + `BambuStudioProjectReader`), não é só entitlement |
| Keychain (Access Code, senha do `.p12`) | Item genérico, ACL por identidade de código | Mesmo mecanismo, mas o *keychain access group* pode precisar virar o Team ID sob sandbox | Baixo — ajuste pontual, sem redesenho |
| `LSUIElement` (menu bar only, sem Dock/ícone) | — | Totalmente compatível | Nenhum |

## Outros requisitos de App Store (não relacionados a sandbox)

- **App Store Connect**: criar o registro do app, bundle ID, ícone em todos
  os tamanhos exigidos, screenshots, descrição, categoria, política de
  privacidade (obrigatória — o app lê dados locais como faixa do Music.app
  e status da impressora; precisa declarar isso no formulário de
  privacidade da App Store mesmo sem nenhum dado saindo do Mac).
- **Certificado "Apple Distribution"** (diferente do "Developer ID
  Application" usado pra distribuição direta) + perfil de provisionamento
  Mac App Store.
- **Revisão de conteúdo**: um app que controla hardware de terceiros
  (impressora Bambu Lab) e faz overlay pra outro app (OBS) geralmente passa
  sem problema, mas vale revisar as guidelines de "duplicar funcionalidade
  do sistema" e "automação" antes de submeter.
- **Versionamento**: `CFBundleVersion` precisa incrementar a cada build
  submetida (hoje fixo em "1" no `Info.plist`).

## Ordem sugerida quando for a hora

1. Sandboxar localmente primeiro (adicionar `com.apple.security.app-sandbox`
   + os entitlements da tabela acima) e testar cada feature manualmente —
   sem ainda submeter nada.
2. Resolver o item de risco alto (bookmark de segurança pra pasta do Bambu
   Studio) — é o único que exige mudança de código, não só de entitlement.
3. Validar os dois itens de risco médio (multicast SSDP, Process Tap) sob
   sandbox — se algum não funcionar, cada um já tem fallback (scan ativo
   pro SSDP; o toggle "Também silenciar no Mac" já é opcional, dá pra
   desabilitar só ele sob sandbox sem perder o resto do overlay).
4. Registrar o app + bundle ID no App Store Connect, gerar o certificado
   "Apple Distribution".
5. Build assinado com esse certificado + `xcrun altool`/Transporter (ou
   Xcode) pra upload.

---

Created by Vinicius Cotrim.
