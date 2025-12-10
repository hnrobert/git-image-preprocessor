# Git Image Preprocessor

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Git%20Image%20Preprocessor-blue.svg?colorA=24292e&colorB=0366d6&style=flat&longCache=true&logo=github)](https://github.com/marketplace/actions/git-image-preprocessor)
[![License](https://img.shields.io/github/license/hnrobert/git-image-preprocessor)](https://github.com/hnrobert/git-image-preprocessor/blob/main/LICENSE)

自动压缩和优化 Git 仓库中的图片文件，支持 JPEG、PNG 和 WebP 格式。可以作为 GitHub Action 在 commit 和 PR 中自动运行。

## 特性

- **自动优化**：自动检测并优化仓库中的图片
- **可配置压缩质量**：支持自定义 JPEG、PNG、WebP 的压缩质量
- **尺寸调整**：可选的图片尺寸限制
- **格式转换**：可选择转换为 WebP 格式以获得更好的压缩率
- **隐私保护**：默认去除 EXIF 元数据信息（位置、设备等）
- **详细报告**：输出优化统计信息
- **即插即用**：易于集成到现有的 GitHub 工作流

### 限制输出文件大小（max-size-kb）

如果设置了 `max-size-kb`（以 KB 为单位），脚本在完成初始压缩（按照 `quality`）后会进一步尝试将最终文件压缩到不超过该大小。算法步骤：

- 先按照目标 `quality` 生成转换产物（保留原图）。
- 若文件体积超过 `max-size-kb`，脚本会尝试通过调整压缩质量或使用 `pngquant`（针对 PNG）进行再压缩，采用二分或估算策略来快速逼近目标体积。
- 脚本会迭代查找一个较优压缩参数，使最终结果落在 `[95% * max-size-kb, max-size-kb]` 的范围内；若无法达到则保留最接近且不超过最大值的结果。

注意：此功能对 JPEG/WebP 的效果更可控（通过 -quality 调节），对 PNG 则采用色深降低和 pngquant 处理，因此行为略有不同。默认值 `0` 表示禁用此限制。

## 🚀 快速开始

### 基础用法

在你的仓库中创建 `.github/workflows/image-optimization.yml`：

```yaml
name: Optimize Images

on:
  push:
    paths:
      - '**.jpg'
      - '**.jpeg'
      - '**.png'
      - '**.webp'

jobs:
  optimize:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Optimize Images
        uses: hnrobert/git-image-preprocessor@v1
        with:
          quality: 85
```

### PR 自动优化

```yaml
name: Optimize PR Images

on:
  pull_request:
    paths:
      - '**.jpg'
      - '**.jpeg'
      - '**.png'
      - '**.webp'

jobs:
  optimize:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.head_ref }}

      - name: Optimize Images
        uses: hnrobert/git-image-preprocessor@v1
        with:
          quality: 80
          max-width: 2000
          max-height: 2000
          commit-message: '🖼️ Auto-optimize images in PR'

      - name: Push changes
        run: git push
```

## ⚙️ 配置选项

| 参数             | 描述                                                                                  | 默认值                                         | 示例              |
| ---------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------- | ----------------- |
| `quality`        | JPEG/WebP 压缩质量 (1-100)                                                            | `85`                                           | `80`              |
| `max-width`      | 最大宽度（像素，0=不限制）                                                            | `0`                                            | `2000`            |
| `max-height`     | 最大高度（像素，0=不限制）                                                            | `0`                                            | `2000`            |
| `convert-to`     | 转换目标格式 (jpg/png/webp)                                                           | `""`                                           | `webp`            |
| `max-size-kb`    | 目标图片大小上限（KB），若为 `0` 则禁用大小限制                                       | `0`                                            | `200`             |
| `remove-exif`    | 去除 EXIF 元数据                                                                      | `true`                                         | `false`           |
| `git-user-name`  | Git 提交用户名                                                                        | `github-actions[bot]`                          | `my-bot`          |
| `git-user-email` | Git 提交邮箱                                                                          | `github-actions[bot]@users.noreply.github.com` | `bot@example.com` |
| `commit-message` | 提交信息                                                                              | `🖼️ Optimize images`                           | `优化图片`        |
| `file-patterns`  | 文件匹配模式                                                                          | `*.jpg *.jpeg *.png *.webp`                    | `*.png *.jpg`     |
| `skip-ci`        | 添加 [skip ci] 到提交信息                                                             | `false`                                        | `true`            |
| `convert-to`     | 将 HEIC/AVIF/TIFF/BMP/GIF 等非标准格式转换到指定目标 (jpg/png/webp)。如果为空则不转换 | `""`                                           | `webp`            |

## 📤 输出

| 输出              | 描述             |
| ----------------- | ---------------- |
| `optimized-count` | 优化的图片数量   |
| `total-saved`     | 总共节省的字节数 |
| `files-changed`   | 修改的文件列表   |

### 使用输出示例

```yaml
- name: Optimize Images
  id: optimize
  uses: hnrobert/git-image-preprocessor@v1
  with:
    quality: 85

- name: Show Results
  run: |
    echo "Optimized ${{ steps.optimize.outputs.optimized-count }} images"
    echo "Saved ${{ steps.optimize.outputs.total-saved }} bytes"
```

## 📝 使用场景

### 1. 自动优化所有提交的图片

```yaml
name: Auto Optimize Images

on:
  push:
    branches: [main, develop]

jobs:
  optimize:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hnrobert/git-image-preprocessor@v1
```

### 2. 高质量压缩

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    quality: 95
```

### 3. 激进压缩（更小的文件）

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    quality: 70
    max-width: 1920
    max-height: 1080
```

### 4. 转换为 WebP 格式

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    convert-to: webp
    quality: 85
```

### 8. 自动将 HEIC/AVIF/TIFF 等格式转换并优化

如果仓库中存在 HEIC/HEIF/AVIF/TIFF/BMP/GIF 等格式，设置 `convert-to`（例如 `convert-to: webp`）可以自动将这些格式转换为目标格式并进行优化：

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    # convert-to: webp  # set to desired target to enable conversion
    convert-to: webp
    quality: 80
    commit-message: 'chore: convert and optimize images'
```

在容器镜像中需要包含 ImageMagick (`convert`) 并启用 HEIC/AVIF 支持（例如安装 `libheif-dev` / `libavif-dev`），以支持自动转换和优化。

注意：当进行自动转换或优化时，默认会先应用 `remove-exif=true`（通过 ImageMagick 的 `-strip`），因此 EXIF 元数据会在转换前被移除（如果启用）。

### 5. 限制图片尺寸

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    max-width: 2048
    max-height: 2048
```

注意，脚本会保持图片的宽高比，不会强制拉伸或压缩图片。如果同时设置了 `max-width` 和 `max-height`，图片最终会根据更小的限制进行缩放。

### 6. 自定义提交信息

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    commit-message: 'chore: optimize images [skip ci]'
    git-user-name: 'Image Bot'
    git-user-email: 'bot@myproject.com'
```

### 7. 保留 EXIF 信息

如果需要保留照片的 EXIF 元数据（如拍摄日期、相机信息等）：

```yaml
- uses: hnrobert/git-image-preprocessor@v1
  with:
    remove-exif: false
```

> **注意**：默认情况下会去除 EXIF 信息以保护隐私和减小文件大小。EXIF 可能包含位置、设备等敏感信息。

## 🔧 支持的图片格式

- **JPEG/JPG**：使用 ImageMagick 优化，默认去除 EXIF
- **PNG**：使用 pngquant + optipng 优化，默认去除 EXIF
- **WebP**：使用 ImageMagick 优化，默认去除 EXIF

- **HEIC/HEIF/AVIF/TIFF/BMP/GIF**：脚本可检测这些常见但不总是受支持的格式；如果 `convert-to` 非空，会自动转换为 `convert-to` 指定的目标格式（jpg/png/webp），然后再进行优化。

## 📋 权限要求

在 PR 中使用时，需要授予 `contents: write` 权限：

```yaml
jobs:
  optimize:
    runs-on: ubuntu-latest
    permissions:
      contents: write
```

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

[MIT License](LICENSE)

## 🔗 相关链接

- [GitHub Marketplace](https://github.com/marketplace/actions/git-image-preprocessor)
- [源代码仓库](https://github.com/hnrobert/git-image-preprocessor)
- [问题反馈](https://github.com/hnrobert/git-image-preprocessor/issues)
