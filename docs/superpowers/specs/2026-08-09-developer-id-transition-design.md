# Developer ID 分发转换设计

日期：2026-08-09
状态：待实现
当前版本：v1.8.6（ad-hoc 签名，未公证）
目标版本：v1.9.0（Developer ID 签名 + Apple 公证）

## 背景

Yohaku Companion 的发布管线自 v1.7.3 起就是双模的：`.github/workflows/release.yml` 根据 5 个 Apple secret 是否齐全，在 ad-hoc 与 Developer ID 之间自动分支。Apple Developer Program 席位现已到位（Team `KAMM5N88X3`），ad-hoc 分支失去存在理由。

本设计描述从「ad-hoc 是常态、Developer ID 是可选」到「Developer ID 是唯一路径」的一次性转换。

## 已确认决策

| 决策 | 取值 |
|---|---|
| Apple Team ID | `KAMM5N88X3` |
| ad-hoc 分支 | 从 workflow 与脚本中彻底删除 |
| `REQUIRE_DEVELOPER_ID` variable | 一并删除 |
| 上线顺序 | 本地全链路预演通过后，再改仓库、配 secret、打 tag |
| 首个 Developer ID 版本 | v1.9.0 |
| 凭据配置方式 | `gh secret set NAME < file`，密钥值不进入对话上下文 |

## 现状事实

探查结论，构成本设计的前提：

| 事实 | 依据 |
|---|---|
| 工程 Team ID 与实际证书不符 | `project.pbxproj:291`（Debug）、`:328`（Release）与 `ExportOptions.plist` 均为 `7VYQTBFBS5`；本机唯一 Developer ID 证书属 `KAMM5N88X3` |
| CI 的 developer-id 分支从未成功执行过 | `release.yml:248-261` 只覆盖 `CODE_SIGN_IDENTITY`，不覆盖 `DEVELOPMENT_TEAM`；`-exportArchive` 会带着 `teamID=7VYQTBFBS5` 去匹配 `KAMM5N88X3` 的证书而失败 |
| 凭据存储已具备自动迁移能力 | `UserDefaultsRelay.swift:42` `CredentialStore.usesKeychainStorage` 运行时读 `kSecCodeInfoTeamIdentifier`；`resolve()` 的 `:1241`、`:1303`、`:1364` 三处已实现 journal → Keychain 迁移 |
| 首个 Developer ID 包将是首个启用 hardened runtime 的包 | ad-hoc 分支显式设置 `ENABLE_HARDENED_RUNTIME=NO`（`release.yml:283`） |
| hardened runtime 无需任何 entitlement 例外 | `LegacyMediaInfoProvider.swift:33` 加载的是 Apple 平台二进制，Library Validation 放行；`JXAMediaInfoProvider.swift:483` 走 `/usr/bin/osascript` 子进程；`media-control` 为 exec 而非 dlopen |
| 本机有两张同名 Developer ID 证书 | `2897C5CDBF3A5DFA1E7804B379F7ED7C3D64C257` 有效期至 2031-07-30；`02604D93C1F7116EA390BF6F41F82E3ADCA894EC` 至 2027-02-01。使用前者 |
| notarytool 只接受 Team Key | App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys，Developer 角色即足够；个人 key 无效 |
| ad-hoc 叙述集中在少数文档 | `YOHAKU_COMPANION_PRODUCT_SPEC.md`、`USER_GUIDE.md`、`PRESENCE_PRODUCT_UI_SPEC.md` 完全未提及，无需改动 |

## 变更范围

### 1. 签名身份

三处 `7VYQTBFBS5` 改为 `KAMM5N88X3`：

- `YohakuCompanion.xcodeproj/project.pbxproj:291`（Debug 配置 `DEVELOPMENT_TEAM`）
- `YohakuCompanion.xcodeproj/project.pbxproj:328`（Release 配置 `DEVELOPMENT_TEAM`）
- `ExportOptions.plist` 的 `teamID`

工程内 `CODE_SIGN_STYLE` 保持 `Automatic` 供本地开发使用；CI 继续显式覆盖为 `Manual`。`ENABLE_HARDENED_RUNTIME = YES` 保持不变。

不新增任何 `com.apple.security.cs.*` entitlement。`YohakuCompanion.entitlements` 不变。

### 2. 发布管线简化

`.github/workflows/release.yml`（当前 826 行）：

| 位置 | 处理 |
|---|---|
| `:138-196` `Select distribution mode` step | 整体删除，替换为一个只校验 5 个 Apple secret 齐备的短 step，缺任一则 `exit 1` |
| `:148`、`:154-160`、`:175-178` | `REQUIRE_DEVELOPER_ID` 全部逻辑删除 |
| `:201`、`:238`、`:294`、`:300`、`:480`、`:625` | `DISTRIBUTION_MODE` env 传递删除 |
| `:217` | keychain 准备的模式判断改为无条件执行 |
| `:248` / `:267-290` | archive 的 `if/else` 拆解，仅保留 developer-id 路径 |
| `:333`、`:370-374` | `verify_signature_mode` 的 adhoc case 与 hardened-runtime 反向断言删除 |
| `:503-507` | appcast notes 的 ad-hoc 警告注入删除 |
| `:638` | 发布 summary 的 adhoc 分支删除 |
| `:685` | 已发布制品校验的模式判断改为无条件执行 |

`scripts/prepare_arm64_app.sh`：

- 删除 `DISTRIBUTION_MODE` 变量（`:10`）与其 `case` 分支（`:18-33`）
- `SIGNING_IDENTITY` 从条件必需改为无条件必需
- `sign_code()` 始终附加 `--options runtime --timestamp`，删除 `SIGNING_TARGET=-` 路径

语义变化：签名模式从运行时分支变为编译期常量。凭据缺失从「静默降级为 ad-hoc」变为「发布失败」。`REQUIRE_DEVELOPER_ID` 这个防降级开关随之失去保护对象，从仓库 variable 中删除。

### 3. 凭据存储

**无 Swift 代码改动。** `CredentialStore.usesKeychainStorage` 在团队签名到位后自动翻转，既有迁移路径会在签名包首次启动时把 journal 中的凭据搬入 Keychain。

`ARCHITECTURE.md:222` 补一句说明：正式分发制品恒为团队签名，Keychain 是常态权威，protected journal 退化为降级路径。机制描述本身不变。

### 4. 文档

| 文件 | 改动 |
|---|---|
| `.agents/skills/release-yohaku-companion/SKILL.md` | 主要改动。`:8`、`:31`、`:41`、`:112`、`:122` 中 Apple secret 由 optional all-or-none 改为硬性必需；`:43` 的 `REQUIRE_DEVELOPER_ID` 整段删除；ad-hoc 模式描述删除 |
| `readme.md:90-91` | IMPORTANT 块重写为 Developer ID 签名 + Apple 公证 |
| `AGENTS.md:37` | 删除 "optional until the project explicitly requires notarized distribution" |
| `DEVELOPMENT.md:11` | 明确要求 Developer ID Application 证书 |
| `DEVELOPMENT.md:366` 附近 | 在 Sparkle secrets 段落旁补充 5 个 Apple secret 的必需性 |
| `ARCHITECTURE.md:222` | 见上节 |

### 5. 版本与发布说明

新增 `.github/release-notes/v1.9.0.md`，必须写明：

- 制品自本版本起由 Developer ID 签名并经 Apple 公证，首次启动不再需要 **Open Anyway**
- **从 v1.8.6 或更早版本升级需要重新授予辅助功能（Accessibility）权限**，因为代码签名身份变更导致 macOS 的 TCC 授权失效。这是一次性的，仅发生在这一跳
- 集成凭据会在首次启动时自动从本地受保护凭据存储迁移至 Keychain，无需重新输入

`project.pbxproj` 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 按仓库既有发布流程递增。

## 执行顺序

1. **本地全链路预演**（不改仓库）
   用 `2897C5CD…` 证书在本机跑通：`xcodebuild archive` → `-exportArchive` → `scripts/prepare_arm64_app.sh` → `xcrun notarytool submit --wait` → `xcrun stapler staple/validate` → `spctl --assess`。
   `DEVELOPMENT_TEAM=KAMM5N88X3` 可由 `xcodebuild` 命令行覆盖，但 `-exportArchive` 的 `teamID` 只能来自 plist 文件，无法命令行覆盖。预演须使用一份放在仓库外临时目录的 `ExportOptions.plist` 副本，其 `teamID` 已改为 `KAMM5N88X3`。

2. **仓库改动**
   按变更范围第 1、2、3、4 节修改，本地重跑一次预演确认改动后仍通过。

3. **CI 凭据配置**
   导出 `.p12`、签发 Team Key，用 `gh secret set NAME < file` 写入 5 个 secret，删除 `REQUIRE_DEVELOPER_ID` variable。

   凭据中间产物（`.p12`、`.p8`、其 base64 编码、口令与 ID 文件）一律落在仓库外的临时目录。`.gitignore` 虽已覆盖 `*.p12`、`*.p8`、`*.pem`、`*.key`，但**未覆盖 `*.base64`**，在仓库内生成 base64 文件会使私钥材料处于可被误提交的状态。完成配置后立即删除全部中间产物。

4. **发布 v1.9.0**
   撰写 release notes，按 `.agents/skills/release-yohaku-companion/SKILL.md` 的既有流程提交版本 commit 并打注解 tag。

## 验证标准

预演与 CI 均须满足：

- `codesign -dv --verbose=4` 输出包含 `Authority=Developer ID Application: Yuhao Jiang (KAMM5N88X3)` 且 `CodeDirectory` flags 含 `runtime`
- `xcrun stapler validate` 对 `.app` 与 `.dmg` 均通过
- `spctl --assess --type execute --verbose=4` 对 `.app` 通过；`spctl --assess --type open --context context:primary-signature` 对 `.dmg` 通过
- `scripts/prepare_arm64_app.sh` 的 arm64-only 全量断言通过
- appcast 含 `sparkle:edSignature=`

hardened runtime 回归验证（预演阶段人工执行，因其无法由 CI 断言）：

- 应用可正常启动且菜单栏项可见
- 媒体信息采集在 `JXAMediaInfoProvider` 与 `LegacyMediaInfoProvider` 两条路径上均能返回数据
- 授予辅助功能权限后窗口标题采集正常
- 凭据落入 Keychain：`security find-generic-password -s dev.innei.YohakuCompanion.credentials.v1` 可查到条目

## 明确不做

- 不启用 App Sandbox。应用依赖辅助功能与 Apple Events，沙箱化是独立且远超本次范围的产品变更
- 不改动任何 Swift 源码。凭据迁移已由既有实现覆盖
- 不新增 `workflow_dispatch` 干跑 job。与「简化 workflow」的目标相反
- 不为 hardened runtime 预防性添加 entitlement 例外。无例外是公证审核最干净的形态，若预演暴露真实缺口再针对性补充
- 不触碰 ProcessReporter 的任何偏好、Keychain service 或 Application Support 数据

## 风险

| 风险 | 缓解 |
|---|---|
| hardened runtime 首次启用导致运行时回归 | 预演阶段人工执行上述回归验证清单，失败则针对性补 entitlement 并重新预演 |
| 用户升级后辅助功能失效被误认为 Bug | v1.9.0 release notes 显著位置说明，且 Sparkle notes 与 GitHub Release 共用该文本 |
| `.p12` 误导出为 2027 到期的那张证书 | 导出前以 SHA-1 hash `2897C5CDBF3A5DFA1E7804B379F7ED7C3D64C257` 精确定位 |
| 误用个人 API Key 导致 notarytool 认证失败 | runbook 明确要求 Team Keys 页签签发 |
| 公证失败烧掉正式 tag | 本地预演先行，公证链路在打 tag 前已验证通过 |
