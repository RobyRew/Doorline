# Door Entry 1.13.5 — reverse engineering notes

Findings from the decrypted `com.bticino.dooreliotc300x` IPA (build 1.13.5, `DoorEliot_iOS`
binary, arm64, unstripped). Sources: `strings`, `otool -ov` (ObjC metadata, IMP addresses),
`otool -tvV` (full `__TEXT` disassembly), and the bundled frameworks (linphone 5.4.42 family).

Sections below are written against the Doorline code so the gap between the official app and
Doorline is explicit. Line references like `0x1000f5ad8` are virtual addresses in the
decrypted binary's `__TEXT`.

## 1. Accounts, plants, gateways

### 1.1 Sign-in (already implemented in Doorline)

Azure AD B2C at `https://login.eliotbylegrand.com`:

- Policies: `B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn`, `B2C_1_BS_DoorEntry_App_iOS-password`.
- `client_id` `68391b24-f2fd-44c7-95b3-e04130d4a287`, redirect
  `com.legrandgroup.c300x://oauth2redirect`, scope
  `openid offline_access https://EliotClouduamprd.onmicrosoft.com/security/access.full`.
- Token endpoint: `/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/token?p=<policy>`.

Doorline's `EliotWebJourney` covers the page-script POST flow (`SelfAsserted`, `confirmed`,
cookie jar, code → token exchange). No change needed.

### 1.2 Portal REST client (`BtWebPortalClient.swift`)

- Base URL: `https://www.myhomeweb.com:443`, path prefix `/eliot` (UserDefaults override key
  `DoorEliot_PORTAL` for QA builds). Built as `https://www.myhomeweb.com:443/eliot` +
  endpoint. Confirmed at `0x100024938–0x100024954` (`/eliot` string) and
  `0x10002492c` (base URL literal).
- Auth: `Authorization: Bearer <eliot access token>`; `PRJ_NAME: C3X` header;
  User-Agent `doorentryforc300x-ios-<version>`.
- Implemented with Alamofire; Doorline uses URLSession — equivalent.

Endpoints (literal pools in the binary):

| Path | Method | Purpose |
|---|---|---|
| `/eliot/plants` | GET | Plant + gateway list |
| `/plants/{p}/gateway` | POST | Create gateway on plant (setup wizard) |
| `/plants/{p}/gateway/{g}` | GET/PUT | Gateway document |
| `/plants/{p}/gateway/{g}/conf` | GET/PUT | Gateway configuration document |
| `/sip/users/plants/{p}/gateway/{g}` | GET/POST | SIP user provisioning |
| `/users/cert/signcert` | POST | CSR → signed client certificate |
| `/plants/{p}/pushNotifications[/{id}]` | GET/POST/DELETE | APNs VoIP push registrations |
| `/plants/{p}/invitations[/{id}]` | GET/POST/… | Multi-user invitations |
| `/legacy/c3x_gdpr_contract_agreement_{email}` | … | GDPR consent |
| `/legacy/c3x_gdpr_privacy_agreement_{email}` | … | GDPR consent |
| `/interop/user/eliotFederation` | … | Eliot federation |

### 1.3 Plant list

Doorline reads `GET /eliot/plants` with `PRJ_NAME: C3X`. The official app's
`PlantRepository`/`JSONModelFactory` parse the same endpoint; the field names Doorline
guesses (`plantId`/`plantID`, `gatewayId`/`gatewayID`) match the strings seen in the binary
(`plant`, `plantId`, `plantID`, `plantName`, `gateway`, `gatewayId`, `gatewayConfig`).

### 1.4 SIP user document (`SipRepository.swift`)

- `GET /sip/users/plants/{p}/gateway/{g}` returns the provisioned SIP user(s).
- Keys present in the binary: `sipUser`, `sipUsers`, `sipAccount`, `sipPassword`,
  `idDevice`, `deviceName`, `username`, `password`, `proxy`.
- `createSipUser(_:deviceName:gatewayId:idDevice:onSuccess:onError:)` POSTs the same path.
- `getSipUserFromWeb(_:gatewayId:username:deviceId:callback:)` is the portal GET variant.

**Doorline gap:** `SipAccountDocument.usernameKeys` lacks `sipUser`/`sipAccount` spellings.
Add them.

## 2. SIP registration (`LinphoneManager.swift` of the official app)

The official app drives linphone through the **C API** (imports at `0x10028bxxx` stubs), not
linphonesw. Doorline uses linphonesw 5.5.32; the C call list below maps 1:1 to linphonesw
properties.

### 2.1 Core creation (`startLibLinphone`, `0x1000f5668`)

- `linphone_core_new_with_config(core, NULL factory config, lpconfig from file)` — the
  lpconfig is `linphonerc-factory` under Application Support
  (`NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, userDomain, YES)`),
  created via `linphone_config_new_with_factory` (`0x1000f63bc`).
- Core creation is gated on `isLinphoneReady` (the `LinphoneConfig` struct holding the sip
  host/port/transport/domain) **and** `SecurityUtils.certificateExists()` — a client
  certificate must already be in the Keychain.
- After creation: `+[ExternalCodecInit initExternalCodec:core]` registers an external
  mediastreamer codec, then `linphone_core_reload_ms_plugins` is available to the app.
  (Doorline: nothing to do unless the 300X negotiates a codec outside the bundled
  msopenh264/msamr/mssilk plugins.)
- Iteration: an `NSTimer` calling `linphone_core_iterate` (Doorline's `autoIterateEnabled`
  is equivalent) plus a second timer calling `refreshRegisters`.
- Logging service: log level set to 32, mask 0, custom `log_message_written` callback that
  forwards to the app's logger (`log.bs.iotleg.com` Graylog in QA builds).
- `AVAudioSessionInterruptionNotification` observer pauses/resumes audio.

### 2.2 Core settings (`finishCoreConfiguration`, `0x1000f5ad8`)

| Setting | Value |
|---|---|
| Ring / ringback | `NULL` — the app plays ringtones itself |
| Static picture | `ic_call_no_video_all.jpg` (sent as the outgoing video stream) |
| TLS client cert / key / root CA | from Keychain: `DoorEliot_IOS_client_cert`, `DoorEliot_IOS_private`, `DoorEliot_IOS_root_ca` (PEM strings) via `linphone_core_set_tls_cert` / `set_tls_key` / `set_root_ca_data` |
| Cert validity | checked before registering; failure logs `INVALID CERTIFICATE DATE RANGE` |
| Video activation policy | `automatically_accept = true`, `automatically_initiate = true` |
| Video display / capture | display on, **capture off** (one-way video: door station → phone) |
| NAT policy | STUN enabled, server `stun.linphone.org` |
| Media encryption | **mandatory**, mode 1 = SRTP |
| DNS SRV | disabled |
| In-call timeout | 60 s (no video) / 180 s (video) |
| No-RTP timeout | same |
| Server certificates | `verify_server_certificates = true`, `verify_server_cn = false` |

### 2.3 Registration (`reInitSipRegistration`, `0x1000f93xx`–`0x1000f9c60`)

- Proxy host: UserDefaults key `DoorEliot_FLEXISIP`, default **`sipserver.bs.iotleg.com`**.
  QA overrides exist (`flexisipProduction/Stable/Staging`). Server host pattern
  `sipserver[0-9]*.bs.iotleg.com`; staging `sipstaging.bs.iotleg.com`; QA
  `bs-c3x-sip4-qa.westeurope.cloudapp.azure.com`.
- Server address: `"<host>:<port>;transport=<transport>"` — port `443`, transport `tls`
  (lowercased). Route: `"sip:<host>:<port>;transport=<transport>"`.
- Identity: `"sip:<username>@<domain>"` where domain comes from the proxy config domain
  (the `/sip/users` document).
- Auth info: `username`, `userid = NULL`, `passwd`, `ha1 = NULL`, `realm = NULL`,
  `domain = <proxy domain>`; previous auth infos cleared first.
- Contact URI parameters: when a push token exists, `"contactInfo: <push description>"` is
  set via `linphone_proxy_config_set_contact_uri_parameters`, and `contact_parameters` is
  cleared (no `pn-provider` in the C client — the contactInfo string carries the push
  description the Flexisip server interprets).
- **Expires: 5,184,000 s (60 days)** — `0x4F1A00` at `0x1000f9c28`.
- Register enabled, added as default proxy, `set_network_reachable(true)`.
- `registerWithGateway(_:localRegistration:ipAddress:)` wraps the flow; with no remote
  certificates it aborts (`ABORTED (remote certificates missing)`).

**Doorline gaps:** expires 60 d; TLS transport with port 443 (Doorline defaults to TLS but
does not set port/expires); SRTP mandatory; STUN; video policy; the client certificate
(§2.4); `verify_server_cn` off; the `contactInfo` push parameter.

### 2.4 Client certificate provisioning (`/users/cert/signcert`)

The app generates a keypair + CSR (RSA, `MscRSAKey.m`, openssl X509 routines are linked) and
POSTs the CSR to `/users/cert/signcert`; the signed certificate is stored in the Keychain
under `DoorEliot_IOS_client_cert`, the private key under `DoorEliot_IOS_private`, the CA
under `DoorEliot_IOS_root_ca`. Registration requires the certificate to exist and be valid.

**Doorline gap:** implement keypair + CSR + signcert + Keychain store, then hand the PEMs
to linphonesw (`core.tlsCert`, `core.tlsKey`, `core.rootCaData`). If the Flexisip edge
tolerates unauthenticated TLS, make it best-effort; otherwise it is a hard requirement.

## 3. Calls (`LinphoneManager.swift`, `IncomingCallController.swift`)

### 3.1 Making a call (`makeCall(_:extraParams:useVideo:sendMedia:isTVCC:)`, `0x1000f6e20`)

- Terminates any current call first.
- Timeouts: 180 s when video, else 60 s (both in-call and nortp).
- `create_call_params(core, NULL)`; `enable_video(useVideo)`.
- **Custom SDP attributes:** every `(key, value)` pair of `extraParams`
  (`[String: String]`) is added with `linphone_call_params_add_custom_sdp_attribute`.
  The app's keypair exchange travels here: attribute names
  `id-it-signKeyPairTypes`, `id-it-encKeyPairTypes`, `id-it-keyPairParamReq`,
  `id-it-keyPairParamRep` (present in the binary's strings).
- When `!sendMedia && useVideo`: `video_direction = RecvOnly`.
- `invite_with_params(core, address, params)`.

### 3.2 Accepting (`acceptCurrentCall(_:)`, `0x1000f714c`)

- `create_call_params(core, call)`; if the **remote** params have video enabled:
  `enable_video(true)` + `video_direction = RecvOnly` (receive only — the phone never
  sends video).
- `enable_audio(true)`, `audio_direction = SendRecv`.
- `accept_with_params(call, params)`, then `enable_mic(true)`.
- `linphone_call_accept_early_media_with_params` is imported — early media is handled.

### 3.3 Declining / ending

- `linphone_call_decline` (imported; one call site `0x100045b00`), `linphone_call_terminate`
  (multiple call sites, incl. the call observer).

### 3.4 CallKit

- `LinphoneManager` conforms to `CXCallObserverDelegate`; `callObserver:callChanged:` at
  `0x1000f7800` reconciles CallKit state with the linphone call (end call when the system
  UI ends it, report/accept on answer). `IncomingCallController` is the ring UI.
- CallKit provider is fed from `linphone_core_get_current_call` and call-state callbacks.
- Call states logged as `LinphoneCallState*` (e.g. `LinphoneCallStateInProgress`); call
  stats via `LinphoneCallStatsHelper` (`download_bandwidth` etc.).

### 3.5 Ringing / audio

- The core's ring/ringback are disabled; the app plays `DEFAULT.mp3` / `OFF.mp3` from the
  bundle and respects the mute/ringtone settings (ringtone_* strings, `ringFile`).
- `audioSessionInterrupted:` handles AVAudioSession interruptions.
- `Call accepted elsewhere` / `call_stat_answered_eslewhere` — the call can be answered on
  another device (the panel or another phone); the app then ends its own call leg.

## 4. The SIP MESSAGE control channel (`LinphoneManager.swift`)

`sendMessageToAddress(_:message:callback:)` (`0x1000fb498`):

- Body format: **`msg: <message>, addr: <address>`** (immediates at `0x1000fb538`).
- `linphone_core_get_chat_room_from_uri(core, toUri)` →
  `linphone_chat_room_create_message(room, body)` → state-changed callback → send.
- A nearby function validates the target as an IPv4 address (` is a valid IP address`,
  regex `^((\d|[1-9]\d|1\d{2}|2[0-4]\d|25[0-5])\.){3}(…)$`) — i.e. when the gateway's local
  IP is known, messages can go to it directly (still via the SIP stack).
- Incoming chat messages are matched against known sipUsers (`matching sender with
  sipAccount: `; `nil sipuser, avoid sending message`; `sender mismatch, deleting chat
  room`) and drive the answering-machine conversation.
- Message strings in the binary: `action_activations`, `action_aswm_enable`,
  `action_aswm_disable`, `action_gateway_update`, plus Doorline's already-known
  `ACTION action_aswm_play id=<id>`. The answering machine also has an
  `answering machine unhandled linphone state` guard.
- The command vocabulary sent over the SIP MESSAGE channel is the `vde_*` set
  (disassembly at `0x1000fc650`, string pool `0x1002b1000`): `vde_doorlock_remote`,
  `vde_doorlock_local`, `vde_doorlock_entr_remote`, `vde_doorlock_entr_local`,
  `vde_call_answer_remote/_local`, `vde_call_home_remote/_local`,
  `vde_aswm_enabled/_disabled`, `vde_autoswitching_*` (camera auto-switch),
  `vde_setup_activation`, `vde_setup_camera`, `vde_analytics_disabled`. The `_local`
  /`_remote` suffix picks the transport: local when the proxy server is reachable on
  the LAN (checked against the proxy-config list, IPv4 regex at `0x1000fb0d0`),
  remote otherwise. The door-lock path builds the OWN frame `*8*19*%@##` (address as
  parameter) alongside the `vde_doorlock_*` message and the gateway SIP identity
  `sip:c300x@{plant}.bs.iotleg.com`.

So the ASWM control path is: SIP MESSAGE to the gateway sip user with `vde_aswm_*`
bodies (and `ACTION action_aswm_play id=<id>` for playback) — not the OWN bus.
Doorline's session sends the vde bodies when a registrar is wired.

## 5. Push (PushKit VoIP)

- `PKPushRegistry` VoIP pushes (`(VOIP allowed)`, `PUSHVOIP payload`, `PUSHVOIP token:`).
- Token registered on the portal: `GET/POST/DELETE /plants/{p}/pushNotifications[/{id}]`
  (`deletePushRegistration(_:notificationId:gateway:shouldRegister:onResult:)`,
  `getPushRegistrations(_:onSuccess:onError:)`).
- On incoming push: `pushRegistry(_:didReceiveIncomingPushWith:for:)` reports a CallKit
  incoming call and wakes the SIP stack; `comingFromPushDelay` throttles re-pushes.
- Registration contact carries `contactInfo: <push desc>` (see §2.3).
- The binary also logs `dbg_linphone_push` and keeps `DoorEliot_IOS_pushToken` in
  UserDefaults.

macOS note: the macOS app can skip push; ringing while the app is open is enough for a
first pass. If Doorline later wants background ringing on macOS, APNs VoIP pushes exist
there too, but that is out of scope for now.

## 6. Local gateway link (XOpen / OpenWebNet over TCP)

### 6.1 Discovery (`BruteForceScanner.swift`, `ARPUtils`)

- The app finds the 300X on the LAN by subnet scan: it opens a socket to read the netmask
  (`Failed to open socket to get netmask`), optionally ARP-scans (`ARPUtils`), and
  brute-forces IPs (`STARTING DISCOVERY, bruteforce: true/false`, `fastBruteForce`,
  `BRUTEFORCE ALREADY RUNNING`, `OWN IP NOT FOUND`). No mDNS.
- Result cached; "OWN IP" = the OpenWebNet gateway address.

### 6.2 Connection (`XOpenGatewayClient.swift`)

- Transport: **SwiftSocket `TCPClient` to `<gateway-ip>:20000`** (`0x4e20` at
  `0x10001892c`) — the standard OpenWebNet TCP port.
- Session open: the OWN XML frame Doorline already has in `C300XCodec.sessionOpen`
  (`OWNSetProtocol`, `Version=2`, `Command=1`, `Monitor=1`, `ConnAlwaysOn=1`) is byte-
  identical in the official binary.
- Association: `associateWithGateway(_:password:gatewayID:languageCode:token:macAddress:isReplacement:…)`
  and `handShakeXopen(ipAddress:password:welcomeMessage:)` — the pairing flow exchanges the
  portal token with the panel over OWN (`Transaction device verification failed`, `secure
  device signature`, `The association was refused by cloud. The device and application are
  on different webservers!`).
- Firmware update (`GatewayUpdateViewController`, `action_gateway_update`, `gwupdate_*`
  strings, zip download + SSZipArchive) and gateway monitoring data
  (`GatewayMessageBuilder`/`GatewayMessageParaser` [sic], nanopb protobuf, battery level
  strings) also run over this link.
- Diagnostic frames present as literals: `*#130**1##` (`BAD ANSWER TO *#130**1##:`),
  `*99*0##` (`error on *99*0##`).

### 6.3 Doorline impact

Doorline has the OWN frames (WHO 8 door lock `*8*19*20##`, actuator `*8*21*10##`,
camera `*8*1#5#4#20*10##`, answering machine `*8*91##`/`*8*92##`) but no TCP transport —
`PortalTransport` only forwards `PUT https://…` frames and everything else stays queued.
Add an OWN transport: NWConnection to `gatewayIP:20000`, session open, frame writes, ACK
reads, reconnect. The gateway IP needs a source: the portal plant/gateway document may
carry it; otherwise a manual entry or the brute-force scan. (The official app keeps the
discovered IP locally, so the portal is not guaranteed to have it.)

## 7. Misc

- Config caching: `configServerETag`, `configServerLastModifiedString`,
  `plantConfChangeReceived()` — the conf document is read with ETag / Last-Modified and
  written with `If-Match`; conf changes are pushed/observed.
- GDPR consent endpoints under `/legacy/c3x_gdpr_*`.
- `isIPhone/isIPhone2/isIPhone4` — the SipUtils device-type strings (deviceName for the
  SIP user / Contact).
- Default gateway association password shown to the user is `12345` (`0x100018788`,
  the "12345" literal) — the standard Classe 300X configuration password.
- Language code `EN` default in the association request (`0x1000187a8`).
- Firebase Crashlytics/RemoteConfig + Dynatrace + Graylog (`log.bs.iotleg.com`) are
  telemetry only; the QR scan, wifi provisioning and Netatmo camera are separate features
  (setup wizard / smart actions), not needed for Doorline.
- `ifconfig.io/ip` — the app queries its public IP (used during gateway association to
  detect NAT).

## 8. Doorline TODO derived from this

1. SIP user parser: add `sipUser`/`sipAccount` username spellings. — in `Sip.swift`.
2. Registrar parity: TLS:443 transport, expires 5,184,000, SRTP mandatory, STUN
   `stun.linphone.org`, verify CN off, video activation policy (auto-accept/initiate),
   in-call/nortp timeouts 60/180 s. — in `LinphoneManager.applyCoreSettings` and
   `register`. The push `contactInfo` contact parameter is not sent yet (no push plumbing).
3. Client certificate: keypair + CSR + `/users/cert/signcert` + Keychain + hand to
   linphonesw. — `CertificateSigningRequest`, `SipCertificateProvisioner`,
   `SipCertificateStore`; wired into `connectSip`. The signcert response envelope is a
   best guess (unverified against the live portal).
4. Call handling: CoreDelegate → ring/answer/decline/end; accept params (audio SendRecv,
   video RecvOnly per remote offer); makeCall with custom SDP attributes
   (`id-it-keyPairParam*` when the keypair exchange is implemented). — call handling is
   in `LinphoneManager`; the keypair SDP exchange is not implemented yet.
5. SIP MESSAGE channel: `msg: X, addr: Y` bodies to the gateway SIP user for
   ASWM play/enable/disable and door lock during a call. — `sendMessage` + incoming
   message parsing in the session.
6. OWN TCP transport to `gatewayIP:20000` (session open + WHO-8 frames + ACK handling) and
   a gateway-IP source (portal doc → manual entry → LAN scan). — `OwnTransport` with a
   manual panel-address field; the LAN brute-force scan is not implemented.
7. Conf document: GET with ETag/If-None-Match, PUT with `If-Match`; real JSON schema. —
   not done; the current raw-text PUT is a placeholder until the schema is pinned down.
8. (iOS) VoIP push registration on `/plants/{p}/pushNotifications`. — not done.
9. macOS SIP: the linphone dependency is platform-filtered to iOS; macOS builds use the
   stub registrar until a macOS-capable linphone package is added.
