# 打包和发布清单

目标：把当前项目打成一个干净包，给别人解压后可以自己登录、编译、运行。

## 必须打包

```text
README.md
INSTALL-OTHER-PC.md
PUBLICATION_GUIDE.md
.gitignore
rpow-cli.js
pipeline-miner.js
rpow-miner-worker.js
rpow-native-miner.c
rpow-gpu-miner.cu
build-native.sh
build-native.ps1
index.js
```

## 不要打包

```text
.rpow-cli-state.json
.rpow-cli-state.*.json
.env
*.log
worker-logs/
worker-states/
worker-pids.txt
node_modules/
rpow-native-miner
rpow-native-miner.exe
rpow-gpu-miner
rpow-gpu-miner.exe
batch-test.js
batch-test.log
prepare-440-single-workers.py
start-440-single-workers.py
release/
*.zip
```

原因：

- `.rpow-cli-state.json` 含账号 cookie/session。
- `*.log` 可能含运行记录。
- `worker-logs/`、`worker-states/` 是旧 CPU worker 运行产物。
- `rpow-gpu-miner`、`rpow-native-miner` 是本机编译产物，换机器可能不能用。
- `batch-test.js` 是测试脚本，不是给普通用户长期使用的入口。

## 推荐压缩包名

```text
rpow2-gpu-cli-miner-release.zip
```

## 发布前检查命令

在项目目录运行：

```bash
node rpow-cli.js map
node rpow-cli.js ledger
node rpow-cli.js --help
```

检查压缩包内容时，应只看到源码、脚本和文档，不应看到状态文件、日志或二进制。

## 给用户的最短使用说明

```bash
# 1. 编译
CUDA_ARCH=sm_120 ./build-native.sh

# 2. 登录
node rpow-cli.js login --email you@example.com
node rpow-cli.js complete-login --link "邮箱收到的登录链接"

# 3. 测试
node rpow-cli.js mine --count 1 --engine gpu --workers 16 --device 0

# 4. 长跑
node pipeline-miner.js --count 1000000 --challenge-concurrency 10 --queue-size 30 --mint-concurrency 10 --workers 16 --device 0 --local-size 256 --rounds 128
```

Windows 编译：

```powershell
$env:CUDA_ARCH="sm_120"
.\build-native.ps1
```

## GitHub 发布建议

仓库名：

```text
rpow2-gpu-cli-miner
```

描述：

```text
RPOW2 command-line miner with CUDA GPU pipeline mode and CPU fallback.
```

第一次提交不要用 `git add .`，建议明确添加文件：

```bash
git add README.md INSTALL-OTHER-PC.md PUBLICATION_GUIDE.md .gitignore rpow-cli.js pipeline-miner.js rpow-miner-worker.js rpow-native-miner.c rpow-gpu-miner.cu build-native.sh build-native.ps1 index.js
git status
git commit -m "Initial GPU CLI miner release"
```

## 如果要带二进制发布

源码包默认不带二进制。若你要给固定系统的人用，可以在 release 附件里单独放：

```text
rpow-gpu-miner        Linux CUDA 构建产物
rpow-gpu-miner.exe    Windows CUDA 构建产物
rpow-native-miner     Linux CPU native 构建产物
rpow-native-miner.exe Windows CPU native 构建产物
```

但要标清楚系统、CUDA 架构和显卡代际。RTX 5090 对应 `sm_120`。