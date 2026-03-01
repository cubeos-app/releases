# Changelog

All notable changes to CubeOS are documented here.
This changelog is generated from conventional commits across all CubeOS repositories.

## v0.2.0-beta.05 — 2026-03-01

### API

- Ethernet gate and AP teardown for Standard profile wizard ([ff5896fa](https://github.com/cubeos-app/api/commit/ff5896fa))
- add reboot step to profile switch and access_url computation ([94a907b5](https://github.com/cubeos-app/api/commit/94a907b5))
- add WiFi AP whitelist/blacklist proxy endpoints ([f4be1494](https://github.com/cubeos-app/api/commit/f4be1494))
- Bluetooth coexistence API with override persistence ([da7fccbb](https://github.com/cubeos-app/api/commit/da7fccbb))
- add dhcp_active field to network status response ([476ca0a4](https://github.com/cubeos-app/api/commit/476ca0a4))
- add GET /api/v1/setup/preconfiguration endpoint ([0ccde67d](https://github.com/cubeos-app/api/commit/0ccde67d))
- DHCP reconciliation, verify steps, and infra error handling ([38340039](https://github.com/cubeos-app/api/commit/38340039))
- replace inline struct with named BluetoothOverrideRequest for swag ([51640d35](https://github.com/cubeos-app/api/commit/51640d35))
- self-healing Pi-hole auth when Swarm env var has stale password ([eb840598](https://github.com/cubeos-app/api/commit/eb840598))

### Dashboard

- Standard profile Ethernet gate and AP teardown in wizard ([4a7b6812](https://github.com/cubeos-app/dashboard/commit/4a7b6812))
- add AP teardown dialog for All-in-One to Standard transition ([765a4dc2](https://github.com/cubeos-app/dashboard/commit/765a4dc2))
- add WiFi interfaces panel in settings ([5989da09](https://github.com/cubeos-app/dashboard/commit/5989da09))
- add DHCP status to network overview, remove dead SetupWizard ([ec924a03](https://github.com/cubeos-app/dashboard/commit/ec924a03))
- add pre-configuration adoption to first-boot wizard ([6f41a492](https://github.com/cubeos-app/dashboard/commit/6f41a492))

### HAL

- USB WiFi AP preference with two-stage test and whitelist/blacklist ([dad2cf78](https://github.com/cubeos-app/hal/commit/dad2cf78))
- Bluetooth/WiFi coexistence management ([50c64877](https://github.com/cubeos-app/hal/commit/50c64877))
- use detected uplink interface for DHCP nmap probe ([d2974345](https://github.com/cubeos-app/hal/commit/d2974345))
- replace hardcoded x86_64 arch and NPM URLs with runtime detection ([17d169e9](https://github.com/cubeos-app/hal/commit/17d169e9))

### Core Apps

- Pi-hole healthcheck uses FTL readiness probe instead of /admin/ ([9421ec8e](https://github.com/cubeos-app/coreapps/commit/9421ec8e))

### Releases

- add Apply now? prompt to console TUI profile change ([2f580496](https://github.com/cubeos-app/releases/commit/2f580496))
- USB WiFi AP preference in boot scripts ([ff971ab8](https://github.com/cubeos-app/releases/commit/ff971ab8))
- boot-time Bluetooth coexistence enforcement ([54930dee](https://github.com/cubeos-app/releases/commit/54930dee))
- automated changelog generation from conventional commits ([b0765206](https://github.com/cubeos-app/releases/commit/b0765206))
- pre-configuration detection engine for Pi Imager, Armbian, custom.toml, LXC ([1473d045](https://github.com/cubeos-app/releases/commit/1473d045))
- compute website download URLs from version instead of dotenv ([05264e6b](https://github.com/cubeos-app/releases/commit/05264e6b))
- set world-readable permissions on DMZ upload directories ([7993503c](https://github.com/cubeos-app/releases/commit/7993503c))
- GitHub pre-release targets correct repo, uploads lite image ([fba35aae](https://github.com/cubeos-app/releases/commit/fba35aae))
- make upload-to-dmz validate-image needs optional ([574358c9](https://github.com/cubeos-app/releases/commit/574358c9))
- migrate Pi-hole config to v6 REST API with retry+verify+fallback ([3b4fdc86](https://github.com/cubeos-app/releases/commit/3b4fdc86))
- use public GitHub mirror URLs for changelog commit links ([eaad216b](https://github.com/cubeos-app/releases/commit/eaad216b))
- set /cubeos/ directory ownership to cubeos:cubeos ([04d5f718](https://github.com/cubeos-app/releases/commit/04d5f718))
- increase package registry upload timeout to 3600s ([648d75cb](https://github.com/cubeos-app/releases/commit/648d75cb))

---

## v0.2.0-beta.04 — 2026-02-28

### API

- **access-profile**: phase 1 — skip DNS/proxy steps for standard profile ([d549795e](https://github.com/cubeos-app/api/commit/d549795e))
- **access-profile**: phase 2 — profile endpoints + test connectivity ([904fc5a7](https://github.com/cubeos-app/api/commit/904fc5a7))
- **access-profile**: phase 3 — access_profile_switch FlowEngine workflow ([e957790a](https://github.com/cubeos-app/api/commit/e957790a))
- **x86**: port mode host + network mode from env ([b7dc4774](https://github.com/cubeos-app/api/commit/b7dc4774))
- **x86**: uptime, memory, app status, and install URL for Tier 2 ([33a49b24](https://github.com/cubeos-app/api/commit/33a49b24))
- **x86-qa3**: NPM port 81, AP hardware detection, memory HAL fallback, schema v24 ([8b65c183](https://github.com/cubeos-app/api/commit/8b65c183))
- **x86-qa3**: AP detection checks WiFi interfaces instead of HAL reachability ([e586857f](https://github.com/cubeos-app/api/commit/e586857f))
- **iridium**: correct SBD text limit from 340 to 120 chars ([655cb678](https://github.com/cubeos-app/api/commit/655cb678))

### Dashboard

- **wizard**: skip AP step when no WiFi or container tier ([72b0b3a7](https://github.com/cubeos-app/dashboard/commit/72b0b3a7))
- **access-profile**: phase 2 — wizard step + settings UI + app access URLs ([f3026595](https://github.com/cubeos-app/dashboard/commit/f3026595))
- **access-profile**: phase 3 — profile switch progress modal ([dffbfffa](https://github.com/cubeos-app/dashboard/commit/dffbfffa))
- **dashboard**: use API_URL env var for nginx upstream instead of hardcoded Pi IP ([3c7fc7ac](https://github.com/cubeos-app/dashboard/commit/3c7fc7ac))
- **x86**: app URLs use IP:port, wizard shows real host, UPS banner filter ([9c475abf](https://github.com/cubeos-app/dashboard/commit/9c475abf))
- **x86**: connecting screen, i18n collision, AP status, install URL ([715b1694](https://github.com/cubeos-app/dashboard/commit/715b1694))
- **iridium**: correct SBD limits, add routing explanation, signal guard ([d648ea06](https://github.com/cubeos-app/dashboard/commit/d648ea06))
- **iridium**: remove verbose explanation banners ([41ae476d](https://github.com/cubeos-app/dashboard/commit/41ae476d))

### HAL

- **access-profile**: phase 2 — DHCP + proxy capability detection endpoints ([d51e7011](https://github.com/cubeos-app/hal/commit/d51e7011))
- **x86**: device detection LXC/VM/physical + network mode AP-aware ([b5e63816](https://github.com/cubeos-app/hal/commit/b5e63816))
- **x86**: container detection via CUBEOS_TIER, ethernet detection for LXC veth ([795b15e3](https://github.com/cubeos-app/hal/commit/795b15e3))
- **gps**: stop claiming FTDI serial devices as GPS receivers ([adb0b1a4](https://github.com/cubeos-app/hal/commit/adb0b1a4))
- **iridium**: eliminate goroutine leak in serial drain/flush ([68458df4](https://github.com/cubeos-app/hal/commit/68458df4))

### Core Apps

- use GATEWAY_IP variable for dashboard nginx proxy_pass ([d7361a2b](https://github.com/cubeos-app/coreapps/commit/d7361a2b))

### Releases

- **console**: add Access Profile menu (item 4) ([5e34fae8](https://github.com/cubeos-app/releases/commit/5e34fae8))
- **ci**: add DMZ download links to GitHub Release body ([ba44a33a](https://github.com/cubeos-app/releases/commit/ba44a33a))
- **installer**: add DATABASE_PATH to generated defaults.env ([8753e7f1](https://github.com/cubeos-app/releases/commit/8753e7f1))
- **installer**: add CUBEOS_ACCESS_PROFILE to defaults.env ([4ac02c98](https://github.com/cubeos-app/releases/commit/4ac02c98))
- **x86-qa3**: cubeos status uptime fallback to /proc/uptime for Tier 2 ([64e16674](https://github.com/cubeos-app/releases/commit/64e16674))
- **releases**: gate Packer builds on version bump commits only ([bc47fc05](https://github.com/cubeos-app/releases/commit/bc47fc05))
- **releases**: add workflow:rules to skip empty pipelines ([8fd35dcb](https://github.com/cubeos-app/releases/commit/8fd35dcb))

---

## v0.2.0-beta.03 — 2026-02-27

### API

- inject X-HAL-Key on all API→HAL requests via transport wrapper ([787e73d6](https://github.com/cubeos-app/api/commit/787e73d6))
- create bind mount dirs before stack deploy; fix setup_complete flag ([33f2a60b](https://github.com/cubeos-app/api/commit/33f2a60b))
- ensure setup_complete flag on startup for existing deployments ([b8bab3cb](https://github.com/cubeos-app/api/commit/b8bab3cb))
- pass compose_path and domain to app removal workflow compensation ([c22160af](https://github.com/cubeos-app/api/commit/c22160af))

### Releases

- **console**: update mode names, add AP settings + factory reset menus ([eb2d4953](https://github.com/cubeos-app/releases/commit/eb2d4953))
- **installer**: treat HTTP 4xx as reachable in registry connectivity check ([f1d06290](https://github.com/cubeos-app/releases/commit/f1d06290))

---

## v0.2.0-beta.02 — 2026-02-27

### API

- Phase 6a — rename network mode constants to v2 names ([7b0df3bd](https://github.com/cubeos-app/api/commit/7b0df3bd))
- Phase 6b — wifi_client mode with 30s fallback + FlowEngine workflow ([ade39c63](https://github.com/cubeos-app/api/commit/ade39c63))
- dynamic interface detection + mode availability (Phase 6c) ([1108b7a3](https://github.com/cubeos-app/api/commit/1108b7a3))
- **api**: send X-HAL-Key header for HAL ACL authentication [Phase 8.4] ([c989d7dd](https://github.com/cubeos-app/api/commit/c989d7dd))

### Dashboard

- Phase 6a — rename network mode constants to v2 names (T6a-07, T6a-08) ([10569151](https://github.com/cubeos-app/dashboard/commit/10569151))
- Phase 6b — WiFiClientTransition overlay + Pi Imager WiFi pre-fill ([2c716535](https://github.com/cubeos-app/dashboard/commit/2c716535))
- interface assignment wizard + hardware-aware mode selector (Phase 6c) ([0d01650e](https://github.com/cubeos-app/dashboard/commit/0d01650e))
- **dashboard**: adopt ResponsiveTable across all pages [Phase 8.2a] ([438d2afe](https://github.com/cubeos-app/dashboard/commit/438d2afe))
- **dashboard**: unified TabBar component and polling optimization [Phase 8.2b] ([a34cb452](https://github.com/cubeos-app/dashboard/commit/a34cb452))
- **dashboard**: Lighthouse audit fixes and vue-i18n setup [Phase 8.2c] ([e70aadb5](https://github.com/cubeos-app/dashboard/commit/e70aadb5))
- **demo**: add full CasaOS app catalogue snapshot to demo App Store ([6fcdc23b](https://github.com/cubeos-app/dashboard/commit/6fcdc23b))
- **dashboard**: Phase 8.2 frontend polish — ResponsiveTable, TabBar, i18n, Lighthouse fixes ([3b1aa259](https://github.com/cubeos-app/dashboard/commit/3b1aa259))
- **dashboard**: i18n extraction — DashboardView, AppsPage, NetworkPage ([5b5ab7de](https://github.com/cubeos-app/dashboard/commit/5b5ab7de))
- **dashboard**: i18n extraction — SystemPage, SettingsPage ([3985a774](https://github.com/cubeos-app/dashboard/commit/3985a774))
- **dashboard**: i18n extraction — AppCard, InstallFlow, NetworkModeSelector, WiFiConnector ([6bf272f3](https://github.com/cubeos-app/dashboard/commit/6bf272f3))
- **dashboard**: i18n extraction — NetworkOverviewTab, WiFiTab, FirewallTab ([90e669ed](https://github.com/cubeos-app/dashboard/commit/90e669ed))
- **dashboard**: i18n extraction — DNSTab, ClientsTab, TrafficTab ([1305eeb0](https://github.com/cubeos-app/dashboard/commit/1305eeb0))
- **dashboard**: i18n extraction — NetworkConfigDialog, WiFiClientTransition, IPConfigStep ([fe89bc7d](https://github.com/cubeos-app/dashboard/commit/fe89bc7d))
- **dashboard**: i18n extraction — VPNTab, VPNManager ([929d5319](https://github.com/cubeos-app/dashboard/commit/929d5319))
- **dashboard**: i18n extraction — MyAppsTab, AppStoreTab, AppManagerTab ([413a6ac8](https://github.com/cubeos-app/dashboard/commit/413a6ac8))
- **dashboard**: i18n extraction — AppDetailSheet, AppHealthModal, DockerTab ([1a85cf25](https://github.com/cubeos-app/dashboard/commit/1a85cf25))
- use define to inject VITE_DEMO_MODE as compile-time constant ([71d2d4a4](https://github.com/cubeos-app/dashboard/commit/71d2d4a4))
- replace VITE_DEMO_MODE with __CUBEOS_DEMO__ compile-time constant ([1e082db2](https://github.com/cubeos-app/dashboard/commit/1e082db2))
- compact demo banner, fix recent_logs demo data format ([ab975d9d](https://github.com/cubeos-app/dashboard/commit/ab975d9d))

### HAL

- Phase 6a — rename network mode constants to v2 names (T6a-06) ([2226b15b](https://github.com/cubeos-app/hal/commit/2226b15b))
- Phase 6b — HAL station mode endpoints for wifi_client switching ([3946a5cf](https://github.com/cubeos-app/hal/commit/3946a5cf))
- HAL interface detection + CUBEOS_TIER support (Phase 6c) ([97cc4ac7](https://github.com/cubeos-app/hal/commit/97cc4ac7))
- **hal**: per-caller ACL middleware and key-based authentication [Phase 8.4] ([673ec620](https://github.com/cubeos-app/hal/commit/673ec620))

### Core Apps

- add hal-internal overlay network for HAL access isolation ([6668dcca](https://github.com/cubeos-app/coreapps/commit/6668dcca))

### Releases

- Phase 6a — rename network mode constants in boot scripts (T6a-09, T6a-10, T6a-11) ([0beebd74](https://github.com/cubeos-app/releases/commit/0beebd74))
- Phase 6b — wifi_client boot fallback, avahi mDNS, WiFi watchdog ([311a4353](https://github.com/cubeos-app/releases/commit/311a4353))
- dynamic interface detection in boot scripts (Phase 6c) ([9b9e70f7](https://github.com/cubeos-app/releases/commit/9b9e70f7))
- Phase 7a — curl installer core ([d6b3c4eb](https://github.com/cubeos-app/releases/commit/d6b3c4eb))
- Phase 7b — cubeos CLI wrapper + channels + lifecycle ([b4a5d3ec](https://github.com/cubeos-app/releases/commit/b4a5d3ec))
- x86_64 Packer template + boot config (Phase 7c Session 2) ([872c0cde](https://github.com/cubeos-app/releases/commit/872c0cde))
- Phase 7c Session 3 — Armbian templates + CI matrix ([f0f3a5fb](https://github.com/cubeos-app/releases/commit/f0f3a5fb))
- Add BananaPi M4 Zero platform (Allwinner H618) ([a5f496aa](https://github.com/cubeos-app/releases/commit/a5f496aa))
- Add Orange Pi 5, ROCK 5B, Quartz64 B platform placeholders ([119c3871](https://github.com/cubeos-app/releases/commit/119c3871))
- add releases upload scripts and channel metadata automation ([3aa0a032](https://github.com/cubeos-app/releases/commit/3aa0a032))
- add hardware-based first-boot network mode detection ([974bd676](https://github.com/cubeos-app/releases/commit/974bd676))
- add hal-internal network and HAL port protection to boot scripts ([ccc3f70d](https://github.com/cubeos-app/releases/commit/ccc3f70d))
- source defaults.env early in boot-lib for CUBEOS_VERSION ([f0f95563](https://github.com/cubeos-app/releases/commit/f0f95563))
- cloud-init --wait hangs forever, blocks entire first boot ([c51b18bb](https://github.com/cubeos-app/releases/commit/c51b18bb))
- remove apt-get from packer chroot (no DNS available) ([73ea835e](https://github.com/cubeos-app/releases/commit/73ea835e))
- hostapd beacon suppression on BCM4345 (Pi 5) ([f5d8ca83](https://github.com/cubeos-app/releases/commit/f5d8ca83))
- update stale base-image/ references in README and Makefile comments ([19bcddc6](https://github.com/cubeos-app/releases/commit/19bcddc6))
- add android_tether case to boot-lib apply_network_mode and write_netplan_for_mode ([d1900ef8](https://github.com/cubeos-app/releases/commit/d1900ef8))
- **ci**: use optional needs for boot-test-x86 job ([4ccbfc4f](https://github.com/cubeos-app/releases/commit/4ccbfc4f))
- **ci**: add needs:[] to sync-installer for immediate execution ([cc00a6c9](https://github.com/cubeos-app/releases/commit/cc00a6c9))
- move wifi watchdog to Phase 3 + add DMZ upload pipeline ([7c0f388d](https://github.com/cubeos-app/releases/commit/7c0f388d))
- restructure repo for multi-platform image building ([a8912b28](https://github.com/cubeos-app/releases/commit/a8912b28))
- Add manual build jobs for 6 Armbian platforms ([5e8ca716](https://github.com/cubeos-app/releases/commit/5e8ca716))
- **releases**: add QEMU post-build validation stage [Phase 8.3] ([b5610bd4](https://github.com/cubeos-app/releases/commit/b5610bd4))
- add QEMU boot test for x86_64 image ([1e449808](https://github.com/cubeos-app/releases/commit/1e449808))
- auto-sync install.sh to website on releases/main push ([04895a2a](https://github.com/cubeos-app/releases/commit/04895a2a))
- fix SSH user (kyriakosp) and key loading for DMZ upload ([7aea3fb9](https://github.com/cubeos-app/releases/commit/7aea3fb9))
- fix sync-installer — use GITLAB_TOKEN directly ([f2aa23a1](https://github.com/cubeos-app/releases/commit/f2aa23a1))
- tag all 10 GitLab repos on every release — mirrors to GitHub automatically ([ded60490](https://github.com/cubeos-app/releases/commit/ded60490))

---

## v0.2.0-beta.01 — 2026-02-24

### API

- circuit breaker core + HAL + NPM integration (Batch 2.0a) ([5ad3aece](https://github.com/cubeos-app/api/commit/5ad3aece))
- **flowengine**: batch 2.5a gap closure - FQDN enrichment, bind mounts, volume storage, webui detection, subdomain prettification, completion hooks ([e5e7c669](https://github.com/cubeos-app/api/commit/e5e7c669))
- **flowengine**: wire FlowEngine into main.go with fat envelope, progress adapter, and adapters ([f40f95e5](https://github.com/cubeos-app/api/commit/f40f95e5))
- **flowengine**: gut inline orchestration, replace with FlowEngine Submit calls, add workflow visibility API ([e6d4fb41](https://github.com/cubeos-app/api/commit/e6d4fb41))
- **flowengine**: add network mode switching workflow with saga rollback ([a8cf5104](https://github.com/cubeos-app/api/commit/a8cf5104))
- **metrics**: add /api/v1/metrics Prometheus endpoint (Batch 2.6) ([dfcc33fa](https://github.com/cubeos-app/api/commit/dfcc33fa))
- **flowengine**: replace inline first-boot setup with first_boot_setup saga workflow ([dbd45a85](https://github.com/cubeos-app/api/commit/dbd45a85))
- registry-first batch 5 — background sync, GC, and update endpoint ([af51dac9](https://github.com/cubeos-app/api/commit/af51dac9))
- offline-first batch 1 — cached_manifests table, registry activities, cache workflow ([6b8be566](https://github.com/cubeos-app/api/commit/6b8be566))
- offline-first batch 2 — auto-cache images to registry on appstore install ([b01504e3](https://github.com/cubeos-app/api/commit/b01504e3))
- **schema**: add v18 migration — update_history, backup_schedules, enhanced backups ([9296be30](https://github.com/cubeos-app/api/commit/9296be30))
- **schema**: add config_snapshots table and P0-seed config models ([d9b4d971](https://github.com/cubeos-app/api/commit/d9b4d971))
- **update**: add UpdateManager with version check and manifest fetcher ([3893f84a](https://github.com/cubeos-app/api/commit/3893f84a))
- **update**: add system_update workflow, activities, and API endpoints ([685eb0c7](https://github.com/cubeos-app/api/commit/685eb0c7))
- **backup**: add scope tiers, hot backup, FlowEngine workflows, and manifest verification ([e8783962](https://github.com/cubeos-app/api/commit/e8783962))
- **backup**: add destination adapters (USB/NFS/SMB) and AES-256-GCM encryption ([379f4c92](https://github.com/cubeos-app/api/commit/379f4c92))
- **backup**: add cron scheduler with retention policy and schedule CRUD API ([8a0169c5](https://github.com/cubeos-app/api/commit/8a0169c5))
- **backup**: add bare-metal restore via USB detection and auto-restore ([0f823a0c](https://github.com/cubeos-app/api/commit/0f823a0c))
- **flowengine**: pass forward step output as compensation input, increase convergence timeout ([6f8db15c](https://github.com/cubeos-app/api/commit/6f8db15c))
- **flowengine**: forward step output piping, SSE timeout exemption, bind mount pre-creation ([e34bae88](https://github.com/cubeos-app/api/commit/e34bae88))
- **flowengine**: align insert_app activity with actual apps table schema ([58efbb2a](https://github.com/cubeos-app/api/commit/58efbb2a))
- **setup**: guard configure_wifi against empty password, safe default in GenerateDefaultConfig ([ed757085](https://github.com/cubeos-app/api/commit/ed757085))
- **setup**: guard empty wifi password, safe defaults, skip bypasses workflow ([45225138](https://github.com/cubeos-app/api/commit/45225138))
- gofmt registry.go + registry_sync.go ([0c1bbf97](https://github.com/cubeos-app/api/commit/0c1bbf97))
- protect system images from install/delete in registry ([24df3385](https://github.com/cubeos-app/api/commit/24df3385))
- three-tier system image protection (registry/appstore/cleanup) ([21d32d63](https://github.com/cubeos-app/api/commit/21d32d63))
- change StoreCachedManifestInput.Manifest to json.RawMessage (fixes unmarshal crash) ([3f735ad6](https://github.com/cubeos-app/api/commit/3f735ad6))
- WebSocket upgrade failing due to missing http.Hijacker on metrics statusWriter ([a167ffbe](https://github.com/cubeos-app/api/commit/a167ffbe))
- **registry**: use localhost:5000 for docker push and fix PathEscape on image names (B2) ([d50ce90b](https://github.com/cubeos-app/api/commit/d50ce90b))
- **flowengine**: make registry activity unmarshal errors non-fatal (B4) ([6378b528](https://github.com/cubeos-app/api/commit/6378b528))
- registry-first deploy — service uses localhost:5000 image ref ([89f362fa](https://github.com/cubeos-app/api/commit/89f362fa))
- **backup**: include encrypted .tar.gz.enc files in backup listing ([d81f5733](https://github.com/cubeos-app/api/commit/d81f5733))
- P1-18: wire integration tests into CI (allow_failure: true) ([81dc1f24](https://github.com/cubeos-app/api/commit/81dc1f24))
- P1-18: fix integration test credentials (use CI variable) ([d0ec8886](https://github.com/cubeos-app/api/commit/d0ec8886))
- batch 2.0b: Docker/Swarm funnelTransport circuit breaker ([78ffe9a7](https://github.com/cubeos-app/api/commit/78ffe9a7))
- batch 2.0c: Pi-hole v6 REST API migration + circuit breaker ([d06e6623](https://github.com/cubeos-app/api/commit/d06e6623))
- P2-10 to P2-16: FlowEngine foundation (store, step executor, migration #16) ([89becb4f](https://github.com/cubeos-app/api/commit/89becb4f))
- P2-17 to P2-22: saga orchestrator, workflow engine, AppRemoveWorkflow, HAL stubs ([e2c551ca](https://github.com/cubeos-app/api/commit/e2c551ca))
- P2-23 to P2-27: AppInstall/AppStoreInstall/AppStoreRemove workflows + real activities ([af58f7fe](https://github.com/cubeos-app/api/commit/af58f7fe))
- **appstore**: gut inline orchestration, replace with FlowEngine Submit calls ([ea325e89](https://github.com/cubeos-app/api/commit/ea325e89))
- registry-first batch 4: API registry awareness + per-repo CI retag ([f5e7aa98](https://github.com/cubeos-app/api/commit/f5e7aa98))
- update workflow tests for batch 2.5a (version 2, 15 steps) ([00173735](https://github.com/cubeos-app/api/commit/00173735))

### Dashboard

- registry-first batch 6 — dashboard registry settings + system images UI ([14aea9d7](https://github.com/cubeos-app/dashboard/commit/14aea9d7))
- offline-first batch 3 — dual install/cache buttons, manifest-based offline apps ([1e0de1ae](https://github.com/cubeos-app/dashboard/commit/1e0de1ae))
- **dashboard**: add Open button for installed apps in App Store (U1) ([474ee720](https://github.com/cubeos-app/dashboard/commit/474ee720))
- add update notification badge to Settings nav item ([e822413d](https://github.com/cubeos-app/dashboard/commit/e822413d))
- **dashboard**: add system updates UI — badge, review panel, history ([60f1a1fe](https://github.com/cubeos-app/dashboard/commit/60f1a1fe))
- **dashboard**: add backup management UI with scope, schedule, restore wizard ([13a69677](https://github.com/cubeos-app/dashboard/commit/13a69677))
- hide system images from offline apps, protect from delete ([f474106e](https://github.com/cubeos-app/dashboard/commit/f474106e))
- hide critical images from offline apps, lock system images in registry ([9dcbcb0d](https://github.com/cubeos-app/dashboard/commit/9dcbcb0d))
- visible Cache Offline button + green checkmarks on install progress steps ([32eb5dc6](https://github.com/cubeos-app/dashboard/commit/32eb5dc6))
- cache offline button in detail sheet + persistent caching progress ([ee906dc3](https://github.com/cubeos-app/dashboard/commit/ee906dc3))
- installed label on store cards + registry refresh after caching ([8c5e99ee](https://github.com/cubeos-app/dashboard/commit/8c5e99ee))
- **registry**: increase image refresh delays for Docker catalog propagation (B2) ([01d06d9c](https://github.com/cubeos-app/dashboard/commit/01d06d9c))
- registry-first deploy — push to localhost:5000 and deploy from compose ([47055a3b](https://github.com/cubeos-app/dashboard/commit/47055a3b))
- Revert "fix: hide system images from offline apps, protect from delete" ([e34cd33e](https://github.com/cubeos-app/dashboard/commit/e34cd33e))
- Revert "feat: registry-first batch 6 — dashboard registry settings + system images UI" ([96deacca](https://github.com/cubeos-app/dashboard/commit/96deacca))
- Reapply "feat: registry-first batch 6 — dashboard registry settings + system images UI" ([21f4b37b](https://github.com/cubeos-app/dashboard/commit/21f4b37b))
- Reapply "fix: hide system images from offline apps, protect from delete" ([fe084c71](https://github.com/cubeos-app/dashboard/commit/fe084c71))
- fix cachedApps response key (cached_apps not apps) — fixes App Store crash ([aeb197e5](https://github.com/cubeos-app/dashboard/commit/aeb197e5))

### HAL

- registry-first batch 4: CI deploy retags + pushes to local registry ([919cdd35](https://github.com/cubeos-app/hal/commit/919cdd35))

### Core Apps

- migrate Dufs + ChromaDB to localhost:5000 registry refs ([c3aec58a](https://github.com/cubeos-app/coreapps/commit/c3aec58a))
- ci-restart uses --pull never for registry-first compose refs ([acf84e36](https://github.com/cubeos-app/coreapps/commit/acf84e36))
- deploy image-versions.env to Pi + disable Dufs healthcheck ([b6206d70](https://github.com/cubeos-app/coreapps/commit/b6206d70))
- P1-19: cross-service smoke test script ([220c772b](https://github.com/cubeos-app/coreapps/commit/220c772b))
- registry-first batch 2: all images reference localhost:5000 with pinned tags ([518fdf0c](https://github.com/cubeos-app/coreapps/commit/518fdf0c))

### Releases

- add Dufs + ChromaDB to core image pipeline (Phase 3 Gap A) ([637bca44](https://github.com/cubeos-app/releases/commit/637bca44))
- **boot**: add USB backup detection for bare-metal restore ([da46684f](https://github.com/cubeos-app/releases/commit/da46684f))
- 0.2.0-beta.01 — Pi Imager distribution, Full+Lite variants, cloud-init ([9dff5b2f](https://github.com/cubeos-app/releases/commit/9dff5b2f))
- Phase 1b losetup graceful teardown, Phase 1c lite variant guards ([9b826abe](https://github.com/cubeos-app/releases/commit/9b826abe))
- Phase 1c find instead of ls glob, Phase 2 PiShrink timeout ([0f94b3e1](https://github.com/cubeos-app/releases/commit/0f94b3e1))
- handle stale GPG keys, add sleep between GHCR downloads ([ff134988](https://github.com/cubeos-app/releases/commit/ff134988))
- Phase 1c core push treats missing lite tarballs as expected skips ([39071252](https://github.com/cubeos-app/releases/commit/39071252))
- Phase 1c core validation skips lite-absent images ([701bb4df](https://github.com/cubeos-app/releases/commit/701bb4df))
- add xz to github release job dependencies ([f242bce7](https://github.com/cubeos-app/releases/commit/f242bce7))
- phase 1.3: security hardening (SSH, sysctl, journald, watchdog, fail2ban) ([2e35e35f](https://github.com/cubeos-app/releases/commit/2e35e35f))
- P1-21: post-build image validation (Phase 1d gate before compression) ([03128aaf](https://github.com/cubeos-app/releases/commit/03128aaf))
- registry-first batch 1: push all images to local registry at build time ([209b15e5](https://github.com/cubeos-app/releases/commit/209b15e5))
- registry-first batch 3: boot sequence sources image-versions, registry deploys first ([1e5e87e6](https://github.com/cubeos-app/releases/commit/1e5e87e6))

---

## Earlier Releases

Alpha releases (v0.1.0-alpha.01 through v0.2.0-alpha.01) are documented in
[GitHub Release History](https://github.com/cubeos-app/releases/releases).
