# HassOS-Actions 升级丢配置 + Action 编译问题 解决方案

## 用户报告

> "升级包升级完自定义的 nginx 和证书啥的就都没有了"

## 根因

HassOS 用 A/B partition + 整个 rootfs 升级的机制。`rootfs-overlay/` 里所有
文件**只编译时烧录到 rootfs**，**OTA 升级不保留**。

HassOS 官方提供 `/mnt/overlay` (hassos-overlay partition) 作为**升级保留的
配置层**，已有持久化路径：
- ✅ `/etc/hostname` `/etc/hosts` `/etc/systemd/timesyncd.conf`
- ✅ `/etc/NetworkManager/system-connections/`
- ✅ `/etc/modules-load.d/` `/etc/modprobe.d/` `/etc/udev/rules.d/`

**但缺用户的关键配置**：
- ❌ `/etc/nginx/nginx.conf`
- ❌ `/var/www/cert/` (SSL 证书)
- ❌ `/etc/ssl/certs/rootCA.cer`
- ❌ `/etc/docker/daemon.json` (大陆 docker 镜像源)

## 修法 (HassOS 官方 PR 3883 模式: bind mount + hassos-bind.target)

**思路**:
1. **首次启动**把 rootfs 的自定义配置**拷到 `/mnt/overlay/<path>`**
2. **systemd mount unit** 在启动时 **bind mount** 回原位
3. **升级后** rootfs 是新的（自定义没了），但 `/mnt/overlay` 是 data partition（**保留**）
4. bind mount 再次生效 — 配置"看起来没变"

## 改动清单 (5 个文件)

### 新增 4 个 systemd mount unit

- `rootfs-overlay/usr/lib/systemd/system/etc-nginx.mount`
  - `What=/mnt/overlay/etc/nginx` → `Where=/etc/nginx`
- `rootfs-overlay/usr/lib/systemd/system/var-www-cert.mount`
  - `What=/mnt/overlay/var/www/cert` → `Where=/var/www/cert`
- `rootfs-overlay/usr/lib/systemd/system/etc-ssl-certs.mount`
  - `What=/mnt/overlay/etc/ssl/certs` → `Where=/etc/ssl/certs`
- `rootfs-overlay/usr/lib/systemd/system/etc-docker.mount`
  - `What=/mnt/overlay/etc/docker` → `Where=/etc/docker`

每个 unit 模板：
- `After=mnt-overlay.mount` (overlay 先挂)
- `Before=nginx.service` / `Before=docker.service` (服务在挂后)
- `WantedBy=hassos-bind.target` (随系统启动)

### 修改 1: `rootfs-overlay/usr/sbin/hassos-cli`

**新增 `init_persistence` 函数**（启动时执行）：
- 检查每个自定义文件，如果 `/mnt/overlay/<path>` 不存在，**从 rootfs 拷过去**
- 启用上面 4 个 mount unit
- **幂等**: 已有文件不覆盖，保留用户后续修改

### 修改 2: `.github/workflows/HassOS-AutoBuild.yml`

**两个改进**:
- `git clone -b main` → `git clone -b stable` (避免 main 编译中断)
- `SYSTEM_SIZE=512M` → `SYSTEM_SIZE=1024M` for **所有** x86_64/aarch64/green/yellow
  (原只有 generic_x86_64 升级；Green 8GB eMMC 装组件时可能不够)

## 验证 (本地 docker 跑通)

### 1. YAML 语法 OK

```
$ python -c "import yaml; yaml.safe_load(open('HassOS-AutoBuild.yml'))"
✅ jobs: ['build']
   matrix targets: ['rpi3_64', 'rpi4_64', 'rpi5_64', 'ova', 'generic_x86_64',
                    'generic_aarch64', 'green', 'yellow']
```

### 2. shell 脚本语法 OK

```
$ sh -n rootfs-overlay/usr/sbin/hassos-cli  # exit 0
$ bash -n rootfs-overlay/usr/sbin/hassos-cli  # exit 0
```

### 3. systemd mount unit verify OK (在 rockylinux docker + systemd 跑)

```
=== etc-docker.mount      === exit: 0
=== etc-nginx.mount       === exit: 0
=== etc-ssl-certs.mount   === exit: 0
=== var-www-cert.mount    === exit: 0
```

### 4. init_persistence 端到端测试 (alpine docker)

```
[5high] 持久化 nginx.conf
[5high] 持久化 cert
[5high] 持久化 rootCA.cer
[5high] 持久化 daemon.json
--- /mnt/overlay 现有文件 ---
/mnt/overlay/etc/docker/daemon.json
/mnt/overlay/etc/nginx/nginx.conf
/mnt/overlay/etc/ssl/certs/rootCA.cer
/mnt/overlay/var/www/cert/github.com+1-key.pem
/mnt/overlay/var/www/cert/github.com+1.pem

=== 模拟第二次启动 (文件已存在, 应该跳过) ===
  二次 init 完成, 验证文件没被覆盖:
6bd1ba4a03e1ad0290da9d3212d74b1f  /mnt/overlay/etc/nginx/nginx.conf
6bd1ba4a03e1ad0290da9d3212d74b1f  /src/etc/nginx/nginx.conf
```

✅ 5 个文件全拷到 `/mnt/overlay`
✅ 第二次启动**跳过** (幂等)
✅ MD5 一致 (没破坏)

## Action 编译能否成功?

**完整 build 跑要 1-2 小时** + **buildroot 2-4 GB 工具链** (本地没空间) +
**qemu 跨平台编译** (本地 arm64 跑不动)，**所以无法本地跑完整 build**。

但:

- ✅ YAML 语法对
- ✅ shell 脚本语法对
- ✅ 4 个 systemd unit 都 `systemd-analyze verify` 通过
- ✅ init_persistence 端到端跑通

**实际 GH Action 跑**要 push 后看：
- 第一次跑会下 buildroot + 编译 8 个 target = 5-8 小时
- 看日志应该能编译过 (无新增破坏性改动)

## Action 的其他问题 (次要, 不影响升级丢配置)

1. **`sudo rm -rf /usr/share/` (line 66)** 危险 — 建议改成只删特定子目录
2. **第三方 action 没 hash pin** (`@main` `@v0.3.2`) — 供应链安全
3. **`wget secrets.KEY_URL/...` 没校验** — 加 SHA256
4. **secrets.KEY_URL 单点** — 拉取失败整个 build 停

这些可以后续单独 PR 修。

## 用户验证步骤

1. `git pull` 拉这 5 个改动
2. push 到 main, 触发 Action
3. 等编译完成 (5-8 小时)
4. 刷新镜像到设备, 首次启动看 `journalctl | grep 5high` 应有:
   ```
   [5high] 持久化 nginx.conf 到 /mnt/overlay/etc/nginx/
   [5high] 持久化 cert 到 /mnt/overlay/var/www/cert/
   [5high] 持久化 rootCA.cer 到 /mnt/overlay/etc/ssl/certs/
   [5high] 持久化 daemon.json 到 /mnt/overlay/etc/docker/
   ```
5. **在 nginx 配置里改一行** (e.g. 加注释), 重启看持久化生效
6. **OTA 升级**到新编译的版本, **看 nginx/cert 还在不在** (应该都还在)
