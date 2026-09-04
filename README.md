# OBS Assistants

App de menu bar para macOS (SwiftUI, menu-bar-only / `LSUIElement`) com três
overlays locais independentes para **OBS Browser Source** — cada um com seu
próprio servidor HTTP embutido, sua própria porta, e seu próprio Start/Stop,
todos rodando juntos no mesmo processo/ícone da barra de menu.

**Created by Vinicius Cotrim.**

## Licença

Todos os direitos reservados — ver [LICENSE](LICENSE). O código-fonte é
público neste repositório só pra referência/transparência; não é
permitido copiar, redistribuir ou publicar derivados sem autorização por
escrito do autor. O app compilado é distribuído separadamente (GitHub
Releases hoje; Mac App Store futuramente).

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
- **Secagem do AMS** 🚧 **em desenvolvimento, aguardando suporte oficial da
  Bambu Lab** — thresholds de umidade por tipo de filamento e notificação
  quando um slot passa do limite já funcionam normalmente (é só leitura de
  status via MQTT, que a Bambu não restringe). O envio do comando pra
  *iniciar/parar a secagem em si*, porém, **não funciona em firmwares mais
  novos** (confirmado numa X2D) — a impressora agora exige uma assinatura
  criptográfica que só o app oficial da Bambu consegue gerar; sem ela, o
  comando é aceito pelo MQTT sem erro nenhum, mas nunca liga o
  aquecedor de verdade. Isso não é um bug deste app — é a Bambu Lab
  restringindo esse tipo de comando de propósito (documentado por eles
  mesmos), e replicar aquela assinatura seria contornar um controle de
  segurança que eles fizeram por um motivo. Por enquanto:
  - A notificação de umidade alta te leva direto pro **app oficial da
    Bambu** (Handy ou Studio) em vez de tentar iniciar por aqui.
  - As opções de automação (auto-start, auto-stop por umidade) ficam
    **travadas na UI** — ativar algo que silenciosamente não funciona
    seria pior que não ter automação nenhuma.
  - O controle manual (botão "Secar"/"Parar" por slot) continua
    disponível pra teste — pode funcionar em modelos/firmwares mais
    antigos onde essa exigência de assinatura ainda não existe.
  - Acompanhe em [issue #2](https://github.com/viniciuscotrim/OBS-Assistants/issues/2)
    — tem a investigação completa (captura real do tráfego MQTT
    comparando o comando deste app com o do Bambu Studio) e os caminhos
    considerados (modo Developer/LAN-only da impressora, login na conta
    Bambu, SDK oficial da Bambu Lab) e por que nenhum resolve sem
    trade-offs que valem a pena discutir antes de implementar.
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
  AMS, contra hardware de verdade. **Pode não fazer efeito** em firmwares
  mais novos (ver "Secagem do AMS" acima e a issue #2) — publica sem erro
  no MQTT mas a impressora pode simplesmente ignorar.
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

- **Assinatura**: o script escolhe automaticamente, em ordem de
  preferência: `Developer ID Application` (certificado real da Apple, ver
  "Distribuição" abaixo) → `OBS Assistants Local Dev` (identidade local
  autoassinada) → ad-hoc (`--sign -`) como último recurso. Uma identidade
  estável (qualquer uma das duas primeiras) evita ter que reconfigurar o
  Keychain (Access Code/senha do `.p12`) a cada rebuild — veja o
  comentário no topo do script pra criar a identidade local, ou a seção
  abaixo pra usar uma conta paga de desenvolvedor Apple.
- **`.dmg`**: usa `create-dmg` (`brew install create-dmg`) se disponível,
  pra um volume com ícone customizado; senão cai automaticamente pra um
  `.dmg` simples via `hdiutil` (só o que o macOS já traz).

## Distribuição (Developer ID + notarização)

Com uma conta paga de desenvolvedor Apple, o app pode ser assinado e
**notarizado** — Gatekeeper para de bloquear pra qualquer pessoa que baixe
o `.dmg`, sem precisar de `xattr`/clique-direito. Setup único:

1. **Keychain Access** → Certificate Assistant → Request a Certificate
   from a Certificate Authority → gera um `.certSigningRequest` (e já
   guarda a chave privada correspondente no seu keychain).
2. [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   → "+" → **Developer ID Application** → suba o CSR → baixe o `.cer`.
3. Duplo clique no `.cer` baixado — instala a identidade completa
   (casando com a chave privada do passo 1).
4. Crie uma senha de app em [appleid.apple.com](https://appleid.apple.com)
   (Sign-In and Security → App-Specific Passwords) e rode:
   ```bash
   xcrun notarytool store-credentials "OBSAssistantsNotary" \
     --apple-id "seu@email.com" --team-id "SEUTEAMID" --password "senha-de-app-gerada"
   ```

Depois disso, `./build_dmg.sh` detecta a identidade Developer ID sozinho,
assina com hardened runtime + entitlements
(`Sources/OBSAssistants/App/OBSAssistants.entitlements`), submete pra
notarização (`xcrun notarytool submit ... --wait`) e faz o *staple* do
ticket no `.dmg` e no `.app` automaticamente — nenhuma senha fica
armazenada no script, só o nome do perfil (`OBSAssistantsNotary`) salvo no
Keychain pelo comando acima.

Sem nenhuma das duas identidades configuradas, o script cai pro fallback
ad-hoc e mostra o aviso de Gatekeeper de sempre:
```bash
xattr -cr "/Applications/OBS Assistants.app"
```

Ver [docs/AppStoreReadiness.md](docs/AppStoreReadiness.md) pro plano —
ainda não implementado — de levar isso pra distribuição via Mac App Store
(App Sandbox, entitlements por feature, o que precisa mudar em cada uma).

## Estrutura

```
Package.swift
Sources/OBSAssistants/
  App/
    OBSAssistantsApp.swift      — entry point (MenuBarExtra), flags de diagnóstico
    AppState.swift               — coordenador central: MQTT + os 2 servidores HTTP (impressora/Studio)
    Info.plist                   — bundle info do .app
    OBSAssistants.entitlements   — hardened runtime (Developer ID/notarização); base pro futuro App Sandbox
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
build_dmg.sh                      — build → .app → .dmg (saída em dist/), assina/notariza quando possível
docs/
  AppStoreReadiness.md              — plano (não implementado) pra distribuição via Mac App Store
LICENSE                             — todos os direitos reservados
```

---

**Created by Vinicius Cotrim.**
