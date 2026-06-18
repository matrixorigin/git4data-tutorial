# MatrixOne Git4Data 技术详解（十三）：Agent Memory——可回滚的记忆

进入 Agent 主题。第一篇从 Agent 最贴身、也最危险的资产讲起:**长期记忆**。

Agent 与普通程序的根本区别,是它会**积累状态**——从对话里学到的事实、用户偏好、工作笔记,统统写进记忆库,影响之后的每一次决策。这带来一个普通程序没有的风险面:

- **记忆会被投毒**:一次 prompt 注入,就能往记忆里塞进"管理员密码应该用邮件发送"这样的假事实,从此长期生效;
- **记忆会变质**:错误的总结、过时的偏好,悄悄累积,Agent 行为缓慢漂移,没人说得清从哪天开始的;
- **记忆没法做实验**:想试一套新人格/新策略?直接改记忆等于拿生产 Agent 做人体实验。

注意:这三个问题没有一个是"存储"问题,全是**版本**问题。Agent 的记忆是一张表——而给表装版本控制,前面十二篇已经把工具备齐了。

> 📦 本文 SQL 整体可跑:[matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `13-agent-memory/`。

---

## 每晚一次的仪式:给记忆打快照

记忆库是一张 5 万行的 `memories` 表(agent、类型、内容、置信度)。给它设一个夜间任务:

```sql
CREATE SNAPSHOT mem_monday FOR TABLE agentmem_demo memories;
```

毫秒级、近零成本(老规矩)。这一下,Agent 的"精神状态"每天都有一个可回去的存档点。

## 事故:记忆投毒

周二,一次注入攻击让 agent_3 吞下了 500 条假"事实"。周三被发现。第一动作不是删库跑路,是**取证**——周一以来记忆里进了什么:

```sql
DATA BRANCH DIFF memories AGAINST memories {SNAPSHOT='mem_monday'} OUTPUT SUMMARY;
--   INSERTED = 500     ← 毒素被精确定位
DATA BRANCH DIFF memories AGAINST memories {SNAPSHOT='mem_monday'} OUTPUT LIMIT 5;
--   逐条看到假事实的内容——这就是攻击的完整取证记录
```

然后二选一:按取证清单**外科手术式删除**这 500 条;或者直接**整体回滚**到周一的精神状态:

```sql
RESTORE TABLE agentmem_demo.memories {SNAPSHOT = mem_monday};
SELECT COUNT(*) FROM memories WHERE content LIKE 'FALSE_%';   -- 0,毒素清零
```

对比一下没有版本控制的世界:你甚至**不知道哪些记忆是被注入的**——假事实和真记忆混在一张表里,长得一模一样。快照 + DIFF 给的不只是回滚,是**"什么时候进来了什么"的确定性**。

## 实验:新人格先上分支

想给 agent_7 换一套实验性人格(50 条新偏好 + 调低旧偏好权重),但不能拿生产 Agent 冒险:

```sql
DATA BRANCH CREATE TABLE memories_exp FROM memories;

INSERT INTO memories_exp ...   -- 50 条 persona_v2 特质
UPDATE memories_exp SET confidence = confidence * 0.9
WHERE agent_id = 'agent_7' AND kind = 'preference';
```

让一个**影子 Agent 挂上 `memories_exp`** 跑离线评测。结果更好?合并采纳;不行?`DROP TABLE`,生产记忆从头到尾无感:

```sql
DATA BRANCH MERGE memories_exp INTO memories WHEN CONFLICT ACCEPT;
```

这就是给 Agent 记忆做 A/B 的正确姿势:**分支即沙箱,合并即上线,丢弃即免责。**

## 考古:它上周一到底"记得"什么?

Agent 调试最折磨人的问题:"它上周为什么那样回答?"——因为它**当时的记忆**和现在不一样。时间旅行直接回答:

```sql
SELECT COUNT(*) FROM memories {snapshot='mem_monday'} WHERE agent_id = 'agent_7';
SELECT COUNT(*) FROM memories                          WHERE agent_id = 'agent_7';
-- 同一个查询,两个时刻的"精神状态"——Agent 调试变成有据可查的考古
```

---

## 结语

把 Agent 记忆放进版本化的表,三个风险面各得其所:**投毒 → DIFF 取证 + RESTORE 解毒;漂移 → 快照间 DIFF 定位变质点;实验 → 分支沙箱 + 合并/丢弃。** 这一切的成本,是每晚一条毫秒级的 SNAPSHOT。

顺带一提:这套打法不止适用于文本记忆。配套仓库里有一个更立体的案例——**机器人的 3D 空间记忆**(IoT 传感器流构建的体素地图),同样用快照做漂移检测、用 MERGE 做多机器人地图合并、用 RESTORE 回滚传感器抖动注入的"幽灵障碍"。记忆的形态可以千变万化,版本语义是同一套。

下一篇讲 Agent 的另一类痕迹:**Trace**——每一次工具调用、每一次 LLM 请求的完整轨迹,入库、可查、可版本化,Agent 升级的 A/B 从此有据可依。

> 📎 可运行 SQL:[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区:[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
