# 本地构建镜像和 Live ISO

本文记录在 `ayaneo-am02.lan` 上绕过 GitHub Actions、直接使用 Podman 和
`just` 构建 AeroCore-OS 镜像及安装 ISO 的流程。

## 前置条件

目标主机需要安装并可执行：

```bash
just --version
podman --version
skopeo --version
```

构建会占用较多磁盘空间和网络流量。本文示例使用 `sudo podman`，因此镜像
必须始终使用同一套 Podman storage；不要在同一流程中混用 rootless Podman
和 rootful Podman。

## 1. 准备源码和基础镜像

```bash
cd ~/Workspace/AeroCore-OS
git status --short

export BASE_IMAGE="ghcr.io/ublue-os/bazzite-deck:stable"
export LIVE_BASE_IMAGE="quay.io/fedora/fedora-kinoite:44"
export IMAGE_BRANCH=stable
export VERSION_TAG=local-test

sudo -E podman pull "$BASE_IMAGE"
```

排查历史版本时必须固定 digest，不要使用会漂移的 `:stable`。例如本次 F43
复现使用了 Bazzite 最后一个 F43 stable digest：

```bash
export BASE_IMAGE="ghcr.io/ublue-os/bazzite-deck@sha256:d63c82406dfb8c0dbd451b579150175fad27a39f9a835f4811d00906b61853b8"
export LIVE_BASE_IMAGE="quay.io/fedora/fedora-kinoite:43"
export FEDORA_VERSION=43
```

## 2. 构建操作系统容器镜像

```bash
sudo -E just build localhost/aerocore-os local-test
```

`just build` 只构建本地操作系统镜像，不会自动生成 ISO。构建后可以检查
Fedora 版本和镜像信息：

```bash
sudo podman run --rm --entrypoint /usr/bin/rpm \
  localhost/aerocore-os:local-test -E %fedora
sudo podman image inspect localhost/aerocore-os:local-test \
  --format '{{.Id}} {{.Digest}}'
```

## 3. 执行 OSTree rechunk（与 CI 一致）

当前 CI 的完整镜像流程还会执行 `ostree-rechunk`：

```bash
sudo podman tag localhost/aerocore-os:local-test aerocore-os:local-test
sudo -E just ostree-rechunk aerocore-os local-test
```

注意：该 recipe 期望传入不带 `localhost/` 的镜像名。直接传入
`localhost/aerocore-os` 会被 recipe 拼成 `localhost/localhost/aerocore-os`，
随后尝试访问 `https://localhost/v2/`，这是命名错误，不是 registry 故障。

如需诊断 rechunk 是否导致 payload 损坏，应在执行本步骤前另建一个镜像 tag，
保留一份未 rechunk 的镜像作为对照。

## 4. 构建 Live ISO

在包含 `installer/` 和 `just_scripts/build-installer-iso.sh` 的源码树中执行：

```bash
export FEDORA_VERSION=43
export LIVE_BASE_IMAGE="quay.io/fedora/fedora-kinoite:43"
export IMAGE_TAG=f43-local-repro

sudo -E just build-live-installer aerocore-os f43-local-repro
```

构建脚本会下载 Fedora 对应版本的安装器 builder，并把本地镜像作为 payload
嵌入 ISO。首次构建会下载大量 RPM，耗时较长；后续构建可复用 Podman 和安装器
缓存。

产物位于：

```text
output/aerocore-os-f43-local-repro-amd64.iso
output/aerocore-os-f43-local-repro-amd64.iso-CHECKSUM
```

校验：

```bash
sha256sum output/aerocore-os-f43-local-repro-amd64.iso
cat output/aerocore-os-f43-local-repro-amd64.iso-CHECKSUM
```

本次实际生成的 F43 复现产物为：

```text
output/aerocore-os-f43-repro-32418033581-amd64.iso
SHA-256: 6ce0b7a03eae32209df5c6a580f7bd0d66113380c73afc7afc651483d57d4a05
```

## 5. F44 本地构建示例

验证当前仓库时，将版本参数统一为 F44，并使用一个不会与发布 tag 混淆的本地
tag：

```bash
cd ~/Workspace/AeroCore-OS
export BASE_IMAGE="ghcr.io/ublue-os/bazzite-deck@<固定的-F44-digest>"
export LIVE_BASE_IMAGE="quay.io/fedora/fedora-kinoite:44"
export FEDORA_VERSION=44

sudo -E podman pull "$BASE_IMAGE"
sudo -E just build localhost/aerocore-os f44-local-test
sudo podman tag localhost/aerocore-os:f44-local-test aerocore-os:f44-local-test
sudo -E just ostree-rechunk aerocore-os f44-local-test
sudo -E just build-live-installer aerocore-os f44-local-test
```

## 与 GitHub CI 的差异

本地流程等价于 CI 的核心构建步骤，但不会自动完成以下动作：

- 推送镜像到 GHCR 或其他 registry；
- 上传 ISO 和 checksum 到 R2；
- 生成 GitHub Actions artifact；
- 通过 workflow 的变量和权限检查选择发布 tag。

因此本地构建适合复现和 A/B 测试。测试 ISO 前应记录基础镜像 digest、源码
commit、`LIVE_BASE_IMAGE`、最终镜像 digest 和 ISO SHA-256，避免把不同版本的
payload 与 Live 环境混在一起。
