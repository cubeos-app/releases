# Changelog

All notable changes to CubeOS are documented here.
This changelog is generated from conventional commits across all CubeOS repositories.

## v0.2.0-beta.04 — 2026-02-28

### API

- **access-profile**: phase 1 — skip DNS/proxy steps for standard profile ([d549795e](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/d549795ebaa71c84c3894a3bfc56b1be2e33a362))
- **access-profile**: phase 2 — profile endpoints + test connectivity ([904fc5a7](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/904fc5a7a51c440b1fcd8e708ad607d7a89e18e9))
- **access-profile**: phase 3 — access_profile_switch FlowEngine workflow ([e957790a](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e957790abea7a8ccfbba70d50ffd92771efaa1bc))
- **x86**: port mode host + network mode from env ([b7dc4774](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/b7dc4774b7426cddde3b9ff7f7cef5bdf75adb66))
- **x86**: uptime, memory, app status, and install URL for Tier 2 ([33a49b24](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/33a49b240b9c14442c46c7c31d15923f82a05d6a))
- **x86-qa3**: NPM port 81, AP hardware detection, memory HAL fallback, schema v24 ([8b65c183](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/8b65c1836bde6ce691ecfaf1bbbe81e15884281f))
- **x86-qa3**: AP detection checks WiFi interfaces instead of HAL reachability ([e586857f](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e586857f8b4d78a06194592db5fd13bbc309410b))
- **iridium**: correct SBD text limit from 340 to 120 chars ([655cb678](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/655cb6781d2553e91fd01656a32febab71ead496))

### Dashboard

- **wizard**: skip AP step when no WiFi or container tier ([72b0b3a7](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/72b0b3a72f8f5e39bb7909c0ea5e4d57272fef01))
- **access-profile**: phase 2 — wizard step + settings UI + app access URLs ([f3026595](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/f3026595f9b3fcc4b32e7a5c6e2d375b29dc6669))
- **access-profile**: phase 3 — profile switch progress modal ([dffbfffa](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/dffbfffada1958bf2b5d70588f8aa9d1a88a3b35))
- **dashboard**: use API_URL env var for nginx upstream instead of hardcoded Pi IP ([3c7fc7ac](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/3c7fc7ac8d49615339bcba0be18354b6da9835bb))
- **x86**: app URLs use IP:port, wizard shows real host, UPS banner filter ([9c475abf](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/9c475abfe5884a5652af8b4a1ad7f3a307be2b3a))
- **x86**: connecting screen, i18n collision, AP status, install URL ([715b1694](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/715b169436bb47ab868947bfde86e5cd986de904))
- **iridium**: correct SBD limits, add routing explanation, signal guard ([d648ea06](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/d648ea06617e3487fbd09b6ceedfff3d94ce858c))
- **iridium**: remove verbose explanation banners ([41ae476d](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/41ae476d7fdef42c1508d004501a16879c239bb0))

### HAL

- **access-profile**: phase 2 — DHCP + proxy capability detection endpoints ([d51e7011](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/d51e7011fb46bc0e073e664532f3dfbb580df621))
- **x86**: device detection LXC/VM/physical + network mode AP-aware ([b5e63816](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/b5e638165f21adf77b1f7d826fad8e3d9150d9e4))
- **x86**: container detection via CUBEOS_TIER, ethernet detection for LXC veth ([795b15e3](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/795b15e39ba924fdca53da4cdeb162aee9cddf32))
- **gps**: stop claiming FTDI serial devices as GPS receivers ([adb0b1a4](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/adb0b1a419fc1c08fb24207b8e9beb742e99eca7))
- **iridium**: eliminate goroutine leak in serial drain/flush ([68458df4](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/68458df41efbbe2e5462d8dfa672ec25577dfef0))

### Core Apps

- use GATEWAY_IP variable for dashboard nginx proxy_pass ([d7361a2b](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/d7361a2ba0f512bc8631227c6bd9bde3b8dc7a74))

### Releases

- **console**: add Access Profile menu (item 4) ([5e34fae8](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/5e34fae8c014b005e7dc4ee16ce06ceff0dc1f89))
- **ci**: add DMZ download links to GitHub Release body ([ba44a33a](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/ba44a33a1ff297e6fda2a8915788215419b7d80b))
- **installer**: add DATABASE_PATH to generated defaults.env ([8753e7f1](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/8753e7f1e6126a72b0c5fcb749012137fe940658))
- **installer**: add CUBEOS_ACCESS_PROFILE to defaults.env ([4ac02c98](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/4ac02c98bb4580391d9727af092c994ac8a81738))
- **x86-qa3**: cubeos status uptime fallback to /proc/uptime for Tier 2 ([64e16674](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/64e166741b7600b0f21aeedaea54950416d7d807))
- **releases**: gate Packer builds on version bump commits only ([bc47fc05](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/bc47fc05fcf181e9ff6c59437746bd03793f37f4))
- **releases**: add workflow:rules to skip empty pipelines ([8fd35dcb](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/8fd35dcb769bedd17e4ebedb3ca21d39cf0f866c))

---

## v0.2.0-beta.03 — 2026-02-27

### API

- inject X-HAL-Key on all API→HAL requests via transport wrapper ([787e73d6](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/787e73d6ba93ee0938a767723a8210a2f1485eb4))
- create bind mount dirs before stack deploy; fix setup_complete flag ([33f2a60b](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/33f2a60b6d87055b155c130e9d1c8e2ec869bf68))
- ensure setup_complete flag on startup for existing deployments ([b8bab3cb](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/b8bab3cb2d1ff4b3d8809c6e8fc02b24b12dbbf1))
- pass compose_path and domain to app removal workflow compensation ([c22160af](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/c22160afe2c69de8bda1abc42e3959a200cca2bb))

### Releases

- **console**: update mode names, add AP settings + factory reset menus ([eb2d4953](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/eb2d4953fa5286044c0eba39628bfdf7c3c6b48b))
- **installer**: treat HTTP 4xx as reachable in registry connectivity check ([f1d06290](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/f1d062903f251a813e517163fbd34c3732ef67f8))

---

## v0.2.0-beta.02 — 2026-02-27

### API

- Phase 6a — rename network mode constants to v2 names ([7b0df3bd](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/7b0df3bda0ffe82a661d6a06761c11423dbfe61e))
- Phase 6b — wifi_client mode with 30s fallback + FlowEngine workflow ([ade39c63](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/ade39c6302120772f22fa4240a191233ed87008d))
- dynamic interface detection + mode availability (Phase 6c) ([1108b7a3](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/1108b7a353a61b86f7fe3be9a43de78f3e246ecb))
- **api**: send X-HAL-Key header for HAL ACL authentication [Phase 8.4] ([c989d7dd](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/c989d7dd145a876a319aa82783193f4a16ce058c))

### Dashboard

- Phase 6a — rename network mode constants to v2 names (T6a-07, T6a-08) ([10569151](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/1056915189b4b237b69abfbb3600102b3fa89b0c))
- Phase 6b — WiFiClientTransition overlay + Pi Imager WiFi pre-fill ([2c716535](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/2c716535fd23e838b5d24d6ec69b6e477d3a7044))
- interface assignment wizard + hardware-aware mode selector (Phase 6c) ([0d01650e](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/0d01650e132db16a0801c74207955dfb21710eb7))
- **dashboard**: adopt ResponsiveTable across all pages [Phase 8.2a] ([438d2afe](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/438d2afefb56f4709ccbe3e604c1f69511f7e464))
- **dashboard**: unified TabBar component and polling optimization [Phase 8.2b] ([a34cb452](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/a34cb452b8c8eac239063cba311678fd128b4770))
- **dashboard**: Lighthouse audit fixes and vue-i18n setup [Phase 8.2c] ([e70aadb5](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/e70aadb5cec07f9cbf9eedc2855b9581cd5ad5a8))
- **demo**: add full CasaOS app catalogue snapshot to demo App Store ([6fcdc23b](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/6fcdc23b7fc93847c91c39dcd9d57601b5103d9b))
- **dashboard**: Phase 8.2 frontend polish — ResponsiveTable, TabBar, i18n, Lighthouse fixes ([3b1aa259](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/3b1aa259e9b0306ae150655c90bd4243e2add506))
- **dashboard**: i18n extraction — DashboardView, AppsPage, NetworkPage ([5b5ab7de](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/5b5ab7de565b5d055f6844bd03b4322618a2a1eb))
- **dashboard**: i18n extraction — SystemPage, SettingsPage ([3985a774](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/3985a774c8a97a6ab3872d55f509ee0b7f0ac8f0))
- **dashboard**: i18n extraction — AppCard, InstallFlow, NetworkModeSelector, WiFiConnector ([6bf272f3](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/6bf272f33737a3454af2ad2ebf2220d57c5bbe70))
- **dashboard**: i18n extraction — NetworkOverviewTab, WiFiTab, FirewallTab ([90e669ed](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/90e669eda0b8010d8c40373e181d0e151ef7ee6b))
- **dashboard**: i18n extraction — DNSTab, ClientsTab, TrafficTab ([1305eeb0](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/1305eeb0ae1f25b7d95f5600876aa0b5141f83de))
- **dashboard**: i18n extraction — NetworkConfigDialog, WiFiClientTransition, IPConfigStep ([fe89bc7d](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/fe89bc7de11ac38b6721bdc4700b22dfa18a5c14))
- **dashboard**: i18n extraction — VPNTab, VPNManager ([929d5319](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/929d5319ad82c19d39f27ea0cf61da6a76194de2))
- **dashboard**: i18n extraction — MyAppsTab, AppStoreTab, AppManagerTab ([413a6ac8](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/413a6ac8021c6755ca310f7db225d2f5ebeed534))
- **dashboard**: i18n extraction — AppDetailSheet, AppHealthModal, DockerTab ([1a85cf25](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/1a85cf2509fa0fe55bb26976ba34be410668a856))
- use define to inject VITE_DEMO_MODE as compile-time constant ([71d2d4a4](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/71d2d4a460ce5e938fa0d29bd10676d31fe1e80e))
- replace VITE_DEMO_MODE with __CUBEOS_DEMO__ compile-time constant ([1e082db2](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/1e082db2102385e3660d1b7f2ba13744bf02a0ee))
- compact demo banner, fix recent_logs demo data format ([ab975d9d](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/ab975d9d6531efdcd30a7219043f2de795e4537a))

### HAL

- Phase 6a — rename network mode constants to v2 names (T6a-06) ([2226b15b](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/2226b15b5a2f896beaa078828f2ca7ee1f5acd85))
- Phase 6b — HAL station mode endpoints for wifi_client switching ([3946a5cf](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/3946a5cf67bfc429aaa09d2917432154615ec9ed))
- HAL interface detection + CUBEOS_TIER support (Phase 6c) ([97cc4ac7](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/97cc4ac7f013a37d1ce960007bcb7918a35916fc))
- **hal**: per-caller ACL middleware and key-based authentication [Phase 8.4] ([673ec620](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/673ec6200b0150e96c3bc527d4ab05451833400b))

### Core Apps

- add hal-internal overlay network for HAL access isolation ([6668dcca](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/6668dcca8b07f0cf1a77657c9c742a3380c6c3f6))

### Releases

- Phase 6a — rename network mode constants in boot scripts (T6a-09, T6a-10, T6a-11) ([0beebd74](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/0beebd7491252df6addb484223b92feb695f2654))
- Phase 6b — wifi_client boot fallback, avahi mDNS, WiFi watchdog ([311a4353](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/311a435344a15ce774587abc08536b15d667311c))
- dynamic interface detection in boot scripts (Phase 6c) ([9b9e70f7](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/9b9e70f76a1f0a95cf8d3168b34b559b0dc4d80a))
- Phase 7a — curl installer core ([d6b3c4eb](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/d6b3c4ebd128557726716212e3bade1ea270d525))
- Phase 7b — cubeos CLI wrapper + channels + lifecycle ([b4a5d3ec](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/b4a5d3ecb15d7cc776ed5feff523bbbf53bc973a))
- x86_64 Packer template + boot config (Phase 7c Session 2) ([872c0cde](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/872c0cde3ac9642ea066237cc781eb8d4072ff65))
- Phase 7c Session 3 — Armbian templates + CI matrix ([f0f3a5fb](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/f0f3a5fbe23c4bc9fcdca521ea19ee30c85cdd8c))
- Add BananaPi M4 Zero platform (Allwinner H618) ([a5f496aa](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/a5f496aa7294a5ff0f9f33670d2a53aaf88ee03b))
- Add Orange Pi 5, ROCK 5B, Quartz64 B platform placeholders ([119c3871](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/119c3871d1e0e1d97c5d53c749a04fbcb0a2ec67))
- add releases upload scripts and channel metadata automation ([3aa0a032](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/3aa0a03201e44c7d9f8780589ef1bc012903c009))
- add hardware-based first-boot network mode detection ([974bd676](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/974bd67615d15bdd17b8891c5d1b622b71673926))
- add hal-internal network and HAL port protection to boot scripts ([ccc3f70d](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/ccc3f70d97b42489a5ed9e95c520a502a868fba8))
- source defaults.env early in boot-lib for CUBEOS_VERSION ([f0f95563](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/f0f95563412a44ad3a5b17912f0cc9846007ba0c))
- cloud-init --wait hangs forever, blocks entire first boot ([c51b18bb](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/c51b18bb573a1ef146baf557d592b6117fc3de50))
- remove apt-get from packer chroot (no DNS available) ([73ea835e](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/73ea835e6f50eac246435d95c74cc41e59cd71e0))
- hostapd beacon suppression on BCM4345 (Pi 5) ([f5d8ca83](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/f5d8ca83bfcc22680aedf6a9793f3e66c3f2a806))
- update stale base-image/ references in README and Makefile comments ([19bcddc6](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/19bcddc6a9c1b85f6746de788443ecaad3103214))
- add android_tether case to boot-lib apply_network_mode and write_netplan_for_mode ([d1900ef8](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/d1900ef88bf1b28fa2a78f8768d958982706405b))
- **ci**: use optional needs for boot-test-x86 job ([4ccbfc4f](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/4ccbfc4f029c43b999f4f6c397827166d924e2d4))
- **ci**: add needs:[] to sync-installer for immediate execution ([cc00a6c9](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/cc00a6c93b115d3d312c9396e8eb9a22188fb57b))
- move wifi watchdog to Phase 3 + add DMZ upload pipeline ([7c0f388d](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/7c0f388dadc05c64281150a3bf772b85e017017d))
- restructure repo for multi-platform image building ([a8912b28](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/a8912b282dfe22cbbc7a3af198512d40cdb878a6))
- Add manual build jobs for 6 Armbian platforms ([5e8ca716](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/5e8ca71649225f6dbfe20b14d464f4a05e4f94ec))
- **releases**: add QEMU post-build validation stage [Phase 8.3] ([b5610bd4](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/b5610bd406cfc03edad29c79798386006843adb0))
- add QEMU boot test for x86_64 image ([1e449808](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/1e449808c499c8f8ffbb0ee15d0bf2ecf12d8351))
- auto-sync install.sh to website on releases/main push ([04895a2a](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/04895a2a9a3a96c311b891508f5fbff24b666b33))
- fix SSH user (kyriakosp) and key loading for DMZ upload ([7aea3fb9](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/7aea3fb9e690ac4cf24165a49c7d8d7c87cb73dd))
- fix sync-installer — use GITLAB_TOKEN directly ([f2aa23a1](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/f2aa23a18804d3ca2989b1762bd0138ca1057850))
- tag all 10 GitLab repos on every release — mirrors to GitHub automatically ([ded60490](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/ded6049035f21d31d6a17ac03b21c404c8b56a60))

---

## v0.2.0-beta.01 — 2026-02-24

### API

- circuit breaker core + HAL + NPM integration (Batch 2.0a) ([5ad3aece](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/5ad3aece4ea3eba3844816926110d3fe8a1f5bc4))
- **flowengine**: batch 2.5a gap closure - FQDN enrichment, bind mounts, volume storage, webui detection, subdomain prettification, completion hooks ([e5e7c669](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e5e7c669969999c741c1684ba32f1c209ab5bd65))
- **flowengine**: wire FlowEngine into main.go with fat envelope, progress adapter, and adapters ([f40f95e5](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/f40f95e55d171a45081e867e3d753ff71b936e70))
- **flowengine**: gut inline orchestration, replace with FlowEngine Submit calls, add workflow visibility API ([e6d4fb41](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e6d4fb41947cb14613348ad4a670e0b8eb1cf99a))
- **flowengine**: add network mode switching workflow with saga rollback ([a8cf5104](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/a8cf5104f683d8efd9eddf0f88a321a35ac1b7b0))
- **metrics**: add /api/v1/metrics Prometheus endpoint (Batch 2.6) ([dfcc33fa](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/dfcc33fa0da5792b8561cd1168dd00d9077f4538))
- **flowengine**: replace inline first-boot setup with first_boot_setup saga workflow ([dbd45a85](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/dbd45a85e41946969c1a4243a16e10575c83f123))
- registry-first batch 5 — background sync, GC, and update endpoint ([af51dac9](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/af51dac9f3f24739b39ddcea2fdfd2b2f11f6578))
- offline-first batch 1 — cached_manifests table, registry activities, cache workflow ([6b8be566](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/6b8be56620a9a61b89529b85d3e6c39af53bcac2))
- offline-first batch 2 — auto-cache images to registry on appstore install ([b01504e3](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/b01504e3c5ae603a26fee9ec68924273063af143))
- **schema**: add v18 migration — update_history, backup_schedules, enhanced backups ([9296be30](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/9296be30464a63a97fe67e042cdca7b56af93f92))
- **schema**: add config_snapshots table and P0-seed config models ([d9b4d971](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/d9b4d97122f175c686bbabe9462144e827f05360))
- **update**: add UpdateManager with version check and manifest fetcher ([3893f84a](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/3893f84ae7502cae7e403b71484a7dcd849778bd))
- **update**: add system_update workflow, activities, and API endpoints ([685eb0c7](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/685eb0c797fe1ce0e4e535270639819b8e8760ac))
- **backup**: add scope tiers, hot backup, FlowEngine workflows, and manifest verification ([e8783962](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e8783962f7d57263708855598057951fcb8cbde4))
- **backup**: add destination adapters (USB/NFS/SMB) and AES-256-GCM encryption ([379f4c92](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/379f4c928a48e71a5849075236ebb6a9a57ca7d2))
- **backup**: add cron scheduler with retention policy and schedule CRUD API ([8a0169c5](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/8a0169c5b4e1ecd89013be32b9224de33f9fc6af))
- **backup**: add bare-metal restore via USB detection and auto-restore ([0f823a0c](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/0f823a0cf19369ffa8cefece600a0d785345eb8f))
- **flowengine**: pass forward step output as compensation input, increase convergence timeout ([6f8db15c](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/6f8db15ce56670eeb5e5b35be19b55a4d078ab58))
- **flowengine**: forward step output piping, SSE timeout exemption, bind mount pre-creation ([e34bae88](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e34bae8850fa676aecfdd21d1de768d7caf69967))
- **flowengine**: align insert_app activity with actual apps table schema ([58efbb2a](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/58efbb2a085199c0390bf1a1441130d872090225))
- **setup**: guard configure_wifi against empty password, safe default in GenerateDefaultConfig ([ed757085](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/ed75708532517d81cfca2c9fb4626dd20fe41616))
- **setup**: guard empty wifi password, safe defaults, skip bypasses workflow ([45225138](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/452251389ba1eb6c3a593e3b314cf63c45d8b555))
- gofmt registry.go + registry_sync.go ([0c1bbf97](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/0c1bbf97d93fe664dda024e08e5a44db26cbaedb))
- protect system images from install/delete in registry ([24df3385](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/24df33859dcaddf7a57bc6dd4b7cf5cfa7936a2b))
- three-tier system image protection (registry/appstore/cleanup) ([21d32d63](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/21d32d634f06ff8946b61a4f7e337eec37fd2acb))
- change StoreCachedManifestInput.Manifest to json.RawMessage (fixes unmarshal crash) ([3f735ad6](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/3f735ad6787b985494b6cd23d849e1c467796879))
- WebSocket upgrade failing due to missing http.Hijacker on metrics statusWriter ([a167ffbe](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/a167ffbe810d7fda4d4b5d15c12a558b8e90293b))
- **registry**: use localhost:5000 for docker push and fix PathEscape on image names (B2) ([d50ce90b](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/d50ce90bc36d4e819a229c570c38eb5e79f6c52d))
- **flowengine**: make registry activity unmarshal errors non-fatal (B4) ([6378b528](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/6378b52845789467ae33ddc1dc2b3721ab1aca52))
- registry-first deploy — service uses localhost:5000 image ref ([89f362fa](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/89f362fa3b25fe1a9011401bb10a049d09028c6f))
- **backup**: include encrypted .tar.gz.enc files in backup listing ([d81f5733](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/d81f57330df1887ffe19383936870dca8e8cf84d))
- P1-18: wire integration tests into CI (allow_failure: true) ([81dc1f24](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/81dc1f248fb37ab566f0931d1f41779492fecc5a))
- P1-18: fix integration test credentials (use CI variable) ([d0ec8886](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/d0ec8886c2f1f7d6c82f5ce27e90bb8370ec415f))
- batch 2.0b: Docker/Swarm funnelTransport circuit breaker ([78ffe9a7](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/78ffe9a75a7b1adc22bc712d7aa1bba981261fa4))
- batch 2.0c: Pi-hole v6 REST API migration + circuit breaker ([d06e6623](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/d06e662315e72500b9043573cdaeb09f79edd64a))
- P2-10 to P2-16: FlowEngine foundation (store, step executor, migration #16) ([89becb4f](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/89becb4fecac0f8774f5f121a577cf8611af8231))
- P2-17 to P2-22: saga orchestrator, workflow engine, AppRemoveWorkflow, HAL stubs ([e2c551ca](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/e2c551ca7498dbe3ae193f3c445c1d6ef17d1263))
- P2-23 to P2-27: AppInstall/AppStoreInstall/AppStoreRemove workflows + real activities ([af58f7fe](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/af58f7fee8c3b0ae30bf5c56faab844876b5883a))
- **appstore**: gut inline orchestration, replace with FlowEngine Submit calls ([ea325e89](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/ea325e897fd433bfc61c7c361831fd68e97b48cd))
- registry-first batch 4: API registry awareness + per-repo CI retag ([f5e7aa98](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/f5e7aa988db16fe1a81bbb0f328103b122ac438a))
- update workflow tests for batch 2.5a (version 2, 15 steps) ([00173735](https://gitlab.nuclearlighters.net/products/cubeos/api/-/commit/00173735d2b1c753e505ba3f0e4d0df362bd7526))

### Dashboard

- registry-first batch 6 — dashboard registry settings + system images UI ([14aea9d7](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/14aea9d74d4a3ec449c2b6da2e7738c31c280f1e))
- offline-first batch 3 — dual install/cache buttons, manifest-based offline apps ([1e0de1ae](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/1e0de1aebea320c79e0797411d508817b6d69844))
- **dashboard**: add Open button for installed apps in App Store (U1) ([474ee720](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/474ee7205860d994f98535244a0f75e3bf34da4b))
- add update notification badge to Settings nav item ([e822413d](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/e822413d7a703a8ff29fa68456f03e654fc7a0b6))
- **dashboard**: add system updates UI — badge, review panel, history ([60f1a1fe](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/60f1a1fe87e4a51c6ead59e3d2b540264afaac19))
- **dashboard**: add backup management UI with scope, schedule, restore wizard ([13a69677](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/13a6967784d3c8797c874423dcc3a0ca4f7f4efd))
- hide system images from offline apps, protect from delete ([f474106e](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/f474106ea3a8d0d841ca4c265898b1567ddb7012))
- hide critical images from offline apps, lock system images in registry ([9dcbcb0d](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/9dcbcb0da4dbaefb905757292b2b1c837defe935))
- visible Cache Offline button + green checkmarks on install progress steps ([32eb5dc6](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/32eb5dc6fad6731a852b5d7b53834defc21d7300))
- cache offline button in detail sheet + persistent caching progress ([ee906dc3](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/ee906dc31ebd1bd2cfe95a13ec7925a66ff62f6e))
- installed label on store cards + registry refresh after caching ([8c5e99ee](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/8c5e99ee83ed4f81aa470e9cfc849988660e7bc0))
- **registry**: increase image refresh delays for Docker catalog propagation (B2) ([01d06d9c](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/01d06d9c73c8fdb576120b923675dc633aa90965))
- registry-first deploy — push to localhost:5000 and deploy from compose ([47055a3b](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/47055a3b70a9928617e16845798e92aa7b6a0679))
- Revert "fix: hide system images from offline apps, protect from delete" ([e34cd33e](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/e34cd33e2366ded6524dad97c7bca5eb6cfe2de9))
- Revert "feat: registry-first batch 6 — dashboard registry settings + system images UI" ([96deacca](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/96deacca43844beb34db15648b72833ff3750261))
- Reapply "feat: registry-first batch 6 — dashboard registry settings + system images UI" ([21f4b37b](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/21f4b37bfda604b1a96fd5b54e37505c2d5892b6))
- Reapply "fix: hide system images from offline apps, protect from delete" ([fe084c71](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/fe084c711d2f6aca9f1adf7e6d001b3d7707d390))
- fix cachedApps response key (cached_apps not apps) — fixes App Store crash ([aeb197e5](https://gitlab.nuclearlighters.net/products/cubeos/dashboard/-/commit/aeb197e5dc90d33068296fe73117c422cec57532))

### HAL

- registry-first batch 4: CI deploy retags + pushes to local registry ([919cdd35](https://gitlab.nuclearlighters.net/products/cubeos/hal/-/commit/919cdd356e8dccffa5f3977e6b033a4e3e164a9d))

### Core Apps

- migrate Dufs + ChromaDB to localhost:5000 registry refs ([c3aec58a](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/c3aec58ac6becbb60be4f586a72460acf76106ee))
- ci-restart uses --pull never for registry-first compose refs ([acf84e36](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/acf84e36a1981492bdc546f163d338356873c2ae))
- deploy image-versions.env to Pi + disable Dufs healthcheck ([b6206d70](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/b6206d70066f420bcb364369e1879e5f44c48fe2))
- P1-19: cross-service smoke test script ([220c772b](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/220c772b25aa6b6ac489555cfb82e1ffde5e865f))
- registry-first batch 2: all images reference localhost:5000 with pinned tags ([518fdf0c](https://gitlab.nuclearlighters.net/products/cubeos/coreapps/-/commit/518fdf0cb7e063d918f0933b293b1948660a862d))

### Releases

- add Dufs + ChromaDB to core image pipeline (Phase 3 Gap A) ([637bca44](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/637bca44ab409057b5930c4375662fe1ef3e3af2))
- **boot**: add USB backup detection for bare-metal restore ([da46684f](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/da46684f96627a6278b6d57847e30ad35a4e3a9b))
- 0.2.0-beta.01 — Pi Imager distribution, Full+Lite variants, cloud-init ([9dff5b2f](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/9dff5b2fe12342231a500b342a10a92d85fa9085))
- Phase 1b losetup graceful teardown, Phase 1c lite variant guards ([9b826abe](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/9b826abec83c57715bd636242ebcbfa147fe4ee3))
- Phase 1c find instead of ls glob, Phase 2 PiShrink timeout ([0f94b3e1](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/0f94b3e1371c4a4b0d7d88cd755b95ad7dd0846e))
- handle stale GPG keys, add sleep between GHCR downloads ([ff134988](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/ff1349882f4bfef32b5499d8fb41dfb5bc9fb520))
- Phase 1c core push treats missing lite tarballs as expected skips ([39071252](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/390712522e8705097ded3b01f321947444f3fe9d))
- Phase 1c core validation skips lite-absent images ([701bb4df](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/701bb4dfd05eff1168e850e7611d67a9396cf24a))
- add xz to github release job dependencies ([f242bce7](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/f242bce72c7456241004a6abd3d2f4e8750f0665))
- phase 1.3: security hardening (SSH, sysctl, journald, watchdog, fail2ban) ([2e35e35f](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/2e35e35fecf202c64f25a66cc69cb458e873f11c))
- P1-21: post-build image validation (Phase 1d gate before compression) ([03128aaf](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/03128aaf9df6d14357c6d583b477a5359e94a98f))
- registry-first batch 1: push all images to local registry at build time ([209b15e5](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/209b15e54626eb5ba4a6e951500f5251365159cb))
- registry-first batch 3: boot sequence sources image-versions, registry deploys first ([1e5e87e6](https://gitlab.nuclearlighters.net/products/cubeos/releases/-/commit/1e5e87e68dc84d73094e2342d74de0819e3477af))

---

## Earlier Releases

Alpha releases (v0.1.0-alpha.01 through v0.2.0-alpha.01) are documented in
[GitHub Release History](https://github.com/cubeos-app/releases/releases).
