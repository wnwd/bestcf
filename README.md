# bestcf

自维护的 Cloudflare 优选 IP 自动更新服务：定时在本机网络跑
[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 优选，
把最快 IP 通过 Cloudflare API 写进指定域名的 A 记录 —— 一个自建版的“优选 DDNS”。

客户端只需把节点地址填这个域名，优选 IP 再怎么漂移都自动跟上。

## 原理

```
cron 式循环 → cfst 测速（视角 = 本机所在网络）→ 筛出合格 IP 池
           → 按 targets.conf 的分组粘性分配 → Cloudflare API 更新各域名自己的 best 记录
```

- **多 IP 分发（分组 + 粘性）**：`targets.conf` 每行一条记录（域名 / 所属 zone / 分组），
  同组记录共用一个 IP；一组当前的 IP 只要还在合格池里就保持不动（粘性），
  掉出池才换池中最好的空闲 IP；池空了则全体不动。每台服务器用自己域名下的
  best 记录，单点风险和域名间关联都比全员共用一个 IP 更低。
- **合格池标准**：丢包 = 0，且延迟 ≤ 本轮最优延迟 × `LATENCY_FACTOR`（默认 2），
  同时不超过 `MAX_LATENCY_MS`（默认 300ms）。
- 测速视角决定一切：**容器跑在哪条线路上，优选的就是哪条线路的最优 IP**。
  家宽优选就必须跑在家里（如 N1），不要跑在云服务器上。
- 目标记录必须是 **DNS only（灰云）**：开了橙云代理，域名会解析到 CF 的
  anycast 地址而不是优选出的那个 IP，优选就白做了。脚本默认 `CF_PROXIED=false`。

## 部署（以 N1 为例，拉取已发布镜像）

镜像发布在 Docker Hub：`wnwd/bestcf`（多架构 amd64 + arm64，N1 直接拉 arm64 版）。

```bash
mkdir bestcf && cd bestcf
# 需要三个文件：docker-compose.yml、.env、targets.conf（后者只放部署机本地）
cp .env.example .env
vi .env            # 填 CF_API_TOKEN（须覆盖 targets.conf 里的全部 zone）
cp targets.conf.example targets.conf
vi targets.conf    # 填真实域名与分组——此文件不进 git、不进镜像
docker compose up -d
docker logs -f bestcf
```

从源码构建（可选）：`docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`
构建时按目标架构从 XIU2/CloudflareSpeedTest 的 Release 拉取 cfst 二进制打进镜像。

## 发布（GitHub Actions → Docker Hub）

推 main 或打 `v*` 标签会自动多架构构建并推送。仓库需先配好两个 Secrets：

| Secret | 值 |
| --- | --- |
| `DOCKERHUB_USERNAME` | **个人** Docker Hub 用户名（组织名不能登录！须是镜像所属组织的成员） |
| `DOCKERHUB_TOKEN` | 在该个人账号下创建的 Access Token（Read & Write） |

镜像名默认 `wnwd/bestcf`，可用仓库变量 `DOCKERHUB_IMAGE` 覆盖。

## 上游自动更新

镜像内的 cfst 版本由仓库根目录的 `CFST_VERSION` 文件锁定（构建时作为 build-arg 注入）。
`check-upstream` 工作流每周一检查 XIU2/CloudflareSpeedTest 的最新 Release：
有新版就自动更新该文件、提交，并触发发布工作流推出新镜像；没新版就静默跳过。
N1 侧想全自动跟随的话，再让 watchtower 之类的工具定时 `docker compose pull` 即可；
不想自动重启容器就手动 pull，节奏自定。

## API Token（最小权限）

Cloudflare 控制台 → 头像 → My Profile → API Tokens → Create Token →
用模板 **Edit zone DNS** → Zone Resources 选上 targets.conf 里出现的**全部 zone**
（一个 Token 可以覆盖多个 zone）。不要用 Global API Key。
Token 只写进 N1 本地的 `.env`，不进 git、不进聊天。

## 客户端用法

六个 media 节点各自用自己域名下的 best 记录（见 targets.conf）：

- 节点地址（server）填各自的 `best.<自己的域名>` —— 解析到该组当前分配的优选 IP
- SNI / Host 仍填各自的 `media.<域名>` —— CF 靠 SNI 分流，与入口 IP 无关
- 三组各持一个 IP：一组变质只影响组内两台，且粘性机制下多数轮次记录不变

从旧版（全员共用一条 best 记录）迁移：更新镜像与 targets.conf 后，
逐个把客户端节点的 server 地址改成各自的 best 记录即可；SNI 不动。

## 配置（.env）

| 变量 | 说明 |
| --- | --- |
| `CF_API_TOKEN` | 必填，须覆盖 targets.conf 里**全部 zone** 的 DNS Edit 权限 |
| `CF_TTL` | 默认 120 |
| `CF_PROXIED` | 默认且应保持 `false` |
| `RUN_INTERVAL` | 循环间隔秒数，默认 3600；设 0 = 只跑一轮就退出 |
| `CFST_ARGS` | 透传给 cfst 的参数（不要带 `-o`），默认 `-dn 10`（池要够分） |
| `MAX_LATENCY_MS` / `LATENCY_FACTOR` | 合格池门槛，默认 300 / 2 |
| `TARGETS_FILE` | 分发清单路径，默认 `/app/targets.conf`（compose 已挂载同名文件可覆盖） |

## 手动跑一轮 / 排查

```bash
docker compose run --rm -e RUN_INTERVAL=0 bestcf   # 立刻测速+更新一次
docker logs bestcf                                 # 看每轮的最优 IP 与写记录结果
```

常见问题：

- 日志 `zone not found`：Token 没包含该 zone，或 `CF_ZONE_NAME` 写错。
- 日志 `no valid best IP`：这一轮 cfst 没测出可用 IP（线路异常或参数过严），
  下一轮会自动重试；可放宽 `CFST_ARGS`（如去掉延迟上限类参数）。
- 解析到的不是优选 IP：检查该记录在 CF 控制台是不是灰云、TTL 是否太长、
  本地 DNS 缓存是否未过期。
