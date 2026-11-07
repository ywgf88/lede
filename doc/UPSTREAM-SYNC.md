# 自动同步上游 coolsnowwolf/lede

配套工作流：`.github/workflows/sync-upstream.yml`。

## 当前状态（2026-11-07 已部署）

- 工作流与本文档已在默认分支 `custom/mt7981` 上，部署 commit `0d578a2f4adaa5a10ad14ba264e5ced2011d8b5e`。
- `master` 镜像分支存在，指向 `55897b73604c`；与上游 `coolsnowwolf/lede:master` 一致。
- 已实跑一次 `dry_run`（run `42324702984`）：`success`，三个推送步骤全部 skipped，两个分支 SHA 前后未变，零副作用。
- 部署时点上游无新提交，故该次 dry_run 输出 `Already up to date at 55897b73604c`；**完整的快进 + 合并路径尚未实跑过**，第一次会在上游产生新 commit 后的那一轮定时同步中执行。
- 已验证「编译占用检测」：`actions/workflows/build-mt7981.yml/runs?status=in_progress` 在 run #3 编译期间返回 `total_count=1`，工作流会置 `busy=true` 并跳过对 `custom/mt7981` 的合并。
- 本地工作副本 `lede-src` 的 `custom/mt7981` 已与远端对齐到同一 commit，可直接 push。

## 分支结构与同步策略

| 分支 | 内容 | 谁可以改 |
|---|---|---|
| `master` | 与 `coolsnowwolf/lede:master` **逐字节一致的镜像** | 只由同步工作流快进，不要手工提交 |
| `custom/mt7981` | `master` + 9 个定制文件 + 两个工作流（**默认分支**） | 我们 |

每次同步做三件事：

1. 从上游拉取 `master`，计算新增 commit 数；没有更新就什么都不做。
2. 用 `git merge --ff-only` 把 fork 的 `master` 快进到上游并推送。
3. 若没有正在运行的固件编译，把 `master` 合并进 `custom/mt7981` 并推送；有编译在跑就跳过本轮，避免改动正在构建的代码。**冲突时**保留已同步的 `master`，不改动定制分支，并自动开一个 issue 提醒人工处理。

**同步不会自动编译**。推送用 `GITHUB_TOKEN`，GitHub 不会为由它产生的事件创建新的 workflow run，所以既不会启动 2–5 小时的编译，也不会 `cancel` 正在跑的编译。想要新固件时，去 Actions 手动运行 `Build LEDE MT7981 firmware`。

## 重新部署 / 迁移（文件必须在默认分支）

定时工作流只在**默认分支**上的文件中生效，因此 `sync-upstream.yml` 必须位于 `custom/mt7981` 的 `.github/workflows/` 下。当前已部署，以下仅在需要重传或迁到别的 fork 时用到：

- **网页（无需任何凭据）**：打开
  `https://github.com/ywgf88/lede/tree/custom/mt7981/.github/workflows`
  → `Add file` → `Upload files` → 上传本地 `sync-upstream.yml` → `Commit changes`。
  文档 `doc/UPSTREAM-SYNC.md` 可同样上传，非必需。
- **命令行**：从 fork 克隆一份，加入文件后推送。本地分析用的 `lede-src`
  已对齐到远端同一 commit，也可以直接改文件后 push：
  ```bash
  git clone -b custom/mt7981 https://github.com/ywgf88/lede.git lede-sync && cd lede-sync
  # 把 sync-upstream.yml 放到 .github/workflows/ 下
  git add .github/workflows/sync-upstream.yml && git commit -m "ci: sync upstream"
  git push
  ```

验证方式：Actions → **Sync upstream LEDE** → `Run workflow` → 勾选 `dry_run` → 运行。
**判读结果**：

| 日志输出 | 含义 |
|---|---|
| `Upstream advanced by N commits` | 上游有新提交，step summary 会列出前 15 条日志；后面三步因 `dry_run` 被跳过 |
| `Already up to date at <sha>` | 上游此刻没有新提交，后面三步因 `changed=false` 被跳过，**同样属于正常空转**，不代表 `dry_run` 生效与否 |

无论哪种，dry_run 都不产生任何推送。真要确认开关生效，可在上游有新提交时分别跑一次 `dry_run` 与正式同步对比。

## 定时与开关

```yaml
on:
  schedule:
    - cron: "23 3 * * 1,4"   # 每周一、周四 03:23 UTC = 北京 11:23
```

- cron 按 **UTC** 解释；避开整点可降低 GitHub 高负载排队延迟。
- 想改成每天：`cron: "23 3 * * *"`；想关掉定时、只保留手动：删除 `schedule:` 整段。
- 手动运行 `Run workflow` 时有两个开关：
  - `dry_run`：只看差异，不推送；
  - `skip_custom_merge`：只更新 `master` 镜像，不动 `custom/mt7981`。
- 公开仓库 **60 天无任何仓库活动**会自动禁用定时工作流；成功同步产生的推送本身就是活动。

## 手动同步（备用）

```bash
# GitHub CLI：只同步 master 镜像
gh repo sync ywgf88/lede -b master

# 或纯 git
git remote add upstream https://github.com/coolsnowwolf/lede.git
git fetch upstream master
git checkout master && git merge --ff-only upstream/master && git push origin master
git checkout custom/mt7981 && git merge --no-edit upstream/master && git push origin custom/mt7981
```

> **不要点仓库首页的 `Sync fork` 按钮的「Update branch」**。该按钮默认作用于**默认分支**，也就是 `custom/mt7981`；它背后调用 `POST /repos/{owner}/{repo}/merge-upstream`，语义是「让这个分支与上游一致」，对定制分支会返回 409 冲突或试图覆盖 9 个定制文件。同理，任何脚本里都不要对 `custom/mt7981` 调用 `merge-upstream`。

## 权限与常见问题

| 现象 | 处理 |
|---|---|
| `git push` 报 `Permission denied` / `protected branch` | Settings → Actions → General → Workflow permissions 选 **Read and write permissions**，然后重跑 |
| `gh api ... runs` 返回 403 | 工作流需要 `actions: read`，已在 `permissions` 中声明 |
| 合并冲突、自动开了 issue | 最可能是 `.gitattributes`（我们改过上游原文件）；按 issue 里的命令本地合并解决后推送 |
| `master` 快进失败（`--ff-only` 报错） | 说明有人手工提交过 `master`，用 `git log master..upstream/master` 检查后决定 reset 或手工合并 |
| 定时时间到了却完全没触发 | fork 的工作流默认需要先在 Actions 页启用；确认 **Sync upstream LEDE** 不是 disabled 状态，且文件确实在默认分支 `custom/mt7981` 上 |
| 同步后固件没更新 | 正常，同步不触发编译；手动运行 `Build LEDE MT7981 firmware` |

## 冲突后的人工处理

```bash
git clone https://github.com/ywgf88/lede.git && cd lede
git checkout custom/mt7981
git remote add upstream https://github.com/coolsnowwolf/lede.git
git fetch upstream
git merge upstream/master
# 解决冲突（通常是 .gitattributes），确认 9 个定制文件仍在：
git status --short
git push origin custom/mt7981
```

解决完可以关掉自动开的 issue。之后定时同步会恢复自动合并。
