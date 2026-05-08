# RPOW2 GPU CLI Miner

这是一个可分发的 RPOW2 命令行 miner。当前主路径是 CUDA GPU 版，适合 RTX 50 系列等 NVIDIA 显卡；同时保留 CPU native 版和 Node.js fallback。


## 环境要求

### GPU 推荐环境

- Node.js 18 或更新版本
- NVIDIA 显卡
- NVIDIA 驱动可用
- CUDA Toolkit，必须能运行 `nvcc`
- Linux/macOS 用 `build-native.sh`，Windows 用 `build-native.ps1`

RTX 5090 默认使用 CUDA 架构：

```text
sm_120
```

如果别人的显卡不是 RTX 50 系列，可以让他按自己的 CUDA 架构设置 `CUDA_ARCH` 后重新编译。

常见参考：

```text
RTX 40 系列: sm_89
RTX 30 系列: sm_86
RTX 20 系列: sm_75
RTX 50 系列: sm_120
```

## 第一次使用教程

进入项目目录。

Linux：

```bash
cd rpow-cli-miner
chmod +x build-native.sh
./build-native.sh
```

Windows PowerShell：

```powershell
cd rpow-cli-miner
.\build-native.ps1
```

确认 CLI 可用：

```bash
node rpow-cli.js map
node rpow-cli.js ledger
```

登录账号：

```bash
node rpow-cli.js login --email you@example.com
node rpow-cli.js complete-login --link "把邮箱里收到的登录链接放这里"
node rpow-cli.js me
```

单次 GPU mint 测试：

```bash
node rpow-cli.js mine --count 1 --engine gpu --workers 16 --device 0
```

如果没有 GPU，可以使用 CPU native：

```bash
node rpow-cli.js mine --count 1 --engine native --workers 8
```

最慢的 Node.js fallback：

```bash
node rpow-cli.js mine --count 1 --engine node --workers 8
```

## 长期运行：GPU 流水线版

`pipeline-miner.js` 是当前推荐的长期运行脚本。它会持续并发拿 challenge，GPU 顺序求解，并并发提交 mint，用来减少等待接口造成的空转。

基础启动：

```bash
node pipeline-miner.js --count 1000000 --challenge-concurrency 10 --queue-size 30 --mint-concurrency 10 --workers 16 --device 0
```

常用参数：

```text
--count                  目标 mint 数量，默认很大
--challenge-concurrency  并发获取 challenge 数量，默认 10
--queue-size             challenge 队列上限，默认 30
--mint-concurrency       并发提交 mint 数量，默认 10
--workers                GPU miner 的 worker 参数，默认 16
--device                 GPU 编号，默认 0
--local-size             CUDA block size，默认 256
--rounds                 每个 CUDA thread 每批尝试 nonce 数，默认 128
--log                    日志文件路径，默认 pipeline-miner.log
--timeout                HTTP 超时，默认 60000 ms
--min-ttl-ms             challenge 剩余时间低于该值就丢弃，默认 20000 ms
```

RTX 5090 当前建议先用这组参数：

```bash
node pipeline-miner.js --count 1000000 --challenge-concurrency 10 --queue-size 30 --mint-concurrency 10 --workers 16 --device 0 --local-size 256 --rounds 128
```

后台运行示例：

```bash
nohup node pipeline-miner.js --count 1000000 --challenge-concurrency 10 --queue-size 30 --mint-concurrency 10 --workers 16 --device 0 > pipeline-console.log 2>&1 &
```

查看日志：

```bash
tail -f pipeline-miner.log
```

日志里看到下面这种行，说明成功：

```text
SUCCESS mint accepted ... minted=...
```

## 重新编译 GPU miner

Linux 默认：

```bash
./build-native.sh
```

指定 CUDA 架构：

```bash
CUDA_ARCH=sm_120 ./build-native.sh
CUDA_ARCH=sm_89 ./build-native.sh
CUDA_ARCH=sm_86 ./build-native.sh
```

Windows PowerShell：

```powershell
$env:CUDA_ARCH="sm_120"
.\build-native.ps1
```

如果提示找不到 `nvcc`，说明 CUDA Toolkit 没装好，或者 `nvcc` 不在 PATH。

## 常用命令

查看账号：

```bash
node rpow-cli.js me
```

查看 ledger：

```bash
node rpow-cli.js ledger
```

查看 activity：

```bash
node rpow-cli.js activity
```

退出登录并清空本地 cookie：

```bash
node rpow-cli.js logout
```

发送 RPOW：

```bash
node rpow-cli.js send --to friend@example.com --amount 1
```
