# iOS App Store 发布

工作流 `.github/workflows/ios-app-store.yml` 自动签名、归档并上传 App Store Connect；Apple 处理构建后，可用于 TestFlight，也可在 App Store Connect 手动选择构建正式提审。**上传成功不代表已经提交审核或上架。**

## 首次配置

当前应用标识为 `com.moonrailgun.sillydraft`，支持 iPhone 和 iPad，最低 iOS 15。版本与构建号只维护根目录 `pubspec.yaml`。商店显示名称建议 `SillyDraft`，SKU 可用 `sillydraft-ios`，主要语言建议简体中文；名称是否可用由 App Store Connect 确认。

1. 在 [Apple Developer 的 Identifiers](https://developer.apple.com/account/resources/identifiers/list) 注册 Explicit App ID：`com.moonrailgun.sillydraft`。使用将发布此应用的付费团队。
2. 在 [App Store Connect](https://appstoreconnect.apple.com/) → 我的 App → 新建 App，选 iOS，选择上述 Bundle ID，填写名称、语言、SKU。保存后记录数字 Apple ID（它不同于 Bundle ID、Team ID 和 Key ID）。[Apple 创建应用说明](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
3. 准备 **Apple Distribution 证书及对应私钥**，导出为带密码的 `.p12`。单独 `.cer`/`.pem` 不含私钥，不能供 CI 签名。若复用本机证书，无需重建或撤销它。
4. 在 Developer → Profiles 创建 **App Store Connect 分发**描述文件，选 SillyDraft 的 App ID 和上述发布证书，下载 `.mobileprovision`。Development、Ad Hoc、企业或其他 App 的描述文件不能使用。
5. 在 App Store Connect → 用户和访问 → 集成 → App Store Connect API，创建 Team API Key（此工作流使用带 Issuer ID 的团队密钥），给上传所需的 Developer 权限或组织规定的更高权限，保存 Key ID、Issuer ID 和仅可下载一次的 `AuthKey_<KEY_ID>.p8`。它不是 APNs 密钥。[Apple API 密钥说明](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
6. 在 GitHub 仓库 Settings → Secrets and variables → Actions 配置下表；初次不要启用自动发布变量，先手动上传验证一次。

## GitHub Secrets

| Secret | 内容 |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | 带私钥的发布 `.p12` 文件的 base64 |
| `IOS_DISTRIBUTION_P12_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `IOS_APP_STORE_PROFILE_BASE64` | SillyDraft App Store `.mobileprovision` 的 base64 |
| `APP_STORE_CONNECT_KEY_ID` | Team API Key 的 Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team API Key 的 Issuer ID |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | `AuthKey_<KEY_ID>.p8` 的 base64 |

Team ID、描述文件 UUID 和证书指纹从描述文件及导入的签名身份验证后获得，不另存一份容易失配的配置。工作流检查应用标识、团队、iOS 分发类型、过期时间和私钥匹配；凭据只放在 runner 临时目录与临时钥匙串，并在成功或失败后清理。参考 [GitHub 签名说明](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。

macOS 上可用下列命令把文件直接写入 GitHub Secret，不在终端输出密钥（替换路径）：

```sh
base64 -i /你的备份目录/signing/apple-distribution.p12 | gh secret set IOS_DISTRIBUTION_P12_BASE64 --repo moonrailgun/sillydraft
gh secret set IOS_DISTRIBUTION_P12_PASSWORD --repo moonrailgun/sillydraft < /你的备份目录/signing/distribution-p12-password.txt
base64 -i /你的备份目录/signing/SillyDraft_AppStore.mobileprovision | gh secret set IOS_APP_STORE_PROFILE_BASE64 --repo moonrailgun/sillydraft
base64 -i /你的备份目录/app-store-connect/AuthKey_KEYID.p8 | gh secret set APP_STORE_CONNECT_KEY_P8_BASE64 --repo moonrailgun/sillydraft
gh secret set APP_STORE_CONNECT_KEY_ID --repo moonrailgun/sillydraft
gh secret set APP_STORE_CONNECT_ISSUER_ID --repo moonrailgun/sillydraft
```

最后两条会交互询问值。不要把 Apple ID 密码或双重验证恢复码放进工作流。

## 运行方式和版本号

- **手动上传**：将改动合并到默认分支后，Actions → iOS App Store → Run workflow，选择要发布的分支或 tag。它先调用现有 `verify.yml`，通过后构建上传。
- **随发布自动上传**：首次上传验证通过后，添加仓库 Variable `IOS_APP_STORE_ENABLED=true`。之后 `release.sh` 推送版本 tag，现有 Release 在所有测试与桌面/Android 包发布成功后调用 iOS 工作流。默认未启用，避免缺少 Apple 凭据影响现有发布。
- iOS 上传失败时，已发布的其他平台 Release 保持可用；在 Actions 重跑失败任务。若 Apple 已收到该构建，不要重复上传相同版本/构建号；先到 App Store Connect 查看处理状态。需要重新出包时更新 `pubspec.yaml` 并按发布规则发布新 tag。
- `manageAppVersionAndBuildNumber=false` 禁止 Xcode 导出时暗改版本。GitHub run number 不参与应用版本号。
- 归档用 Flutter **3.47.7**、`macos-26` runner 和 Xcode **26.4.1**。Apple 当前要求 Xcode 26 / iOS 26 SDK 或更新版本；runner 若移除固定版本，先核对镜像再升级路径，不静默改成 latest。[Apple SDK 要求](https://developer.apple.com/news/upcoming-requirements/)、[GitHub runner 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- Actions artifact 保存 IPA 和含 dSYM 的 `.xcarchive.zip`，保留 **30 天**；请下载到私人发布备份的 `artifacts/` 长期保管。原始归档通过 ZIP 保留目录属性。证书和 API 私钥不打入 artifact，也不上传公开 GitHub Release。构建使用 [Apple altool](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) 验证与上传；Apple 后续处理失败仍需在 App Store Connect 查看。

工作流文件不会自行配置远端 Secrets 或触发上传；需先准备凭据，再由发布者手动运行，或明确启用上面的随发布上传开关。证书/API key 到期或撤销后，更新备份和对应 Secrets。

## 正式提审前的产品与资料检查

下列是 2026-11-03 的源码检查结果，不能因工作流可构建而跳过：

- **隐私政策与 AI 同意**：已公开发布[隐私政策](https://github.com/moonrailgun/sillydraft/blob/main/docs/privacy-policy.md)，设置页提供外部浏览器入口，联系渠道为项目 GitHub Issues。向第三方 AI 发送内容前明确告知数据与接收方并取得同意的流程仍待补齐。模型设置里的地址和 API Key 输入不能替代完整披露。[审核指南 5.1.1、5.1.2](https://developer.apple.com/app-store/review/guidelines/)
- **App Privacy 问卷**：小说内容、提示词、对话和参考图片可发往用户选择的模型服务；备份可发往用户选择的同步服务，HTML 页面可加载 HTTPS 资源。需按实际接收方和保留方式填报，不能仅因本地优先就直接选择“不收集数据”。`lib/app/services.dart` 当前将 API 密钥存于本机 `secrets.json`，不要在政策里声称所有密钥存于 Keychain。[Apple 隐私说明](https://developer.apple.com/app-store/app-privacy-details/)
- **加密出口合规**：核心使用 AES-GCM 加密作品备份及资源，并使用网络加密。完成 Apple 加密问卷，确定适用声明和所需文件后再设置 `ITSAppUsesNonExemptEncryption`；不能仅以 HTTPS 为依据直接填写 `false`。[Apple 加密合规](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- **隐私清单**：在最终签名 archive 中核对 Flutter/插件的 `PrivacyInfo.xcprivacy`、required-reason API 和 Xcode 隐私报告。本任务未替第三方 SDK 作隐私声明。
- **iOS 插画限制已接入**：隐藏 NSFW 引擎选项，忽略已有 NSFW 角色配置，并在分类、任务执行和远程桌面调用处限制 NSFW/未分类生图；已标记 NSFW 的参考图不可用于生成。参考图、人设、重绘、助手批量生图和旧任务重试也受限，普通插画可继续。此流程依赖用户配置的分类模型，没有输出像素审查；不能因此直接勾选所有内容均无或声称保证过滤所有成人内容。实际分级仍按完整产品能力填写。
- **年龄分级、内容与地区**：按实际 AI 生成能力、导入内容和 HTML 前端完成新年龄分级问卷；核对用户导入脚本的边界与审核指南 2.5.2。发布地区、价格、版权主体、欧盟交易者信息和中国大陆可用性/所需资质应按发布者的真实情况填写。纯加载工具的用途应写入审核说明，不能据此替所有用户资源作版权保证。
- **审核可访问性**：无账号即可打开示例、阅读和编辑；AI 功能需一个审核期间可用、带限额的演示连接，或与 Apple 认可的完整演示方式配合。不要让审核员购买自己的模型额度，也不要把个人长期 API key 放入 App。示例不能冒充真实模型输出。
- **权限与真机**：在 iPhone/iPad 验证导入导出、相机扫码拒绝/允许、局域网、前后台、阅读与编辑；上传/签名成功不能替代真机验收。

## 商店材料与截图

准备名称、副标题、描述、关键词、支持 URL、隐私 URL、版权、审核联系人和审核说明。首次版本在 App Store Connect 选择与上传 IPA 相符的版本号；完成价格/地区、内容版权、年龄分级、隐私和加密信息，再选构建手动添加审核。

截图使用应用真实界面与无私人信息的示例内容，不把历史测试图冒充本次真机证据。当前 Apple 要求 iPhone Dynamic Island 中等屏幕组，支持 iPad 时还需 13 英寸 iPad；可用竖图分别为 **1206×2622** 与 **2064×2752**，PNG/JPEG 不带透明通道。上传前按 [Apple 最新截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) 和控制台实际栏位复核。

仓库提供专用截图测试，仅使用临时示例库与内存密钥，不读取作者作品或模型账号。在开发用模拟器执行（Flutter drive 会安装并清理应用，不要指向装有重要数据的设备）：

```sh
SILLYDRAFT_SCREENSHOT_DIR=/你的备份目录/store-materials/screenshots/iphone \
flutter drive --driver=test_driver/app_store_screenshots.dart \
  --target=integration_test/app_store_screenshots_test.dart \
  --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false \
  -d <iPhone-simulator-id>
```

换成 iPad 模拟器和独立 `ipad` 目录重复运行。保留原始截图、可编辑排版源文件和最终 PNG；尺寸合格仍需检查文字清晰、布局、当前版本一致性与实际功能。截图测试不调用真实模型。

如需展示插画，将可公开使用的示例图片单独放在素材目录，通过本机临时 HTTP 服务供模拟器导入（不要把服务目录指向含证书或密钥的备份根目录）：

```sh
python3 -m http.server 8769 --bind 127.0.0.1 --directory /你的公开插画素材目录
```

在另一个终端运行上述截图命令，增加环境变量 `SILLYDRAFT_REQUIRE_ILLUSTRATION=true` 和参数 `--dart-define=STORE_ILLUSTRATION_URL=http://127.0.0.1:8769/示例.png`。会额外导出真实插画详情页 `illustration.png`；窄屏还会导出含操作按钮的 `illustration-details.png`。只接受本机回环地址，导入发生在临时作品库；此图是导入示例，不冒充应用内模型生成结果。完成后关闭临时服务。

## 集中备份

在 Git 工作区之外保留一个私人目录，包含：发布 `.p12` 与密码、公开证书、`.mobileprovision`、Team/Key/Issuer/Apple ID、API `.p8`、工作流和源码快照、商店文案/隐私稿/审核说明、截图原图与设计源文件、每次正式 IPA/archive/dSYM、审核往来和最终发布记录。

整个目录应存到加密备份介质或可信加密存储；它包含发布私钥和恢复密码，不能公开分享。`.cer` 不能代替 `.p12`，GitHub Secrets 也不能反向取回原值。证书申请的 CSR 只在重新申请时有参考价值；对应私钥必须备份。尚未取得的材料保留明确待办，不能创建空文件假装已备份。
