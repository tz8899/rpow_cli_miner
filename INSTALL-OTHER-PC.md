# 给别人电脑安装使用教程

这个目录是 RPOW2 GPU CLI miner 的可分发版本。对方拿到压缩包后，按下面步骤操作即可。

## 1. 解压

把压缩包解压到一个普通目录，例如：

```text
C:\Users\你的用户名\Downloads\rpow-cli-miner
```

或 Linux：

```text
/home/你的用户名/rpow-cli-miner
```

## 2. 安装 Node.js

需要 Node.js 18 或更新版本。

检查：

```bash
node -v
```

如果没有 Node.js，先安装 Node.js LTS。

## 3. 安装 GPU 编译环境

### Linux / Ubuntu

安装基础工具和 CUDA Toolkit，确保 `nvcc` 可用：

```bash
nvcc --version
nvidia-smi
```

然后进入项目目录编译：

```bash
chmod +x build-native.sh
CUDA_ARCH=sm_120 ./build-native.sh
```

如果不是 RTX 50 系列，替换 `CUDA_ARCH`：

```text
RTX 40 系列: sm_89
RTX 30 系列: sm_86
RTX 20 系列: sm_75
RTX 50 系列: sm_120
```

### Windows

安装：

```text
Node.js 18+
NVIDIA Driver
CUDA Toolkit
MSYS2 / gcc
```

确认 PowerShell 里能运行：

```powershell
node -v
nvcc --version
nvidia-smi
```

编译：

```powershell
$env:CUDA_ARCH="sm_120"
.\build-native.ps1
```

## 4. 登录账号

```bash
node rpow-cli.js login --email you@example.com
node rpow-cli.js complete-login --link "邮箱收到的登录链接"
node rpow-cli.js me
```

登录后会生成：

```text
.rpow-cli-state.json
```

这个文件是个人账号状态，不能分享给别人。

## 5. 先跑一次测试

```bash
node rpow-cli.js mine --count 1 --engine gpu --workers 16 --device 0
```

看到 `mint/claim accepted` 就说明可用。

## 6. 长期运行推荐命令

```bash
node pipeline-miner.js --count 1000000 --challenge-concurrency 10 --queue-size 30 --mint-concurrency 10 --workers 16 --device 0 --local-size 256 --rounds 128
```

后台运行 Linux 示例：

```bash
nohup node pipeline-miner.js --count 1000000 --challenge-concurrency 10 --queue-size 30 --mint-concurrency 10 --workers 16 --device 0 > pipeline-console.log 2>&1 &
```

查看日志：

```bash
tail -f pipeline-miner.log
```

## 7. 常见问题

### 找不到 `rpow-gpu-miner`

说明 GPU miner 没编译成功。重新运行：

```bash
CUDA_ARCH=sm_120 ./build-native.sh
```

Windows：

```powershell
$env:CUDA_ARCH="sm_120"
.\build-native.ps1
```

### 找不到 `nvcc`

CUDA Toolkit 没装好，或者 PATH 没配置。先修 CUDA 环境。

### 登录失败或未授权

重新登录：

```bash
node rpow-cli.js logout
node rpow-cli.js login --email you@example.com
node rpow-cli.js complete-login --link "新的登录链接"
```

### GPU 算得快但 mint 慢

这是接口等待，不是显卡慢。长期运行用 `pipeline-miner.js`，不要只用单次 `rpow-cli.js mine`。

## 8. 不要分享的文件

不要把这些发给别人：

```text
.rpow-cli-state.json
*.log
worker-logs/
worker-states/
```