# 推送到 GitHub 的完整步骤

> 本资料包已在本地完成 `git init` + 首次提交（commit `d47e2b8`，28 个文件，作者 `PCLM50 Research`）。
> 你要做的只有：**建空仓库 → 改一条 remote → push**。

## 第 1 步：在 GitHub 建一个空仓库

打开 https://github.com/new ，填：

| 字段 | 建议值 |
|---|---|
| Repository name | **`pclm50-recovery-research`** |
| Description | `OPPO PCLM50 (Reno3 元气版) 逆向实测记录：lk 的 recovery 校验机制、自编 permissive 内核的 12 个构建卡点` |
| 可见性 | Public（想给后人看就选这个） |
| **Initialize this repository with** | **一个都不要勾**（不要 README / 不要 .gitignore / 不要 license）—— 否则会与本地已有提交冲突 |

建好后记下地址，形如：
```
https://github.com/<你的用户名>/pclm50-recovery-research.git
```

## 第 2 步：加 remote 并推送

```bash
cd /mnt/工作区/pclm50-report

# 把 <你的用户名> 换成真实的
git remote add origin https://github.com/<你的用户名>/pclm50-recovery-research.git

# 主分支名（GitHub 默认 main）
git branch -M main

git push -u origin main
```

推送时会提示输入用户名和密码 —— **密码位置要填 Personal Access Token（PAT），不是账号密码**。
GitHub 早在 2021 年就不支持密码推送了。

### 怎么生成 PAT

https://github.com/settings/tokens → *Generate new token (classic)* →
勾选 **`repo`** 这一项即可 → 生成后复制（只显示一次）→ 粘贴到密码提示处。

> 更省事的方式（推荐，不用 token）：
> ```bash
> # 用 SSH 而不是 HTTPS
> git remote add origin git@github.com:<你的用户名>/pclm50-recovery-research.git
> git push -u origin main
> ```
> 前提是你已经把 SSH 公钥加到 GitHub（https://github.com/settings/keys）。
> 本机已有密钥：`~/.ssh/id_ed25519.pub`

## 第 3 步（可选）：改署名

现在的 commit 作者是中性占位 `PCLM50 Research <pclm50-research@users.noreply.local>`。
如果想换成你自己：

```bash
cd /mnt/工作区/pclm50-report
git config user.name  "你的名字"
git config user.email "你的邮箱"
git commit --amend --reset-author --no-edit
git push -f -u origin main      # 已推送过才需要 -f
```

> 提醒：公开仓库里 commit 作者是**永久公开**的，用真邮箱等于公开邮箱。
> GitHub 支持 noreply 邮箱（`<数字>+<用户名>@users.noreply.github.com`）可以避免暴露真实邮箱。

## 第 4 步（可选）：完善仓库门面

建好仓库后建议在 GitHub 网页上加：

- **Topics**（标签，决定别人能不能搜到你）—— 一次性粘贴下面这一行到 Topics 输入框（逗号分隔，每粘贴一个会变成独立标签）：

  ```
  android,oppo,qualcomm,sm7250,lito,bootloader,avb,lk,kernel-module,kernel-build,twrp,recovery,apatch,kernelpatch,reverse-engineering,pclm50,reno3,verified-boot,vermagic,kernel-signature
  ```

  > GitHub 的 Topics 上限是 20 个，上面正好 20 个。优先保这 5 个（搜索量最大）：
  > `pclm50` `sm7250` `bootloader` `kernel-module` `twrp`
- **About → Website**：可留空
- **Releases**：把 `PCLM50-逆向实测记录-20261111.tar.gz`（307 KB）作为附件挂一个 release，
  方便别人一次性下载全部资料

## 找不到 Topics 在哪？

**路径一（推荐）**：打开仓库首页 → 看**右侧栏**（窄屏在下方）→ 找到 **About** 标题 → 点它右边的**齿轮图标 ⚙** → 弹出框里就有 **Topics** 输入框

**路径二**：直接访问 `https://github.com/<你的用户名>/pclm50-recovery-research` 后按上述找 About 齿轮

**路径三**：仓库 → Settings → 页面最下方 **Features** 区域也能找到 Topics

> 注意：Topics **不在** Settings 的常规位置，它是 About 弹窗里的。手机浏览器需要把页面拉到最底下才看得到 About。

## 找不到 Releases 在哪？

直接访问（需已登录）：
```
https://github.com/<你的用户名>/pclm50-recovery-research/releases/new
```

或者：仓库首页 → 右侧栏 → **Releases** → 右侧 **Create a new release**

> 如果访问 `/releases/new` 报 404，通常是因为**还没登录**，或者仓库名拼错。

## 一个安全提醒

推送前请再确认一遍仓库里**没有**这些东西（本项目已做过脱敏和检查）：

- [x] 设备序列号 —— 已替换为 `<DEVICE_SERIAL>`
- [x] 无密码 / token / API key
- [x] 无个人身份信息
- [ ] 你自己再扫一眼 `evidence/` 目录（那是设备原始日志，虽然已脱敏序列号，
      但里面可能有你的 Wi-Fi 配置、应用包名、运营商等痕迹 —— **公开前值得过一遍**）

```bash
# 快速自查
grep -rniE 'ssid|imei|iccid|imsi|手机号|password' /mnt/工作区/pclm50-report/evidence/ | head -20
```

## 如果以后想从这里继续

```bash
# 本地仓库位置
/mnt/工作区/pclm50-report

# 内核工程（1.9 GB，未纳入 git）
/mnt/工作区/pclm50-kernel/
  aosp/                     # 已配好的 AOSP 布局
  kernel.tar.gz             # 源码 170 MB
  modules.tar.gz            # 驱动 45 MB
  prepare_kernel.sh         # 幂等重打三道门
  fix_kernel_tree.py        # Kconfig 引用自动修复
  fix_headers.py            # 头文件自动补齐（含硬护栏）
```
