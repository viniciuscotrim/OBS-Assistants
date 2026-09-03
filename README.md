# OBS Assistants

App de menu bar para macOS (SwiftUI, menu-bar-only / `LSUIElement`) com três
overlays locais independentes para **OBS Browser Source** — cada um com seu
próprio servidor HTTP embutido, sua própria porta, e seu próprio Start/Stop,
todos rodando juntos no mesmo processo/ícone da barra de menu.

**Created by Vinicius Cotrim.**

---

## Os três overlays

| Overlay | O que mostra | Fonte dos dados | Porta padrão |
|---|---|---|---|
| **Impressora** | Status de impressão da Bambu Lab (progresso, temperaturas, câmara, filamento, secagem do AMS…) | MQTT direto na impressora (rede local, porta 8883) | `8090` |
| **Bambu Studio** | Detalhes de fatiamento (altura de camada, paredes, infill… ~470 campos) | Arquivo `.3mf` mais recente numa pasta local | `8091` |
| **Now Playing** | Faixa em reprodução no Music.app (capa, progresso, marquee), com opção de transmitir o áudio real pro OBS | AppleScript (Music.app) | `8080` |

Todos os três servidores **começam parados** quando o app abre — você inicia
só o(s) que for realmente usar naquela sessão de stream, pelo menu da barra
("Servidores") ou pela própria janela de configurações de cada overlay.

## Como usar

1. Abra o app — ele fica só na barra de menu (sem ícone no Dock).
2. Clique no ícone da barra pra abrir o menu:
   - **Impressora (MQTT)**: preencha IP, serial e Access Code (ou clique
     numa impressora encontrada automaticamente na rede) e conecte.
   - **Certificado X.509 (fallback)**: só necessário se a impressora
     rejeitar o login padrão (firmware pós-jan/2025) — veja a seção
     [Fallback X.509](#fallback-x509-firmware-pós-janeiro2025) abaixo.
   - **Servidores**: uma linha por overlay — bolinha de status,
     Iniciar/Parar, um botão de engrenagem que abre as configurações
     completas daquele overlay, e a URL do OBS (clique em cima pra copiar).
3. Na janela de cada overlay (aberta pela engrenagem) você configura porta,
   tema, campos visíveis, campos combinados, e tudo mais específico daquele
   overlay.
4. No OBS: Fontes → + → Browser Source → cole a URL copiada → marque fundo
   transparente (já é transparente por padrão nos três).

### Permissões que o macOS vai pedir

- **Rede Local** — pro overlay da Impressora conversar com a Bambu Lab via
  MQTT. Ajustes do Sistema > Privacidade e Segurança > Rede Local.
- **Automação** — pro overlay Now Playing controlar o Music.app via Apple
  Events (ler faixa/artista/álbum/posição/capa). Ajustes do Sistema >
  Privacidade e Segurança > Automação.
- **Gravação de Tela** — só se você ativar "Transmitir áudio do Music no
  overlay" no Now Playing (usa a mesma classe de API que o "Application
  Audio Capture" do próprio OBS). Ajustes do Sistema > Privacidade e
  Segurança > Gravação de Tela.

---

## Overlay: Impressora (Bambu Lab)

Conecta via MQTT (usuário `bblp`, senha = Access Code da tela da impressora)
e expõe tudo que a impressora reporta como JSON (`/status`) + uma página de
overlay HTML/CSS/JS que faz polling desse endpoint. Funciona com qualquer
modelo Bambu Lab (X1/P1/A1/H2D…) — o protocolo MQTT é o mesmo em todos, ver
[OpenBambuAPI](https://github.com/Doridian/OpenBambuAPI/blob/main/mqtt.md).

- **Descoberta automática** de impressoras na rede — SSDP passivo (portas
  1990/2021) + um scan ativo de fallback (bate na porta 8883 de cada IP e
  confere o certificado TLS), já que roteadores mesh costumam engolir
  multicast.
- **Campos combinados ("composites")** — junte múltiplos campos num só
  (ex: "231/450" pra progresso/total), com um editor completo no menu.
- **Ordem e visibilidade dos campos** — escolha quais campos aparecem no
  overlay e em que ordem (grid esquerda→direita, cima→baixo).
- **Secagem do AMS** — thresholds de umidade por tipo de filamento,
  notificação quando um slot passa do limite, início automático opcional
  (com auto-stop por umidade ou por duração fixa), botão manual pra iniciar
  secagem em qualquer slot.
- **Aparência**: tema (dark/twitch/transparente), escala de texto, escala
  da caixa (largura/altura independentes), auto-fit de texto.
- A URL do OBS é **estática** — muda tema/escala/campos no app e o overlay
  já aberto no OBS atualiza sozinho no próximo poll, sem precisar recopiar
  a URL.

### Fallback X.509 (firmware pós-janeiro/2025)

Firmwares mais novos podem rejeitar o login padrão bblp/Access Code. Nesse
caso o app tenta automaticamente um certificado cliente `.p12` (mTLS) como
fallback — configure o caminho e a senha do `.p12` na seção "Certificado
X.509" do menu. Este app não fornece um certificado; veja a referência
OpenBambuAPI acima para como obter o seu.

## Overlay: Bambu Studio

Lê o `.3mf` mais recente de uma pasta que você escolhe (ex: onde você
salva/exporta seus projetos fatiados) e expõe os ~470 campos de fatiamento
(altura de camada, paredes, infill, suportes…) como overlay — já que o
relatório MQTT da impressora nunca inclui esses detalhes.

- Re-escaneia sozinho sempre que um novo job começa na impressora (detecta
  pela mudança de `subtask_name`/`gcode_file` no MQTT), com um timer de
  20s como reforço pra qualquer outro caso (ex: você só arrastou um `.3mf`
  novo pra pasta, sem imprimir ainda).
- Mesmas features do overlay da Impressora, mas **totalmente
  independentes**: campos combinados, ordem/visibilidade, tema, escalas —
  nada é compartilhado entre os dois, cada um tem seu próprio conjunto.
- Servidor HTTP próprio (porta independente, ver tabela acima) — pode rodar
  como uma segunda Browser Source posicionada separadamente no OBS.

## Overlay: Now Playing (Music.app)

- Faz polling do Music.app a cada 1s via AppleScript embutido (compilado
  uma vez, sem spawnar `osascript` a cada tick) — título, artista, álbum,
  posição, duração, play/pause/stop/troca de faixa.
- Extrai a capa do álbum em alta resolução, só quando a faixa muda.
- Overlay web: polling a cada 500ms + interpolação client-side (barra de
  progresso fluida), crossfade de capa, marquee automático em
  título/artista longos, fundo transparente, auto-hide quando nada tá
  tocando.
- 3 temas: `dark`, `twitch-purple`, `transparent` — **próprio dessa
  janela**, independente do tema dos overlays de Impressora/Bambu Studio.
- **Áudio pro stream** — dois toggles independentes:
  - *Transmitir áudio do Music no overlay*: captura o áudio real do
    Music.app (ScreenCaptureKit, a mesma classe de API do "Application
    Audio Capture" do próprio OBS) e transmite pela Browser Source via
    WebSocket — assim o OBS pega vídeo (overlay) e áudio numa fonte só,
    sem precisar de uma segunda fonte de áudio. Sozinho, você continua
    ouvindo o Music.app normalmente nos seus alto-falantes/fones **e** o
    mesmo áudio vai pro stream.
  - *Também silenciar no Mac*: some junto quando você quer que o Music.app
    toque **só** no stream, mudo nos seus alto-falantes (um tap de
    processo no Core Audio, `macOS 14.2+`) — só fica disponível com a
    transmissão ligada.

---

## Rodando em desenvolvimento

```bash
swift run
```

Na primeira execução o macOS vai pedir as permissões listadas acima
(Automação pro Music.app, Rede Local pra impressora). Sem Automação,
`/nowplaying` sempre volta "stopped".

Teste rápido de cada overlay (depois de iniciar o servidor correspondente
no menu):

```bash
curl -s http://localhost:8090/status | python3 -m json.tool      # Impressora
curl -s http://localhost:8091/status | python3 -m json.tool      # Bambu Studio
curl -s http://localhost:8080/nowplaying | python3 -m json.tool  # Now Playing
open "http://localhost:8090/overlay.html?theme=twitch"
```

### Testando sem hardware (impressora)

Variáveis de ambiente só pra desenvolvimento — nunca usadas no launch normal
do usuário. Quando qualquer uma delas está setada, as configurações (e os
dois segredos no Keychain) passam a persistir num namespace descartável, pra
um test run nunca sobrescrever a config real de um usuário:

- `OA_SCAN_TEST=1` — escaneia a subrede local por impressoras e sai.
- `OA_KEYCHAIN_TEST=write:<valor>` / `OA_KEYCHAIN_TEST=read` — testa o
  caminho de salvar/ler o Access Code no Keychain.
- `OA_TEST_PAYLOAD=<caminho.json>[,<caminho2.json>,…]` — substitui a conexão
  MQTT real por um replay de relatório(s) capturado(s), injetado no mesmo
  pipeline que um MQTT real usaria.
- `OA_SNIFF_REQUESTS=1` — loga passivamente qualquer publish MQTT em
  `device/<serial>/request` (ex: pra capturar o payload real de um comando
  que o app oficial da Bambu envia), sem nunca enviar nada.
- `OA_DRY_TEST=<amsID>:<tipo>:<tempC>:<horas>` /
  `OA_DRY_STOP_TEST=<amsID>` — envia um comando real de secagem/parada pro
  AMS, contra hardware de verdade.
- `OA_PRINT_AMS_STATUS=1` — conecta e imprime o status real de cada slot do
  AMS (filamento, umidade, secagem ativa) a cada ~2s por ~80s, depois sai.
  Usado pra descobrir o amsID/tipo de filamento reais antes de rodar
  `OA_DRY_TEST` com valores corretos, em vez de adivinhar.
- `OA_ISOLATED_DEFAULTS=1` — força o namespace descartável sem nenhum dos
  efeitos acima.
- `OA_ACCESS_CODE_OVERRIDE=<valor>` — pula a leitura do Keychain (que
  intermitentemente trava/expira em 3s durante testes) usando um valor
  direto.

## Empacotamento (.app + .dmg)

```bash
./build_dmg.sh
```

Gera `dist/OBS Assistants.app` + `dist/OBS Assistants-<versão>.dmg`. Passos
automatizados: `swift build -c release` (universal arm64+x86_64 quando o
toolchain suporta, senão nativo) → monta o `.app` → `codesign` → empacota o
`.dmg`.

- **Assinatura**: usa a identidade local "OBS Assistants Local Dev" se ela
  já existir no keychain de login, senão cai pra ad-hoc (`--sign -`). Uma
  identidade estável evita ter que reconfigurar o Keychain (Access
  Code/senha do `.p12`) a cada rebuild — veja o comentário no topo do
  script pra criar a identidade uma vez.
- **`.dmg`**: usa `create-dmg` (`brew install create-dmg`) se disponível,
  pra um volume com ícone customizado; senão cai automaticamente pra um
  `.dmg` simples via `hdiutil` (só o que o macOS já traz).
- **Gatekeeper**: não é notarizado (identidade local/ad-hoc, não uma conta
  paga de desenvolvedor Apple) — no primeiro launch, clique com botão
  direito no app → Abrir (uma vez), ou:
  ```bash
  xattr -cr "/Applications/OBS Assistants.app"
  ```

## Estrutura

```
Package.swift
Sources/OBSAssistants/
  App/
    OBSAssistantsApp.swift      — entry point (MenuBarExtra), flags de diagnóstico
    AppState.swift               — coordenador central: MQTT + os 2 servidores HTTP (impressora/Studio)
    Info.plist                   — bundle info do .app
  Settings/
    AppSettings.swift            — todas as configs persistidas (UserDefaults + Keychain)
  MQTT/
    BambuConnectionManager.swift — conexão MQTT (TLS, fallback X.509, comandos AMS)
    MQTTClient.swift, MQTTPacket.swift — cliente MQTT mínimo, sem dependências
  Discovery/
    PrinterDiscoveryService.swift — descoberta passiva (SSDP)
    LanCertificateScanner.swift   — scan ativo por certificado TLS na 8883
  Parsing/
    PrinterReport.swift, FieldCategory.swift — achata o JSON MQTT em campos
    BambuStudioProjectReader.swift — lê campos de fatiamento de um .3mf
  Drying/
    DryingController.swift, DryingProfile.swift,
    DryingNotificationManager.swift, AMSSlotStatus.swift — secagem do AMS
  HTTPServer/
    LocalHTTPServer.swift        — servidor HTTP genérico (Impressora e Bambu Studio, uma instância cada)
    OverlayAssets.swift           — HTML/CSS/JS do overlay de Impressora/Bambu Studio, embutido
  NowPlaying/
    NowPlayingState.swift         — coordenador do overlay Now Playing (independente de AppState)
    MusicPoller.swift             — polling do Music.app via AppleScript
    NowPlayingHTTPServer.swift    — servidor HTTP próprio (WebSocket de áudio incluso)
    NowPlayingAssets.swift        — HTML/CSS/JS do overlay Now Playing, embutido
    AudioCaptureEngine.swift      — captura (ScreenCaptureKit) + mute local (Core Audio), independentes
    NowPlayingInfo.swift          — modelo JSON da faixa atual
  UI/
    MenuBarContentView.swift      — popover raiz (conexão MQTT, certificado, "Servidores")
    PrinterOverlayView.swift, StudioOverlayView.swift, NowPlayingOverlayView.swift — janela de config de cada overlay
    OverlayTabWindowControllers.swift — abre/foca as 3 janelas acima
    FieldRow.swift, FieldSearchPicker.swift, FlowLayout.swift, SharedControls.swift — componentes reutilizáveis
    DryConfirmationView.swift, DryConfirmationWindowController.swift — confirmação de início de secagem
  Security/
    KeychainHelper.swift          — leitura/escrita no Keychain (Access Code, senha do .p12)
build_dmg.sh                      — build → .app → .dmg (saída em dist/)
```

---

**Created by Vinicius Cotrim.**
