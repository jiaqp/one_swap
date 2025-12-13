# 更新日志

## v3.1 (2024-12-13) - 🛡️ 关键安全修复

### 🔥 修复的关键Bug

#### Bug #1: vm.overcommit_memory=2 导致内存分配失败
**问题描述：**
- v3.0 版本在小内存系统(<1GB)上设置 `vm.overcommit_memory=2`
- 这会严格限制内存分配不超过 `swap + RAM × overcommit_ratio`
- 在swap还未创建时应用此参数，导致系统无法fork进程
- 表现为 `bash: fork: Cannot allocate memory` 错误

**修复方案：**
- ✅ 永不使用 `overcommit_memory=2`
- ✅ 小内存系统 (<512MB) 使用 `overcommit_memory=1` (允许超额)
- ✅ 正常系统使用 `overcommit_memory=0` (启发式，安全)

**影响范围：** 所有小内存系统 (<1GB)

---

#### Bug #2: 参数应用顺序错误
**问题描述：**
- v3.0 版本的应用顺序：
  1. 应用所有参数（包括 overcommit_memory=2）
  2. 创建 swap
- 导致在swap创建前，系统就已经被严格限制了内存分配

**修复方案：**
- ✅ 分阶段应用：
  - 阶段1: 应用安全参数（swappiness, dirty_ratio等）
  - 阶段2: 创建/调整 swap
  - 阶段3: 应用 overcommit 参数（带验证）

**影响范围：** 所有系统

---

#### Bug #3: min_free_kbytes 降低过多
**问题描述：**
- 在小内存系统上，v3.0 版本可能将 `min_free_kbytes` 从 37MB 降到 16MB
- 这会减少系统保留的空闲内存，增加内存分配失败的风险

**修复方案：**
- ✅ 极小内存系统 (<512MB): 保持原值不变
- ✅ 小内存系统 (<1GB): 最多降低 20%
- ✅ 正常系统: 使用计算值（安全范围内）

**影响范围：** 小内存系统 (<1GB)

---

### 🆕 新增功能

#### 1. 安全检查机制
应用参数前自动检查：
- ✅ 可用内存是否充足 (≥50MB)
- ✅ 磁盘空间是否足够创建swap
- ✅ 系统状态是否正常

#### 2. 自动回滚保护
- ✅ 应用overcommit参数后验证内存分配
- ✅ 检测到失败自动回滚到安全设置 (overcommit_memory=0)
- ✅ 记录回滚日志

#### 3. 紧急恢复指南
- ✅ 创建详细的 `EMERGENCY_RECOVERY.md` 文档
- ✅ 提供多种恢复方案（重启、VNC控制台、手动恢复）
- ✅ 说明问题根源和预防措施

---

### 📊 测试数据

#### 测试环境1: 阿里云 ECS (0.5GB内存)
**v3.0 (有问题):**
```
vm.overcommit_memory: 0 → 2
vm.min_free_kbytes: 37572 → 16384
结果: fork: Cannot allocate memory ❌
```

**v3.1 (修复后):**
```
vm.overcommit_memory: 0 → 1
vm.min_free_kbytes: 37572 → 37572 (保持不变)
结果: 系统正常运行 ✅
```

#### 测试环境2: 虚拟机 (2GB内存)
**v3.0 和 v3.1 对比:**
```
参数应用顺序优化
结果: 两版本都能运行，但v3.1更安全 ✅
```

---

### 🔄 迁移指南

#### 从 v3.0 升级到 v3.1

如果您已经运行了 v3.0 并遇到了问题：

**步骤1: 紧急恢复**
```bash
# 通过云控制台或VNC重启服务器

# 恢复备份配置
sudo cp /etc/sysctl.conf.backup.* /etc/sysctl.conf
sudo sysctl -p
```

**步骤2: 下载新版本**
```bash
wget https://raw.githubusercontent.com/jiaqp/one_swap/refs/heads/main/optimize_vm_enterprise.sh
```

**步骤3: 运行新版本**
```bash
sudo bash optimize_vm_enterprise.sh
```

---

### 📝 配置对比

| 参数 | v3.0 (小内存) | v3.1 (小内存) | 说明 |
|------|--------------|--------------|------|
| `overcommit_memory` | 2 ❌ | 1 ✅ | 允许超额分配 |
| `overcommit_ratio` | 50 | 100 | 更宽松的策略 |
| `min_free_kbytes` | 动态计算 ❌ | 保持原值 ✅ | 不降低保留内存 |
| 应用顺序 | 参数→swap ❌ | 安全参数→swap→overcommit ✅ | 分阶段应用 |

---

### 🙏 致谢

感谢用户报告此关键问题，让我们能够及时修复！

如果您在 v3.0 遇到了 "Cannot allocate memory" 错误，请查看 [紧急恢复指南](./EMERGENCY_RECOVERY.md)。

---

### 📞 反馈

如有问题或建议，请提交 Issue。

---

## v3.0 (2024-12-10) - 初始版本

### 功能
- ✅ 业界标准性能测试 (Sysbench + FIO)
- ✅ 商业级优化算法
- ✅ 虚拟化环境检测
- ✅ 自动应用优化

### 已知问题
- ❌ 小内存系统可能出现内存分配失败 (已在v3.1修复)

