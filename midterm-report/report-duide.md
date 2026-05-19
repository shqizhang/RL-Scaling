Cloud-Native LLM Serving 课题的核心课题是——在分布式云环境中实现高效、弹性、可观测的大模型推理服务，通过 Prefill/Decode 分离、KV Cache 复用、语义调度与自动扩缩容 来突破单卡瓶颈，实现规模化智能推理。该课题基于Nvidia Dynamo的PD分离架构部署，针对RL场景高GPU idel的情况，实现了 elastic role Switch和 decoder request consolidation的能力，基于该能力，实现更加弹性的Auto scaling的策略用于提高GPU的effective hour，减少 idel时间。

这是这个研究课题的核心价值，基于这个思路，将report重新修改，围绕着这个课题议题，遵循学术报告写作的模式，重新整理内容，更加符合学术报告的范本，可以依据参考RL-Scaling\midterm-report\report_sample.pdf的报告的模版和内容递进的关系，参照这个样本，完成一份完整的详细的具有递进关系的研究报告。所有可以参考的文档在C:\projects\IP\RL-Scaling\docs和C:\projects\IP\RL-Scaling\tutorial\scaling，同时需要再次学习分析实现PD Switch和request consolidation的代码，利用好这些资料，同时查询官方的必要的资料，完成每个小节的内容。

要求，每个章节的内容需要准确，结构清晰，要点明确，重点突出。需要配图的部分，用简图替代。

round 2
遵循 Prefill–Decode (PD) 分离范式的大语言模型 (LLM) 推理服务将计算划分到两类功能不同的 GPU 池中：prefill worker（计算密集型）和 decode worker（显存带宽密集型）。这种布局在在线服务场景下最大化了各阶段效率，
后面需要加上：基于当下的主流的PD分离的推理服务引擎的部署框架dynamo，本课题的重点是强化学习的场景下使用LLM推理服务面对的困难：高GPU限制的浪费。
根据这个衔接逻辑润色，再提出当前的问题, 完善摘要部分。另外，再次review文档和测试reportC:\projects\IP\RL-Scaling\test-scripts\reports，确认一下“：完整的 decode→prefill→decode 往返在 ≈ 850 ms 内完成；六个在途长 decode 请求（各有 > 1000 个已生成 token）可从目标 worker 迁出，零错误、平均 6.1 ms”文中所有的数据都需要和实际的准确的。

引言部分，前面先加一段简洁dynamo的内容作为后续的RL 场景下的Auto scaling的衔接。

2.1Prefill–Decode 分离这里是否需要增加一个图更合适？如果是的，再此处添加一个placeholder。

这些 CR 重建 WorkerSet——没有 etcd，没有中心化注册中心。关键的是，CR 是判断给定 pod 是否在聊天池中的唯一可观测真相来源。

确定一下我们实现PD Switch的关键是修改CR？还是modelcard还是DWMD还是别的什么术语？这里全文都需要准确和一致，或者从表述的层级上严格区分，请double check这个架构的准确实现和术语。

Prefill–Decode 分离这里需要介绍一下这是一种通用的部署实践，然后再解释这样的优势和prefill decode的工作原理。补上相关的逻辑递进，让报告更完整，逻辑更自洽。

NVIDIA Dynamo 运行时，这里是否需要一个dynamo的架构图？需要的话，同样加上placeholder作为提示。

3.1 部署拓扑
这里的9090端口是作为prefill或者decode对frontend router提供处理请求的端口是吗？那为了实现dualmode, 这个pod的endpoint和对外暴露的端口的关系是什么？我理解PD热切换是在部署的的时候允许这个worker起两个端口，比如启用A端口就是作为prefill，启动B端口就是作为decoder，还是都是9090一个端口？和sidecar 9091端口有什么关系和区别？需要在这个章节详细解释，不要让人产生误解。

模块边界的指责这一列的介绍也要review一遍术语的表达是够准确，所涉及的层级和术语需要严格对应。

4.1 问题陈述部分对场景的描述再详细一些，以及采用了状态机的机制也加上。

(a) 多 chunk 合并（commit a82816c3d6）(b) 单 TCP 槽分发器（commit fe78f1b652）去掉commit号。

由于 partner-prefill 在 d→p 方向发布 prefill MDC（p→d 方向重新发布 decode MDC），两个方向现在具有对称开销。这里的MDC是什么？和前面的CR ModelCard等是什么关系？总之这些术语需要做一个详细的整理和一致性的检查和修改。

弹性 PD 角色切换 (S2)去掉S2 以及后续的S3。
这个部分还需要加上一部分，RL-Scaling实现了PD Switch的逻辑是通过修改CR？CMD？的元数据，需要补充k8s是如何通过这些重新做部署上的service discovery，实现分布式的部署场景下， PD Switch后能够确保端到端的逻辑上的正确的，同时解释已经部署的pod name是没有变化的，解释原因，和如何通过测试观测或者确认确实实现了PD的role Switch。让这个部分的方案更加完整和准确。

解码器请求整合 (S3)去掉s1 s2 s3，全文中所有的 s1 s2 s3都需要用准确的描述来表达。
聊天 WorkerSet这个是官方的表述吗？准确的应该是怎样的，检查全文这里的表述，必要的话更改为准确的。

5.2 三阶段 Block-Hold 协议这里只展示NIXL 拉取（可选，快速）的方案，不需要提replay的方案。图里也需要与这个方案一致且确保KV的一致性，不会出错或者丢失。删掉和replay方案相关的内容。重点

进程内请求注册表这一章节替换为migrate的策略实现，解释是如何决定将哪个decode上的request migrate到哪个decode上，注册表的内容是其中一个环节，必要的话可以保留。

以上的修改建议，都需要在对应的中英文report上修改。注意，需要配图解释的部分，加上简图或者placeholder。